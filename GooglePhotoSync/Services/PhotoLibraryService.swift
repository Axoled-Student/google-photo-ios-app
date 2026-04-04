import AVFoundation
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
    case missingImageData
    case missingVideoAsset
    case failedToCreateExportSession
    case failedToExport(Error)
    case failedToReadFileSize

    var errorDescription: String? {
        switch self {
        case .assetUnavailable:
            return "The selected photo could not be found in the Apple Photos library."
        case .resourceUnavailable:
            return "The original resource for this item is not available."
        case .missingImageData:
            return "Apple Photos did not return image data for this item."
        case .missingVideoAsset:
            return "Apple Photos did not return a playable video asset for this item."
        case .failedToCreateExportSession:
            return "Apple Photos could not create a video export session for this item."
        case .failedToExport(let error):
            return "Exporting from Apple Photos failed: \(error.localizedDescription)"
        case .failedToReadFileSize:
            return "The exported file size could not be determined."
        }
    }
}

struct PhotoLibraryScanSnapshot: Sendable {
    let totalCount: Int
    let descriptors: [LibraryAssetDescriptor]
}

final class PhotoLibraryService: NSObject, PHPhotoLibraryChangeObserver {
    var onLibraryChange: (@MainActor () -> Void)?
    private let observesPhotoLibraryChanges: Bool

    init(observesPhotoLibraryChanges: Bool = true) {
        self.observesPhotoLibraryChanges = observesPhotoLibraryChanges
        super.init()
        if observesPhotoLibraryChanges {
            PHPhotoLibrary.shared().register(self)
        }
    }

    deinit {
        if observesPhotoLibraryChanges {
            PHPhotoLibrary.shared().unregisterChangeObserver(self)
        }
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

    func scanSnapshot(excluding uploadedIdentifiers: Set<String>) -> PhotoLibraryScanSnapshot {
        Self.scanSnapshot(excluding: uploadedIdentifiers)
    }

    nonisolated static func syncableAssetCount() -> Int {
        scanSnapshot(excluding: []).totalCount
    }

    nonisolated static func fetchDescriptors(excluding uploadedIdentifiers: Set<String>) -> [LibraryAssetDescriptor] {
        scanSnapshot(excluding: uploadedIdentifiers).descriptors
    }

    nonisolated static func scanSnapshot(excluding uploadedIdentifiers: Set<String>) -> PhotoLibraryScanSnapshot {
        let options = PHFetchOptions()

        let assets = PHAsset.fetchAssets(with: options)
        var totalCount = 0
        var descriptors: [LibraryAssetDescriptor] = []
        descriptors.reserveCapacity(assets.count)

        assets.enumerateObjects { asset, _, _ in
            guard asset.mediaType == .image || asset.mediaType == .video else {
                return
            }

            totalCount += 1

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

        return PhotoLibraryScanSnapshot(totalCount: totalCount, descriptors: descriptors)
    }

    func prepareAsset(
        for descriptor: LibraryAssetDescriptor,
        onProgress: @escaping @Sendable (Double, String) async -> Void = { _, _ in }
    ) async throws -> PreparedAsset {
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [descriptor.localIdentifier], options: nil)
        guard let asset = fetchResult.firstObject else {
            throw PhotoLibraryServiceError.assetUnavailable
        }

        let resource = Self.primaryResource(for: asset)
        let originalFilename = resource?.originalFilename ?? Self.fallbackFileName(for: asset)

        let url = try await exportAsset(
            asset: asset,
            resource: resource,
            kind: descriptor.kind,
            originalFilename: originalFilename,
            onProgress: onProgress
        )

        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let fileSize = values.fileSize else {
            throw PhotoLibraryServiceError.failedToReadFileSize
        }

        let contentFingerprint = try await FileFingerprint.sha256Hex(for: url) { progress in
            await onProgress(progress, "Calculating fingerprint")
        }

        return PreparedAsset(
            descriptor: descriptor,
            fileURL: url,
            fileSize: Int64(fileSize),
            mimeType: Self.mimeType(for: resource, kind: descriptor.kind, exportedURL: url),
            contentFingerprint: contentFingerprint
        )
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in
            self?.onLibraryChange?()
        }
    }

    private func exportAsset(
        asset: PHAsset,
        resource: PHAssetResource?,
        kind: MediaAssetKind,
        originalFilename: String,
        onProgress: @escaping @Sendable (Double, String) async -> Void
    ) async throws -> URL {
        if let resource {
            do {
                return try await exportPrimaryResource(
                    resource,
                    fallbackFilename: originalFilename,
                    onProgress: onProgress
                )
            } catch {
                await onProgress(0, "Retrying export")
            }
        }

        switch kind {
        case .photo:
            return try await exportPhoto(
                asset: asset,
                originalFilename: originalFilename,
                onProgress: onProgress
            )
        case .video:
            return try await exportVideo(
                asset: asset,
                originalFilename: originalFilename,
                onProgress: onProgress
            )
        }
    }

    private func exportPrimaryResource(
        _ resource: PHAssetResource,
        fallbackFilename: String,
        onProgress: @escaping @Sendable (Double, String) async -> Void
    ) async throws -> URL {
        let resourceFilename = resource.originalFilename.isEmpty ? fallbackFilename : resource.originalFilename
        let destinationURL = Self.exportURL(for: resourceFilename)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        options.progressHandler = { progress in
            Task {
                await onProgress(progress, "Downloading from Apple Photos")
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: destinationURL, options: options) { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                continuation.resume(returning: ())
            }
        }

        return destinationURL
    }

    private func exportPhoto(
        asset: PHAsset,
        originalFilename: String,
        onProgress: @escaping @Sendable (Double, String) async -> Void
    ) async throws -> URL {
        await onProgress(0, "Preparing photo")

        if let sourceURL = await requestFullSizeImageURL(for: asset) {
            let filename = sourceURL.lastPathComponent.isEmpty ? originalFilename : sourceURL.lastPathComponent
            let destinationURL = Self.exportURL(for: filename)
            try Self.copyItem(at: sourceURL, to: destinationURL)
            await onProgress(1, "Photo ready")
            return destinationURL
        }

        let (imageData, dataUTI) = try await requestImageData(for: asset)
        let fallbackExtension = UTType(dataUTI ?? "")?.preferredFilenameExtension ?? "jpg"
        let destinationURL = Self.exportURL(
            for: Self.normalizedFileName(
                from: originalFilename,
                fallbackExtension: fallbackExtension
            )
        )
        try imageData.write(to: destinationURL, options: .atomic)
        await onProgress(1, "Photo ready")
        return destinationURL
    }

    private func exportVideo(
        asset: PHAsset,
        originalFilename: String,
        onProgress: @escaping @Sendable (Double, String) async -> Void
    ) async throws -> URL {
        await onProgress(0, "Preparing video")

        let videoAsset = try await requestVideoAsset(for: asset)

        if let urlAsset = videoAsset as? AVURLAsset, urlAsset.url.isFileURL {
            let filename = urlAsset.url.lastPathComponent.isEmpty ? originalFilename : urlAsset.url.lastPathComponent
            let destinationURL = Self.exportURL(for: filename)
            try Self.copyItem(at: urlAsset.url, to: destinationURL)
            await onProgress(1, "Video ready")
            return destinationURL
        }

        return try await exportVideoAsset(
            videoAsset,
            originalFilename: originalFilename,
            onProgress: onProgress
        )
    }

    private func requestFullSizeImageURL(for asset: PHAsset) async -> URL? {
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = true

        return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            asset.requestContentEditingInput(with: options) { input, _ in
                continuation.resume(returning: input?.fullSizeImageURL)
            }
        }
    }

    private func requestImageData(for asset: PHAsset) async throws -> (Data, String?) {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.version = .current

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, String?), Error>) in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, dataUTI, _, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let data, !data.isEmpty else {
                    continuation.resume(throwing: PhotoLibraryServiceError.missingImageData)
                    return
                }

                continuation.resume(returning: (data, dataUTI))
            }
        }
    }

    private func requestVideoAsset(for asset: PHAsset) async throws -> AVAsset {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.version = .current

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AVAsset, Error>) in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let avAsset else {
                    continuation.resume(throwing: PhotoLibraryServiceError.missingVideoAsset)
                    return
                }

                continuation.resume(returning: avAsset)
            }
        }
    }

    private func exportVideoAsset(
        _ videoAsset: AVAsset,
        originalFilename: String,
        onProgress: @escaping @Sendable (Double, String) async -> Void
    ) async throws -> URL {
        guard let exportSession = AVAssetExportSession(
            asset: videoAsset,
            presetName: AVAssetExportPresetPassthrough
        ) ?? AVAssetExportSession(
            asset: videoAsset,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw PhotoLibraryServiceError.failedToCreateExportSession
        }

        let outputFileType: AVFileType
        if exportSession.supportedFileTypes.contains(.mp4) {
            outputFileType = .mp4
        } else if exportSession.supportedFileTypes.contains(.mov) {
            outputFileType = .mov
        } else if let firstSupportedType = exportSession.supportedFileTypes.first {
            outputFileType = firstSupportedType
        } else {
            outputFileType = .mov
        }

        let fallbackExtension = outputFileType == .mp4 ? "mp4" : "mov"
        let destinationURL = Self.exportURL(
            for: Self.normalizedFileName(
                from: originalFilename,
                fallbackExtension: fallbackExtension
            )
        )

        exportSession.outputURL = destinationURL
        exportSession.outputFileType = outputFileType
        exportSession.shouldOptimizeForNetworkUse = false
        await onProgress(0, "Exporting video")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exportSession.exportAsynchronously {
                switch exportSession.status {
                case .completed:
                    continuation.resume(returning: ())
                case .failed:
                    continuation.resume(throwing: exportSession.error ?? PhotoLibraryServiceError.resourceUnavailable)
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                default:
                    continuation.resume(throwing: PhotoLibraryServiceError.resourceUnavailable)
                }
            }
        }

        await onProgress(1, "Video ready")
        return destinationURL
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

    private static func normalizedFileName(from originalFilename: String, fallbackExtension: String) -> String {
        let pathExtension = (originalFilename as NSString).pathExtension
        if pathExtension.isEmpty {
            return "\(UUID().uuidString).\(fallbackExtension)"
        }

        return originalFilename
    }

    private static func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    }

    private static func mimeType(for resource: PHAssetResource?, kind: MediaAssetKind, exportedURL: URL) -> String {
        if let resource,
           let type = UTType(resource.uniformTypeIdentifier),
           let mimeType = type.preferredMIMEType {
            return mimeType
        }

        if let fileType = UTType(filenameExtension: exportedURL.pathExtension),
           let mimeType = fileType.preferredMIMEType {
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
