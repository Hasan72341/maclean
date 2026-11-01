import Darwin
import Foundation

public struct DeepCleanFailure: Codable, Sendable {
    public let path: String
    public let reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

public struct DeepCleanResult: Codable, Sendable {
    public var planned: [String] = []
    public var movedToTrash: [String] = []
    public var deleted: [String] = []
    public var failed: [DeepCleanFailure] = []

    public init() {}

    public var removedCount: Int {
        movedToTrash.count + deleted.count
    }
}

public enum DeepCleaner {
    public static func cleanMailTrash(
        report: MailTrashReport,
        apply: Bool,
        permanent: Bool,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> DeepCleanResult {
        var result = DeepCleanResult()
        for mailbox in report.mailboxes {
            let mailboxPath = PathCanon.resolve(mailbox.path)
            guard let enumerator = fileManager.enumerator(
                at: URL(fileURLWithPath: mailboxPath),
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles],
                errorHandler: { _, _ in true }
            ) else { continue }

            for case let file as URL in enumerator {
                guard file.pathExtension.lowercased() == "emlx" else { continue }
                guard let values = try? file.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                ), values.isRegularFile == true, values.isSymbolicLink != true else {
                    continue
                }
                let path = PathCanon.resolve(file.path)
                guard path.hasPrefix(mailboxPath + "/") else {
                    result.failed.append(DeepCleanFailure(
                        path: file.path,
                        reason: "outside mailbox"
                    ))
                    continue
                }
                result.planned.append(path)
                guard apply else { continue }
                do {
                    switch try Removal.remove(
                        path: path,
                        permanent: permanent,
                        home: home,
                        fileManager: fileManager
                    ) {
                    case .trashed: result.movedToTrash.append(path)
                    case .deleted: result.deleted.append(path)
                    }
                } catch {
                    result.failed.append(DeepCleanFailure(
                        path: path,
                        reason: error.localizedDescription
                    ))
                }
            }
        }
        return result
    }

    public static func cleanPhotosDuplicates(
        report: PhotosDuplicateReport,
        apply: Bool,
        permanent: Bool,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> DeepCleanResult {
        var result = DeepCleanResult()
        var seen = Set<String>()
        for group in report.exactGroups {
            let ordered = group.paths.sorted()
            guard ordered.count > 1 else { continue }
            for path in ordered.dropFirst() {
                guard seen.insert(path).inserted else { continue }
                let canonical = PathCanon.resolve(path)
                guard canonical.contains(".photoslibrary/originals/") else {
                    result.failed.append(DeepCleanFailure(
                        path: path,
                        reason: "outside Photos originals"
                    ))
                    continue
                }
                guard !isSymbolicLink(canonical, fileManager: fileManager) else {
                    result.failed.append(DeepCleanFailure(
                        path: path,
                        reason: "symbolic link"
                    ))
                    continue
                }
                result.planned.append(canonical)
                guard apply else { continue }
                do {
                    switch try Removal.remove(
                        path: canonical,
                        permanent: permanent,
                        home: home,
                        fileManager: fileManager
                    ) {
                    case .trashed: result.movedToTrash.append(canonical)
                    case .deleted: result.deleted.append(canonical)
                    }
                } catch {
                    result.failed.append(DeepCleanFailure(
                        path: canonical,
                        reason: error.localizedDescription
                    ))
                }
            }
        }
        return result
    }

    public static func cleanProtectedStores(
        report: ProtectedStoreReport,
        kinds: Set<String>,
        apply: Bool,
        permanent: Bool,
        requireRoot: Bool = true,
        deletedUsersRoot: URL = URL(fileURLWithPath: "/Users/DeletedUsers"),
        documentVersionsRoot: URL = URL(fileURLWithPath: "/.DocumentRevisions-V100"),
        fileManager: FileManager = .default
    ) -> DeepCleanResult {
        var result = DeepCleanResult()
        if requireRoot, geteuid() != 0 {
            result.failed.append(DeepCleanFailure(
                path: "system",
                reason: "protected-store cleanup requires root; run with sudo"
            ))
            return result
        }
        if apply, !permanent {
            result.failed.append(DeepCleanFailure(
                path: "system",
                reason: "protected-store cleanup requires --permanent"
            ))
            return result
        }

        let groups: [(String, String, [ProtectedStoreItem])] = [
            ("deleted-user", deletedUsersRoot.path, report.deletedUsers),
            ("document-version", documentVersionsRoot.path, report.documentVersions),
            ("system-cache", "", report.systemCaches),
        ]
        for (kind, rootPath, items) in groups where kinds.contains(kind) {
            for item in items {
                let root = rootPath.isEmpty ? item.detail : rootPath
                let canonicalRoot = PathCanon.resolve(root)
                let canonical = PathCanon.resolve(item.path)
                guard canonical != canonicalRoot,
                      canonical.hasPrefix(canonicalRoot + "/"),
                      !isSymbolicLink(canonical, fileManager: fileManager) else {
                    result.failed.append(DeepCleanFailure(
                        path: item.path,
                        reason: "outside allowed root or symbolic link"
                    ))
                    continue
                }
                result.planned.append(canonical)
                guard apply else { continue }
                do {
                    try Safety.validateIdentity(
                        path: canonical,
                        device: item.device,
                        inode: item.inode,
                        fileManager: fileManager
                    )
                    switch try Removal.remove(
                        path: canonical,
                        permanent: permanent,
                        home: FileManager.default.homeDirectoryForCurrentUser,
                        fileManager: fileManager
                    ) {
                    case .trashed: result.movedToTrash.append(canonical)
                    case .deleted: result.deleted.append(canonical)
                    }
                } catch {
                    result.failed.append(DeepCleanFailure(
                        path: canonical,
                        reason: error.localizedDescription
                    ))
                }
            }
        }
        return result
    }

    private static func isSymbolicLink(
        _ path: String,
        fileManager: FileManager
    ) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path) else {
            return false
        }
        return attributes[.type] as? FileAttributeType == .typeSymbolicLink
    }
}
