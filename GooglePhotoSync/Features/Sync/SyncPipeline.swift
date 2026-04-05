import Foundation

struct SyncProgressSnapshot: Sendable {
    let metrics: SyncMetrics
    let uploadedLikeCompletedCount: Int
    let processedItemsCount: Int
}

private struct ActiveSyncItem: Sendable {
    let assetID: String
    let fileName: String
    let queueIndex: Int
    var phase: SyncPhase
    var progress: Double
    var bytesSent: Int64
    var estimatedSize: Int64
    var lastUpdated: Date
}

actor SyncProgressTracker {
    private let totalItems: Int
    private let startedAt = Date.now
    private let sink: @MainActor @Sendable (SyncProgressSnapshot) -> Void

    private var estimatedTotalBytes: Int64
    private var committedUploadedBytes: Int64 = 0
    private var uploadedLikeCompletedCount = 0
    private var processedItemsCount = 0
    private var activeItems: [String: ActiveSyncItem] = [:]
    private var lastDetailText: String

    init(
        totalItems: Int,
        estimatedTotalBytes: Int64,
        initialDetail: String,
        sink: @escaping @MainActor @Sendable (SyncProgressSnapshot) -> Void
    ) {
        self.totalItems = totalItems
        self.estimatedTotalBytes = estimatedTotalBytes
        self.lastDetailText = initialDetail
        self.sink = sink
    }

    func beginAsset(
        assetID: String,
        fileName: String,
        queueIndex: Int,
        estimatedSize: Int64,
        detail: String
    ) async {
        activeItems[assetID] = ActiveSyncItem(
            assetID: assetID,
            fileName: fileName,
            queueIndex: queueIndex,
            phase: .preparing,
            progress: 0,
            bytesSent: 0,
            estimatedSize: estimatedSize,
            lastUpdated: .now
        )
        lastDetailText = detail
        await emit()
    }

    func updatePreparing(
        assetID: String,
        progress: Double,
        detail: String
    ) async {
        guard var item = activeItems[assetID] else { return }
        item.phase = .preparing
        item.progress = min(max(progress, 0), 1)
        item.lastUpdated = .now
        activeItems[assetID] = item
        lastDetailText = detail
        await emit()
    }

    func updatePreparedSize(
        assetID: String,
        actualSize: Int64
    ) async {
        guard var item = activeItems[assetID] else { return }
        estimatedTotalBytes = max(0, estimatedTotalBytes + (actualSize - item.estimatedSize))
        item.estimatedSize = actualSize
        item.lastUpdated = .now
        activeItems[assetID] = item
        await emit()
    }

    func updateUploading(
        assetID: String,
        bytesSent: Int64,
        detail: String
    ) async {
        guard var item = activeItems[assetID] else { return }
        item.phase = .uploading
        item.bytesSent = max(bytesSent, 0)
        item.progress = min(max(Double(item.bytesSent) / Double(max(item.estimatedSize, 1)), 0), 1)
        item.lastUpdated = .now
        activeItems[assetID] = item
        lastDetailText = detail
        await emit()
    }

    func markDuplicate(
        assetID: String,
        detail: String
    ) async {
        guard let item = activeItems.removeValue(forKey: assetID) else { return }
        processedItemsCount += 1
        uploadedLikeCompletedCount += 1
        estimatedTotalBytes = max(currentUploadedBytes, estimatedTotalBytes - item.estimatedSize)
        lastDetailText = detail
        await emit()
    }

    func markUnavailable(
        assetID: String,
        detail: String
    ) async {
        guard let item = activeItems.removeValue(forKey: assetID) else { return }
        processedItemsCount += 1
        estimatedTotalBytes = max(currentUploadedBytes, estimatedTotalBytes - item.estimatedSize)
        lastDetailText = detail
        await emit()
    }

    func markUploaded(
        assetID: String,
        fileSize: Int64,
        detail: String
    ) async {
        guard let item = activeItems.removeValue(forKey: assetID) else { return }
        processedItemsCount += 1
        uploadedLikeCompletedCount += 1
        committedUploadedBytes += max(fileSize, item.bytesSent)
        estimatedTotalBytes = max(currentUploadedBytes, estimatedTotalBytes)
        lastDetailText = detail
        await emit()
    }

    func complete(detail: String) async {
        activeItems.removeAll()
        lastDetailText = detail
        await emit(phaseOverride: .syncingComplete)
    }

    private var currentUploadedBytes: Int64 {
        committedUploadedBytes + activeItems.values.reduce(into: Int64.zero) { partialResult, item in
            partialResult += item.bytesSent
        }
    }

    private func emit(phaseOverride: SyncPhase? = nil) async {
        let activeCount = activeItems.count
        let uploadingCount = activeItems.values.reduce(into: 0) { partialResult, item in
            if item.phase == .uploading {
                partialResult += 1
            }
        }
        let phase: SyncPhase
        if let phaseOverride {
            phase = phaseOverride
        } else if uploadingCount > 0 {
            phase = .uploading
        } else if activeCount > 0 {
            phase = .preparing
        } else {
            phase = .idle
        }

        let activeItemsSorted = activeItems.values.sorted {
            if $0.phase != $1.phase {
                return $0.phase == .uploading
            }

            if $0.lastUpdated != $1.lastUpdated {
                return $0.lastUpdated > $1.lastUpdated
            }

            return $0.queueIndex < $1.queueIndex
        }

        let currentFileName: String?
        if activeCount == 0 {
            currentFileName = nil
        } else if activeCount == 1 {
            currentFileName = activeItemsSorted.first?.fileName
        } else if let primaryItem = activeItemsSorted.first {
            currentFileName = "\(primaryItem.fileName) + \(activeCount - 1) more"
        } else {
            currentFileName = nil
        }

        let currentItemProgress: Double
        if activeCount == 0 {
            currentItemProgress = 0
        } else {
            let combinedProgress = activeItems.values.reduce(into: 0.0) { partialResult, item in
                partialResult += item.progress
            }
            currentItemProgress = combinedProgress / Double(activeCount)
        }

        let detailText: String
        if activeCount > 1 {
            let preparingCount = max(activeCount - uploadingCount, 0)
            detailText = "\(uploadingCount) uploading, \(preparingCount) preparing. \(lastDetailText)"
        } else {
            detailText = lastDetailText
        }

        let uploadedBytes = currentUploadedBytes
        let metrics = SyncMetrics(
            phase: phase,
            totalItems: totalItems,
            completedItems: processedItemsCount,
            uploadedBytes: uploadedBytes,
            estimatedTotalBytes: max(estimatedTotalBytes, uploadedBytes),
            currentFileName: currentFileName,
            currentItemProgress: currentItemProgress,
            detailText: detailText,
            activeTransferStartedAt: (uploadedBytes > 0 || uploadingCount > 0) ? startedAt : nil,
            activeTransferBaselineBytes: 0,
            updatedAt: .now,
            activeItemCount: activeCount
        )

        await sink(
            SyncProgressSnapshot(
                metrics: metrics,
                uploadedLikeCompletedCount: uploadedLikeCompletedCount,
                processedItemsCount: processedItemsCount
            )
        )
    }
}

enum FingerprintUploadResolution: Sendable {
    case existing(UploadManifestEntry)
    case newlyUploaded(UploadManifestEntry)
}

actor GooglePhotosWriteGate {
    private let maxConcurrentWrites: Int
    private var targetConcurrentWrites: Int
    private var activeWrites = 0
    private var consecutiveSuccesses = 0
    private var cooldownEndsAt: Date?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maxConcurrentWrites: Int, initialConcurrentWrites: Int = 2) {
        let normalizedMax = max(maxConcurrentWrites, 1)
        self.maxConcurrentWrites = normalizedMax
        self.targetConcurrentWrites = min(max(initialConcurrentWrites, 1), normalizedMax)
    }

    func acquire() async {
        refreshCooldownWindowIfNeeded()

        if activeWrites < effectiveConcurrentWrites {
            activeWrites += 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        activeWrites = max(activeWrites - 1, 0)
        resumeWaitersIfPossible()
    }

    func registerSuccessfulWrite() {
        refreshCooldownWindowIfNeeded()

        guard cooldownEndsAt == nil else { return }

        consecutiveSuccesses += 1
        if targetConcurrentWrites < maxConcurrentWrites, consecutiveSuccesses >= 8 {
            targetConcurrentWrites += 1
            consecutiveSuccesses = 0
            resumeWaitersIfPossible()
        }
    }

    func registerQuotaError() {
        targetConcurrentWrites = 1
        consecutiveSuccesses = 0
        cooldownEndsAt = .now.addingTimeInterval(90)
    }

    private var effectiveConcurrentWrites: Int {
        if let cooldownEndsAt, cooldownEndsAt > .now {
            return 1
        }

        return targetConcurrentWrites
    }

    private func refreshCooldownWindowIfNeeded() {
        if let cooldownEndsAt, cooldownEndsAt <= .now {
            self.cooldownEndsAt = nil
        }
    }

    private func resumeWaitersIfPossible() {
        refreshCooldownWindowIfNeeded()

        while activeWrites < effectiveConcurrentWrites, let waiter = waiters.first {
            waiters.removeFirst()
            activeWrites += 1
            waiter.resume()
        }
    }
}

actor FingerprintUploadCoordinator {
    private let manifestStore: UploadManifestStore
    private var inflightUploads: [String: Task<UploadManifestEntry, Error>] = [:]

    init(manifestStore: UploadManifestStore) {
        self.manifestStore = manifestStore
    }

    func resolveUpload(
        fingerprint: String,
        fileName: String,
        fileSize: Int64,
        operation: @escaping @Sendable () async throws -> UploadManifestEntry
    ) async throws -> FingerprintUploadResolution {
        if let existingEntry = try await manifestStore.entry(
            matchingContentFingerprint: fingerprint,
            fileName: fileName,
            fileSize: fileSize
        ) {
            return .existing(existingEntry)
        }

        if let inflightTask = inflightUploads[fingerprint] {
            return .existing(try await inflightTask.value)
        }

        let uploadTask = Task {
            try await operation()
        }
        inflightUploads[fingerprint] = uploadTask

        do {
            let uploadedEntry = try await uploadTask.value
            inflightUploads[fingerprint] = nil
            return .newlyUploaded(uploadedEntry)
        } catch {
            inflightUploads[fingerprint] = nil
            throw error
        }
    }
}

enum SyncAssetProcessor {
    static func run(
        descriptor: LibraryAssetDescriptor,
        queueIndex: Int,
        totalCount: Int,
        tracker: SyncProgressTracker,
        deduper: FingerprintUploadCoordinator,
        writeGate: GooglePhotosWriteGate,
        manifestStore: UploadManifestStore,
        googlePhotosAPI: GooglePhotosAPI,
        onUploadedEntry: @escaping @MainActor @Sendable (UploadManifestEntry) -> Void
    ) async throws {
        let detailPrefix = "\(queueIndex + 1) of \(totalCount)"
        await tracker.beginAsset(
            assetID: descriptor.localIdentifier,
            fileName: descriptor.fileName,
            queueIndex: queueIndex,
            estimatedSize: descriptor.estimatedByteCount,
            detail: "Preparing \(detailPrefix)"
        )

        let photoLibraryService = PhotoLibraryService(observesPhotoLibraryChanges: false)

        let preparedAsset: PreparedAsset
        do {
            preparedAsset = try await photoLibraryService.prepareAsset(for: descriptor) { progress, stage in
                let normalizedProgress: Double
                if stage == "Calculating fingerprint" {
                    normalizedProgress = 0.75 + (progress * 0.25)
                } else if stage == "Photo ready" || stage == "Video ready" {
                    normalizedProgress = 0.75
                } else {
                    normalizedProgress = progress * 0.75
                }

                await tracker.updatePreparing(
                    assetID: descriptor.localIdentifier,
                    progress: normalizedProgress,
                    detail: "\(stage) \(detailPrefix)"
                )
            }
        } catch {
            await tracker.markUnavailable(
                assetID: descriptor.localIdentifier,
                detail: "Skipped unavailable item \(detailPrefix)"
            )
            return
        }

        defer {
            try? FileManager.default.removeItem(at: preparedAsset.fileURL)
        }

        await tracker.updatePreparedSize(
            assetID: descriptor.localIdentifier,
            actualSize: preparedAsset.fileSize
        )
        await tracker.updatePreparing(
            assetID: descriptor.localIdentifier,
            progress: 1,
            detail: "Waiting for Google Photos \(detailPrefix)"
        )

        let resolution = try await deduper.resolveUpload(
            fingerprint: preparedAsset.contentFingerprint,
            fileName: descriptor.fileName,
            fileSize: preparedAsset.fileSize
        ) {
            await writeGate.acquire()
            defer {
                Task {
                    await writeGate.release()
                }
            }

            do {
                let uploadToken = try await googlePhotosAPI.uploadFile(
                    at: preparedAsset.fileURL,
                    mimeType: preparedAsset.mimeType
                ) { bytesSent in
                    await tracker.updateUploading(
                        assetID: descriptor.localIdentifier,
                        bytesSent: bytesSent,
                        detail: "Uploading \(detailPrefix)"
                    )
                }

                let createdItem = try await googlePhotosAPI.createMediaItem(
                    uploadToken: uploadToken,
                    fileName: preparedAsset.descriptor.fileName,
                    albumID: nil
                )

                let entry = UploadManifestEntry(
                    localIdentifier: descriptor.localIdentifier,
                    fileName: descriptor.fileName,
                    fileSize: preparedAsset.fileSize,
                    mediaItemID: createdItem.id,
                    productURL: createdItem.productUrl.flatMap(URL.init(string:)),
                    uploadedAt: .now,
                    contentFingerprint: preparedAsset.contentFingerprint
                )

                try await manifestStore.markUploaded(entry)
                await writeGate.registerSuccessfulWrite()
                return entry
            } catch {
                if GooglePhotosAPIError.isQuotaRateLimit(error) {
                    await writeGate.registerQuotaError()
                }
                throw error
            }
        }

        switch resolution {
        case .existing(let existingEntry):
            if existingEntry.localIdentifier != descriptor.localIdentifier {
                try await manifestStore.linkDuplicateAsset(
                    localIdentifier: descriptor.localIdentifier,
                    fileName: descriptor.fileName,
                    fileSize: preparedAsset.fileSize,
                    contentFingerprint: preparedAsset.contentFingerprint,
                    originalEntry: existingEntry
                )
            }

            await tracker.markDuplicate(
                assetID: descriptor.localIdentifier,
                detail: "Skipped duplicate \(detailPrefix)"
            )
        case .newlyUploaded(let entry):
            await tracker.markUploaded(
                assetID: descriptor.localIdentifier,
                fileSize: preparedAsset.fileSize,
                detail: "Uploaded \(detailPrefix)"
            )
            await onUploadedEntry(entry)
        }
    }
}
