import Foundation

enum MediaAssetKind: String, Codable, Hashable, Sendable {
    case photo
    case video

    var label: String {
        switch self {
        case .photo:
            return "Photo"
        case .video:
            return "Video"
        }
    }
}

struct LibraryAssetDescriptor: Identifiable, Hashable, Sendable {
    let id: String
    let localIdentifier: String
    let fileName: String
    let kind: MediaAssetKind
    let creationDate: Date?
    let pixelWidth: Int
    let pixelHeight: Int
    let duration: TimeInterval

    init(
        localIdentifier: String,
        fileName: String,
        kind: MediaAssetKind,
        creationDate: Date?,
        pixelWidth: Int,
        pixelHeight: Int,
        duration: TimeInterval
    ) {
        self.id = localIdentifier
        self.localIdentifier = localIdentifier
        self.fileName = fileName
        self.kind = kind
        self.creationDate = creationDate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
    }

    var estimatedByteCount: Int64 {
        switch kind {
        case .photo:
            let estimated = Double(max(pixelWidth * pixelHeight, 2_000_000)) * 0.42
            return Int64(max(estimated, 1_800_000))
        case .video:
            let seconds = max(duration, 5)
            let estimated = seconds * 2_000_000
            return Int64(max(estimated, 12_000_000))
        }
    }
}

struct PreparedAsset: Sendable {
    let descriptor: LibraryAssetDescriptor
    let fileURL: URL
    let fileSize: Int64
    let mimeType: String
    let contentFingerprint: String
}

struct RecentUpload: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let fileName: String
    let uploadedAt: Date
    let mediaItemID: String
    let productURL: URL?

    init(
        id: UUID = UUID(),
        fileName: String,
        uploadedAt: Date,
        mediaItemID: String,
        productURL: URL?
    ) {
        self.id = id
        self.fileName = fileName
        self.uploadedAt = uploadedAt
        self.mediaItemID = mediaItemID
        self.productURL = productURL
    }
}

struct UploadManifestEntry: Codable, Hashable, Sendable {
    let localIdentifier: String
    let fileName: String
    let fileSize: Int64
    let mediaItemID: String
    let productURL: URL?
    let uploadedAt: Date
    let contentFingerprint: String?
}

struct UploadManifest: Codable, Hashable, Sendable {
    var entries: [String: UploadManifestEntry] = [:]
}

struct GoogleUserProfile: Equatable, Sendable {
    let email: String?
    let displayName: String?
}

enum SyncPhase: String, Equatable, Sendable {
    case idle
    case awaitingPermissions
    case preparing
    case uploading
    case syncingComplete
    case failed
}

struct SyncMetrics: Equatable, Sendable {
    var phase: SyncPhase = .idle
    var totalItems: Int = 0
    var completedItems: Int = 0
    var uploadedBytes: Int64 = 0
    var estimatedTotalBytes: Int64 = 0
    var currentFileName: String?
    var currentItemProgress: Double = 0
    var detailText: String = "Connect Google and allow Photos access to start."
    var activeTransferStartedAt: Date?
    var activeTransferBaselineBytes: Int64 = 0
    var updatedAt: Date = .now

    var progressFraction: Double {
        if estimatedTotalBytes > 0 {
            return min(max(Double(uploadedBytes) / Double(estimatedTotalBytes), 0), 1)
        }

        guard totalItems > 0 else { return 0 }
        return min(max(Double(completedItems) / Double(totalItems), 0), 1)
    }

    var currentItemProgressFraction: Double {
        min(max(currentItemProgress, 0), 1)
    }

    var bytesPerSecond: Double? {
        guard let activeTransferStartedAt else { return nil }
        let elapsed = updatedAt.timeIntervalSince(activeTransferStartedAt)
        let transferredBytes = max(uploadedBytes - activeTransferBaselineBytes, 0)
        guard transferredBytes > 0 else { return nil }
        guard elapsed > 0.25 else { return nil }
        return Double(transferredBytes) / elapsed
    }

    var estimatedRemainingSeconds: TimeInterval? {
        guard let bytesPerSecond, bytesPerSecond > 1 else { return nil }
        let remainingBytes = max(estimatedTotalBytes - uploadedBytes, 0)
        guard remainingBytes > 0 else { return nil }
        return Double(remainingBytes) / bytesPerSecond
    }
}
