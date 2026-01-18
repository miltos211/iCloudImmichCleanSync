import ArgumentParser
import Photos
import ImmichShared

@main
struct PhotoExporter: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "photo-exporter",
        abstract: "Export photos and videos from iCloud Photo Library to local files",
        version: "1.0.0",
        subcommands: [ListAssets.self, ExportAsset.self]
    )
}

// MARK: - List Assets Command
struct ListAssets: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-assets",
        abstract: "List all photo and video assets from Photo Library"
    )
    
    @Option(name: .long, help: "Filter by media type")
    var type: MediaType = .all
    
    @Flag(name: .long, help: "Return only screenshots")
    var screenshotsOnly = false
    
    @Flag(name: .long, help: "Exclude screenshots")
    var noScreenshots = false
    
    func run() async throws {
        let photoManager = await PhotoManager()
        
        // Check PhotoKit permissions
        let hasPermission = await photoManager.requestPhotoLibraryAccess()
        guard hasPermission else {
            print(JSONEncoder.encodeError("PhotoKit permission denied", code: 2))
            Foundation.exit(2)
        }
        
        do {
            let assets = try await photoManager.listAssets(
                type: type,
                screenshotsOnly: screenshotsOnly,
                excludeScreenshots: noScreenshots
            )
            
            let jsonData = try JSONEncoder().encode(assets)
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                print(jsonString)
            }
            Foundation.exit(0)
        } catch {
            print(JSONEncoder.encodeError("Failed to list assets: \(error.localizedDescription)", code: 4))
            Foundation.exit(4)
        }
    }
}

// MARK: - Export Asset Command
struct ExportAsset: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export-asset",
        abstract: "Export a specific asset to local file"
    )
    
    @Argument(help: "Asset local identifier")
    var assetId: String
    
    @Argument(help: "Output directory path")
    var outputDirectory: String
    
    func run() async throws {
        let photoManager = await PhotoManager()
        
        // Check PhotoKit permissions
        let hasPermission = await photoManager.requestPhotoLibraryAccess()
        guard hasPermission else {
            print(JSONEncoder.encodeError("PhotoKit permission denied", code: 2))
            Foundation.exit(2)
        }
        
        do {
            let result = try await photoManager.exportAsset(
                assetId: assetId,
                outputDirectory: outputDirectory
            )
            
            let jsonData = try JSONEncoder().encode(result)
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                print(jsonString)
            }
            Foundation.exit(0)
        } catch PhotoManagerError.assetNotFound {
            print(JSONEncoder.encodeError("Asset not found: \(assetId)", code: 3))
            Foundation.exit(3)
        } catch {
            print(JSONEncoder.encodeError("Export failed: \(error.localizedDescription)", code: 4))
            Foundation.exit(4)
        }
    }
}

// MARK: - Media Type Enum
// MARK: - Media Type Extension
extension MediaType: ExpressibleByArgument {}

// MARK: - JSON Error Helper
extension JSONEncoder {
    static func encodeError(_ message: String, code: Int) -> String {
        let error = ErrorResponse(success: false, error: message, errorCode: code)
        if let data = try? JSONEncoder().encode(error),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return "{\"success\": false, \"error\": \"\(message)\", \"error_code\": \(code)}"
    }
}

struct ErrorResponse: Codable {
    let success: Bool
    let error: String
    let errorCode: Int
    
    enum CodingKeys: String, CodingKey {
        case success
        case error
        case errorCode = "error_code"
    }
}