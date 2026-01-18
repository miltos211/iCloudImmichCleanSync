import Foundation
import Photos

// MARK: - Photo Manager
@MainActor
public class PhotoManager {
    
    public init() {}
    
    // MARK: - Permission Handling
    public func requestPhotoLibraryAccess() async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        
        switch status {
        case .authorized, .limited:
            return true
        case .notDetermined:
            let newStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            return newStatus == .authorized || newStatus == .limited
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
    
    // MARK: - List Assets
    public func listAssets(
        type: MediaType,
        screenshotsOnly: Bool,
        excludeScreenshots: Bool
    ) async throws -> [AssetInfo] {
        // Ensure access first
        guard await requestPhotoLibraryAccess() else {
            throw PhotoManagerError.permissionDenied
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                Log("Fetching assets with type: \(type), screenshotsOnly: \(screenshotsOnly), excludeScreenshots: \(excludeScreenshots)", level: .debug, category: "PhotoManager")
                do {
                    // Build fetch options
                    let fetchOptions = PHFetchOptions()
                    
                    // Media type predicate
                    var predicates: [NSPredicate] = []
                    
                    switch type {
                    case .image:
                        predicates.append(NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue))
                    case .video:
                        predicates.append(NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue))
                    case .all:
                        predicates.append(NSPredicate(format: "mediaType == %d OR mediaType == %d", 
                                                    PHAssetMediaType.image.rawValue, 
                                                    PHAssetMediaType.video.rawValue))
                    }
                    
                    // Screenshot filtering
                    if screenshotsOnly {
                        predicates.append(NSPredicate(format: "mediaSubtypes & %d != 0", PHAssetMediaSubtype.photoScreenshot.rawValue))
                    } else if excludeScreenshots {
                        predicates.append(NSPredicate(format: "mediaSubtypes & %d == 0", PHAssetMediaSubtype.photoScreenshot.rawValue))
                    }
                    
                    fetchOptions.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
                    fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
                    
                    // Fetch assets
                    let assets = PHAsset.fetchAssets(with: fetchOptions)
                    var assetInfos: [AssetInfo] = []
                    
                    assets.enumerateObjects { asset, _, _ in
                        let assetInfo = AssetInfo(
                            id: asset.localIdentifier,
                            type: asset.mediaType == .image ? "image" : "video",
                            creationDate: self.formatDate(asset.creationDate),
                            isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot),
                            isLivePhoto: asset.mediaSubtypes.contains(.photoLive)
                        )
                        assetInfos.append(assetInfo)
                    }
                    
                    continuation.resume(returning: assetInfos)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Export Asset
    public func exportAsset(assetId: String, outputDirectory: String) async throws -> ExportResult {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                // Find asset by ID
                let fetchOptions = PHFetchOptions()
                fetchOptions.predicate = NSPredicate(format: "localIdentifier == %@", assetId)
                let assets = PHAsset.fetchAssets(with: fetchOptions)
                
                guard let asset = assets.firstObject else {
                    continuation.resume(throwing: PhotoManagerError.assetNotFound)
                    return
                }
                
                // Create output directory if needed
                let outputURL = URL(fileURLWithPath: outputDirectory)
                do {
                    try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
                } catch {
                    continuation.resume(throwing: PhotoManagerError.exportFailed("Cannot create output directory: \(error.localizedDescription)"))
                    return
                }
                
                // For Live Photos, only export the image component
                if asset.mediaSubtypes.contains(.photoLive) {
                    self.exportLivePhotoImageOnly(asset: asset, outputDirectory: outputDirectory) { result in
                        continuation.resume(with: result)
                    }
                } else if asset.mediaType == .image {
                    self.exportImage(asset: asset, outputDirectory: outputDirectory) { result in
                        continuation.resume(with: result)
                    }
                } else if asset.mediaType == .video {
                    self.exportVideo(asset: asset, outputDirectory: outputDirectory) { result in
                        continuation.resume(with: result)
                    }
                } else {
                    continuation.resume(throwing: PhotoManagerError.exportFailed("Unsupported media type"))
                }
            }
        }
    }
    
    // MARK: - Export Image
    private func exportImage(asset: PHAsset, outputDirectory: String, completion: @escaping (Result<ExportResult, Error>) -> Void) {
        let manager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.version = .original
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        
        // Request image data (preserves original format and metadata)
        manager.requestImageDataAndOrientation(for: asset, options: options) { data, dataUTI, orientation, info in
            guard let imageData = data,
                  let uniformTypeIdentifier = dataUTI else {
                completion(.failure(PhotoManagerError.exportFailed("Failed to get image data")))
                return
            }
            
            do {
                let result = try self.saveImageData(
                    imageData, 
                    asset: asset, 
                    outputDirectory: outputDirectory,
                    uniformTypeIdentifier: uniformTypeIdentifier
                )
                completion(.success(result))
            } catch {
                completion(.failure(error))
            }
        }
    }
    
    // MARK: - Export Live Photo (Image Only)
    private func exportLivePhotoImageOnly(asset: PHAsset, outputDirectory: String, completion: @escaping (Result<ExportResult, Error>) -> Void) {
        // For Live Photos, we use the same image export logic but mark it as Live Photo
        exportImage(asset: asset, outputDirectory: outputDirectory) { result in
            switch result {
            case .success(var exportResult):
                // Update metadata to reflect Live Photo status
                exportResult.metadata.isLivePhoto = true
                exportResult.metadata.livePhotoVideoComplement = nil // Video not exported
                completion(.success(exportResult))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
    
    // MARK: - Export Video
    private func exportVideo(asset: PHAsset, outputDirectory: String, completion: @escaping (Result<ExportResult, Error>) -> Void) {
        let manager = PHImageManager.default()
        let options = PHVideoRequestOptions()
        options.version = .original
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        
        manager.requestAVAsset(forVideo: asset, options: options) { avAsset, audioMix, info in
            guard let urlAsset = avAsset as? AVURLAsset else {
                completion(.failure(PhotoManagerError.exportFailed("Failed to get video URL")))
                return
            }
            
            do {
                let result = try self.saveVideoFile(
                    urlAsset.url,
                    asset: asset,
                    outputDirectory: outputDirectory
                )
                completion(.success(result))
            } catch {
                completion(.failure(error))
            }
        }
    }
    
    // MARK: - Save Image Data
    private func saveImageData(
        _ data: Data,
        asset: PHAsset,
        outputDirectory: String,
        uniformTypeIdentifier: String
    ) throws -> ExportResult {
        // Determine file extension
        let fileExtension = self.fileExtension(for: uniformTypeIdentifier)
        
        // Create unique filename
        let originalFilename = self.generateFilename(for: asset, extension: fileExtension)
        let outputURL = URL(fileURLWithPath: outputDirectory).appendingPathComponent(originalFilename)
        
        // Write file
        try data.write(to: outputURL)
        
        // Create metadata
        let metadata = AssetMetadata(
            originalFilename: originalFilename,
            creationDate: formatDate(asset.creationDate),
            modificationDate: formatDate(asset.modificationDate),
            location: extractLocation(from: asset),
            cameraMake: nil,
            cameraModel: nil,
            lensModel: nil,
            dimensions: Dimensions(width: Int(asset.pixelWidth), height: Int(asset.pixelHeight)),
            fileSize: data.count,
            mediaType: "image",
            format: fileExtension.uppercased(),
            duration: nil,
            fps: nil,
            isFavorite: asset.isFavorite,
            isHidden: asset.isHidden,
            burstIdentifier: asset.burstIdentifier,
            icloudStatus: "downloaded",
            isLivePhoto: asset.mediaSubtypes.contains(.photoLive),
            livePhotoVideoComplement: nil
        )
        
        return ExportResult(
            success: true,
            filePath: outputURL.path,
            metadata: metadata
        )
    }
    
    // MARK: - Save Video File
    private func saveVideoFile(
        _ sourceURL: URL,
        asset: PHAsset,
        outputDirectory: String
    ) throws -> ExportResult {
        // Create unique filename
        let originalFilename = self.generateFilename(for: asset, extension: "mov")
        let outputURL = URL(fileURLWithPath: outputDirectory).appendingPathComponent(originalFilename)
        
        // Copy video file
        try FileManager.default.copyItem(at: sourceURL, to: outputURL)
        
        // Get file size
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let fileSize = fileAttributes[.size] as? Int ?? 0
        
        // Create metadata
        let metadata = AssetMetadata(
            originalFilename: originalFilename,
            creationDate: formatDate(asset.creationDate),
            modificationDate: formatDate(asset.modificationDate),
            location: extractLocation(from: asset),
            cameraMake: nil,
            cameraModel: nil,
            lensModel: nil,
            dimensions: Dimensions(width: Int(asset.pixelWidth), height: Int(asset.pixelHeight)),
            fileSize: fileSize,
            mediaType: "video",
            format: "MOV",
            duration: asset.duration,
            fps: nil,
            isFavorite: asset.isFavorite,
            isHidden: asset.isHidden,
            burstIdentifier: asset.burstIdentifier,
            icloudStatus: "downloaded",
            isLivePhoto: false,
            livePhotoVideoComplement: nil
        )
        
        return ExportResult(
            success: true,
            filePath: outputURL.path,
            metadata: metadata
        )
    }
    
    // MARK: - Helper Methods
    private func generateFilename(for asset: PHAsset, extension: String) -> String {
        let assetId = asset.localIdentifier.replacingOccurrences(of: "/", with: "_")
        return "asset_\(assetId).\(`extension`)"
    }
    
    private func fileExtension(for uti: String) -> String {
        // Handle common UTI types
        switch uti {
        case "public.heic": return "heic"
        case "public.heif": return "heif"
        case "public.jpeg": return "jpg"
        case "public.png": return "png"
        case "public.tiff": return "tiff"
        case "com.apple.quicktime-movie": return "mov"
        case "public.mpeg-4": return "mp4"
        case "public.avi": return "avi"
        case "public.3gpp": return "3gp"
        case "public.mpeg": return "mpg"
        case "com.compuserve.gif": return "gif"
        case "public.jpeg-2000": return "jp2"
        case "com.adobe.pdf": return "pdf"
        case "public.bmp": return "bmp"
        case "com.adobe.photoshop-image": return "psd"
        case "public.pbm": return "pbm"
        case "public.webp": return "webp"
        case "public.avif": return "avif"
        case "public.dng": return "dng"
        case "com.canon.cr2-raw-image": return "cr2"
        case "com.nikon.nef-raw-image": return "nef"
        case "com.sony.arw-raw-image": return "arw"
        case "com.adobe.raw-image": return "dng"
        default:
            // Try to extract extension from UTI if it follows the pattern
            if uti.contains(".") {
                let parts = uti.components(separatedBy: ".")
                if let lastPart = parts.last, lastPart.count <= 4 {
                    // Common patterns like "public.xyz" or "com.company.xyz"
                    switch lastPart.lowercased() {
                    case "heic", "heif", "jpg", "jpeg", "png", "tiff", "tif", "gif", "bmp", "webp", "avif":
                        return lastPart.lowercased() == "jpeg" ? "jpg" : lastPart.lowercased()
                    case "mov", "mp4", "avi", "3gp", "mpg", "m4v":
                        return lastPart.lowercased()
                    default:
                        break
                    }
                }
            }
            // Last resort: return "dat" but this should rarely happen now
            return "dat"
        }
    }
    
    private func formatDate(_ date: Date?) -> String {
        guard let date = date else { return "" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
    
    private func extractLocation(from asset: PHAsset) -> Location? {
        guard let location = asset.location else { return nil }
        return Location(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitude: location.altitude
        )
    }
}

// MARK: - Error Types
public enum PhotoManagerError: Error, LocalizedError {
    case assetNotFound
    case exportFailed(String)
    case permissionDenied
    
    public var errorDescription: String? {
        switch self {
        case .assetNotFound:
            return "Asset not found"
        case .exportFailed(let message):
            return "Export failed: \(message)"
        case .permissionDenied:
            return "Photo library permission denied"
        }
    }
}