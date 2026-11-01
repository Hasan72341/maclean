import Foundation

public struct CloudLocation: Codable, Sendable {
    public let name: String
    public let path: String
    public let bytes: Int64
    public let files: Int

    public init(name: String, path: String, bytes: Int64, files: Int) {
        self.name = name
        self.path = path
        self.bytes = bytes
        self.files = files
    }
}

public struct CloudFile: Codable, Sendable {
    public let path: String
    public let bytes: Int64
    public let modified: Date?

    public init(path: String, bytes: Int64, modified: Date?) {
        self.path = path
        self.bytes = bytes
        self.modified = modified
    }
}

public struct CloudScan: Codable, Sendable {
    public let locations: [CloudLocation]
    public let largeFiles: [CloudFile]

    public init(locations: [CloudLocation], largeFiles: [CloudFile]) {
        self.locations = locations
        self.largeFiles = largeFiles
    }
}

public enum CloudScanner {
    public static func scan(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        minLargeBytes: Int64 = 100 * 1024 * 1024,
        fileManager: FileManager = .default
    ) -> CloudScan {
        var roots: [(String, URL)] = [
            ("Dropbox", home.appendingPathComponent("Dropbox")),
            ("OneDrive", home.appendingPathComponent("OneDrive")),
            ("Google Drive", home.appendingPathComponent("Google Drive")),
            ("iCloud Drive", home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")),
        ]

        let cloudStorage = home.appendingPathComponent("Library/CloudStorage")
        if let entries = try? fileManager.contentsOfDirectory(
            at: cloudStorage,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) {
            for entry in entries {
                let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDirectory {
                    roots.append((entry.lastPathComponent, entry))
                }
            }
        }

        var seen = Set<String>()
        var locations: [CloudLocation] = []
        var largeFiles: [CloudFile] = []

        for (name, root) in roots {
            let path = root.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            guard fileManager.fileExists(atPath: path) else { continue }

            let size = FileSizer.measure(root, fileManager: fileManager)
            locations.append(
                CloudLocation(name: name, path: path, bytes: size.bytes, files: size.files)
            )
            largeFiles.append(contentsOf: files(under: root, minBytes: minLargeBytes, fileManager: fileManager))
        }

        return CloudScan(
            locations: locations.sorted { $0.bytes > $1.bytes },
            largeFiles: largeFiles.sorted { $0.bytes > $1.bytes }
        )
    }

    private static func files(
        under root: URL,
        minBytes: Int64,
        fileManager: FileManager
    ) -> [CloudFile] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(FileSizer.keys),
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var results: [CloudFile] = []
        var scanned = 0

        for case let url as URL in enumerator {
            scanned += 1
            if scanned > 200_000 { break }
            guard let values = try? url.resourceValues(forKeys: FileSizer.keys) else { continue }
            if values.isSymbolicLink == true || values.isDirectory == true { continue }
            let size = Int64(values.fileSize ?? 0)
            guard size >= minBytes else { continue }
            results.append(
                CloudFile(path: url.path, bytes: size, modified: values.contentModificationDate)
            )
        }
        return results
    }
}
