import SwiftUI
import SwiftData
import ImmichShared
import Photos
import AVKit
import AVFoundation

struct AssetGridView: View {
    @EnvironmentObject var syncManager: SyncManager
    @Query(sort: \Asset.creationDate, order: .reverse) private var assets: [Asset]
    
    @AppStorage("immichUrl") private var immichUrl = ""
    @AppStorage("apiKey") private var apiKey = ""
    
    @State private var filter: AssetFilter = .pending
    @State private var gridColumns = [GridItem(.adaptive(minimum: 200, maximum: 200), spacing: 2)]
    @State private var showDuplicateProgress = false
    @State private var duplicateCheckMessage = ""
    @State private var selectedAsset: Asset?
    @State private var showImagePreview = false
    @State private var showRefreshProgress = false
    @State private var showUploadProgress = false
    
    enum AssetFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case pending = "Pending"
        case completed = "Completed"
        case failed = "Failed"
        
        var id: String { self.rawValue }
    }
    
    var filteredAssets: [Asset] {
        switch filter {
        case .all:
            return assets
        case .pending:
            return assets.filter { $0.status == "pending" }
        case .completed:
            return assets.filter { $0.status == "completed" }
        case .failed:
            return assets.filter { $0.status == "failed" }
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Top Bar
            HStack {
                Picker("Filter", selection: $filter) {
                    ForEach(AssetFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 300)
                
                Spacer()
                
                Button {
                    Task {
                        // Reset filter to show all pending
                        filter = .pending
                        showRefreshProgress = true
                        
                        do {
                            try await syncManager.scanLibrary()
                            try? await Task.sleep(for: .seconds(1)) // Show completion for 1 second
                        } catch {
                            Log("Refresh failed: \(error.localizedDescription)", level: .error, category: "AssetGrid")
                        }
                        
                        showRefreshProgress = false
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                
                Button {
                    Task {
                        syncManager.configure(url: immichUrl, apiKey: apiKey)
                        showDuplicateProgress = true
                        await syncManager.checkDuplicates()
                        try? await Task.sleep(for: .seconds(2)) // Show result for 2 seconds
                        showDuplicateProgress = false
                    }
                } label: {
                    Label("Check Duplicates", systemImage: "doc.on.doc")
                }
                .disabled(syncManager.isSyncing)
                
                Button {
                    Task {
                        syncManager.configure(url: immichUrl, apiKey: apiKey)
                        showUploadProgress = true
                        await syncManager.startSync()
                        try? await Task.sleep(for: .seconds(2)) // Show completion for 2 seconds
                        showUploadProgress = false
                    }
                } label: {
                    Label(syncManager.isSyncing ? "Syncing..." : "Sync Now", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(syncManager.isSyncing)
            }
            .padding()
            .background(Material.bar)
            
            // Grid
            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: 2) {
                    ForEach(filteredAssets) { asset in
                        AssetThumbnail(asset: asset)
                            .frame(width: 200, height: 200)
                            .clipped()
                            .onTapGesture {
                                selectedAsset = asset
                                showImagePreview = true
                            }
                    }
                }
                .padding(.bottom, 200) // Prevent overlap with sidebar
            }
        }
        .sheet(isPresented: $showRefreshProgress) {
            VStack(spacing: 20) {
                ProgressView()
                    .controlSize(.large)
                    .scaleEffect(1.5)
                
                Text(syncManager.refreshProgress)
                    .font(.headline)
                
                Text("Please wait...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 350, height: 200)
            .padding()
        }
        .sheet(isPresented: $showDuplicateProgress) {
            VStack(spacing: 20) {
                if syncManager.duplicateCheckTotal > 0 {
                    ProgressView(value: Double(syncManager.duplicateCheckCurrent), total: Double(syncManager.duplicateCheckTotal)) {
                        Text(syncManager.duplicateCheckProgress)
                            .font(.headline)
                    }
                    .progressViewStyle(.linear)
                    .frame(width: 300)
                    
                    Text("\(syncManager.duplicateCheckCurrent) / \(syncManager.duplicateCheckTotal)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .scaleEffect(1.5)
                    
                    Text(syncManager.duplicateCheckProgress)
                        .font(.headline)
                }
                
                Text("Please wait...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 350, height: 200)
            .padding()
        }
        .sheet(isPresented: $showUploadProgress) {
            VStack(spacing: 20) {
                if syncManager.uploadTotal > 0 {
                    ProgressView(value: Double(syncManager.uploadCurrent), total: Double(syncManager.uploadTotal)) {
                        Text(syncManager.uploadProgress)
                            .font(.headline)
                    }
                    .progressViewStyle(.linear)
                    .frame(width: 300)
                    
                    Text("\(syncManager.uploadCurrent) / \(syncManager.uploadTotal)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .scaleEffect(1.5)
                    
                    Text(syncManager.uploadProgress)
                        .font(.headline)
                }
                
                Text("Please wait...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 350, height: 200)
            .padding()
        }
        .sheet(isPresented: $showImagePreview) {
            if let asset = selectedAsset {
                FullImagePreview(asset: asset)
            }
        }
    }
}

struct AssetThumbnail: View {
    let asset: Asset
    @State private var image: NSImage?
    @State private var isLoading = false
    
    var body: some View {
        ZStack {
            if let image = image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .overlay {
                        if isLoading {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "photo")
                                .foregroundStyle(.secondary)
                        }
                    }
            }
            
            // Video Play Icon Overlay
            if asset.assetType == "video" {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
            }
            
            // Status Overlay
            VStack {
                HStack {
                    Spacer()
                    StatusIcon(status: asset.status)
                }
                Spacer()
            }
            .padding(4)
        }
        .task {
            await loadThumbnail()
        }
    }
    
    private func loadThumbnail() async {
        guard image == nil else { return }
        isLoading = true
        
        let id = asset.id
        
        // Fetch PHAsset
        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(format: "localIdentifier == %@", id)
        let assets = PHAsset.fetchAssets(with: fetchOptions)
        
        guard let phAsset = assets.firstObject else {
            isLoading = false
            return
        }
        
        // Request Image (works for both photos and video thumbnails)
        let manager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        
        let targetSize = CGSize(width: 600, height: 600) // Higher resolution for better quality
        
        manager.requestImage(for: phAsset, targetSize: targetSize, contentMode: .aspectFill, options: options) { result, info in
            if let result = result {
                self.image = result
            }
            self.isLoading = false
        }
    }
}

struct StatusIcon: View {
    let status: String
    
    var body: some View {
        Group {
            switch status {
            case "completed":
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .background(Circle().fill(.white))
            case "failed":
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .background(Circle().fill(.white))
            case "pending":
                Image(systemName: "cloud.fill")
                    .foregroundStyle(.secondary)
                    .background(Circle().fill(.white).opacity(0.8))
            default:
                EmptyView()
            }
        }
        .font(.system(size: 14))
        .shadow(radius: 2)
    }
}

struct FullImagePreview: View {
    let asset: Asset
    @State private var fullImage: NSImage?
    @State private var isLoading = true
    @State private var player: AVPlayer?
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        VStack {
            HStack {
                Text(asset.originalFilename)
                    .font(.headline)
                Spacer()
                Button("Close") {
                    player?.pause()
                    dismiss()
                }
            }
            .padding()
            
            if isLoading {
                ProgressView("Loading...")
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let player = player {
                VideoPlayerView(player: player)
                    .onDisappear {
                        player.pause()
                    }
            } else if let image = fullImage {
                GeometryReader { geometry in
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
            } else {
                Text("Failed to load media")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .task {
            // Fetch PHAsset to determine actual media type
            let fetchOptions = PHFetchOptions()
            fetchOptions.predicate = NSPredicate(format: "localIdentifier == %@", asset.id)
            let assets = PHAsset.fetchAssets(with: fetchOptions)
            
            if let phAsset = assets.firstObject {
                if phAsset.mediaType == .video {
                    await loadVideo()
                } else {
                    await loadFullImage()
                }
            } else {
                isLoading = false
            }
        }
    }
    
    private func loadVideo() async {
        let id = asset.id
        
        await MainActor.run {
            isLoading = true
        }
        
        // Fetch PHAsset
        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(format: "localIdentifier == %@", id)
        let assets = PHAsset.fetchAssets(with: fetchOptions)
        
        guard let phAsset = assets.firstObject else {
            await MainActor.run {
                isLoading = false
            }
            return
        }
        
        // Request video using continuation for proper async/await
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let manager = PHImageManager.default()
            let options = PHVideoRequestOptions()
            options.version = .current
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            
            manager.requestPlayerItem(forVideo: phAsset, options: options) { playerItem, info in
                Task { @MainActor in
                    if let playerItem = playerItem {
                        self.player = AVPlayer(playerItem: playerItem)
                        Log("Video loaded successfully", category: "FullImagePreview")
                    } else {
                        Log("Failed to load video", level: .error, category: "FullImagePreview")
                    }
                    self.isLoading = false
                    continuation.resume()
                }
            }
        }
    }
    
    private func loadFullImage() async {
        let id = asset.id
        
        // Fetch PHAsset
        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(format: "localIdentifier == %@", id)
        let assets = PHAsset.fetchAssets(with: fetchOptions)
        
        guard let phAsset = assets.firstObject else {
            isLoading = false
            return
        }
        
        // Request full resolution image
        let manager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        
        manager.requestImage(for: phAsset, targetSize: PHImageManagerMaximumSize, contentMode: .aspectFit, options: options) { result, info in
            if let result = result {
                self.fullImage = result
            }
            self.isLoading = false
        }
    }
}

// macOS-compatible video player view
struct VideoPlayerView: NSViewRepresentable {
    let player: AVPlayer
    
    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.player = player
        playerView.controlsStyle = .default
        playerView.showsFullScreenToggleButton = true
        return playerView
    }
    
    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}
