import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

public struct DuplicateGroup: Codable, Sendable {
    public let size: Int64
    public let hash: String
    public let paths: [String]

    public init(size: Int64, hash: String, paths: [String]) {
        self.size = size
        self.hash = hash
        self.paths = paths
    }

    public var wastedBytes: Int64 {
        size * Int64(max(0, paths.count - 1))
    }
}

public enum DuplicateScanner {
    static let keys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .fileSizeKey,
    ]

    public static func scan(
        directories: [URL],
        minBytes: Int64 = 1024 * 1024,
        fileManager: FileManager = .default
    ) -> [DuplicateGroup] {
        var bySize: [Int64: [URL]] = [:]

        for directory in directories {
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }

            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: keys) else { continue }
                if values.isSymbolicLink == true || values.isDirectory == true { continue }
                let size = Int64(values.fileSize ?? 0)
                if size < minBytes { continue }
                bySize[size, default: []].append(url)
            }
        }

        var groups: [DuplicateGroup] = []
        for (size, urls) in bySize where urls.count > 1 {
            var byHash: [String: [URL]] = [:]
            for url in urls {
                guard let hash = sha256(of: url) else { continue }
                byHash[hash, default: []].append(url)
            }
            for (hash, matches) in byHash where matches.count > 1 {
                groups.append(
                    DuplicateGroup(
                        size: size,
                        hash: hash,
                        paths: matches.map(\.path).sorted()
                    )
                )
            }
        }

        return groups.sorted { $0.wastedBytes > $1.wastedBytes }
    }

    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let data = try? handle.read(upToCount: 1 << 20)
            guard let data, !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public struct SimilarImageGroup: Codable, Sendable {
    public let paths: [String]
    public let bytes: Int64

    public init(paths: [String], bytes: Int64) {
        self.paths = paths
        self.bytes = bytes
    }
}

public enum SimilarImageScanner {
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "bmp", "gif", "webp",
    ]

    public static func scan(
        directories: [URL],
        maxDistance: Int = 10,
        minBytes: Int64 = 16 * 1024,
        maxImages: Int = 8000,
        fileManager: FileManager = .default
    ) -> [SimilarImageGroup] {
        var candidates: [(url: URL, size: Int64)] = []

        for directory in directories {
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: Array(DuplicateScanner.keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }

            for case let url as URL in enumerator {
                if candidates.count >= maxImages { break }
                guard imageExtensions.contains(url.pathExtension.lowercased()) else { continue }
                guard let values = try? url.resourceValues(forKeys: DuplicateScanner.keys) else { continue }
                if values.isSymbolicLink == true || values.isDirectory == true { continue }
                let size = Int64(values.fileSize ?? 0)
                if size < minBytes { continue }
                candidates.append((url, size))
            }
        }

        var hashed: [(url: URL, size: Int64, hash: UInt64)] = []
        for candidate in candidates {
            guard let hash = dHash(candidate.url) else { continue }
            hashed.append((candidate.url, candidate.size, hash))
        }

        var clusters: [(hash: UInt64, urls: [URL], size: Int64)] = []
        for item in hashed {
            if let index = clusters.firstIndex(where: {
                ($0.hash ^ item.hash).nonzeroBitCount <= maxDistance
            }) {
                clusters[index].urls.append(item.url)
                clusters[index].size += item.size
            } else {
                clusters.append((item.hash, [item.url], item.size))
            }
        }

        return clusters
            .filter { $0.urls.count > 1 }
            .map {
                SimilarImageGroup(
                    paths: $0.urls.map(\.path).sorted(),
                    bytes: $0.size
                )
            }
            .sorted { $0.bytes > $1.bytes }
    }

    public static func dHash(_ url: URL) -> UInt64? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
            kCGImageSourceShouldCacheImmediately: false,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let width = 9
        let height = 8
        var pixels = [UInt8](repeating: 0, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()

        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        var hash: UInt64 = 0
        var bit = 0
        for y in 0..<height {
            for x in 0..<(width - 1) {
                let left = pixels[y * width + x]
                let right = pixels[y * width + x + 1]
                if left > right {
                    hash |= (UInt64(1) << UInt64(bit))
                }
                bit += 1
            }
        }
        return hash
    }
}
