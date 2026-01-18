import SwiftUI
import SwiftData
import ImmichShared

@main
struct ImmichUploaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    let container: ModelContainer
    @StateObject private var syncManager: SyncManager
    
    init() {
        do {
            let modelContainer = try ModelContainer(for: Asset.self)
            _syncManager = StateObject(wrappedValue: SyncManager(modelContainer: modelContainer))
            self.container = modelContainer
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(syncManager)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            SidebarCommands()
        }
        .modelContainer(container)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // When running from command line (swift run), the app might not activate automatically
        // and might not have a dock icon or menu bar.
        // We force it to be a regular app and activate it.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        
        // Ensure the window is brought to front
        DispatchQueue.main.async {
            if let window = NSApp.windows.first {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}
