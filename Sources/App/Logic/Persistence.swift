import SwiftData
import Foundation
import SQLite3
import ImmichShared

@Model
final class Asset {
    @Attribute(.unique) var id: String
    var originalFilename: String
    var assetType: String // "image" or "video"
    var creationDate: Date
    var status: String // "pending", "completed", "failed"
    var immichId: String?
    var errorMessage: String?
    var retryCount: Int
    var processedAt: Date?
    var fileSize: Int?
    var uploadDuration: Double?
    var sha1: String? // hex SHA-1 of the exported file; set after first export
    
    init(id: String, originalFilename: String, assetType: String, creationDate: Date, status: String = "pending") {
        self.id = id
        self.originalFilename = originalFilename
        self.assetType = assetType
        self.creationDate = creationDate
        self.status = status
        self.retryCount = 0
    }
}

// Helper for converting string date from spec to Date object
extension Asset {
    static func parseDate(_ dateString: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: dateString) ?? Date()
    }
}

/// Where the app keeps its database. SwiftData's default (~/Library/Application Support/default.store) is shared
/// by every unsandboxed app that doesn't choose its own file, and on macOS 27 Apple's icloudmailagent uses it too:
/// each process migrates the file to its own model when it opens it, deleting the other's data.
enum AssetStore {
    static func url() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.immich.uploader", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("ImmichUploader.store")
        if !FileManager.default.fileExists(atPath: url.path) {
            copyLegacyStore(from: support.appendingPathComponent("default.store"), to: url)
        }
        return url
    }
    
    /// One-time move from the shared default.store, only if it holds this app's assets. VACUUM INTO writes a
    /// consistent snapshot even while another process has the old file open.
    private static func copyLegacyStore(from old: URL, to new: URL) {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(old.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return }
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM ZASSET", -1, &stmt, nil) == SQLITE_OK else { return }
        let count = sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : 0
        sqlite3_finalize(stmt)
        guard count > 0 else { return }
        
        let target = new.path.replacingOccurrences(of: "'", with: "''")
        if sqlite3_exec(db, "VACUUM INTO '\(target)'", nil, nil, nil) == SQLITE_OK {
            Log("Copied \(count) assets from the shared default.store to \(new.path)", category: "Persistence")
        } else {
            Log("Could not copy the old default.store (\(String(cString: sqlite3_errmsg(db)))), starting with an empty database", level: .warning, category: "Persistence")
            try? FileManager.default.removeItem(at: new)
        }
    }
}
