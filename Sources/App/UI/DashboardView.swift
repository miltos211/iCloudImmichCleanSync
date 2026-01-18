import SwiftUI
import SwiftData
import Charts

struct DashboardView: View {
    @EnvironmentObject var syncManager: SyncManager
    @Query private var assets: [Asset]
    @Query(filter: #Predicate<Asset> { $0.status == "completed" }) private var completedAssets: [Asset]
    @Query(filter: #Predicate<Asset> { $0.status == "failed" }) private var failedAssets: [Asset]
    
    @AppStorage("immichUrl") private var immichUrl = ""
    @AppStorage("apiKey") private var apiKey = ""
    
    private var progress: Double {
        guard !assets.isEmpty else { return 0 }
        return Double(completedAssets.count) / Double(assets.count)
    }
    
    private var processedCount: Int { completedAssets.count }
    private var totalCount: Int { assets.count }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Hero Status Ring
                ZStack {
                    Circle()
                        .stroke(lineWidth: 20)
                        .foregroundStyle(.tertiary)
                    
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(style: StrokeStyle(lineWidth: 20, lineCap: .round))
                        .foregroundStyle(
                            AngularGradient(
                                gradient: Gradient(colors: [.purple, .blue]),
                                center: .center
                            )
                        )
                        .rotationEffect(.degrees(-90))
                        .animation(.spring, value: progress)
                    
                    VStack {
                        Image(systemName: syncManager.isSyncing ? "arrow.triangle.2.circlepath" : "cloud.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(syncManager.isSyncing ? Color.purple.gradient : Color.secondary.gradient)
                            .symbolEffect(.bounce, value: syncManager.isSyncing)
                        
                        Text(syncManager.isSyncing ? "Syncing..." : "Ready")
                            .font(.title2)
                            .fontWeight(.bold)
                        
                        Text("\(Int(progress * 100))%")
                            .font(.largeTitle)
                            .fontWeight(.heavy)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 250, height: 250)
                .padding(.top, 40)
                
                // Action Buttons
                HStack {
                    if syncManager.isSyncing {
                        Button(role: .cancel) {
                            // TODO: Add stop logic
                        } label: {
                            Label("Stop Sync", systemImage: "stop.fill")
                        }
                    } else {
                        Button {
                            syncManager.configure(url: immichUrl, apiKey: apiKey)
                            Task {
                                await syncManager.startSync()
                            }
                        } label: {
                            Label("Start Sync", systemImage: "play.fill")
                                .font(.title3)
                                .frame(minWidth: 150)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(immichUrl.isEmpty || apiKey.isEmpty)
                    }
                }
                
                if let error = syncManager.lastError {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
                
                // Metrics Grid
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 16) {
                    MetricCard(title: "Photos", value: "\(processedCount)", icon: "photo.stack")
                    MetricCard(title: "Remaining", value: "\(totalCount - processedCount)", icon: "hourglass")
                    // MetricCard(title: "Speed", value: "12.5 MB/s", icon: "speedometer")
                    MetricCard(title: "Errors", value: "\(failedAssets.count)", icon: "exclamationmark.triangle", color: failedAssets.isEmpty ? .secondary : .red)
                }
                .padding(.horizontal)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let icon: String
    var color: Color = .primary
    
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Spacer()
            Text(value)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(color)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(height: 100)
        .background(Material.ultraThin, in: RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    DashboardView()
}
