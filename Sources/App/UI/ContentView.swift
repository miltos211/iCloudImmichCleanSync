import SwiftUI
import ImmichShared

struct ContentView: View {
    @State private var selectedItem: NavigationItem? = .dashboard
    
    enum NavigationItem: Int, CaseIterable, Identifiable {
        case dashboard
        case photos
        case settings
        case logs
        
        var id: Int { self.rawValue }
        
        var title: String {
            switch self {
            case .dashboard: return "Dashboard"
            case .photos: return "Library"
            case .settings: return "Settings"
            case .logs: return "Logs"
            }
        }
        
        var icon: String {
            switch self {
            case .dashboard: return "gauge.with.dots.needle.bottom.50percent"
            case .photos: return "photo.stack"
            case .settings: return "gearshape"
            case .logs: return "list.bullet.rectangle"
            }
        }
    }
    
    var body: some View {
        NavigationSplitView {
            List(NavigationItem.allCases, selection: $selectedItem) { item in
                NavigationLink(value: item) {
                    Label(item.title, systemImage: item.icon)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .listStyle(.sidebar)
        } detail: {
            switch selectedItem {
            case .dashboard:
                DashboardView()
            case .photos:
                AssetGridView()
            case .settings:
                SettingsView()
            case .logs:
                LogView()
            case .none:
                Text("Select an item")
            }
        }
    }
}

#Preview {
    ContentView()
}
