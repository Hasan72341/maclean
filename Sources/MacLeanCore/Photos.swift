import Foundation

public struct PhotosLibraryInfo: Codable, Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let originalFiles: Int
    public let bytes: Int64

    public init(path: String, originalFiles: Int, bytes: Int64) {
        self.path = path
        self.originalFiles = originalFiles
        self.bytes = bytes
    }
}

public struct PhotosDuplicateReport: Codable, Sendable {
    public let libraries: [PhotosLibraryInfo]
    public let exactGroups: [DuplicateGroup]
    public let similarGroups: [SimilarImageGroup]
    public let wastedBytes: Int64
    public let similarBytes: Int64
    public let error: String?

    public init(
        libraries: [PhotosLibraryInfo],
        exactGroups: [DuplicateGroup],
        similarGroups: [SimilarImageGroup],
        wastedBytes: Int64,
        similarBytes: Int64,
        error: String?
    ) {
        self.libraries = libraries
        self.exactGroups = exactGroups
        self.similarGroups = similarGroups
        self.wastedBytes = wastedBytes
        self.similarBytes = similarBytes
        self.error = error
    }

    public static let empty = PhotosDuplicateReport(
        libraries: [],
        exactGroups: [],
        similarGroups: [],
        wastedBytes: 0,
        similarBytes: 0,
        error: nil
    )
}

public enum PhotosDuplicateScanner {
    public static func scan(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        libraries: [URL]? = nil,
        includeSimilar: Bool = false,
        maxDistance: Int = 10,
        fileManager: FileManager = .default
    ) -> PhotosDuplicateReport {
        let libraryURLs = libraries ?? discoverLibraries(home: home, fileManager: fileManager)
        var infos: [PhotosLibraryInfo] = []
        var exact: [DuplicateGroup] = []
        var similar: [SimilarImageGroup] = []
        var originalsDirectories: [URL] = []

        for library in libraryURLs {
            let originals = library.appendingPathComponent("originals", isDirectory: true)
            guard fileManager.fileExists(atPath: originals.path) else { continue }
            let size = FileSizer.measure(originals, fileManager: fileManager)
            infos.append(
                PhotosLibraryInfo(
                    path: library.path,
                    originalFiles: size.files,
                    bytes: size.bytes
                )
            )
            originalsDirectories.append(originals)
        }

        for originals in originalsDirectories {
            exact.append(contentsOf: DuplicateScanner.scan(
                directories: [originals],
                minBytes: 1,
                fileManager: fileManager
            ))
            if includeSimilar {
                similar.append(contentsOf: SimilarImageScanner.scan(
                    directories: [originals],
                    maxDistance: maxDistance,
                    minBytes: 1,
                    fileManager: fileManager
                ))
            }
        }

        exact.sort { $0.wastedBytes > $1.wastedBytes }
        similar.sort { $0.bytes > $1.bytes }
        return PhotosDuplicateReport(
            libraries: infos,
            exactGroups: exact,
            similarGroups: similar,
            wastedBytes: exact.reduce(0) { $0 + $1.wastedBytes },
            similarBytes: similar.reduce(0) { $0 + $1.bytes },
            error: originalsDirectories.isEmpty
                ? "No Photos library originals were accessible."
                : nil
        )
    }

    public static func discoverLibraries(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [URL] {
        let pictures = home.appendingPathComponent("Pictures", isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: pictures,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.filter {
            $0.pathExtension.lowercased() == "photoslibrary"
                && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }
}
