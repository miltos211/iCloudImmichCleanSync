import Foundation

// MARK: - Media Type Enum
public enum MediaType: String, CaseIterable, Codable {
    case all = "all"
    case image = "image"
    case video = "video"
}

// MARK: - Asset Info (for list-assets command)
public struct AssetInfo: Codable {
    public let id: String
    public let type: String
    public let creationDate: String
    public let isScreenshot: Bool
    public let isLivePhoto: Bool
    
    enum CodingKeys: String, CodingKey {
        case id
        case type
        case creationDate = "creation_date"
        case isScreenshot = "is_screenshot"
        case isLivePhoto = "is_live_photo"
    }
    
    public init(id: String, type: String, creationDate: String, isScreenshot: Bool, isLivePhoto: Bool) {
        self.id = id
        self.type = type
        self.creationDate = creationDate
        self.isScreenshot = isScreenshot
        self.isLivePhoto = isLivePhoto
    }
}

// MARK: - Export Result (for export-asset command)
public struct ExportResult: Codable {
    public let success: Bool
    public let filePath: String
    public var metadata: AssetMetadata
    
    enum CodingKeys: String, CodingKey {
        case success
        case filePath = "file_path"
        case metadata
    }
    
    public init(success: Bool, filePath: String, metadata: AssetMetadata) {
        self.success = success
        self.filePath = filePath
        self.metadata = metadata
    }
}

// MARK: - Asset Metadata
public struct AssetMetadata: Codable {
    public let originalFilename: String
    public let creationDate: String
    public let modificationDate: String
    public let location: Location?
    public let cameraMake: String?
    public let cameraModel: String?
    public let lensModel: String?
    public let dimensions: Dimensions
    public let fileSize: Int
    public let mediaType: String
    public let format: String
    public let duration: Double?
    public let fps: Double?
    public let isFavorite: Bool
    public let isHidden: Bool
    public let burstIdentifier: String?
    public let icloudStatus: String
    public var isLivePhoto: Bool
    public var livePhotoVideoComplement: String?
    
    // Custom encoding to ensure all fields are included
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(originalFilename, forKey: .originalFilename)
        try container.encode(creationDate, forKey: .creationDate)
        try container.encode(modificationDate, forKey: .modificationDate)
        try container.encode(location, forKey: .location)
        try container.encode(cameraMake, forKey: .cameraMake)
        try container.encode(cameraModel, forKey: .cameraModel)
        try container.encode(lensModel, forKey: .lensModel)
        try container.encode(dimensions, forKey: .dimensions)
        try container.encode(fileSize, forKey: .fileSize)
        try container.encode(mediaType, forKey: .mediaType)
        try container.encode(format, forKey: .format)
        try container.encode(duration, forKey: .duration)
        try container.encode(fps, forKey: .fps)
        try container.encode(isFavorite, forKey: .isFavorite)
        try container.encode(isHidden, forKey: .isHidden)
        try container.encode(burstIdentifier, forKey: .burstIdentifier)
        try container.encode(icloudStatus, forKey: .icloudStatus)
        try container.encode(isLivePhoto, forKey: .isLivePhoto)
        try container.encode(livePhotoVideoComplement, forKey: .livePhotoVideoComplement)
    }
    
    enum CodingKeys: String, CodingKey {
        case originalFilename = "original_filename"
        case creationDate = "creation_date"
        case modificationDate = "modification_date"
        case location
        case cameraMake = "camera_make"
        case cameraModel = "camera_model"
        case lensModel = "lens_model"
        case dimensions
        case fileSize = "file_size"
        case mediaType = "media_type"
        case format
        case duration
        case fps
        case isFavorite = "is_favorite"
        case isHidden = "is_hidden"
        case burstIdentifier = "burst_identifier"
        case icloudStatus = "icloud_status"
        case isLivePhoto = "is_live_photo"
        case livePhotoVideoComplement = "live_photo_video_complement"
    }
    
    public init(originalFilename: String, creationDate: String, modificationDate: String, location: Location?, cameraMake: String?, cameraModel: String?, lensModel: String?, dimensions: Dimensions, fileSize: Int, mediaType: String, format: String, duration: Double?, fps: Double?, isFavorite: Bool, isHidden: Bool, burstIdentifier: String?, icloudStatus: String, isLivePhoto: Bool, livePhotoVideoComplement: String?) {
        self.originalFilename = originalFilename
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.location = location
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.lensModel = lensModel
        self.dimensions = dimensions
        self.fileSize = fileSize
        self.mediaType = mediaType
        self.format = format
        self.duration = duration
        self.fps = fps
        self.isFavorite = isFavorite
        self.isHidden = isHidden
        self.burstIdentifier = burstIdentifier
        self.icloudStatus = icloudStatus
        self.isLivePhoto = isLivePhoto
        self.livePhotoVideoComplement = livePhotoVideoComplement
    }
}

// MARK: - Location
public struct Location: Codable {
    public let latitude: Double
    public let longitude: Double
    public let altitude: Double
    
    public init(latitude: Double, longitude: Double, altitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
    }
}

// MARK: - Dimensions
public struct Dimensions: Codable {
    public let width: Int
    public let height: Int
    
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}