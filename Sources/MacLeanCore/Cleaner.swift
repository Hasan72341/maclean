import Darwin
import Foundation

public struct CleanFailure: Sendable {
    public let path: String
    public let reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

public struct CleanResult: Sendable {
    public var planned: [JunkItem] = []
    public var movedToTrash: [JunkItem] = []
    public var deleted: [JunkItem] = []
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

public struct CleanOptions: Sendable {
    public var apply: Bool
    public var permanent: Bool
    public var includeCaution: Bool
    public var categories: Set<JunkCategory>?

    public init(
        apply: Bool = false,
        permanent: Bool = false,
        includeCaution: Bool = false,
        categories: Set<JunkCategory>? = nil
    ) {
        self.apply = apply
        self.permanent = permanent
        self.includeCaution = includeCaution
        self.categories = categories
    }

    public func select(from report: ScanReport) -> [JunkItem] {
        report.items.filter { item in
            if let categories, !categories.contains(item.category) { return false }
            guard let rule = Rules.rule(id: item.ruleID) else { return false }
            if rule.scanOnly {
                guard categories?.contains(rule.category) == true, includeCaution else { return false }
            }
            if !rule.autoselect, !includeCaution { return false }
            if rule.requiresRoot, geteuid() != 0 { return false }
            return true
        }
    }
}

public final class Cleaner {
    private let home: URL
    private let fileManager: FileManager
    private let roots: RuleRoots

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        includeSystemPaths: Bool = true
    ) {
        self.home = home
        self.fileManager = fileManager
        self.roots = RuleRoots(home: home, includeSystemPaths: includeSystemPaths)
    }

    public func clean(_ items: [JunkItem], options: CleanOptions) -> CleanResult {
        var result = CleanResult()
        let ordered = items.sorted {
            $0.path.split(separator: "/").count > $1.path.split(separator: "/").count
        }

        for item in ordered {
            guard let rule = Rules.rule(id: item.ruleID) else {
                result.skipped.append(CleanFailure(path: item.path, reason: "unknown rule \(item.ruleID)"))
                continue
            }
            if rule.requiresRoot, geteuid() != 0 {
                result.skipped.append(CleanFailure(path: item.path, reason: "requires root"))
                continue
            }

            do {
                try Safety.validate(
                    path: item.path,
                    roots: roots.roots(for: rule, fileManager: fileManager),
                    home: home,
                    allowRootItself: rule.targetsRootItself,
                    fileManager: fileManager
                )
                try Safety.validateIdentity(
                    path: item.path,
                    device: item.device,
                    inode: item.inode,
                    fileManager: fileManager
                )
            } catch {
                result.skipped.append(CleanFailure(path: item.path, reason: error.localizedDescription))
                continue
            }

            guard options.apply else {
                result.planned.append(item)
                continue
            }

            do {
                switch try Removal.remove(
                    path: item.path,
                    permanent: options.permanent,
                    home: home,
                    fileManager: fileManager
                ) {
                case .deleted:
                    result.deleted.append(item)
                case .trashed:
                    result.movedToTrash.append(item)
                }
            } catch {
                result.failed.append(CleanFailure(path: item.path, reason: error.localizedDescription))
            }
        }

        return result
    }
}
