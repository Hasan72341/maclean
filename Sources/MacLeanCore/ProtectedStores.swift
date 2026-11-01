import Darwin
import Foundation

public struct ProtectedStoreItem: Codable, Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let kind: String
    public let bytes: Int64
    public let detail: String
    public let requiresRoot: Bool
    public let device: UInt64?
    public let inode: UInt64?

    public init(
        path: String,
        name: String,
        kind: String,
        bytes: Int64,
        detail: String,
        requiresRoot: Bool,
        device: UInt64? = nil,
        inode: UInt64? = nil
    ) {
        self.path = path
        self.name = name
        self.kind = kind
        self.bytes = bytes
        self.detail = detail
        self.requiresRoot = requiresRoot
        self.device = device
        self.inode = inode
    }
}

public struct UniversalBinaryItem: Codable, Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let archs: [String]
    public let bytes: Int64
    public let estimatedSavings: Int64
    public let device: UInt64?
    public let inode: UInt64?

    public init(
        path: String,
        name: String,
        archs: [String],
        bytes: Int64,
        estimatedSavings: Int64,
        device: UInt64? = nil,
        inode: UInt64? = nil
    ) {
        self.path = path
        self.name = name
        self.archs = archs
        self.bytes = bytes
        self.estimatedSavings = estimatedSavings
        self.device = device
        self.inode = inode
    }
}

public struct ProtectedStoreReport: Codable, Sendable {
    public let isRoot: Bool
    public let deletedUsers: [ProtectedStoreItem]
    public let documentVersions: [ProtectedStoreItem]
    public let systemCaches: [ProtectedStoreItem]
    public let universalBinaries: [UniversalBinaryItem]
    public let errors: [String]

    public init(
        isRoot: Bool,
        deletedUsers: [ProtectedStoreItem],
        documentVersions: [ProtectedStoreItem],
        systemCaches: [ProtectedStoreItem],
        universalBinaries: [UniversalBinaryItem],
        errors: [String]
    ) {
        self.isRoot = isRoot
        self.deletedUsers = deletedUsers
        self.documentVersions = documentVersions
        self.systemCaches = systemCaches
        self.universalBinaries = universalBinaries
        self.errors = errors
    }

    public static let empty = ProtectedStoreReport(
        isRoot: false,
        deletedUsers: [],
        documentVersions: [],
        systemCaches: [],
        universalBinaries: [],
        errors: []
    )

    public var totalBytes: Int64 {
        deletedUsers.reduce(0) { $0 + $1.bytes }
            + documentVersions.reduce(0) { $0 + $1.bytes }
            + systemCaches.reduce(0) { $0 + $1.bytes }
    }

    public var universalBytes: Int64 {
        universalBinaries.reduce(0) { $0 + $1.bytes }
    }

    public var universalSavings: Int64 {
        universalBinaries.reduce(0) { $0 + $1.estimatedSavings }
    }
}

public enum ProtectedStoreScanner {
    public static let defaultSystemCacheRoots: [URL] = [
        URL(fileURLWithPath: "/Library/Caches"),
        URL(fileURLWithPath: "/Library/Logs"),
        URL(fileURLWithPath: "/private/var/log"),
        URL(fileURLWithPath: "/private/var/db/diagnostics"),
        URL(fileURLWithPath: "/private/var/db/uuidtext"),
    ]

    public static func scan(
        deletedUsersRoot: URL = URL(fileURLWithPath: "/Users/DeletedUsers"),
        documentVersionsRoot: URL = URL(fileURLWithPath: "/.DocumentRevisions-V100"),
        systemCacheRoots: [URL] = defaultSystemCacheRoots,
        applicationRoots: [URL]? = nil,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> ProtectedStoreReport {
        var errors: [String] = []
        let deleted = scanDeletedUserInstallers(
            root: deletedUsersRoot,
            fileManager: fileManager,
            errors: &errors
        )
        let versions = scanChildren(
            root: documentVersionsRoot,
            kind: "document-version",
            detail: "Document revision history",
            requiresRoot: true,
            fileManager: fileManager,
            errors: &errors
        )
        var caches: [ProtectedStoreItem] = []
        for root in systemCacheRoots {
            caches.append(contentsOf: scanChildren(
                root: root,
                kind: "system-cache",
                detail: root.path,
                requiresRoot: true,
                fileManager: fileManager,
                errors: &errors
            ))
        }
        let universal = scanUniversalBinaries(
            applicationRoots: applicationRoots ?? [
                URL(fileURLWithPath: "/Applications"),
                home.appendingPathComponent("Applications"),
            ],
            fileManager: fileManager,
            errors: &errors
        )

        return ProtectedStoreReport(
            isRoot: geteuid() == 0,
            deletedUsers: deleted.sorted { $0.bytes > $1.bytes },
            documentVersions: versions.sorted { $0.bytes > $1.bytes },
            systemCaches: caches.sorted { $0.bytes > $1.bytes },
            universalBinaries: universal.sorted { $0.estimatedSavings > $1.estimatedSavings },
            errors: errors
        )
    }

    private static func scanDeletedUserInstallers(
        root: URL,
        fileManager: FileManager,
        errors: inout [String]
    ) -> [ProtectedStoreItem] {
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            errors.append(
                "Could not read \(root.path): \(error.localizedDescription). "
                    + "Root or Full Disk Access may be required."
            )
            return []
        }

        return entries.compactMap { entry in
            guard entry.pathExtension.lowercased() == "dmg",
                  let values = try? entry.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                  ),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else { return nil }
            let size = FileSizer.measure(entry, fileManager: fileManager)
            return ProtectedStoreItem(
                path: entry.path,
                name: entry.lastPathComponent,
                kind: "deleted-user",
                bytes: size.bytes,
                detail: "Deleted-user installer",
                requiresRoot: true,
                device: size.device,
                inode: size.inode
            )
        }
    }

    private static func scanChildren(
        root: URL,
        kind: String,
        detail: String,
        requiresRoot: Bool,
        fileManager: FileManager,
        errors: inout [String]
    ) -> [ProtectedStoreItem] {
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            errors.append(
                "Could not read \(root.path): \(error.localizedDescription). "
                    + "Root or Full Disk Access may be required."
            )
            return []
        }

        var items: [ProtectedStoreItem] = []
        for entry in entries.prefix(500) {
            guard let values = try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]),
                  values.isSymbolicLink != true else { continue }
            let size = FileSizer.measure(entry, fileManager: fileManager)
            guard size.bytes > 0 || size.isDirectory else { continue }
            items.append(
                ProtectedStoreItem(
                    path: entry.path,
                    name: entry.lastPathComponent,
                    kind: kind,
                    bytes: size.bytes,
                    detail: detail,
                    requiresRoot: requiresRoot,
                    device: size.device,
                    inode: size.inode
                )
            )
        }
        return items
    }

    private static func scanUniversalBinaries(
        applicationRoots: [URL],
        fileManager: FileManager,
        errors: inout [String]
    ) -> [UniversalBinaryItem] {
        var items: [UniversalBinaryItem] = []
        for applications in applicationRoots {
            guard let apps = try? fileManager.contentsOfDirectory(
                at: applications,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for app in apps where app.pathExtension == "app" {
                guard shouldScanApplication(app, fileManager: fileManager) else { continue }
                let contents = app.appendingPathComponent("Contents", isDirectory: true)
                guard let enumerator = fileManager.enumerator(
                    at: contents,
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles],
                    errorHandler: { _, _ in true }
                ) else { continue }

                for case let candidate as URL in enumerator {
                    guard candidate.path != "/Contents",
                          candidate.pathExtension != "lproj",
                          candidate.lastPathComponent != "CodeResources",
                          !candidate.path.contains("/_CodeSignature/"),
                          let values = try? candidate.resourceValues(
                            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                          ),
                          values.isRegularFile == true,
                          values.isSymbolicLink != true,
                          isMachO(candidate),
                          let archs = architectures(for: candidate),
                          archs.count > 1 else { continue }

                    let size = FileSizer.measure(candidate, fileManager: fileManager)
                    let estimated = max(
                        0,
                        size.bytes - size.bytes / Int64(archs.count)
                    )
                    items.append(
                        UniversalBinaryItem(
                            path: candidate.path,
                            name: app.deletingPathExtension().lastPathComponent,
                            archs: archs,
                            bytes: size.bytes,
                            estimatedSavings: estimated,
                            device: size.device,
                            inode: size.inode
                        )
                    )
                }
            }
        }
        return items
    }

    private static func shouldScanApplication(
        _ app: URL,
        fileManager: FileManager
    ) -> Bool {
        let path = PathCanon.resolve(app.path)
        if path.hasPrefix("/System/") || path.hasPrefix("/Library/Apple/") {
            return false
        }
        return true
    }

    private static func architectures(for binary: URL) -> [String]? {
        let result = ProcessRunner.run(
            "/usr/bin/lipo",
            ["-archs", binary.path],
            timeout: 10
        )
        guard result.status == 0 else { return nil }
        return result.stdout
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty && $0 != "Non-fat" }
    }

    private static func isMachO(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4), data.count == 4 else {
            return false
        }
        let magic = data.withUnsafeBytes { $0.load(as: UInt32.self) }
        let machOMagics: Set<UInt32> = [
            0xFEEDFACE, 0xCEFAEDFE, 0xFEEDFACF, 0xCFFAEDFE,
            0xCAFEBABE, 0xBEBAFECA, 0xCAFEBABF, 0xBFBAFECA,
        ]
        return machOMagics.contains(magic)
    }
}
