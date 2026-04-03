import Foundation
import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
final class AppModel {
    private struct LocalLibrarySnapshot: Sendable {
        let totalLibraryCount: Int
        let pendingCount: Int
    }

    let configuration: AppConfiguration

    var userProfile: GoogleUserProfile?
    var photoAccessState: PhotoAccessState
    var syncMetrics = SyncMetrics()
    var isBootstrapped = false
    var isSignedIn = false
    var isSigningIn = false
    var isSyncing = false
    var lastErrorMessage: String?
    var statusTitle: String
    var statusDetail: String
    var recentUploads: [RecentUpload] = []
    var totalLibraryCount = 0
    var uploadedCount = 0
    var pendingCount = 0
    var lastSyncDate: Date?

    private let authService: GoogleOAuthService
    private var photoLibraryService: PhotoLibraryService?
    private let manifestStore = UploadManifestStore()
    private let googlePhotosAPI: GooglePhotosAPI
    private let skipsBootstrapWork: Bool
    private var syncTask: Task<Void, Never>?
    private var pendingResync = false
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    init() {
        let configuration = AppConfiguration.load()
        let authService = GoogleOAuthService(configuration: configuration)
        let skipsBootstrapWork = ProcessInfo.processInfo.environment["UITEST_DISABLE_BOOTSTRAP"] == "1"

        self.configuration = configuration
        self.authService = authService
        self.photoLibraryService = nil
        self.googlePhotosAPI = GooglePhotosAPI { [authService] in
            try await authService.freshAccessToken()
        }
        self.skipsBootstrapWork = skipsBootstrapWork
        self.userProfile = authService.profile
        self.photoAccessState = PhotoLibraryService.currentAuthorizationState()
        self.isSignedIn = authService.isSignedIn
        self.statusTitle = "Connect your Google account"
        self.statusDetail = "Google Photo Sync uploads your Apple Photos library into Google Photos."

        updateStatus()
    }

    var primaryActionTitle: String {
        if !configuration.isConfigured {
            return "Install Latest Build"
        }

        if isSigningIn {
            return "Connecting..."
        }

        if !isSignedIn {
            return "Sign in with Google"
        }

        if !photoAccessState.isGranted {
            return "Allow Photos Access"
        }

        if isSyncing {
            return "Syncing..."
        }

        return pendingCount == 0 ? "Check for New Photos" : "Sync Now"
    }

    var primaryActionDisabled: Bool {
        isSigningIn
    }

    var canSignOut: Bool {
        isSignedIn
    }

    var canRetry: Bool {
        !isSyncing && syncMetrics.phase == .failed && isSignedIn && photoAccessState.isGranted
    }

    func bootstrap() async {
        guard !isBootstrapped else { return }
        isBootstrapped = true

        guard !skipsBootstrapWork else {
            updateStatus()
            return
        }

        await refreshLocalState()

        if configuration.isConfigured, isSignedIn, photoAccessState.isGranted, pendingCount > 0 {
            scheduleSync(reason: "startup")
        }
    }

    func handleScenePhaseChange(_ phase: ScenePhase) {
        guard phase == .active, isBootstrapped, !skipsBootstrapWork else { return }

        Task { [weak self] in
            guard let self else { return }
            await self.refreshLocalState()

            if self.configuration.isConfigured,
               self.isSignedIn,
               self.photoAccessState.isGranted,
               self.pendingCount > 0 {
                self.scheduleSync(reason: "foreground")
            }
        }
    }

    func performPrimaryAction() async {
        if !configuration.isConfigured {
            lastErrorMessage = configuration.configurationMessage
            updateStatus()
            return
        }

        if !isSignedIn {
            await signIn()
            return
        }

        if !photoAccessState.isGranted {
            await requestPhotoAccess()
            return
        }

        scheduleSync(reason: "manual")
    }

    func signOut() {
        syncTask?.cancel()
        syncTask = nil
        finishBackgroundTask()

        authService.signOut()
        userProfile = nil
        isSignedIn = false
        isSigningIn = false
        isSyncing = false
        lastErrorMessage = nil
        syncMetrics = SyncMetrics()
        pendingCount = 0
        updateStatus()
    }

    func retrySync() {
        scheduleSync(reason: "retry")
    }

    private func signIn() async {
        guard !isSigningIn else { return }
        isSigningIn = true
        lastErrorMessage = nil
        updateStatus()

        defer {
            isSigningIn = false
            updateStatus()
        }

        do {
            userProfile = try await authService.signIn()
            isSignedIn = true

            if photoAccessState == .notDetermined {
                photoAccessState = await ensurePhotoLibraryService().requestAuthorization()
            }

            await refreshLocalState()

            if photoAccessState.isGranted, pendingCount > 0 {
                scheduleSync(reason: "post-sign-in")
            }
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func requestPhotoAccess() async {
        photoAccessState = await ensurePhotoLibraryService().requestAuthorization()
        await refreshLocalState()

        if photoAccessState.isGranted, pendingCount > 0 {
            scheduleSync(reason: "photo-permission")
        }
    }

    private func scheduleSync(reason: String) {
        guard configuration.isConfigured, isSignedIn, photoAccessState.isGranted else {
            updateStatus()
            return
        }

        guard syncTask == nil else {
            pendingResync = true
            return
        }

        syncTask = Task { [weak self] in
            await self?.runSync(reason: reason)
        }
    }

    private func runSync(reason: String) async {
        beginBackgroundTask()
        isSyncing = true
        pendingResync = false
        lastErrorMessage = nil
        syncMetrics.phase = .preparing
        syncMetrics.detailText = "Scanning your Apple Photos library for items to upload."
        syncMetrics.updatedAt = .now
        updateStatus()

        defer {
            finishBackgroundTask()
            isSyncing = false
            syncTask = nil
            updateStatus()

            if pendingResync {
                pendingResync = false
                scheduleSync(reason: "queued")
            }
        }

        do {
            let uploadedIdentifiers = try await manifestStore.uploadedIdentifiers()
            let librarySnapshot = await scanLibrary(excluding: uploadedIdentifiers)
            let assets = await Task.detached(priority: .userInitiated) {
                PhotoLibraryService.fetchDescriptors(excluding: uploadedIdentifiers)
            }.value
            let photoLibraryService = ensurePhotoLibraryService()

            totalLibraryCount = librarySnapshot.totalLibraryCount
            uploadedCount = uploadedIdentifiers.count
            pendingCount = assets.count

            guard !assets.isEmpty else {
                syncMetrics.phase = .syncingComplete
                syncMetrics.currentFileName = nil
                syncMetrics.detailText = "Everything already uploaded from this device."
                syncMetrics.updatedAt = .now
                lastSyncDate = .now
                await refreshLocalState()
                return
            }

            syncMetrics = SyncMetrics(
                phase: .preparing,
                totalItems: assets.count,
                completedItems: 0,
                uploadedBytes: 0,
                estimatedTotalBytes: assets.reduce(into: Int64.zero) { partialResult, asset in
                    partialResult += asset.estimatedByteCount
                },
                currentFileName: nil,
                detailText: "Preparing \(assets.count) items for upload.",
                activeTransferStartedAt: nil,
                updatedAt: .now
            )

            let album = try await googlePhotosAPI.findOrCreateAlbum(named: configuration.albumTitle)

            for (index, asset) in assets.enumerated() {
                try Task.checkCancellation()

                syncMetrics.phase = .preparing
                syncMetrics.currentFileName = asset.fileName
                syncMetrics.detailText = "Preparing \(index + 1) of \(assets.count)"
                syncMetrics.updatedAt = .now

                do {
                    let prepared = try await photoLibraryService.prepareAsset(for: asset)
                    defer {
                        try? FileManager.default.removeItem(at: prepared.fileURL)
                    }

                    if let existingEntry = try await manifestStore.entry(
                        matchingContentFingerprint: prepared.contentFingerprint,
                        fileName: asset.fileName,
                        fileSize: prepared.fileSize
                    ) {
                        try await manifestStore.linkDuplicateAsset(
                            localIdentifier: asset.localIdentifier,
                            fileName: asset.fileName,
                            fileSize: prepared.fileSize,
                            contentFingerprint: prepared.contentFingerprint,
                            originalEntry: existingEntry
                        )

                        syncMetrics.completedItems = index + 1
                        syncMetrics.estimatedTotalBytes = max(
                            syncMetrics.uploadedBytes,
                            syncMetrics.estimatedTotalBytes - prepared.fileSize
                        )
                        syncMetrics.currentFileName = asset.fileName
                        syncMetrics.detailText = "Skipped duplicate \(index + 1) of \(assets.count)"
                        syncMetrics.updatedAt = .now

                        uploadedCount += 1
                        pendingCount = max(assets.count - (index + 1), 0)
                        continue
                    }

                    syncMetrics.estimatedTotalBytes = max(
                        syncMetrics.uploadedBytes + prepared.fileSize,
                        syncMetrics.estimatedTotalBytes + (prepared.fileSize - asset.estimatedByteCount)
                    )

                    let baseUploadedBytes = syncMetrics.uploadedBytes
                    if syncMetrics.activeTransferStartedAt == nil {
                        syncMetrics.activeTransferStartedAt = .now
                    }

                    let uploadToken = try await googlePhotosAPI.uploadFile(
                        at: prepared.fileURL,
                        mimeType: prepared.mimeType
                    ) { [weak self] bytesSent in
                        await MainActor.run {
                            guard let self else { return }
                            self.syncMetrics.phase = .uploading
                            self.syncMetrics.currentFileName = asset.fileName
                            self.syncMetrics.uploadedBytes = baseUploadedBytes + bytesSent
                            self.syncMetrics.detailText = "Uploading \(index + 1) of \(assets.count)"
                            self.syncMetrics.updatedAt = .now
                        }
                    }

                    let createdItem = try await googlePhotosAPI.createMediaItem(
                        uploadToken: uploadToken,
                        fileName: prepared.descriptor.fileName,
                        albumID: album.id
                    )

                    let entry = UploadManifestEntry(
                        localIdentifier: asset.localIdentifier,
                        fileName: asset.fileName,
                        fileSize: prepared.fileSize,
                        mediaItemID: createdItem.id,
                        productURL: createdItem.productUrl.flatMap(URL.init(string:)),
                        uploadedAt: .now,
                        contentFingerprint: prepared.contentFingerprint
                    )

                    try await manifestStore.markUploaded(entry)

                    syncMetrics.completedItems = index + 1
                    syncMetrics.uploadedBytes = baseUploadedBytes + prepared.fileSize
                    syncMetrics.detailText = "Uploaded \(index + 1) of \(assets.count)"
                    syncMetrics.updatedAt = .now

                    uploadedCount += 1
                    pendingCount = max(assets.count - (index + 1), 0)
                    lastSyncDate = entry.uploadedAt
                    recentUploads.insert(
                        RecentUpload(
                            fileName: entry.fileName,
                            uploadedAt: entry.uploadedAt,
                            mediaItemID: entry.mediaItemID,
                            productURL: entry.productURL
                        ),
                        at: 0
                    )
                    recentUploads = Array(recentUploads.prefix(8))
                }
            }

            syncMetrics.phase = .syncingComplete
            syncMetrics.activeTransferStartedAt = nil
            syncMetrics.currentFileName = nil
            syncMetrics.detailText = "Sync complete. New photos will queue automatically."
            syncMetrics.updatedAt = .now
            await refreshLocalState()
        } catch is CancellationError {
            syncMetrics = SyncMetrics()
            syncMetrics.activeTransferStartedAt = nil
            syncMetrics.detailText = "Sync paused."
            syncMetrics.updatedAt = .now
        } catch {
            lastErrorMessage = error.localizedDescription
            syncMetrics.phase = .failed
            syncMetrics.activeTransferStartedAt = nil
            syncMetrics.detailText = error.localizedDescription
            syncMetrics.updatedAt = .now
            await refreshLocalState()
        }

        _ = reason
    }

    private func refreshLocalState() async {
        do {
            let manifestEntries = try await manifestStore.recentEntries()
            recentUploads = manifestEntries.map {
                RecentUpload(
                    fileName: $0.fileName,
                    uploadedAt: $0.uploadedAt,
                    mediaItemID: $0.mediaItemID,
                    productURL: $0.productURL
                )
            }
            uploadedCount = try await manifestStore.uploadedCount()
            let uploadedIdentifiers = try await manifestStore.uploadedIdentifiers()
            let librarySnapshot = await scanLibrary(excluding: uploadedIdentifiers)
            totalLibraryCount = librarySnapshot.totalLibraryCount
            pendingCount = librarySnapshot.pendingCount
            lastSyncDate = manifestEntries.first?.uploadedAt ?? lastSyncDate
            if syncMetrics.phase != .failed {
                lastErrorMessage = nil
            }
        } catch {
            lastErrorMessage = error.localizedDescription
        }

        updateStatus()
    }

    private func scanLibrary(excluding uploadedIdentifiers: Set<String>) async -> LocalLibrarySnapshot {
        guard photoAccessState.isGranted else {
            return LocalLibrarySnapshot(totalLibraryCount: 0, pendingCount: 0)
        }

        return await Task.detached(priority: .userInitiated) {
            let descriptors = PhotoLibraryService.fetchDescriptors(excluding: uploadedIdentifiers)
            return LocalLibrarySnapshot(
                totalLibraryCount: PhotoLibraryService.syncableAssetCount(),
                pendingCount: descriptors.count
            )
        }.value
    }

    private func ensurePhotoLibraryService() -> PhotoLibraryService {
        if let photoLibraryService {
            return photoLibraryService
        }

        let photoLibraryService = PhotoLibraryService()
        photoLibraryService.onLibraryChange = { [weak self] in
            self?.handleLibraryChange()
        }
        self.photoLibraryService = photoLibraryService
        return photoLibraryService
    }

    private func handleLibraryChange() {
        guard isBootstrapped, !skipsBootstrapWork else { return }

        Task { [weak self] in
            guard let self else { return }
            await self.refreshLocalState()

            if self.isSignedIn, self.photoAccessState.isGranted, self.pendingCount > 0 {
                if self.isSyncing {
                    self.pendingResync = true
                } else {
                    self.scheduleSync(reason: "library-change")
                }
            }
        }
    }

    private func updateStatus() {
        if !configuration.isConfigured {
            statusTitle = "Google sign-in missing"
            statusDetail = configuration.configurationMessage
            return
        }

        if let lastErrorMessage, syncMetrics.phase == .failed {
            statusTitle = "Sync failed"
            statusDetail = lastErrorMessage
            return
        }

        if !isSignedIn {
            statusTitle = "Connect your Google account"
            statusDetail = "The app signs in with OAuth, creates an album named \"\(configuration.albumTitle)\", and uploads media there."
            return
        }

        if !photoAccessState.isGranted {
            statusTitle = "Allow access to Apple Photos"
            statusDetail = "The app needs read access to your Apple Photos library before it can prepare uploads."
            return
        }

        if isSyncing {
            statusTitle = "Uploading to Google Photos"
            statusDetail = "Background execution is best-effort on iOS while the app remains active."
            return
        }

        if pendingCount == 0 {
            statusTitle = "All caught up"
            if let lastSyncDate {
                statusDetail = "Last successful upload \(lastSyncDate.formatted(.relative(presentation: .named)))."
            } else {
                statusDetail = "Everything from this device is already uploaded."
            }
            return
        }

        statusTitle = "\(pendingCount) items ready to upload"
        statusDetail = "New items are detected automatically while the app is running."
    }

    private func beginBackgroundTask() {
        guard backgroundTaskID == .invalid else { return }

        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "GooglePhotoSyncUpload") { [weak self] in
            Task { @MainActor in
                self?.syncTask?.cancel()
                self?.finishBackgroundTask()
            }
        }
    }

    private func finishBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }
}
