import Foundation

public struct DocumentVersionItem: Codable, Sendable, Identifiable {
    public var id: String { versionPath }
    public let filePath: String
    public let versionPath: String
    public let modified: Date
    public let bytes: Int64
    public let selected: Bool

    public init(
        filePath: String,
        versionPath: String,
        modified: Date,
        bytes: Int64,
        selected: Bool
    ) {
        self.filePath = filePath
        self.versionPath = versionPath
        self.modified = modified
        self.bytes = bytes
        self.selected = selected
    }
}

public struct DocumentVersionFile: Codable, Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let app: String
    public let bytes: Int64
    public let versions: [DocumentVersionItem]

    public init(path: String, app: String, bytes: Int64, versions: [DocumentVersionItem]) {
        self.path = path
        self.app = app
        self.bytes = bytes
        self.versions = versions
    }
}

public struct DocumentVersionsReport: Codable, Sendable {
    public let files: [DocumentVersionFile]
    public let totalBytes: Int64
    public let selectedBytes: Int64
    public let error: String?

    public init(
        files: [DocumentVersionFile],
        totalBytes: Int64,
        selectedBytes: Int64,
        error: String?
    ) {
        self.files = files
        self.totalBytes = totalBytes
        self.selectedBytes = selectedBytes
        self.error = error
    }

    public static let empty = DocumentVersionsReport(
        files: [],
        totalBytes: 0,
        selectedBytes: 0,
        error: nil
    )
}

public enum DocumentVersionsScanner {
    public static let defaultExtensions: Set<String> = [
        "pages", "sffpages", "pages-tef",
        "key", "sffkey", "key-tef",
        "numbers", "sffnumbers", "numbers-tef",
        "sketch",
    ]

    public static func scan(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        roots: [URL]? = nil,
        extensions: Set<String> = defaultExtensions,
        selectionWindow: TimeInterval = 14_400,
        maxFiles: Int = 8_000,
        fileManager: FileManager = .default
    ) -> DocumentVersionsReport {
        let searchRoots = roots ?? [
            home.appendingPathComponent("Documents"),
            home.appendingPathComponent("Desktop"),
            home.appendingPathComponent("Downloads"),
            home.appendingPathComponent("Library/Mobile Documents"),
        ].filter { fileManager.fileExists(atPath: $0.path) }

        var files: [DocumentVersionFile] = []
        var scanned = 0

        for root in searchRoots {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }

            for case let url as URL in enumerator {
                if scanned >= maxFiles { break }
                guard extensions.contains(url.pathExtension.lowercased()) else { continue }
                guard let values = try? url.resourceValues(
                    forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
                ),
                (values.isRegularFile == true || values.isDirectory == true),
                values.isSymbolicLink != true else {
                    continue
                }
                scanned += 1
                let versions = NSFileVersion.otherVersionsOfItem(at: url) ?? []
                guard !versions.isEmpty else { continue }

                let dated = versions.compactMap { version -> (NSFileVersion, Date)? in
                    guard let modified = version.modificationDate else { return nil }
                    return (version, modified)
                }.sorted { $0.1 < $1.1 }
                guard !dated.isEmpty else { continue }

                let selected = selectedIndexes(
                    dates: dated.map(\.1),
                    window: selectionWindow
                )
                let items = dated.enumerated().map { index, entry in
                    DocumentVersionItem(
                        filePath: url.path,
                        versionPath: entry.0.url.path,
                        modified: entry.1,
                        bytes: FileSizer.measure(entry.0.url, fileManager: fileManager).bytes,
                        selected: selected.contains(index)
                    )
                }
                let total = items.reduce(0) { $0 + $1.bytes }
                files.append(
                    DocumentVersionFile(
                        path: url.path,
                        app: applicationName(for: url),
                        bytes: total,
                        versions: items
                    )
                )
            }
        }

        files.sort { $0.bytes > $1.bytes }
        return DocumentVersionsReport(
            files: files,
            totalBytes: files.reduce(0) { $0 + $1.bytes },
            selectedBytes: files.reduce(0) { $0 + $1.versions.filter(\.selected).reduce(0) { $0 + $1.bytes } },
            error: searchRoots.isEmpty ? "No document search roots were accessible." : nil
        )
    }

    public static func selectedIndexes(
        dates: [Date],
        window: TimeInterval = 14_400
    ) -> Set<Int> {
        guard dates.count > 1 else { return [] }
        var selected = Set<Int>()
        for index in 1..<(dates.count - 1) {
            if abs(dates[index].timeIntervalSince(dates[index - 1])) < window {
                selected.insert(index)
            }
        }
        return selected
    }

    private static func applicationName(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "pages", "sffpages", "pages-tef": return "Pages"
        case "numbers", "sffnumbers", "numbers-tef": return "Numbers"
        case "key", "sffkey", "key-tef": return "Keynote"
        case "sketch": return "Sketch"
        default: return "Documents"
        }
    }
}

public enum DocumentVersionCleaner {
    public static func clean(
        report: DocumentVersionsReport,
        apply: Bool,
        fileManager: FileManager = .default
    ) -> DeepCleanResult {
        var result = DeepCleanResult()
        for file in report.files {
            let url = URL(fileURLWithPath: file.path)
            let versions = NSFileVersion.otherVersionsOfItem(at: url) ?? []
            guard !versions.isEmpty else {
                result.failed.append(DeepCleanFailure(
                    path: file.path,
                    reason: "could not read versions"
                ))
                continue
            }
            for item in file.versions where item.selected {
                guard let version = versions.first(where: { $0.url.path == item.versionPath }) else {
                    result.failed.append(DeepCleanFailure(
                        path: item.versionPath,
                        reason: "version disappeared"
                    ))
                    continue
                }
                result.planned.append(item.versionPath)
                guard apply else { continue }
                do {
                    try version.remove()
                    result.deleted.append(item.versionPath)
                } catch {
                    result.failed.append(DeepCleanFailure(
                        path: item.versionPath,
                        reason: error.localizedDescription
                    ))
                }
            }
        }
        return result
    }
}
