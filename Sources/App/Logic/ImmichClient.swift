import Foundation
import ImmichShared

enum ImmichError: Error {
    case invalidURL
    case authenticationFailed
    case serverError(Int)
    case networkError(Error)
    case decodingError(Error)
}

extension ImmichError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid server URL"
        case .authenticationFailed: return "Authentication failed (check API key)"
        case .serverError(let code): return "Server returned HTTP \(code)"
        case .networkError(let e): return "Network error: \(e.localizedDescription)"
        case .decodingError(let e): return "Could not decode server response: \(e.localizedDescription)"
        }
    }
}

actor ImmichClient {
    private let baseURL: String
    private let apiKey: String
    
    init(baseURL: String, apiKey: String) {
        // Normalize: remove trailing slashes and /api suffix
        var normalized = baseURL.trimmingCharacters(in: .init(charactersIn: "/"))
        if normalized.hasSuffix("/api") {
            normalized = String(normalized.dropLast(4))
        }
        self.baseURL = normalized
        self.apiKey = apiKey
    }
    
    /// Performs the request and logs one parseable line: `METHOD path -> HTTP status (ms)`.
    /// Non-2xx responses also log the (truncated) body; transport failures log the URLError.
    /// The API key header is never logged.
    private func perform(_ request: URLRequest, label: String, bodyFile: URL? = nil) async throws -> (Data, HTTPURLResponse) {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? "?"
        let fileBytes = bodyFile.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int }
        let bytesOut = fileBytes ?? request.httpBody?.count ?? 0
        let start = Date()
        func ms() -> Int { Int(Date().timeIntervalSince(start) * 1000) }
        
        let data: Data
        let response: URLResponse
        do {
            if let bodyFile {
                // Streamed from disk: the file is never loaded into memory
                (data, response) = try await URLSession.shared.upload(for: request, fromFile: bodyFile)
            } else {
                (data, response) = try await URLSession.shared.data(for: request)
            }
        } catch {
            let code = (error as? URLError).map { " code=\($0.code.rawValue)" } ?? ""
            Log("\(label): \(method) \(path) -> TRANSPORT ERROR\(code) (\(ms()) ms, sent \(bytesOut) B): \(error.localizedDescription)", level: .error, category: "ImmichClient")
            throw ImmichError.networkError(error)
        }
        
        guard let http = response as? HTTPURLResponse else {
            Log("\(label): \(method) \(path) -> non-HTTP response (\(ms()) ms)", level: .error, category: "ImmichClient")
            throw ImmichError.networkError(URLError(.badServerResponse))
        }
        
        let ok = (200...299).contains(http.statusCode)
        var line = "\(label): \(method) \(path) -> HTTP \(http.statusCode) (\(ms()) ms, sent \(bytesOut) B, received \(data.count) B)"
        if !ok {
            let body = String(data: data.prefix(500), encoding: .utf8) ?? "<binary>"
            line += " body=\(body)"
        }
        Log(line, level: ok ? .debug : .error, category: "ImmichClient")
        return (data, http)
    }
    
    /// Cheap unauthenticated reachability probe (GET /api/server/ping). `timeout` is user-configurable (Settings).
    /// Throws `.networkError` when the server can't be reached at all (VPN down, offline, DNS, timeout).
    func checkReachable(timeout: TimeInterval) async throws {
        guard let url = URL(string: "\(baseURL)/api/server/ping") else {
            throw ImmichError.invalidURL
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (_, http) = try await perform(request, label: "checkReachable")
        guard (200...299).contains(http.statusCode) else {
            throw ImmichError.serverError(http.statusCode)
        }
    }
    
    /// True when the error is specifically a timeout (no answer at all within the time limit).
    nonisolated static func isTimeout(_ error: Error) -> Bool {
        var inner = error
        if case ImmichError.networkError(let wrapped) = error { inner = wrapped }
        return (inner as? URLError)?.code == .timedOut
    }
    
    /// True when the error means "couldn't reach the server" (offline, VPN/Tailscale down, DNS, timeout),
    /// as opposed to the server answering with a rejection. Such failures should pause the sync, not fail assets.
    nonisolated static func isConnectivityError(_ error: Error) -> Bool {
        var inner = error
        if case ImmichError.networkError(let wrapped) = error { inner = wrapped }
        guard let urlError = inner as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .timedOut, .internationalRoamingOff, .dataNotAllowed:
            return true
        default:
            return false
        }
    }
    
    func validateConnection() async throws -> Bool {
        // User suggested /api-keys/me which returns the current key info
        guard let url = URL(string: "\(baseURL)/api/api-keys/me") else {
            throw ImmichError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        Log("Validating connection to \(url.absoluteString)", level: .debug, category: "ImmichClient")
        
        let (_, httpResponse) = try await perform(request, label: "validateConnection")
        
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw ImmichError.authenticationFailed
        }
        
        return httpResponse.statusCode == 200
    }
    
    struct ServerAsset {
        let id: String
        let originalFileName: String
    }
    
    private struct SearchResponse: Decodable {
        struct Page: Decodable {
            struct Item: Decodable {
                let id: String
                let originalFileName: String
            }
            let items: [Item]
            let nextPage: String?
        }
        let assets: Page
    }
    
    /// Every asset the key can see (timeline + archive), id and original file name only.
    /// Pages of 1000 (the server's maximum); roughly 1 request per 1000 assets.
    func listServerAssets(progress: (@MainActor (Int) -> Void)? = nil) async throws -> [ServerAsset] {
        guard let url = URL(string: "\(baseURL)/api/search/metadata") else {
            throw ImmichError.invalidURL
        }
        
        var all: [ServerAsset] = []
        for visibility in ["timeline", "archive"] {
            var page = 1
            while true {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.httpBody = try JSONSerialization.data(withJSONObject: [
                    "page": page, "size": 1000, "visibility": visibility, "withExif": false, "withPeople": false
                ] as [String: Any])
                
                let (data, http) = try await perform(request, label: "listServerAssets(\(visibility) page \(page))")
                guard (200...299).contains(http.statusCode) else {
                    throw ImmichError.serverError(http.statusCode)
                }
                
                let decoded: SearchResponse
                do {
                    decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
                } catch {
                    Log("listServerAssets: could not decode response: \(error) body=\(String(data: data.prefix(500), encoding: .utf8) ?? "<binary>")", level: .error, category: "ImmichClient")
                    throw ImmichError.decodingError(error)
                }
                
                all.append(contentsOf: decoded.assets.items.map { ServerAsset(id: $0.id, originalFileName: $0.originalFileName) })
                await progress?(all.count)
                
                guard let next = decoded.assets.nextPage, let nextPage = Int(next), nextPage > page else { break }
                page = nextPage
            }
        }
        return all
    }
    
    struct UploadCheckItem: Encodable {
        let id: String
        let checksum: String
    }
    
    private struct UploadCheckRequest: Encodable {
        let assets: [UploadCheckItem]
    }
    
    private struct UploadCheckResponse: Decodable {
        struct Result: Decodable {
            let id: String
            let action: String      // "accept" | "reject"
            let reason: String?     // "duplicate" | "unsupported-format"
            let assetId: String?
            let isTrashed: Bool?
        }
        let results: [Result]
    }
    
    /// Asks the server which of these files it already has (matched by SHA-1).
    /// Returns [local id: existing Immich asset id] for duplicates only.
    func bulkUploadCheck(_ items: [UploadCheckItem]) async throws -> [String: String] {
        guard let url = URL(string: "\(baseURL)/api/assets/bulk-upload-check") else {
            throw ImmichError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(UploadCheckRequest(assets: items))
        
        let (data, httpResponse) = try await perform(request, label: "bulkUploadCheck(\(items.count) files)")
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw ImmichError.serverError(httpResponse.statusCode)
        }
        
        do {
            let results = try JSONDecoder().decode(UploadCheckResponse.self, from: data).results
            var duplicates: [String: String] = [:]
            for r in results where r.action == "reject" && r.reason == "duplicate" {
                if let assetId = r.assetId { duplicates[r.id] = assetId }
            }
            let unsupported = results.filter { $0.reason == "unsupported-format" }.count
            Log("bulkUploadCheck: \(duplicates.count) duplicate, \(unsupported) unsupported, \(results.count - duplicates.count - unsupported) new", level: .debug, category: "ImmichClient")
            return duplicates
        } catch {
            Log("bulkUploadCheck: could not decode response: \(error) body=\(String(data: data.prefix(500), encoding: .utf8) ?? "<binary>")", level: .error, category: "ImmichClient")
            throw ImmichError.decodingError(error)
        }
    }
    
    func uploadAsset(fileUrl: URL, assetId: String, metadata: AssetMetadata, deviceId: String) async throws -> String {
        guard let url = URL(string: "\(baseURL)/api/assets") else {
            throw ImmichError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        // Build the multipart body on disk (off the actor, so parallel uploads don't queue behind each other's file copy)
        let fields: [(String, String)] = [
            ("deviceAssetId", assetId),
            ("deviceId", deviceId),
            ("fileCreatedAt", metadata.creationDate),
            ("fileModifiedAt", metadata.modificationDate),
            ("isFavorite", String(metadata.isFavorite)),
        ]
        let filename = metadata.originalFilename
        let bodyFile = try await Task.detached {
            try ImmichClient.writeMultipartFile(fileUrl: fileUrl, filename: filename, fields: fields, boundary: boundary)
        }.value
        defer { try? FileManager.default.removeItem(at: bodyFile) }
        
        let (data, httpResponse) = try await perform(request, label: "uploadAsset(\(filename))", bodyFile: bodyFile)
        
        if !(200...299).contains(httpResponse.statusCode) {
            throw ImmichError.serverError(httpResponse.statusCode)
        }
        
        struct UploadResponse: Decodable {
            let id: String
            let status: String?
        }
        
        do {
            let uploadResult = try JSONDecoder().decode(UploadResponse.self, from: data)
            // 201 = created, 200 = server already had this file (duplicate)
            Log("uploadAsset(\(filename)): status=\(uploadResult.status ?? "unknown") immichId=\(uploadResult.id)", category: "ImmichClient")
            return uploadResult.id
        } catch {
            Log("uploadAsset: could not decode response: \(error) body=\(String(data: data.prefix(500), encoding: .utf8) ?? "<binary>")", level: .error, category: "ImmichClient")
            throw ImmichError.decodingError(error)
        }
    }
    
    /// Writes the multipart/form-data body to a temp file, copying the asset in 1 MB chunks.
    nonisolated private static func writeMultipartFile(fileUrl: URL, filename: String, fields: [(String, String)], boundary: String) throws -> URL {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("immich-upload-\(UUID().uuidString).multipart")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let writer = try FileHandle(forWritingTo: out)
        defer { try? writer.close() }
        
        func write(_ text: String) throws { try writer.write(contentsOf: Data(text.utf8)) }
        
        for (name, value) in fields {
            try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        
        let mimeType = UTType(filenameExtension: fileUrl.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"assetData\"; filename=\"\(filename)\"\r\nContent-Type: \(mimeType)\r\n\r\n")
        
        let reader = try FileHandle(forReadingFrom: fileUrl)
        defer { try? reader.close() }
        while let chunk = try reader.read(upToCount: 1 << 20), !chunk.isEmpty {
            try writer.write(contentsOf: chunk)
        }
        
        try write("\r\n--\(boundary)--\r\n")
        return out
    }
}

import UniformTypeIdentifiers
