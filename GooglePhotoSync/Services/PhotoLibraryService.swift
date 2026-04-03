import Foundation
import Photos
import UniformTypeIdentifiers

enum PhotoAccessState: Equatable, Sendable {
    case notDetermined
    case denied
    case limited
    case authorized

    var isGranted: Bool {
        self == .authorized || self == .limited
    }
}

enum PhotoLibraryServiceError: LocalizedError {
    case assetUnavailable
    case resourceUnavailable
    case failedToExport(Error)
    case failedToReadFileSize

    var errorDescription: String? {
        switch self {
        case .assetUnavailable:
            return "The selected photo could not be found in the Apple Photos library."
        case .resourceUnavailable:
            return "The original resource for this item is not available."
        case .failedToExport(let error):
            return "Exporting from Apple Photos failed: \(error.localizedDescription)"
        case .failedToReadFileSize:
            return "The exported file size could not be determined."
        }
    }
}

final class PhotoLibraryService: NSObject, PHPhotoLibraryChangeObserver {
    var onLibraryChange: (@MainActor () -> Void)?

    override init() {
        super.init()
        PHPhotoLibrary.shared().register(self)
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    func currentAuthorizationState() -> PhotoAccessState {
        Self.currentAuthorizationState()
    }

    nonisolated static func currentAuthorizationState() -> PhotoAccessState {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized:
            return .authorized
        case .limited:
            return .limited
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
    }

    func requestAuthorization() async -> PhotoAccessState {
        let status = await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }

        switch status {
        case .authorized:
            return .authorized
        case .limited:
            return .limited
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
    }

    func syncableAssetCount() -> Int {
        Self.syncableAssetCount()
    }

    func fetchDescriptors(excluding uploadedIdentifiers: Set<String>) -> [LibraryAssetDescriptor] {
        Self.fetchDescriptors(excluding: uploadedIdentifiers)
    }

    nonisolated static func syncableAssetCount() -> Int {
        let fetchResult = PHAsset.fetchAssets(with: PHFetchOptions())
        var count = 0
        fetchResult.enumerateObjects { asset, _, _ in
            if asset.mediaType == .image || asset.mediaType == .video {
                count += 1
            }
        }
        return count
    }

    nonisolated static func fetchDescriptors(excluding uploadedIdentifiers: Set<String>) -> [LibraryAssetDescriptor] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

        let assets = PHAsset.fetchAssets(with: options)
        var descriptors: [LibraryAssetDescriptor] = []
        descriptors.reserveCapacity(assets.count)

        assets.enumerateObjects { asset, _, _ in
            guard asset.mediaType == .image || asset.mediaType == .video else {
                return
            }

            guard !uploadedIdentifiers.contains(asset.localIdentifier) else {
                return
            }

            let resource = Self.primaryResource(for: asset)
            let fileName = resource?.originalFilename ?? Self.fallbackFileName(for: asset)

            descriptors.append(
                LibraryAssetDescriptor(
                    localIdentifier: asset.localIdentifier,
                    fileName: fileName,
                    kind: asset.mediaType == .video ? .video : .photo,
                    creationDate: asset.creationDate,
                    pixelWidth: asset.pixelWidth,
                    pixelHeight: asset.pixelHeight,
                    duration: asset.duration
                )
            )
        }

        return descriptors
    }

    func prepareAsset(for descriptor: LibraryAssetDescriptor) async throws -> PreparedAsset {
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [descriptor.localIdentifier], options: nil)
        guard let asset = fetchResult.firstObject else {
            throw PhotoLibraryServiceError.assetUnavailable
        }

        guard let resource = Self.primaryResource(for: asset) else {
            throw PhotoLibraryServiceError.resourceUnavailable
        }

        let url = Self.exportURL(for: resource.originalFilename)

        do {
            try await write(resource: resource, to: url)
        } catch {
            throw PhotoLibraryServiceError.failedToExport(error)
        }

        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let fileSize = values.fileSize else {
            throw PhotoLibraryServiceError.failedToReadFileSize
        }

        return PreparedAsset(
            descriptor: descriptor,
            fileURL: url,
            fileSize: Int64(fileSize),
            mimeType: Self.mimeType(for: resource, kind: descriptor.kind),
            contentFingerprint: try FileFingerprint.sha256Hex(for: url)
        )
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in
            self?.onLibraryChange?()
        }
    }

    private func write(resource: PHAssetResource, to url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: nil) { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                continuation.resume(returning: ())
            }
        }
    }

    private static func primaryResource(for asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)

        let preferredTypes: [PHAssetResourceType] = [
            .fullSizePhoto,
            .photo,
            .fullSizeVideo,
            .video,
            .alternatePhoto,
            .pairedVideo
        ]

        for type in preferredTypes {
            if let match = resources.first(where: { $0.type == type }) {
                return match
            }
        }

        return resources.first
    }

    private static func fallbackFileName(for asset: PHAsset) -> String {
        let stem = asset.mediaType == .video ? "video" : "photo"
        let suffix = asset.mediaType == .video ? "mov" : "jpg"
        return "\(stem)-\(asset.localIdentifier).\(suffix)"
    }

    private static func exportURL(for originalFilename: String) -> URL {
        let fileExtension = (originalFilename as NSString).pathExtension
        let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return fileExtension.isEmpty ? baseURL : baseURL.appendingPathExtension(fileExtension)
    }

    private static func mimeType(for resource: PHAssetResource, kind: MediaAssetKind) -> String {
        if let type = UTType(resource.uniformTypeIdentifier), let mimeType = type.preferredMIMEType {
            return mimeType
        }

        switch kind {
        case .photo:
            return "image/jpeg"
        case .video:
            return "video/quicktime"
        }
    }
}
