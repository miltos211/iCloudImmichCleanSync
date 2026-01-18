import Foundation
import SwiftData
import ImmichShared
import SwiftUI

@MainActor
class SyncManager: ObservableObject {
    @Published var isSyncing = false
    @Published var lastError: String?
    @Published var duplicateCheckProgress: String = ""
    @Published var duplicateCheckCurrent: Int = 0
    @Published var duplicateCheckTotal: Int = 0
    @Published var refreshProgress: String = ""
    @Published var isRefreshing: Bool = false
    @Published var uploadProgress: String = ""
    @Published var uploadCurrent: Int = 0
    @Published var uploadTotal: Int = 0
    
    private let photoManager = PhotoManager()
    private var immichClient: ImmichClient?
    private let modelContext: ModelContext
    
    init(modelContainer: ModelContainer) {
        // Create a new context for the manager
        self.modelContext = ModelContext(modelContainer)
        self.modelContext.autosaveEnabled = false // We will save manually
    }
    
    func configure(url: String, apiKey: String) {
        self.immichClient = ImmichClient(baseURL: url, apiKey: apiKey)
    }
    
    func startSync() async {
        guard let client = immichClient else {
            lastError = "Please configure settings first"
            return
        }
        
        isSyncing = true
        defer { isSyncing = false }
        
        do {
            // 1. Validate Connection
            if try await !client.validateConnection() {
                lastError = "Could not connect to Immich server"
                return
            }
            
            // 2. Scan Library (Discovery + DB Update)
            try await scanLibrary()
            
            // 3. Process Pending Assets
            try await processPendingAssets(client: client)
            
        } catch {
            lastError = error.localizedDescription
            print("Sync failed: \(error)")
        }
    }
    
    /// Public method to refresh library without uploading
    func scanLibrary() async throws {
        isRefreshing = true
        defer { isRefreshing = false }
        
        refreshProgress = "Clearing existing database..."
        Log("Clearing existing assets from database", category: "SyncManager")
        
        // Delete all existing assets
        let descriptor = FetchDescriptor<Asset>()
        let allAssets = try modelContext.fetch(descriptor)
        for asset in allAssets {
            modelContext.delete(asset)
        }
        try modelContext.save()
        
        refreshProgress = "Scanning iCloud Photo Library..."
        Log("Scanning iCloud Photo Library", category: "SyncManager")
        
        // Read settings from UserDefaults
        let syncPictures = UserDefaults.standard.bool(forKey: "syncPictures")
        let syncVideos = UserDefaults.standard.bool(forKey: "syncVideos")
        let uploadScreenshots = UserDefaults.standard.bool(forKey: "uploadScreenshots")
        
        // If syncPictures key doesn't exist, default to true
        let includePictures = UserDefaults.standard.object(forKey: "syncPictures") == nil ? true : syncPictures
        
        var allAssetInfos: [AssetInfo] = []
        
        // Fetch pictures (excluding screenshots unless uploadScreenshots is true)
        if includePictures {
            let imageAssets = try await photoManager.listAssets(
                type: .image,
                screenshotsOnly: false,
                excludeScreenshots: !uploadScreenshots
            )
            allAssetInfos.append(contentsOf: imageAssets)
        }
        
        // Fetch videos
        if syncVideos {
            let videoAssets = try await photoManager.listAssets(
                type: .video,
                screenshotsOnly: false,
                excludeScreenshots: false
            )
            allAssetInfos.append(contentsOf: videoAssets)
        }
        
        // Fetch screenshots separately if enabled and pictures are disabled
        if uploadScreenshots && !includePictures {
            let screenshotAssets = try await photoManager.listAssets(
                type: .image,
                screenshotsOnly: true,
                excludeScreenshots: false
            )
            allAssetInfos.append(contentsOf: screenshotAssets)
        }
        
        refreshProgress = "Adding \(allAssetInfos.count) assets to database..."
        Log("Found \(allAssetInfos.count) assets", category: "SyncManager")
        
        // Update Database
        try updateDatabase(with: allAssetInfos)
        
        refreshProgress = "Refresh complete"
        Log("Library refresh complete - \(allAssetInfos.count) assets added", category: "SyncManager")
    }
    
    private func updateDatabase(with assetInfos: [AssetInfo]) throws {
        // Since we cleared the database, all assets are new
        for info in assetInfos {
            let asset = Asset(
                id: info.id,
                originalFilename: "Pending...", // Don't know filename until export
                assetType: info.type,
                creationDate: Asset.parseDate(info.creationDate)
            )
            modelContext.insert(asset)
        }
        
        try modelContext.save()
        Log("Added \(assetInfos.count) new assets to database", category: "SyncManager")
    }
    
    /// Manually check for duplicates on server without uploading
    func checkDuplicates() async {
        guard let client = immichClient else {
            Log("Please configure settings first", level: .error, category: "SyncManager")
            duplicateCheckProgress = "Not configured"
            duplicateCheckCurrent = 0
            duplicateCheckTotal = 0
            return
        }
        
        do {
            duplicateCheckProgress = "Connecting to server..."
            duplicateCheckCurrent = 0
            duplicateCheckTotal = 0
            
            // Validate connection first
            if try await !client.validateConnection() {
                Log("Could not connect to Immich server", level: .error, category: "SyncManager")
                duplicateCheckProgress = "Connection failed"
                return
            }
            
            duplicateCheckProgress = "Fetching pending assets..."
            
            // Get all pending assets
            let descriptor = FetchDescriptor<Asset>(
                predicate: #Predicate<Asset> { $0.status == "pending" },
                sortBy: [SortDescriptor(\.creationDate)]
            )
            let pendingAssets = try modelContext.fetch(descriptor)
            
            if pendingAssets.isEmpty {
                Log("No pending assets to check", level: .info, category: "SyncManager")
                duplicateCheckProgress = "No pending assets"
                return
            }
            
            duplicateCheckTotal = pendingAssets.count
            Log("Checking \(pendingAssets.count) assets for duplicates...", level: .info, category: "SyncManager")
            
            // Use same deviceId as old Python script for compatibility
            let deviceId = "photo-sync-script"
            var markedCount = 0
            
            // Check in chunks of 500
            let chunks = stride(from: 0, to: pendingAssets.count, by: 500).map {
                Array(pendingAssets[$0..<min($0 + 500, pendingAssets.count)])
            }
            
            for (index, chunk) in chunks.enumerated() {
                let idsToCheck = chunk.map { $0.id }
                
                do {
                    let existingIds = try await client.checkAssets(deviceAssetIds: idsToCheck, deviceId: deviceId)
                    let existingSet = Set(existingIds)
                    
                    for (assetIndex, asset) in chunk.enumerated() {
                        duplicateCheckCurrent = (index * 500) + assetIndex + 1
                        duplicateCheckProgress = "Checking asset \(duplicateCheckCurrent) / \(duplicateCheckTotal)"
                        
                        if existingSet.contains(asset.id) {
                            asset.status = "completed"
                            asset.immichId = "existing"
                            asset.processedAt = Date()
                            markedCount += 1
                        }
                    }
                    try modelContext.save()
                } catch {
                    Log("Failed to check chunk: \(error.localizedDescription)", level: .error, category: "SyncManager")
                }
            }
            
            duplicateCheckProgress = "Found \(markedCount) duplicates"
            Log("Duplicate check complete: \(markedCount) assets already exist on server", level: .info, category: "SyncManager")
        } catch {
            Log("Duplicate check failed: \(error.localizedDescription)", level: .error, category: "SyncManager")
            duplicateCheckProgress = "Check failed"
        }
    }
    
    private func processPendingAssets(client: ImmichClient) async throws {
        uploadProgress = "Fetching pending assets..."
        uploadCurrent = 0
        uploadTotal = 0
        
        // Fetch specific batch of pending assets
        let descriptor = FetchDescriptor<Asset>(
            predicate: #Predicate<Asset> { $0.status == "pending" || ($0.status == "failed" && $0.retryCount < 3) },
            sortBy: [SortDescriptor(\.creationDate)]
        )
        let pendingAssets = try modelContext.fetch(descriptor)
        
        Log("Found \(pendingAssets.count) pending assets", category: "SyncManager")
        if pendingAssets.isEmpty { 
            uploadProgress = "No pending assets to upload"
            return 
        }
        
        uploadProgress = "Checking for duplicates..."
        
        // Deduplication Step: Check presence on server
        // Using same deviceId as old Python script for compatibility
        let deviceId = "photo-sync-script" 
        
        // Bulk check in chunks of 500
        let chunks = stride(from: 0, to: pendingAssets.count, by: 500).map {
            Array(pendingAssets[$0..<min($0 + 500, pendingAssets.count)])
        }
        
        for chunk in chunks {
            if !isSyncing { break }
            
            let idsToCheck = chunk.map { $0.id }
            
            do {
                Log("Checking existence for \(idsToCheck.count) assets...", level: .debug, category: "SyncManager")
                let existingIds = try await client.checkAssets(deviceAssetIds: idsToCheck, deviceId: deviceId)
                let existingSet = Set(existingIds)
                
                // Map results
                for asset in chunk {
                    if existingSet.contains(asset.id) { // using asset.id as deviceAssetId
                        Log("Skipping existing asset: \(asset.id)", level: .debug, category: "SyncManager")
                        asset.status = "completed"
                        asset.immichId = "existing" // We don't get the UUID back from this endpoint, but that's fine for dedupe
                        asset.processedAt = Date()
                    }
                }
                try modelContext.save()
            } catch {
                Log("Failed to check asset existence: \(error.localizedDescription)", level: .error, category: "SyncManager")
                // Continue, will try to upload and fail/dedupe there if needed
            }
        }
        
        // Re-fetch only those still pending after check
        // Note: In a real app we might optimize this, but this ensures we don't process completed ones
        let remainingDescriptor = FetchDescriptor<Asset>(
             predicate: #Predicate<Asset> { $0.status == "pending" || ($0.status == "failed" && $0.retryCount < 3) },
             sortBy: [SortDescriptor(\.creationDate)]
        )
        let assetsToUpload = try modelContext.fetch(remainingDescriptor)
        
        uploadTotal = assetsToUpload.count
        Log("Uploading \(uploadTotal) assets", category: "SyncManager")
        
        if uploadTotal == 0 {
            uploadProgress = "All assets already uploaded"
            return
        }
        
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("immich_upload")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        for (index, asset) in assetsToUpload.enumerated() {
            if !isSyncing { break }
            
            uploadCurrent = index + 1
            uploadProgress = "Uploading asset \(uploadCurrent) / \(uploadTotal)"
            
            do {
                Log("Processing asset \(uploadCurrent)/\(uploadTotal): \(asset.id)", category: "SyncManager")
                
                // Export
                let exportResult = try await photoManager.exportAsset(
                    assetId: asset.id,
                    outputDirectory: tempDir.path
                )
                
                // Update filename in DB
                asset.originalFilename = exportResult.metadata.originalFilename
                
                Log("Uploading \(exportResult.metadata.originalFilename) (\(exportResult.metadata.fileSize / 1024 / 1024) MB)", category: "SyncManager")
                
                // Upload
                let immichId = try await client.uploadAsset(
                    fileUrl: URL(fileURLWithPath: exportResult.filePath),
                    assetId: asset.id,
                    metadata: exportResult.metadata,
                    deviceId: deviceId
                )
                
                // Success
                asset.status = "completed"
                asset.immichId = immichId
                asset.processedAt = Date()
                asset.fileSize = exportResult.metadata.fileSize
                
                Log("Successfully uploaded: \(exportResult.metadata.originalFilename)", level: .info, category: "SyncManager")
                
                // Cleanup
                try? FileManager.default.removeItem(atPath: exportResult.filePath)
                
                try modelContext.save()
                
            } catch {
                Log("Failed to upload asset \(asset.id): \(error.localizedDescription)", level: .error, category: "SyncManager")
                asset.status = "failed"
                asset.errorMessage = error.localizedDescription
                asset.retryCount += 1
                try? modelContext.save()
            }
        }
        
        uploadProgress = "Upload complete"
        Log("Upload complete: \(uploadCurrent) assets processed", category: "SyncManager")
    }
}
