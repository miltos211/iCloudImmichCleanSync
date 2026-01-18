import SwiftData
import Foundation

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
