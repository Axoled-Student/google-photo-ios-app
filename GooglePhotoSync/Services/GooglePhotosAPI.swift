import Foundation

final class GooglePhotosAPI: @unchecked Sendable {
    private let session: URLSession
    private let accessTokenProvider: @Sendable () async throws -> String

    init(
        session: URLSession = .shared,
        accessTokenProvider: @escaping @Sendable () async throws -> String
    ) {
        self.session = session
        self.accessTokenProvider = accessTokenProvider
    }

    func findOrCreateAlbum(named title: String) async throws -> GoogleAlbum {
        var pageToken: String?

        repeat {
            let url = try Self.albumsURL(pageToken: pageToken)
            let request = try await authorizedRequest(url: url)
            let response: AlbumListResponse = try await decode(request)

            if let album = response.albums.first(where: {
                $0.title.compare(title, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }) {
                return album
            }

            pageToken = response.nextPageToken
        } while pageToken != nil

        var request = try await authorizedRequest(
            url: URL(string: "https://photoslibrary.googleapis.com/v1/albums")!,
            method: "POST"
        )
        request.httpBody = try JSONEncoder().encode(CreateAlbumRequest(album: AlbumPayload(title: title)))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        return try await decode(request)
    }

    func uploadFile(
        at fileURL: URL,
        mimeType: String,
        onProgress: @escaping (Int64) async -> Void
    ) async throws -> String {
        let fileSize = try fileURL.fileByteCount
        let uploadSession = try await createUploadSession(rawSize: fileSize, mimeType: mimeType)

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer {
            try? handle.close()
        }

        let preferredChunkSize = max(uploadSession.chunkGranularity, 4 * 1024 * 1024)
        let normalizedChunkSize = preferredChunkSize - (preferredChunkSize % uploadSession.chunkGranularity)
        let chunkSize = max(normalizedChunkSize, uploadSession.chunkGranularity)

        var offset: Int64 = 0

        while offset < fileSize {
            try handle.seek(toOffset: UInt64(offset))
            let count = Int(min(Int64(chunkSize), fileSize - offset))
            guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else {
                throw GooglePhotosAPIError.unexpectedEmptyChunk
            }

            let isFinalChunk = offset + Int64(chunk.count) >= fileSize
            var attempt = 0

            while true {
                do {
                    let responseData = try await sendChunk(
                        to: uploadSession.url,
                        offset: offset,
                        data: chunk,
                        finalize: isFinalChunk
                    )

                    offset += Int64(chunk.count)
                    await onProgress(offset)

                    if isFinalChunk {
                        guard let uploadToken = String(data: responseData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                            !uploadToken.isEmpty else {
                            throw GooglePhotosAPIError.missingUploadToken
                        }

                        return uploadToken
                    }

                    break
                } catch {
                    attempt += 1
                    guard attempt < 4 else {
                        throw error
                    }

                    try await Task.sleep(for: .seconds(Double(attempt)))
                    offset = try await queryUploadOffset(uploadURL: uploadSession.url, fallbackOffset: offset)
                }
            }
        }

        throw GooglePhotosAPIError.missingUploadToken
    }

    func createMediaItem(
        uploadToken: String,
        fileName: String,
        albumID: String?
    ) async throws -> CreatedMediaItem {
        let body = BatchCreateRequest(
            albumId: albumID,
            newMediaItems: [
                NewMediaItem(
                    simpleMediaItem: SimpleMediaItem(
                        uploadToken: uploadToken,
                        fileName: fileName
                    )
                )
            ]
        )

        var request = try await authorizedRequest(
            url: URL(string: "https://photoslibrary.googleapis.com/v1/mediaItems:batchCreate")!,
            method: "POST"
        )
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let response: BatchCreateResponse = try await decode(request)
        guard let result = response.newMediaItemResults.first else {
            throw GooglePhotosAPIError.invalidBatchCreateResponse
        }

        if let status = result.status {
            let statusCode = status.code ?? 0
            if statusCode != 0 {
                throw GooglePhotosAPIError.apiMessage(
                    status.message ?? "Google Photos failed to create the media item."
                )
            }
        }

        guard let mediaItem = result.mediaItem else {
            throw GooglePhotosAPIError.invalidBatchCreateResponse
        }

        return mediaItem
    }

    private func createUploadSession(rawSize: Int64, mimeType: String) async throws -> UploadSession {
        var request = try await authorizedRequest(
            url: URL(string: "https://photoslibrary.googleapis.com/v1/uploads")!,
            method: "POST"
        )
        request.setValue("0", forHTTPHeaderField: "Content-Length")
        request.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        request.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        request.setValue(mimeType, forHTTPHeaderField: "X-Goog-Upload-Content-Type")
        request.setValue(String(rawSize), forHTTPHeaderField: "X-Goog-Upload-Raw-Size")

        let (_, response) = try await perform(request)

        guard
            let uploadURLString = response.value(forHTTPHeaderField: "X-Goog-Upload-URL"),
            let uploadURL = URL(string: uploadURLString) else {
            throw GooglePhotosAPIError.missingHeader("X-Goog-Upload-URL")
        }

        let granularity = Int(response.value(forHTTPHeaderField: "X-Goog-Upload-Chunk-Granularity") ?? "")
            ?? (256 * 1024)

        return UploadSession(url: uploadURL, chunkGranularity: granularity)
    }

    private func sendChunk(
        to uploadURL: URL,
        offset: Int64,
        data: Data,
        finalize: Bool
    ) async throws -> Data {
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        request.setValue(finalize ? "upload, finalize" : "upload", forHTTPHeaderField: "X-Goog-Upload-Command")
        request.setValue(String(offset), forHTTPHeaderField: "X-Goog-Upload-Offset")

        let (responseData, _) = try await perform(request)
        return responseData
    }

    private func queryUploadOffset(uploadURL: URL, fallbackOffset: Int64) async throws -> Int64 {
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue("0", forHTTPHeaderField: "Content-Length")
        request.setValue("query", forHTTPHeaderField: "X-Goog-Upload-Command")

        let (_, response) = try await perform(request)
        guard let receivedValue = response.value(forHTTPHeaderField: "X-Goog-Upload-Size-Received"),
              let serverOffset = Int64(receivedValue) else {
            return fallbackOffset
        }

        return serverOffset
    }

    private func authorizedRequest(
        url: URL,
        method: String = "GET"
    ) async throws -> URLRequest {
        let token = try await accessTokenProvider()
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func decode<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, _) = try await perform(request)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            let body = if data.isEmpty {
                "<empty response body>"
            } else {
                String(data: data.prefix(2_048), encoding: .utf8) ?? "<non-UTF8 response body>"
            }

            throw GooglePhotosAPIError.decodingFailure(
                type: String(describing: T.self),
                message: error.localizedDescription,
                body: body
            )
        }
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0

        while true {
            do {
                let (data, response) = try await session.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw GooglePhotosAPIError.invalidHTTPResponse
                }

                guard (200..<300).contains(httpResponse.statusCode) else {
                    let message = String(data: data, encoding: .utf8) ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
                    if attempt < 4, Self.shouldRetry(statusCode: httpResponse.statusCode) {
                        attempt += 1
                        try await Self.sleepBeforeRetry(response: httpResponse, attempt: attempt)
                        continue
                    }

                    throw GooglePhotosAPIError.httpStatus(code: httpResponse.statusCode, message: message)
                }

                return (data, httpResponse)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if attempt < 4, Self.shouldRetry(error: error) {
                    attempt += 1
                    try await Self.sleepBeforeRetry(response: nil, attempt: attempt)
                    continue
                }

                throw error
            }
        }
    }

    private static func albumsURL(pageToken: String?) throws -> URL {
        var components = URLComponents(string: "https://photoslibrary.googleapis.com/v1/albums")!
        components.queryItems = [
            URLQueryItem(name: "pageSize", value: "50"),
            pageToken.map { URLQueryItem(name: "pageToken", value: $0) }
        ].compactMap { $0 }

        guard let url = components.url else {
            throw GooglePhotosAPIError.invalidHTTPResponse
        }

        return url
    }

    private static func shouldRetry(statusCode: Int) -> Bool {
        statusCode == 429 || statusCode == 500 || statusCode == 502 || statusCode == 503 || statusCode == 504
    }

    private static func shouldRetry(error: Error) -> Bool {
        guard let urlError = error as? URLError else {
            return false
        }

        switch urlError.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .notConnectedToInternet:
            return true
        default:
            return false
        }
    }

    private static func sleepBeforeRetry(
        response: HTTPURLResponse?,
        attempt: Int
    ) async throws {
        if let retryAfterHeader = response?.value(forHTTPHeaderField: "Retry-After") {
            if let retryAfterSeconds = TimeInterval(retryAfterHeader) {
                try await Task.sleep(for: .seconds(max(retryAfterSeconds, 1)))
                return
            }

            if let retryAfterDate = HTTPDateParser.date(from: retryAfterHeader) {
                let delay = retryAfterDate.timeIntervalSinceNow
                if delay > 0 {
                    try await Task.sleep(for: .seconds(delay))
                    return
                }
            }
        }

        let backoff = min(pow(2.0, Double(attempt - 1)), 8)
        try await Task.sleep(for: .seconds(backoff))
    }
}

private struct UploadSession {
    let url: URL
    let chunkGranularity: Int
}

private enum HTTPDateParser {
    static func date(from value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        return formatter.date(from: value)
    }
}

struct GoogleAlbum: Codable, Sendable {
    let id: String
    let title: String
    let productUrl: String?
}

struct CreatedMediaItem: Codable, Sendable {
    let id: String
    let productUrl: String?
}

private struct AlbumListResponse: Decodable {
    let albums: [GoogleAlbum]
    let nextPageToken: String?

    private enum CodingKeys: String, CodingKey {
        case albums
        case nextPageToken
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        albums = try container.decodeIfPresent([GoogleAlbum].self, forKey: .albums) ?? []
        nextPageToken = try container.decodeIfPresent(String.self, forKey: .nextPageToken)
    }
}

private struct CreateAlbumRequest: Encodable {
    let album: AlbumPayload
}

private struct AlbumPayload: Encodable {
    let title: String
}

private struct BatchCreateRequest: Encodable {
    let albumId: String?
    let newMediaItems: [NewMediaItem]
}

private struct NewMediaItem: Encodable {
    let simpleMediaItem: SimpleMediaItem
}

private struct SimpleMediaItem: Encodable {
    let uploadToken: String
    let fileName: String
}

private struct BatchCreateResponse: Decodable {
    let newMediaItemResults: [BatchCreateResult]

    private enum CodingKeys: String, CodingKey {
        case newMediaItemResults
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        newMediaItemResults = try container.decodeIfPresent([BatchCreateResult].self, forKey: .newMediaItemResults) ?? []
    }
}

private struct BatchCreateResult: Decodable {
    let status: GoogleStatus?
    let mediaItem: CreatedMediaItem?
}

private struct GoogleStatus: Decodable {
    let code: Int?
    let message: String?
}

enum GooglePhotosAPIError: LocalizedError {
    case invalidHTTPResponse
    case httpStatus(code: Int, message: String)
    case missingHeader(String)
    case missingUploadToken
    case invalidBatchCreateResponse
    case apiMessage(String)
    case unexpectedEmptyChunk
    case decodingFailure(type: String, message: String, body: String)

    var errorDescription: String? {
        switch self {
        case .invalidHTTPResponse:
            return "Google Photos returned an invalid HTTP response."
        case .httpStatus(let code, let message):
            return "Google Photos returned HTTP \(code): \(message)"
        case .missingHeader(let header):
            return "Google Photos did not return the required header \(header)."
        case .missingUploadToken:
            return "Google Photos did not return an upload token for the uploaded file."
        case .invalidBatchCreateResponse:
            return "Google Photos did not confirm the newly created media item."
        case .apiMessage(let message):
            return message
        case .unexpectedEmptyChunk:
            return "A prepared file produced an empty upload chunk."
        case .decodingFailure(let type, let message, let body):
            return "Failed to decode \(type): \(message). Response body: \(body)"
        }
    }
}

private extension URL {
    var fileByteCount: Int64 {
        get throws {
            let values = try resourceValues(forKeys: [.fileSizeKey])
            guard let fileSize = values.fileSize else {
                throw GooglePhotosAPIError.invalidHTTPResponse
            }

            return Int64(fileSize)
        }
    }
}
