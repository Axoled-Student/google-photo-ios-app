import CryptoKit
import Foundation

enum FileFingerprint {
    static func sha256Hex(
        for fileURL: URL,
        onProgress: (@Sendable (Double) async -> Void)? = nil
    ) async throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer {
            try? handle.close()
        }

        let fileSize = try fileURL.fileByteCount
        var processedBytes: Int64 = 0
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
            processedBytes += Int64(chunk.count)

            if let onProgress {
                await onProgress(
                    min(max(Double(processedBytes) / Double(max(fileSize, 1)), 0), 1)
                )
            }
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
