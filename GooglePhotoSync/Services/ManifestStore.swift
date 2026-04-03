import Foundation

actor UploadManifestStore {
    private let fileManager: FileManager
    private let fileURL: URL
    private var cachedManifest: UploadManifest?

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.fileURL = directory.appendingPathComponent("upload-manifest.json")
    }

    func snapshot() throws -> UploadManifest {
        if let cachedManifest {
            return cachedManifest
        }

        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        guard fileManager.fileExists(atPath: fileURL.path) else {
            let manifest = UploadManifest()
            cachedManifest = manifest
            return manifest
        }

        let data = try Data(contentsOf: fileURL)
        let manifest = try JSONDecoder.iso8601.decode(UploadManifest.self, from: data)
        cachedManifest = manifest
        return manifest
    }

    func uploadedIdentifiers() throws -> Set<String> {
        Set(try snapshot().entries.keys)
    }

    func entry(
        matchingContentFingerprint fingerprint: String,
        fileName: String,
        fileSize: Int64
    ) throws -> UploadManifestEntry? {
        let normalizedFileName = fileName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return try snapshot().entries.values.first(where: {
            if $0.contentFingerprint == fingerprint {
                return true
            }

            guard $0.contentFingerprint == nil else {
                return false
            }

            return $0.fileSize == fileSize &&
                $0.fileName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedFileName
        })
    }

    func uploadedCount() throws -> Int {
        try snapshot().entries.count
    }

    func recentEntries(limit: Int = 8) throws -> [UploadManifestEntry] {
        try snapshot().entries.values
            .sorted(by: { $0.uploadedAt > $1.uploadedAt })
            .prefix(limit)
            .map { $0 }
    }

    func markUploaded(_ entry: UploadManifestEntry) throws {
        var manifest = try snapshot()
        manifest.entries[entry.localIdentifier] = entry
        try persist(manifest)
    }

    func linkDuplicateAsset(
        localIdentifier: String,
        fileName: String,
        fileSize: Int64,
        contentFingerprint: String,
        originalEntry: UploadManifestEntry
    ) throws {
        var manifest = try snapshot()
        manifest.entries[localIdentifier] = UploadManifestEntry(
            localIdentifier: localIdentifier,
            fileName: fileName,
            fileSize: fileSize,
            mediaItemID: originalEntry.mediaItemID,
            productURL: originalEntry.productURL,
            uploadedAt: originalEntry.uploadedAt,
            contentFingerprint: contentFingerprint
        )
        try persist(manifest)
    }

    private func persist(_ manifest: UploadManifest) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.prettyPrinted.encode(manifest)
        try data.write(to: fileURL, options: .atomic)
        cachedManifest = manifest
    }
}

private extension JSONEncoder {
    static var prettyPrinted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
