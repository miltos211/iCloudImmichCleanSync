import SwiftUI
import ImmichShared

struct LogView: View {
    @ObservedObject var logManager = LogManager.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("System Logs")
                    .font(.headline)
                Spacer()
                Button("Copy All") {
                    copyAllLogs()
                }
                Button("Clear") {
                    logManager.logs.removeAll()
                }
            }
            .padding()
            .background(Material.bar)
            
            // Log List
            List(logManager.logs.reversed()) { entry in
                HStack(alignment: .top, spacing: 8) {
                    Text(entry.date, style: .time)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospaced()
                    
                    Text(entry.category)
                        .font(.caption)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(4)
                    
                    Text(entry.message)
                        .font(.custom("Menlo", size: 11))
                        .foregroundStyle(entry.level.color)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 2)
                .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
        }
    }
    
    private func copyAllLogs() {
        let logText = logManager.logs.reversed().map { entry in
            let timestamp = entry.date.formatted(date: .omitted, time: .standard)
            return "[\(timestamp)] [\(entry.category)] [\(entry.level.rawValue)] \(entry.message)"
        }.joined(separator: "\n")
        
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(logText, forType: .string)
    }
}

#Preview {
    LogView()
}

extension LogManager.LogLevel {
    var color: Color {
        switch self {
        case .info: return .primary
        case .warning: return .orange
        case .error: return .red
        case .debug: return .secondary
        }
    }
}
