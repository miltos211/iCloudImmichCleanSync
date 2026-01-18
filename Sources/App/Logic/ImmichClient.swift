import Foundation
import ImmichShared

enum ImmichError: Error {
    case invalidURL
    case authenticationFailed
    case serverError(Int)
    case networkError(Error)
    case decodingError(Error)
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
    
    func validateConnection() async throws -> Bool {
        // User suggested /api-keys/me which returns the current key info
        guard let url = URL(string: "\(baseURL)/api/api-keys/me") else {
            throw ImmichError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        Log("Validating connection to \(url.absoluteString)", level: .debug, category: "ImmichClient")
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }
            
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw ImmichError.authenticationFailed
            }
            
            return httpResponse.statusCode == 200
        } catch {
            throw ImmichError.networkError(error)
        }
    }
    
    struct CheckRequest: Encodable {
        let deviceAssetIds: [String]
        let deviceId: String
    }
    
    struct CheckResponse: Decodable {
        let existingIds: [String]
    }
    
    func checkAssets(deviceAssetIds: [String], deviceId: String) async throws -> [String] {
        guard let url = URL(string: "\(baseURL)/api/assets/exist") else {
            throw ImmichError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        let body = CheckRequest(deviceAssetIds: deviceAssetIds, deviceId: deviceId)
        request.httpBody = try JSONEncoder().encode(body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw ImmichError.serverError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        
        let result = try JSONDecoder().decode(CheckResponse.self, from: data)
        return result.existingIds
    }
    
    func uploadAsset(fileUrl: URL, assetId: String, metadata: AssetMetadata, deviceId: String) async throws -> String {
        guard let url = URL(string: "\(baseURL)/api/assets") else {
            throw ImmichError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        let httpBody = try createMultipartBody(fileUrl: fileUrl, assetId: assetId, metadata: metadata, deviceId: deviceId, boundary: boundary)
        request.httpBody = httpBody
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ImmichError.networkError(URLError(.badServerResponse))
        }
        
        if !(200...299).contains(httpResponse.statusCode) {
            // Check for conflict (already exists code) if needed, but we rely on checkAssets mostly
            if let errorJson = String(data: data, encoding: .utf8) {
                print("Upload Error: \(errorJson)")
            }
            throw ImmichError.serverError(httpResponse.statusCode)
        }
        
        struct UploadResponse: Decodable {
            let id: String
        }
        
        let uploadResult = try JSONDecoder().decode(UploadResponse.self, from: data)
        return uploadResult.id
    }
    
    private func createMultipartBody(fileUrl: URL, assetId: String, metadata: AssetMetadata, deviceId: String, boundary: String) throws -> Data {
        var body = Data()
        let boundaryPrefix = "--\(boundary)\r\n"
        
        func appendField(_ name: String, _ value: String) {
            body.append(boundaryPrefix.data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        
        appendField("deviceAssetId", assetId)
        appendField("deviceId", deviceId)
        appendField("fileCreatedAt", metadata.creationDate)
        appendField("fileModifiedAt", metadata.modificationDate)
        appendField("isFavorite", String(metadata.isFavorite))
        
        // File Data
        body.append(boundaryPrefix.data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"assetData\"; filename=\"\(metadata.originalFilename)\"\r\n".data(using: .utf8)!)
        
        // Determine MIME type
        let mimeType = UTType(filenameExtension: fileUrl.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        
        let fileData = try Data(contentsOf: fileUrl)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)
        
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
        return body
    }
}

import UniformTypeIdentifiers
