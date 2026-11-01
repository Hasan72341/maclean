import Darwin
import Foundation

/// Verbose progress reported while scanning.
public enum ScanEvent: Sendable {
    public enum SkipReason: Sendable, Equatable {
        case excluded
        case claimed
        case symbolicLink
        case empty
        case belowMinimum(Int64)

        public var text: String {
            switch self {
            case .excluded: return "excluded by rule"
            case .claimed: return "already claimed by another rule"
            case .symbolicLink: return "symbolic link"
            case .empty: return "empty"
            case .belowMinimum: return "below minimum size"
            }
        }
    }

    case ruleStarted(ruleID: String, title: String, category: JunkCategory, roots: Int)
    case ruleSkipped(ruleID: String, title: String, reason: String)
    case rootMissing(ruleID: String, path: String)
    case rootEntered(ruleID: String, path: String, entries: Int)
    case measuring(ruleID: String, path: String)
    case entrySkipped(ruleID: String, path: String, reason: SkipReason)
    case itemFound(JunkItem)
    case ruleFinished(ruleID: String, title: String, items: Int, files: Int, bytes: Int64, examined: Int, seconds: Double)
    case cancelled
}

public final class JunkScanner {
    private let home: URL
    private let fileManager: FileManager
    private let largeFileThreshold: Int64
    private let roots: RuleRoots

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        includeSystemPaths: Bool = true,
        largeFileThreshold: Int64 = 500 * 1024 * 1024
    ) {
        self.home = home
        self.fileManager = fileManager
        self.largeFileThreshold = largeFileThreshold
        self.roots = RuleRoots(home: home, includeSystemPaths: includeSystemPaths)
    }

    public func scan(categories: Set<JunkCategory>? = nil, minBytes: Int64 = 0) -> ScanReport {
        scan(categories: categories, minBytes: minBytes, rules: nil, observer: nil, isCancelled: nil)
    }

    /// Scans with optional verbose events. `rules` defaults to the active rule
    /// set (`Rules.all`); `isCancelled` is polled between entries.
    public func scan(
        categories: Set<JunkCategory>? = nil,
        minBytes: Int64 = 0,
        rules: [JunkRule]? = nil,
        observer: (@Sendable (ScanEvent) -> Void)?,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) -> ScanReport {
        var items: [JunkItem] = []
        var claimed = Set<String>()
        let emit: (ScanEvent) -> Void = { event in observer?(event) }
        let cancelled: () -> Bool = { isCancelled?() ?? false }

        for rule in rules ?? Rules.all {
            if cancelled() { emit(.cancelled); break }
            if let categories, !categories.contains(rule.category) { continue }
            if rule.requiresRoot, geteuid() != 0 {
                emit(.ruleSkipped(ruleID: rule.id, title: rule.title, reason: "needs administrator rights"))
                continue
            }

            let started = Date()
            let ruleRoots = roots.roots(for: rule, fileManager: fileManager)
            emit(.ruleStarted(ruleID: rule.id, title: rule.title, category: rule.category, roots: ruleRoots.count))
            var ruleItems = 0
            var ruleBytes: Int64 = 0
            var ruleFiles = 0
            var examined = 0

            for root in ruleRoots {
                if cancelled() { break }
                guard fileManager.fileExists(atPath: root.path) else {
                    emit(.rootMissing(ruleID: rule.id, path: root.path))
                    continue
                }

                let list = candidates(for: rule, root: root)
                emit(.rootEntered(ruleID: rule.id, path: root.path, entries: list.count))

                for candidate in list {
                    if cancelled() { break }
                    examined += 1
                    let path = candidate.standardizedFileURL.path
                    if rule.isExcluded(candidate.lastPathComponent) {
                        emit(.entrySkipped(ruleID: rule.id, path: path, reason: .excluded))
                        continue
                    }
                    if isClaimed(path, in: claimed) {
                        emit(.entrySkipped(ruleID: rule.id, path: path, reason: .claimed))
                        continue
                    }

                    emit(.measuring(ruleID: rule.id, path: path))
                    let size = FileSizer.measure(candidate, fileManager: fileManager)
                    if size.isSymbolicLink {
                        emit(.entrySkipped(ruleID: rule.id, path: path, reason: .symbolicLink))
                        continue
                    }
                    if size.files == 0 {
                        emit(.entrySkipped(ruleID: rule.id, path: path, reason: .empty))
                        continue
                    }
                    if size.bytes < minBytes {
                        emit(.entrySkipped(ruleID: rule.id, path: path, reason: .belowMinimum(size.bytes)))
                        continue
                    }

                    claimed.insert(path)
                    let item = JunkItem(
                        path: path,
                        bytes: size.bytes,
                        files: size.files,
                        ruleID: rule.id,
                        ruleTitle: rule.title,
                        category: rule.category,
                        risk: rule.risk,
                        autoselect: rule.autoselect,
                        requiresRoot: rule.requiresRoot,
                        isDirectory: size.isDirectory,
                        modified: size.modified,
                        device: size.device,
                        inode: size.inode
                    )
                    items.append(item)
                    ruleItems += 1
                    ruleBytes += size.bytes
                    ruleFiles += size.files
                    emit(.itemFound(item))
                }
            }
            emit(.ruleFinished(
                ruleID: rule.id,
                title: rule.title,
                items: ruleItems,
                files: ruleFiles,
                bytes: ruleBytes,
                examined: examined,
                seconds: Date().timeIntervalSince(started)
            ))
        }

        items.sort { lhs, rhs in
            if lhs.category != rhs.category { return lhs.category.order < rhs.category.order }
            return lhs.bytes > rhs.bytes
        }
        return ScanReport(items: items)
    }

    private func candidates(for rule: JunkRule, root: URL) -> [URL] {
        switch rule.mode {
        case .contents:
            let options: FileManager.DirectoryEnumerationOptions = []
            return (try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: Array(FileSizer.keys),
                options: options
            )) ?? []

        case .whole:
            return [root]

        case .largeFiles(let olderThanDays):
            return largeFiles(under: root, rule: rule, olderThanDays: olderThanDays)
        }
    }

    private func largeFiles(under root: URL, rule: JunkRule, olderThanDays: Int?) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(FileSizer.keys),
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { return [] }

        let cutoff = olderThanDays.map { Date().addingTimeInterval(-Double($0) * 86_400) }
        var matches: [URL] = []

        for case let url as URL in enumerator {
            if rule.isExcluded(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: FileSizer.keys) else { continue }
            if values.isSymbolicLink == true || values.isDirectory == true { continue }
            if let cutoff, let modified = values.contentModificationDate, modified > cutoff { continue }

            let size = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            if size >= largeFileThreshold {
                matches.append(url)
            }
        }
        return matches
    }

    private func isClaimed(_ path: String, in claimed: Set<String>) -> Bool {
        if claimed.contains(path) { return true }
        var current = URL(fileURLWithPath: path)
        while true {
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path || parent.path == "/" { return false }
            if claimed.contains(parent.path) { return true }
            current = parent
        }
    }
}
