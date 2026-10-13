import Foundation
import SwiftData
import ImmichShared
import SwiftUI

@MainActor
class SyncManager: ObservableObject {
    @Published var isSyncing = false
    @Published var isStopping = false
    private var isCheckingDuplicates = false
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
    
    private var serverURL = ""
    
    func configure(url: String, apiKey: String) {
        self.serverURL = url
        self.immichClient = ImmichClient(baseURL: url, apiKey: apiKey)
    }
    
    /// Connection check timeout in seconds (Settings > Connection check timeout). 8 is the recommended default.
    private static var reachabilityTimeout: Int {
        let value = UserDefaults.standard.integer(forKey: "reachabilityTimeout")
        return value > 0 ? value : 8
    }
    
    /// Runs before every sync / duplicate check. Fails fast with a clear message when Immich can't be reached.
    private func ensureServerReachable(client: ImmichClient) async -> Bool {
        let seconds = Self.reachabilityTimeout
        do {
            try await client.checkReachable(timeout: TimeInterval(seconds))
            return true
        } catch {
            let url = URL(string: serverURL)
            let host = url?.host ?? serverURL
            let address = url?.port.map { "\(host):\($0)" } ?? host
            if ImmichClient.isTimeout(error) {
                lastError = "Can't reach Immich at \(address), health check got no answer after \(seconds)s."
            } else if ImmichClient.isConnectivityError(error) {
                lastError = "Can't reach Immich at \(address): \(error.localizedDescription)"
            } else {
                lastError = "Immich at \(address) answered unexpectedly: \(error.localizedDescription)"
            }
            Log("Server not reachable, not starting: \(lastError ?? "")", level: .error, category: "SyncManager")
            return false
        }
    }
    
    /// Called when a request fails because the server became unreachable mid-sync: stop starting new work and
    /// leave everything unfinished pending (no retry is burned).
    private func connectionLost() {
        guard !isStopping else { return }
        isStopping = true
        lastError = "Lost connection to Immich. Sync paused; press Start Sync once it is reachable again."
        uploadProgress = "Connection lost - pausing"
        Log("Connection to Immich lost, pausing sync", level: .error, category: "SyncManager")
    }
    
    func startSync() async {
        guard let client = immichClient else {
            lastError = "Please configure settings first"
            return
        }
        
        isSyncing = true
        isStopping = false
        lastError = nil
        defer {
            isSyncing = false
            isStopping = false
        }
        
        // 0. Is the server reachable at all? (every start/resume)
        guard await ensureServerReachable(client: client) else { return }
        
        do {
            // 1. Validate Connection (API key)
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
    
    /// Ask a running sync to stop. Assets already in flight finish (a few seconds, longer for big videos);
    /// nothing new is started, and everything not finished stays pending for the next run.
    func stopSync() {
        guard isSyncing, !isStopping else { return }
        isStopping = true
        uploadProgress = "Stopping... finishing in-flight assets"
        Log("Stop requested", category: "SyncManager")
    }
    
    /// Delete every locally tracked asset (status, Immich ids). The next scan starts from scratch.
    func resetDatabase() throws {
        Log("Resetting local database", category: "SyncManager")
        try modelContext.delete(model: Asset.self)
        try modelContext.save()
        refreshProgress = ""
    }
    
    /// Public method to refresh library without uploading.
    /// Merges with the existing database: known assets keep their status; only new ones are added.
    func scanLibrary() async throws {
        isRefreshing = true
        defer { isRefreshing = false }
        
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
        Log("Library refresh complete", category: "SyncManager")
    }
    
    private func updateDatabase(with assetInfos: [AssetInfo]) throws {
        // @Attribute(.unique) would upsert and reset status, so only insert ids we don't know yet
        let existingIds = Set(try modelContext.fetch(FetchDescriptor<Asset>()).map { $0.id })
        var added = 0
        for info in assetInfos where !existingIds.contains(info.id) {
            let asset = Asset(
                id: info.id,
                originalFilename: "Pending...", // Don't know filename until export
                assetType: info.type,
                creationDate: Asset.parseDate(info.creationDate)
            )
            modelContext.insert(asset)
            added += 1
        }
        
        try modelContext.save()
        Log("Added \(added) new assets to database (\(assetInfos.count - added) already known)", category: "SyncManager")
    }
    
    /// Local export name without extension. The exporter names files `asset_<localIdentifier with / as _>.<ext>`,
    /// and Immich keeps that as the original file name, so it identifies an asset on the server.
    private static func exportStem(forLocalId id: String) -> String {
        "asset_" + id.replacingOccurrences(of: "/", with: "_")
    }
    
    /// Marks pending assets the server already has as completed, without exporting anything.
    /// 1) by file name (list of the server's assets), 2) by stored SHA-1 for the rest. Returns how many were marked.
    @discardableResult
    private func dropServerDuplicates(client: ImmichClient, assets: [Asset]) async -> Int {
        var marked = 0
        
        do {
            duplicateCheckProgress = "Reading assets from server..."
            let serverAssets = try await client.listServerAssets { count in
                self.duplicateCheckProgress = "Reading assets from server... \(count)"
            }
            
            var idByStem: [String: String] = [:]
            for sa in serverAssets {
                idByStem[(sa.originalFileName as NSString).deletingPathExtension] = sa.id
            }
            let appNamed = idByStem.keys.filter { $0.hasPrefix("asset_") }.count
            Log("Server has \(serverAssets.count) assets, \(appNamed) named like this app's exports (asset_*). Sample: \(serverAssets.prefix(3).map { $0.originalFileName }.joined(separator: ", "))", category: "SyncManager")
            
            for (i, asset) in assets.enumerated() {
                if let existingId = idByStem[Self.exportStem(forLocalId: asset.id)] {
                    asset.status = "completed"
                    asset.immichId = existingId
                    asset.processedAt = Date()
                    marked += 1
                }
                if i % 200 == 0 { duplicateCheckCurrent = i; await Task.yield() }
            }
            try modelContext.save()
            Log("Matched \(marked) of \(assets.count) pending assets by file name", category: "SyncManager")
        } catch {
            Log("Name-based duplicate check failed: \(error.localizedDescription)", level: .error, category: "SyncManager")
        }
        
        // Anything exported before has a checksum, which also catches files that were renamed on the server
        let remaining = assets.filter { $0.status == "pending" }
        let withHash = remaining.filter { $0.sha1 != nil }.count
        if withHash > 0 {
            marked += await markExistingOnServer(client: client, assets: remaining)
        }
        duplicateCheckCurrent = assets.count
        return marked
    }
    
    /// Marks assets whose checksum the server already has as completed. Assets without a sha1 are ignored.
    /// Returns how many were marked. A failed chunk is logged and skipped (those assets just get uploaded normally).
    @discardableResult
    private func markExistingOnServer(client: ImmichClient, assets: [Asset]) async -> Int {
        let checkable = assets.filter { $0.sha1 != nil }
        var marked = 0
        
        for start in stride(from: 0, to: checkable.count, by: 500) {
            if (!isSyncing && !isCheckingDuplicates) || isStopping { break }
            let chunk = Array(checkable[start..<min(start + 500, checkable.count)])
            
            do {
                let duplicates = try await client.bulkUploadCheck(chunk.map { .init(id: $0.id, checksum: $0.sha1!) })
                for asset in chunk {
                    if let existingId = duplicates[asset.id] {
                        asset.status = "completed"
                        asset.immichId = existingId
                        asset.processedAt = Date()
                        marked += 1
                    }
                }
                try modelContext.save()
            } catch {
                Log("Failed to check chunk at \(start): \(error.localizedDescription)", level: .error, category: "SyncManager")
            }
            duplicateCheckCurrent = min(start + chunk.count, checkable.count)
        }
        return marked
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
        
        isCheckingDuplicates = true
        defer { isCheckingDuplicates = false }
        
        do {
            duplicateCheckProgress = "Connecting to server..."
            duplicateCheckCurrent = 0
            duplicateCheckTotal = 0
            
            // Reachable at all? (Tailscale/VPN), then is the API key accepted?
            guard await ensureServerReachable(client: client) else {
                duplicateCheckProgress = "Server unreachable"
                return
            }
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
            Log("Checking \(pendingAssets.count) pending assets for duplicates...", level: .info, category: "SyncManager")
            
            let markedCount = await dropServerDuplicates(client: client, assets: pendingAssets)
            
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
        
        // Same device id the old Python script used (still sent on upload for compatibility)
        let deviceId = "photo-sync-script"
        
        uploadProgress = "Checking for duplicates..."
        // Match against what is already on the server (by name, then by stored checksum) before exporting anything.
        // Files that match neither are checked once more, by checksum, right after their export.
        await dropServerDuplicates(client: client, assets: pendingAssets)
        
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
        
        // Each asset costs several ~200 ms round trips to the server plus an iCloud export, so run a few at once
        let workers = Self.uploadConcurrency
        Log("Processing \(uploadTotal) assets with \(workers) parallel workers", category: "SyncManager")
        
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            for asset in assetsToUpload {
                if !isSyncing || isStopping { break }
                if running >= workers {
                    await group.next()
                    running -= 1
                }
                group.addTask { @MainActor in
                    await self.processAsset(asset, client: client, tempDir: tempDir, deviceId: deviceId)
                }
                running += 1
            }
            await group.waitForAll()
        }
        
        if isStopping && lastError != nil {
            uploadProgress = "Paused (connection lost) after \(uploadCurrent) of \(uploadTotal)"
            Log("Sync paused: \(uploadCurrent) of \(uploadTotal) assets processed, the rest stay pending", category: "SyncManager")
        } else if isStopping {
            uploadProgress = "Stopped after \(uploadCurrent) of \(uploadTotal)"
            Log("Sync stopped: \(uploadCurrent) of \(uploadTotal) assets processed, the rest stay pending", category: "SyncManager")
        } else {
            uploadProgress = "Upload complete"
            Log("Upload complete: \(uploadCurrent) assets processed", category: "SyncManager")
        }
    }
    
    /// Number of assets processed at the same time (Settings > Parallel uploads, default 4).
    private static var uploadConcurrency: Int {
        let value = UserDefaults.standard.integer(forKey: "uploadConcurrency")
        return value > 0 ? min(value, 8) : 4
    }
    
    /// Export -> hash -> server check -> upload for one asset. Failures are recorded on the asset, never thrown.
    private func processAsset(_ asset: Asset, client: ImmichClient, tempDir: URL, deviceId: String) async {
        var exportedPath: String?
        defer {
            if let exportedPath { try? FileManager.default.removeItem(atPath: exportedPath) }
            uploadCurrent += 1
            uploadProgress = "Processed \(uploadCurrent) / \(uploadTotal)"
        }
        
        func ms(since start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }
        
        do {
            Log("Processing asset: \(asset.id)", level: .debug, category: "SyncManager")
            
            // Export
            var t = Date()
            let exportResult = try await photoManager.exportAsset(
                assetId: asset.id,
                outputDirectory: tempDir.path
            )
            exportedPath = exportResult.filePath
            let exportMs = ms(since: t)
            let name = exportResult.metadata.originalFilename
            asset.originalFilename = name
            
            // Hash the exported file so later runs can skip it without exporting again
            t = Date()
            let fileURL = URL(fileURLWithPath: exportResult.filePath)
            let sha1 = try await Checksum.sha1Hex(of: fileURL)
            asset.sha1 = sha1
            asset.fileSize = exportResult.metadata.fileSize
            try modelContext.save()
            let hashMs = ms(since: t)
            
            // Server already has this exact file? Skip the upload.
            t = Date()
            let known = (try? await client.bulkUploadCheck([.init(id: asset.id, checksum: sha1)])) ?? [:]
            let checkMs = ms(since: t)
            if let existingId = known[asset.id] {
                asset.status = "completed"
                asset.immichId = existingId
                asset.processedAt = Date()
                try modelContext.save()
                Log("Already on server, skipped upload: \(name) immichId=\(existingId) [export \(exportMs) ms, hash \(hashMs) ms, check \(checkMs) ms]", category: "SyncManager")
                return
            }
            
            // Upload
            t = Date()
            let sizeKB = exportResult.metadata.fileSize / 1024
            let immichId = try await client.uploadAsset(
                fileUrl: fileURL,
                assetId: asset.id,
                metadata: exportResult.metadata,
                deviceId: deviceId
            )
            let uploadMs = ms(since: t)
            
            asset.status = "completed"
            asset.immichId = immichId
            asset.processedAt = Date()
            try modelContext.save()
            
            let rate = uploadMs > 0 ? String(format: "%.2f", Double(sizeKB) / 1024.0 / (Double(uploadMs) / 1000.0)) : "-"
            Log("Uploaded \(name) (\(sizeKB) KB) [export \(exportMs) ms, hash \(hashMs) ms, check \(checkMs) ms, upload \(uploadMs) ms = \(rate) MB/s]", category: "SyncManager")
        } catch {
            if ImmichClient.isConnectivityError(error) {
                // Not this asset's fault: leave it pending (no retry burned) and pause the whole sync
                Log("Connection problem on asset \(asset.id), leaving it pending: \(error.localizedDescription)", level: .error, category: "SyncManager")
                connectionLost()
                return
            }
            Log("Failed to upload asset \(asset.id): \(error.localizedDescription)", level: .error, category: "SyncManager")
            asset.status = "failed"
            asset.errorMessage = error.localizedDescription
            asset.retryCount += 1
            try? modelContext.save()
        }
    }
}
