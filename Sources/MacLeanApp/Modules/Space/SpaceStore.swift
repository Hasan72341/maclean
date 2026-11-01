import AppKit
import Foundation
import MacLeanCore
import SwiftUI

@MainActor
final class SpaceStore: ObservableObject {
    static let shared = SpaceStore()

    // Live
    @Published private(set) var freeHistory: [Double] = []
    @Published private(set) var usedHistory: [Double] = []
    @Published var progress: [String: SpaceProgressInfo] = [:]
    private var activeJobs: [String: SpaceProgress] = [:]

    // Overview
    @Published private(set) var breakdown: [SpaceFolderUsage] = []
    @Published private(set) var breakdownState: LoadState = .idle



    // Large & old
    @Published private(set) var largeFiles: [SpaceFile] = []
    @Published private(set) var largeState: LoadState = .idle
    @Published var largeMinMB: Int = 100
    @Published var largeOlderDays: Int = 0

    // Duplicates
    @Published private(set) var duplicates: [DuplicateGroup] = []
    @Published private(set) var dupInfo: [String: SpaceFile] = [:]
    @Published private(set) var dupState: LoadState = .idle
    @Published var dupRoots: [String] = [SpacePaths.url("Downloads").path, SpacePaths.url("Documents").path]
    @Published var dupMinMB: Double = 1

    // Similar images
    @Published private(set) var similar: [SimilarImageGroup] = []
    @Published private(set) var similarInfo: [String: SpaceFile] = [:]
    @Published private(set) var similarState: LoadState = .idle
    @Published var similarRoots: [String] = [SpacePaths.url("Pictures").path, SpacePaths.url("Downloads").path, SpacePaths.url("Desktop").path]
    @Published var similarDistance: Double = 8

    // Disk images
    @Published private(set) var diskImages: [Artifact] = []
    @Published private(set) var diskImagesState: LoadState = .idle
    @Published var diskImageAgeDays: Int = 30
    @Published var diskImageMinMB: Int = 100

    // Downloads
    @Published private(set) var downloads: [SpaceFile] = []
    @Published private(set) var downloadsState: LoadState = .idle

    // File types
    @Published private(set) var typeReport: SpaceTypeReport?
    @Published private(set) var typeState: LoadState = .idle
    @Published var typeRoot: String = SpacePaths.home

    // Cloud
    @Published private(set) var cloud: CloudScan?
    @Published private(set) var cloudState: LoadState = .idle

    // Mail
    @Published private(set) var mail: [Artifact] = []
    @Published private(set) var mailState: LoadState = .idle

    // Empty folders / archives
    @Published private(set) var emptyFolders: [SpaceFile] = []
    @Published private(set) var emptyState: LoadState = .idle
    @Published private(set) var archives: [SpaceFile] = []
    @Published private(set) var archivesState: LoadState = .idle

    // Trash / volumes
    @Published private(set) var trash: [SpaceFile] = []
    @Published private(set) var trashState: LoadState = .idle
    @Published private(set) var volumes: [SpaceVolume] = []
    @Published private(set) var volumesState: LoadState = .idle

    private var sampler: Task<Void, Never>?

    init() {
        sampler = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let disk = SystemMonitor.shared.latest.disk
                if disk.total > 0 {
                    Self.push(&self.freeHistory, Double(disk.available))
                    Self.push(&self.usedHistory, disk.usedFraction * 100)
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private static func push(_ array: inout [Double], _ value: Double) {
        array.append(value)
        if array.count > SystemMonitor.historyLength { array.removeFirst(array.count - SystemMonitor.historyLength) }
    }

    // MARK: - Job progress

    private func begin(_ key: String) -> (SpaceProgress, Task<Void, Never>) {
        activeJobs[key]?.cancel()
        let p = SpaceProgress()
        activeJobs[key] = p
        progress[key] = SpaceProgressInfo()
        let poll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.progress[key] = p.snapshot
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        return (p, poll)
    }

    private func end(_ key: String, _ p: SpaceProgress, _ poll: Task<Void, Never>) {
        poll.cancel()
        progress[key] = p.snapshot
        if activeJobs[key] === p { activeJobs[key] = nil }
    }

    func cancel(_ key: String) { activeJobs[key]?.cancel() }

    func isCancelled(_ key: String) -> Bool { activeJobs[key]?.isCancelled ?? false }

    // MARK: - Overview breakdown

    static let homeFolders: [(String, String)] = [
        ("Desktop", "menubar.dock.rectangle"), ("Documents", "doc.on.doc"), ("Downloads", "arrow.down.circle"),
        ("Library", "building.columns"), ("Movies", "film"), ("Music", "music.note"), ("Pictures", "photo.on.rectangle"),
        ("Developer", "hammer"), ("Applications", "square.grid.2x2"), (".Trash", "trash"),
    ]

    func loadBreakdown(force: Bool = false) async {
        if breakdownState.isLoading || (!force && breakdownState.loadedAt != nil) { return }
        breakdownState = .loading("Measuring home folders…")
        let folders = Self.homeFolders.map { (name: $0.0, icon: $0.1, url: SpacePaths.url($0.0)) }
        var results: [SpaceFolderUsage] = []
        await withTaskGroup(of: SpaceFolderUsage?.self) { group in
            for folder in folders {
                let url = folder.url, name = folder.name, icon = folder.icon
                group.addTask {
                    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                    let size = await engine { FileSizer.measure(url) }
                    return SpaceFolderUsage(name: name == ".Trash" ? "Trash" : name, path: url.path, bytes: size.bytes, files: size.files, icon: icon)
                }
            }
            for await item in group {
                if let item {
                    results.append(item)
                    breakdown = results.sorted { $0.bytes > $1.bytes }
                }
            }
        }
        breakdown = results.sorted { $0.bytes > $1.bytes }
        breakdownState = .loaded(Date())
    }

    // MARK: - Large & old files

    func scanLarge() async {
        let key = "large"
        largeState = .loading("Searching your home folder for large files…")
        let (p, poll) = begin(key)
        let minBytes: Int64 = 50 * 1_048_576
        let roots = [FileManager.default.homeDirectoryForCurrentUser]
        let found: [SpaceFile] = await engine {
            var out: [SpaceFile] = []
            SpaceWalker.walk(roots: roots, progress: p) { url, values in
                let size = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
                if size >= minBytes { out.append(SpaceFile.make(url, values)) }
                p.tick(url.path, matched: out.count)
            }
            return out.sorted { $0.bytes > $1.bytes }
        }
        let cancelled = p.isCancelled
        end(key, p, poll)
        largeFiles = found
        largeState = cancelled ? .failed("Scan stopped — showing \(found.count) results found so far") : .loaded(Date())
    }

    var filteredLarge: [SpaceFile] {
        let min = Int64(largeMinMB) * 1_048_576
        let cutoff = largeOlderDays > 0 ? Date().addingTimeInterval(-Double(largeOlderDays) * 86_400) : nil
        return largeFiles.filter { f in
            guard f.bytes >= min else { return false }
            if let cutoff { return (f.modified ?? .distantPast) < cutoff }
            return true
        }
    }

    // MARK: - Duplicates

    func scanDuplicates() async {
        dupState = .loading("Hashing files with matching sizes…")
        let roots = dupRoots.map { URL(fileURLWithPath: $0) }
        let minBytes = Int64(dupMinMB * 1_048_576)
        let groups = await engine { DuplicateScanner.scan(directories: roots, minBytes: max(1, minBytes)) }
        let paths = groups.flatMap(\.paths)
        let info = await engine { () -> [String: SpaceFile] in
            var map: [String: SpaceFile] = [:]
            for path in paths { if let f = SpaceFile.load(path, measure: false) { map[path] = f } }
            return map
        }
        duplicates = groups
        dupInfo = info
        dupState = .loaded(Date())
    }

    func duplicateGroup(_ hash: String) -> DuplicateGroup? { duplicates.first { $0.hash == hash } }

    /// Paths to remove so that only the newest (or oldest) copy of each group remains.
    func duplicateCopies(keepNewest: Bool, in groups: [DuplicateGroup]? = nil) -> Set<String> {
        var out = Set<String>()
        for group in groups ?? duplicates {
            let sorted = group.paths.sorted {
                let a = dupInfo[$0]?.modified ?? .distantPast, b = dupInfo[$1]?.modified ?? .distantPast
                return keepNewest ? a > b : a < b
            }
            for path in sorted.dropFirst() where SpaceSafety.canRemove(path) { out.insert(path) }
        }
        return out
    }

    // MARK: - Similar images

    func scanSimilar() async {
        similarState = .loading("Fingerprinting images…")
        let roots = similarRoots.map { URL(fileURLWithPath: $0) }
        let distance = Int(similarDistance)
        let groups = await engine { SimilarImageScanner.scan(directories: roots, maxDistance: distance) }
        let paths = groups.flatMap(\.paths)
        let info = await engine { () -> [String: SpaceFile] in
            var map: [String: SpaceFile] = [:]
            for path in paths { if let f = SpaceFile.load(path, measure: false) { map[path] = f } }
            return map
        }
        similar = groups
        similarInfo = info
        similarState = .loaded(Date())
    }

    func similarGroup(_ key: String) -> SimilarImageGroup? { similar.first { $0.paths.first == key } }

    // MARK: - Disk images

    func scanDiskImages() async {
        diskImagesState = .loading("Looking for disk images…")
        let age = diskImageAgeDays
        let minBytes = Int64(diskImageMinMB) * 1_048_576
        diskImages = await engine { DiskImageScanner.scan(olderThanDays: age, minBytes: minBytes) }
        diskImagesState = .loaded(Date())
    }

    // MARK: - Downloads

    func scanDownloads() async {
        downloadsState = .loading("Analysing Downloads…")
        let root = SpacePaths.url("Downloads")
        let result: Result<[SpaceFile], SpaceError> = await engine {
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(SpaceFile.keys), options: [.skipsHiddenFiles]) else {
                return .failure(SpaceError(message: "Cannot read ~/Downloads. Grant Full Disk Access or Files & Folders permission."))
            }
            var out: [SpaceFile] = []
            for url in entries {
                guard let values = try? url.resourceValues(forKeys: SpaceFile.keys), values.isSymbolicLink != true else { continue }
                out.append(SpaceFile.make(url, values, measureDirectories: true))
            }
            return .success(out.sorted { $0.bytes > $1.bytes })
        }
        switch result {
        case .success(let files):
            downloads = files
            downloadsState = .loaded(Date())
        case .failure(let error):
            downloadsState = .failed(error.message)
        }
    }

    nonisolated static func isStaleInstaller(_ f: SpaceFile) -> Bool {
        guard SpaceKind.installerExtensions.contains(f.ext) else { return false }
        guard let date = f.ageReference else { return false }
        return Date().timeIntervalSince(date) > 30 * 86_400
    }

    // MARK: - File types

    func scanTypes() async {
        let key = "types"
        typeState = .loading("Classifying files…")
        let (p, poll) = begin(key)
        let root = typeRoot
        let rootURL = URL(fileURLWithPath: root)
        let report: SpaceTypeReport = await engine {
            var report = SpaceTypeReport(root: root)
            var matched = 0
            let keepMin: Int64 = 256 * 1024
            SpaceWalker.walk(roots: [rootURL], skipLibrary: true, progress: p) { url, values in
                let size = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
                let ext = url.pathExtension.lowercased()
                let kind = SpaceKind.classify(ext)
                report.stats[kind.rawValue, default: SpaceKindStat()].bytes += size
                report.stats[kind.rawValue, default: SpaceKindStat()].count += 1
                let extKey = ext.isEmpty ? "(none)" : ext
                report.extensions[extKey, default: SpaceKindStat()].bytes += size
                report.extensions[extKey, default: SpaceKindStat()].count += 1
                if size >= keepMin {
                    report.files[kind.rawValue, default: []].append(SpaceFile.make(url, values))
                }
                matched += 1
                p.tick(url.path, matched: matched)
            }
            for (k, list) in report.files {
                report.files[k] = Array(list.sorted { $0.bytes > $1.bytes }.prefix(3000))
            }
            return report
        }
        end(key, p, poll)
        typeReport = report
        typeState = .loaded(Date())
    }

    // MARK: - Cloud

    func scanCloud() async {
        cloudState = .loading("Measuring cloud storage folders…")
        cloud = await engine { CloudScanner.scan(minLargeBytes: 50 * 1_048_576) }
        cloudState = .loaded(Date())
    }

    func cloudLocation(_ path: String) -> CloudLocation? { cloud?.locations.first { $0.path == path } }

    func cloudFiles(under path: String?) -> [SpaceFile] {
        (cloud?.largeFiles ?? [])
            .filter { path == nil || $0.path.hasPrefix(path! + "/") }
            .map { SpaceFile(path: $0.path, bytes: $0.bytes, modified: $0.modified) }
    }

    /// Removes local copies of iCloud Drive files while keeping them in iCloud.
    func evict(_ files: [SpaceFile]) async -> RemovalSummary {
        let paths = files.map(\.path)
        let sizes = Dictionary(files.map { ($0.path, $0.bytes) }, uniquingKeysWith: { a, _ in a })
        let summary: RemovalSummary = await engine {
            var s = RemovalSummary()
            for path in paths {
                do {
                    try FileManager.default.evictUbiquitousItem(at: URL(fileURLWithPath: path))
                    s.removed += 1
                    s.bytes += sizes[path] ?? 0
                } catch {
                    s.failures.append((path, error.localizedDescription))
                }
            }
            return s
        }
        ActivityLog.shared.record("Space", "Removed local iCloud copies", summary)
        await scanCloud()
        return summary
    }

    // MARK: - Mail

    func scanMail() async {
        mailState = .loading("Reading Mail attachment folders…")
        mail = await engine { MailScanner.scan() }
        let mailDir = SpacePaths.url("Library/Mail").path
        if mail.isEmpty, FileManager.default.fileExists(atPath: mailDir), !FileManager.default.isReadableFile(atPath: mailDir) {
            mailState = .failed("Mail data is protected. Grant Full Disk Access to MacLean to scan attachments.")
            return
        }
        mailState = .loaded(Date())
    }

    // MARK: - Empty folders

    func scanEmptyFolders() async {
        let key = "empty"
        emptyState = .loading("Looking for empty folders…")
        let (p, poll) = begin(key)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let found: [SpaceFile] = await engine {
            var out: [SpaceFile] = []
            let fm = FileManager.default
            SpaceWalker.walk(roots: [home], includeDirectories: true, progress: p) { url, values in
                p.tick(url.path, matched: out.count)
                guard values.isDirectory == true, values.isPackage != true else { return }
                guard SpaceSafety.canRemove(url.path) else { return }
                guard let entries = try? fm.contentsOfDirectory(atPath: url.path) else { return }
                let meaningful = entries.filter { $0 != ".DS_Store" && $0 != ".localized" && $0 != "Icon\r" }
                if meaningful.isEmpty {
                    var f = SpaceFile.make(url, values)
                    f.bytes = 0
                    f.files = 0
                    f.note = entries.isEmpty ? "Empty" : "Only Finder metadata"
                    out.append(f)
                }
            }
            return out.sorted { $0.path < $1.path }
        }
        end(key, p, poll)
        emptyFolders = found
        emptyState = .loaded(Date())
    }

    // MARK: - Archives

    func scanArchives() async {
        let key = "archives"
        archivesState = .loading("Looking for archives and installers…")
        let (p, poll) = begin(key)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let exts = SpaceKind.archiveExtensions
        let found: [SpaceFile] = await engine {
            var out: [SpaceFile] = []
            SpaceWalker.walk(roots: [home], includeDirectories: true, progress: p) { url, values in
                p.tick(url.path, matched: out.count)
                let ext = url.pathExtension.lowercased()
                guard exts.contains(ext) else { return }
                out.append(SpaceFile.make(url, values, measureDirectories: values.isDirectory == true))
            }
            return out.sorted { $0.bytes > $1.bytes }
        }
        end(key, p, poll)
        archives = found
        archivesState = .loaded(Date())
    }

    // MARK: - Trash & volumes

    func scanTrash() async {
        trashState = .loading("Measuring Trash…")
        let trashURL = SpacePaths.url(".Trash")
        let result: Result<[SpaceFile], SpaceError> = await engine {
            guard let entries = try? FileManager.default.contentsOfDirectory(at: trashURL, includingPropertiesForKeys: Array(SpaceFile.keys), options: []) else {
                return .failure(SpaceError(message: "Cannot read the Trash. Grant Full Disk Access to MacLean."))
            }
            var out: [SpaceFile] = []
            for url in entries where url.lastPathComponent != ".DS_Store" {
                guard let values = try? url.resourceValues(forKeys: SpaceFile.keys) else { continue }
                out.append(SpaceFile.make(url, values, measureDirectories: true))
            }
            return .success(out.sorted { $0.bytes > $1.bytes })
        }
        switch result {
        case .success(let files): trash = files; trashState = .loaded(Date())
        case .failure(let e): trashState = .failed(e.message)
        }
    }

    func emptyTrash() async -> RemovalSummary {
        let summary = await EngineActions.emptyTrash()
        ActivityLog.shared.record("Space", "Emptied Trash", summary)
        await scanTrash()
        if let index = breakdown.firstIndex(where: { $0.name == "Trash" }) {
            breakdown[index].bytes = trash.reduce(0) { $0 + $1.bytes }
            breakdown[index].files = trash.reduce(0) { $0 + $1.files }
        }
        return summary
    }

    func loadVolumes() async {
        volumesState = .loading("Reading mounted volumes…")
        volumes = await engine { SpaceVolume.list() }
        volumesState = .loaded(Date())
    }

    func eject(_ volume: SpaceVolume) async -> String? {
        let url = URL(fileURLWithPath: volume.path)
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: url)
            await loadVolumes()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Removal

    /// Moves files to the Trash through the engine, then patches every cache.
    func trash(_ files: [SpaceFile], title: String) async -> RemovalSummary {
        var refused: [(path: String, reason: String)] = []
        var allowed: [SpaceFile] = []
        for f in files {
            if let reason = SpaceSafety.refusal(f.path) { refused.append((f.path, "refused: \(reason)")) } else { allowed.append(f) }
        }
        let sizes = Dictionary(allowed.map { ($0.path, $0.bytes) }, uniquingKeysWith: { a, _ in a })
        var summary = await EngineActions.trashFiles(allowed.map(\.path), bytes: sizes)
        summary.failures.append(contentsOf: refused)
        let failed = Set(summary.failures.map(\.path))
        didRemove(allowed.filter { !failed.contains($0.path) })
        ActivityLog.shared.record("Space", title, summary)
        return summary
    }

    /// Cleans engine artifacts (mail attachments, disk images) via ArtifactCleaner.
    func clean(_ artifacts: [Artifact], title: String) async -> RemovalSummary {
        let summary = await EngineActions.cleanArtifacts(artifacts)
        let failed = Set(summary.failures.map(\.path))
        didRemove(artifacts.filter { !failed.contains($0.path) }.map(SpaceFile.from))
        ActivityLog.shared.record("Space", title, summary)
        return summary
    }

    private func didRemove(_ removed: [SpaceFile]) {
        guard !removed.isEmpty else { return }
        LensStore.shared.didRemove(removed)
        let set = Set(removed.map(\.path))
        func gone(_ p: String) -> Bool {
            if set.contains(p) { return true }
            return removed.contains { p.hasPrefix($0.path + "/") }
        }
        largeFiles.removeAll { gone($0.path) }
        downloads.removeAll { gone($0.path) }
        emptyFolders.removeAll { gone($0.path) }
        archives.removeAll { gone($0.path) }
        trash.removeAll { gone($0.path) }
        diskImages.removeAll { gone($0.path) }
        mail.removeAll { gone($0.path) }

        duplicates = duplicates.compactMap { g in
            let left = g.paths.filter { !gone($0) }
            return left.count > 1 ? DuplicateGroup(size: g.size, hash: g.hash, paths: left) : nil
        }
        similar = similar.compactMap { g in
            let left = g.paths.filter { !gone($0) }
            guard left.count > 1 else { return nil }
            let bytes = left.reduce(Int64(0)) { $0 + (similarInfo[$1]?.bytes ?? 0) }
            return SimilarImageGroup(paths: left, bytes: bytes)
        }
        if var report = typeReport {
            for f in removed where !f.isDirectory {
                let k = f.kind.rawValue
                report.stats[k]?.bytes -= f.bytes
                report.stats[k]?.count -= 1
                report.files[k]?.removeAll { $0.path == f.path }
            }
            typeReport = report
        }
        if let scan = cloud {
            let locations = scan.locations.map { loc -> CloudLocation in
                let freed = removed.filter { $0.path.hasPrefix(loc.path + "/") }
                let bytes = freed.reduce(Int64(0)) { $0 + $1.bytes }
                let count = freed.reduce(0) { $0 + $1.files }
                return CloudLocation(name: loc.name, path: loc.path, bytes: max(0, loc.bytes - bytes), files: max(0, loc.files - count))
            }
            cloud = CloudScan(locations: locations, largeFiles: scan.largeFiles.filter { !gone($0.path) })
        }
        for f in removed {
            for index in breakdown.indices where f.path.hasPrefix(breakdown[index].path + "/") {
                breakdown[index].bytes = max(0, breakdown[index].bytes - f.bytes)
                breakdown[index].files = max(0, breakdown[index].files - f.files)
            }
        }
    }

    // MARK: - Folder picking

    func chooseFolders(multiple: Bool = true) -> [String] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = multiple
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.prompt = "Choose"
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.map(\.path)
    }
}

struct SpaceError: Error, Sendable {
    var message: String
}
