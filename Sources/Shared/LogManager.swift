import Foundation
import Combine

public class LogManager: ObservableObject {
    public static let shared = LogManager()
    
    public struct LogEntry: Identifiable {
        public let id = UUID()
        public let date = Date()
        public let level: LogLevel
        public let message: String
        public let category: String
    }
    
    public enum LogLevel: String {
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
        case debug = "DEBUG"
    }
    
    @Published public var logs: [LogEntry] = []
    
    private init() {
        addLog("Log Manager started", category: "System")
    }
    
    public func addLog(_ message: String, level: LogLevel = .info, category: String = "General") {
        DispatchQueue.main.async {
            self.logs.append(LogEntry(level: level, message: message, category: category))
            // Keep log size manageable
            if self.logs.count > 1000 {
                self.logs.removeFirst(100)
            }
        }
        // Also print to console for terminal visibility
        print("[\(category)] [\(level.rawValue)] \(message)")
    }
    
    public func logError(_ error: Error, category: String) {
        addLog(error.localizedDescription, level: .error, category: category)
    }
}

// Global helper
public func Log(_ message: String, level: LogManager.LogLevel = .info, category: String = "App") {
    LogManager.shared.addLog(message, level: level, category: category)
}
