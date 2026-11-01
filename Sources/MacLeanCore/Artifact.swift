import Foundation

public struct Artifact: Codable, Sendable, Hashable {
    public let path: String
    public let bytes: Int64
    public let files: Int
    public let group: String
    public let detail: String
    public let risk: Risk
    public let autoselect: Bool
    public let allowedRoot: String
    public let isDirectory: Bool
    public let modified: Date?
    public let device: UInt64?
    public let inode: UInt64?

    public init(
        path: String,
        bytes: Int64,
        files: Int,
        group: String,
        detail: String,
        risk: Risk,
        autoselect: Bool,
        allowedRoot: String,
        isDirectory: Bool,
        modified: Date?,
        device: UInt64? = nil,
        inode: UInt64? = nil
    ) {
        self.path = path
        self.bytes = bytes
        self.files = files
        self.group = group
        self.detail = detail
        self.risk = risk
        self.autoselect = autoselect
        self.allowedRoot = allowedRoot
        self.isDirectory = isDirectory
        self.modified = modified
        self.device = device
        self.inode = inode
    }
}

public enum ArtifactBuilder {
    public static func make(
        path: String,
        allowedRoot: String,
        group: String,
        detail: String = "",
        risk: Risk = .caution,
        autoselect: Bool = false,
        fileManager: FileManager = .default
    ) -> Artifact? {
        guard fileManager.fileExists(atPath: path) else { return nil }
        let size = FileSizer.measure(URL(fileURLWithPath: path), fileManager: fileManager)
        if size.isSymbolicLink { return nil }
        if size.files == 0, size.bytes == 0 { return nil }
        return Artifact(
            path: PathCanon.resolve(path),
            bytes: size.bytes,
            files: size.files,
            group: group,
            detail: detail,
            risk: risk,
            autoselect: autoselect,
            allowedRoot: PathCanon.resolve(allowedRoot),
            isDirectory: size.isDirectory,
            modified: size.modified,
            device: size.device,
            inode: size.inode
        )
    }
}

public struct ArtifactCleanResult: Sendable {
    public var planned: [Artifact] = []
    public var movedToTrash: [Artifact] = []
    public var deleted: [Artifact] = []
    public var skipped: [CleanFailure] = []
    public var failed: [CleanFailure] = []

    public init() {}

    public var reclaimedBytes: Int64 {
        deleted.reduce(0) { $0 + $1.bytes }
    }

    public var trashedBytes: Int64 {
        movedToTrash.reduce(0) { $0 + $1.bytes }
    }
}

public final class ArtifactCleaner {
    private let home: URL
    private let fileManager: FileManager

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        self.home = home
        self.fileManager = fileManager
    }

    public func clean(
        _ artifacts: [Artifact],
        apply: Bool,
        permanent: Bool,
        includeCaution: Bool
    ) -> ArtifactCleanResult {
        var result = ArtifactCleanResult()
        let ordered = artifacts.sorted {
            $0.path.split(separator: "/").count > $1.path.split(separator: "/").count
        }

        for artifact in ordered {
            if !artifact.autoselect, !includeCaution { continue }

            do {
                try validate(artifact)
            } catch {
                result.skipped.append(CleanFailure(path: artifact.path, reason: error.localizedDescription))
                continue
            }

            guard apply else {
                result.planned.append(artifact)
                continue
            }

            do {
                switch try Removal.remove(
                    path: artifact.path,
                    permanent: permanent,
                    home: home,
                    fileManager: fileManager
                ) {
                case .deleted:
                    result.deleted.append(artifact)
                case .trashed:
                    result.movedToTrash.append(artifact)
                }
            } catch {
                result.failed.append(CleanFailure(path: artifact.path, reason: error.localizedDescription))
            }
        }

        return result
    }

    private func validate(_ artifact: Artifact) throws {
        let root = PathCanon.resolve(artifact.allowedRoot)
        guard Self.isAllowedRoot(root, home: home) else {
            throw SafetyError.forbiddenPath(root)
        }
        try Safety.validate(
            path: artifact.path,
            roots: [URL(fileURLWithPath: root)],
            home: home,
            allowRootItself: true,
            fileManager: fileManager
        )
        try Safety.validateIdentity(
            path: artifact.path,
            device: artifact.device,
            inode: artifact.inode,
            fileManager: fileManager
        )
    }

    private static func isAllowedRoot(_ path: String, home: URL) -> Bool {
        let homePath = PathCanon.resolve(home.standardizedFileURL.path)
        guard path != homePath else { return false }
        if path.hasPrefix(homePath + "/") { return true }

        let prefixes = [
            "/Applications",
            "/Library",
            "/var/db/receipts",
            "/private/var/db/receipts",
            "/usr/local",
            "/opt",
            "/Volumes",
        ].map(PathCanon.resolve)
        return prefixes.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
}
