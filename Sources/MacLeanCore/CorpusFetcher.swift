import CryptoKit
import Foundation

public enum CorpusFetchError: LocalizedError {
    case invalidURL
    case timedOut
    case network(String)
    case http(Int)
    case tooLarge(Int)
    case invalidDatabase
    case write(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "invalid corpus URL"
        case .timedOut: return "corpus download timed out"
        case .network(let message): return "corpus download failed: \(message)"
        case .http(let status): return "corpus server returned HTTP \(status)"
        case .tooLarge(let size): return "corpus is too large (\(size) bytes)"
        case .invalidDatabase: return "downloaded file is not a SQLite database"
        case .write(let message): return "could not cache corpus: \(message)"
        }
    }
}

public enum CorpusFetcher {
    public static let maxBytes = 64 * 1024 * 1024
    public static let cacheLifetime: TimeInterval = 24 * 60 * 60

    private struct CacheMetadata: Codable {
        let url: String
        let etag: String?
        let lastModified: String?
        let downloadedAt: Date
        let size: Int
        let sha256: String
    }

    private struct FetchResponse: @unchecked Sendable {
        let data: Data?
        let response: HTTPURLResponse?
        let error: Error?
    }

    private final class FetchBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: FetchResponse?

        func set(_ response: FetchResponse) {
            lock.lock()
            value = response
            lock.unlock()
        }

        func get() -> FetchResponse? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    public static func isRemote(_ source: String) -> Bool {
        let lower = source.lowercased()
        return lower.hasPrefix("https://") || lower.hasPrefix("http://")
    }

    public static func cacheLocation(
        for source: String,
        cacheDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL? {
        guard isRemote(source) else { return nil }
        let directory = cacheDirectory ?? defaultCacheDirectory(fileManager: fileManager)
        let key = sha256Hex(source)
        return directory.appendingPathComponent("\(key).sqlite")
    }

    public static func resolve(
        _ source: String,
        cacheDirectory: URL? = nil,
        refresh: Bool = false,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard isRemote(source) else {
            return URL(fileURLWithPath: (source as NSString).expandingTildeInPath)
        }
        guard let url = URL(string: source) else {
            throw CorpusFetchError.invalidURL
        }

        let directory = cacheDirectory ?? defaultCacheDirectory(fileManager: fileManager)
        let key = sha256Hex(source)
        let target = directory.appendingPathComponent("\(key).sqlite")
        let metadataURL = directory.appendingPathComponent("\(key).json")
        let metadata = readMetadata(metadataURL)

        if !refresh,
           let metadata,
           fileManager.fileExists(atPath: target.path),
           Date().timeIntervalSince(metadata.downloadedAt) < cacheLifetime {
            return target
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("maclean/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-sqlite3, application/octet-stream", forHTTPHeaderField: "Accept")
        if fileManager.fileExists(atPath: target.path), let metadata {
            if let etag = metadata.etag {
                request.setValue(etag, forHTTPHeaderField: "If-None-Match")
            }
            if let lastModified = metadata.lastModified {
                request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
            }
        }

        do {
            let result = try download(request)
            let status = result.response?.statusCode ?? 0

            if status == 304, fileManager.fileExists(atPath: target.path) {
                writeMetadata(
                    CacheMetadata(
                        url: source,
                        etag: result.response?.value(forHTTPHeaderField: "ETag") ?? metadata?.etag,
                        lastModified: result.response?.value(forHTTPHeaderField: "Last-Modified") ?? metadata?.lastModified,
                        downloadedAt: Date(),
                        size: metadata?.size ?? 0,
                        sha256: metadata?.sha256 ?? ""
                    ),
                    to: metadataURL
                )
                return target
            }

            guard status == 200 else {
                throw CorpusFetchError.http(status)
            }
            guard let data = result.data else {
                throw CorpusFetchError.network("empty response")
            }
            if let length = result.response?.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init),
               length > maxBytes {
                throw CorpusFetchError.tooLarge(length)
            }
            guard data.count <= maxBytes else {
                throw CorpusFetchError.tooLarge(data.count)
            }
            guard isSQLite(data) else {
                throw CorpusFetchError.invalidDatabase
            }

            try ensureDirectory(directory, fileManager: fileManager)
            let temporary = directory.appendingPathComponent("\(key).\(UUID().uuidString).tmp")
            do {
                try data.write(to: temporary)
                try? fileManager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: temporary.path
                )
                if fileManager.fileExists(atPath: target.path) {
                    _ = try fileManager.replaceItemAt(target, withItemAt: temporary)
                } else {
                    try fileManager.moveItem(at: temporary, to: target)
                }
            } catch {
                try? fileManager.removeItem(at: temporary)
                throw CorpusFetchError.write(error.localizedDescription)
            }

            let digest = sha256Hex(data)
            writeMetadata(
                CacheMetadata(
                    url: source,
                    etag: result.response?.value(forHTTPHeaderField: "ETag"),
                    lastModified: result.response?.value(forHTTPHeaderField: "Last-Modified"),
                    downloadedAt: Date(),
                    size: data.count,
                    sha256: digest
                ),
                to: metadataURL
            )
            return target
        } catch {
            if !refresh, fileManager.fileExists(atPath: target.path) {
                return target
            }
            throw error
        }
    }

    private static func download(_ request: URLRequest) throws -> FetchResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 120
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let semaphore = DispatchSemaphore(value: 0)
        let box = FetchBox()
        let task = session.dataTask(with: request) { data, response, error in
            box.set(
                FetchResponse(
                    data: data,
                    response: response as? HTTPURLResponse,
                    error: error
                )
            )
            semaphore.signal()
        }
        task.resume()

        if semaphore.wait(timeout: .now() + 120) == .timedOut {
            task.cancel()
            throw CorpusFetchError.timedOut
        }
        guard let result = box.get() else {
            throw CorpusFetchError.network("no response")
        }
        if let error = result.error {
            throw CorpusFetchError.network(error.localizedDescription)
        }
        return result
    }

    private static func isSQLite(_ data: Data) -> Bool {
        data.starts(with: Data("SQLite format 3\u{0}".utf8))
    }

    private static func defaultCacheDirectory(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
        return base.appendingPathComponent("maclean/corpus", isDirectory: true)
    }

    private static func ensureDirectory(_ directory: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }

    private static func readMetadata(_ url: URL) -> CacheMetadata? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CacheMetadata.self, from: data)
    }

    private static func writeMetadata(_ metadata: CacheMetadata, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(metadata) else { return }
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private static func sha256Hex(_ string: String) -> String {
        sha256Hex(Data(string.utf8))
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
