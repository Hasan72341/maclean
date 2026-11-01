import AppKit
import MacLeanCore
import SwiftUI

enum LensChartStyle: String, CaseIterable, Identifiable {
    case sunburst = "Sunburst"
    case bubbles = "Bubbles"
    case treemap = "Treemap"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .sunburst: return "circle.circle"
        case .bubbles: return "circle.grid.cross"
        case .treemap: return "square.grid.3x3.square"
        }
    }
}

enum LensColors {
    static func kind(_ kind: LensKind) -> Color {
        switch kind {
        case .apps: return Color(nsColor: .systemIndigo)
        case .video: return Theme.accent
        case .audio: return Theme.info
        case .images: return Theme.success
        case .documents: return Theme.warning
        case .archives: return Theme.danger
        case .developer: return Color(nsColor: .systemPurple)
        case .other: return Color(nsColor: .systemGray)
        }
    }

    static func icon(_ item: LensItem) -> String {
        if item.isAggregate { return "ellipsis.circle" }
        if item.isPackage && item.kind == .apps { return "app.dashed" }
        if item.isDirectory { return item.isPackage ? "shippingbox" : "folder.fill" }
        switch item.kind {
        case .apps: return "app"
        case .video: return "film"
        case .audio: return "music.note"
        case .images: return "photo"
        case .documents: return "doc.text"
        case .archives: return "archivebox"
        case .developer: return "chevron.left.forwardslash.chevron.right"
        case .other: return "doc"
        }
    }

    /// Colour of a direct child of the folder being shown.
    static func child(_ item: LensItem, index: Int) -> Color {
        if item.isAggregate { return Theme.faint }
        if item.isDirectory { return SpacePalette.color(index) }
        return kind(item.kind)
    }
}

/// Space Lens scans: one full tree per scanned root. Folders below a scanned
/// root are served from that tree without rescanning.
@MainActor
final class LensStore: ObservableObject {
    static let shared = LensStore()

    final class Session: Identifiable {
        let root: String
        let progress = LensProgress()
        let started = Date()
        var result: LensResult?
        var state: LoadState = .loading("Starting…")
        var finished: Date?
        var live = LensProgress().snapshot
        var rateHistory: [Double] = []
        /// Opened from a saved map instead of a fresh scan.
        var fromDisk = false
        /// Scanned by the CLI as root after the administrator password prompt.
        var elevated = false
        var adminCancelFile: String?
        var note: String?
        var scanned: Date?
        var bytesHistory: [Double] = []
        var id: String { root }

        init(root: String) { self.root = root }

        var elapsed: TimeInterval { (finished ?? Date()).timeIntervalSince(started) }
    }

    @Published private(set) var sessions: [String: Session] = [:]
    /// Saved maps on disk, by root.
    @Published private(set) var saved: [String: LensArchive.Header] = [:]
    private var pendingSaves: Set<String> = []

    init() {
        Task { await refreshSaved() }
    }

    func refreshSaved() async {
        let list = await engine { LensArchive.saved().map(\.header) }
        saved = Dictionary(list.map { ($0.root, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// The saved map whose tree contains `path` (deepest root wins).
    func savedHeader(covering path: String) -> LensArchive.Header? {
        let target = Self.normalize(path)
        return saved.values
            .filter { target == $0.root || target.hasPrefix($0.root == "/" ? "/" : $0.root + "/") }
            .max { $0.root.count < $1.root.count }
    }
    /// Bumped whenever a session or tree changes, so views refresh.
    @Published private(set) var revision = 0
    @Published var style: LensChartStyle = LensChartStyle(rawValue: UserDefaults.standard.string(forKey: "lens.style") ?? "") ?? .sunburst {
        didSet { UserDefaults.standard.set(style.rawValue, forKey: "lens.style") }
    }

    static func normalize(_ path: String) -> String {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath()
        return url.path.isEmpty ? "/" : url.path
    }

    /// The finished scan whose tree contains `path` (the deepest root wins).
    func session(covering path: String) -> Session? {
        let target = Self.normalize(path)
        return sessions.values
            .filter { s in
                guard s.result != nil else { return false }
                let prefix = s.root == "/" ? "/" : s.root + "/"
                return target == s.root || target.hasPrefix(prefix)
            }
            .max { $0.root.count < $1.root.count }
    }

    func item(_ path: String) -> LensItem? {
        session(covering: path)?.result?.root.find(Self.normalize(path))
    }

    var recent: [Session] {
        sessions.values.sorted { ($0.finished ?? $0.started) > ($1.finished ?? $1.started) }
    }

    /// Starts a scan of `path` unless a finished scan already covers it.
    func scan(_ path: String, force: Bool = false) {
        let root = Self.normalize(path)
        if let existing = sessions[root], existing.state.isLoading { return }
        if !force, session(covering: root) != nil { return }
        if !force, let header = savedHeader(covering: root), sessions[header.root] == nil {
            openSaved(header.root)
            return
        }
        if root == "/", !Self.adminDisabled, let cli = CLI.locate(), getuid() != 0 {
            scanAsAdmin(root, cli: cli.path)
            return
        }
        startScan(root)
    }

    /// Smoke tests and the "scan without password" fallback.
    nonisolated static var adminDisabled: Bool { ProcessInfo.processInfo.environment["MACLEAN_LENS_NO_ADMIN"] != nil }

    private func startScan(_ root: String, note: String? = nil) {
        let session = Session(root: root)
        session.note = note
        session.state = .loading("Scanning \(SpacePaths.display(root))…")
        sessions[root] = session
        revision += 1

        let progress = session.progress
        let url = URL(fileURLWithPath: root)
        Task {
            // Live counters twice a second while the engine walks the tree.
            var lastFiles = 0
            while session.state.isLoading {
                let snap = progress.snapshot
                session.live = snap
                session.rateHistory.append(Double(snap.files - lastFiles) * 2)
                session.bytesHistory.append(Double(snap.bytes))
                if session.rateHistory.count > 120 { session.rateHistory.removeFirst() }
                if session.bytesHistory.count > 120 { session.bytesHistory.removeFirst() }
                lastFiles = snap.files
                revision += 1
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        Task {
            let result = await engine(priority: .userInitiated) { LensScanner.scan(root: url, progress: progress) }
            session.live = progress.snapshot
            session.finished = Date()
            if result.cancelled {
                session.state = .failed("Scan cancelled")
                sessions[root] = nil
            } else if !FileManager.default.isReadableFile(atPath: root) {
                session.state = .failed("MacLean cannot read this folder. Grant Full Disk Access in System Settings › Privacy & Security.")
            } else {
                session.result = result
                session.scanned = Date()
                session.state = .loaded(Date())
                save(root)
            }
            revision += 1
        }
    }

    /// Scans as root: macOS asks for the administrator password, then the
    /// bundled CLI walks the disk (system folders included) and writes the map
    /// to a file this app loads. Progress is polled from a file the CLI updates.
    private func scanAsAdmin(_ root: String, cli: String) {
        let session = Session(root: root)
        session.elevated = true
        session.state = .loading("Waiting for administrator password…")
        sessions[root] = session
        revision += 1

        let work = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/MacLean/LensAdmin")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let token = UUID().uuidString.prefix(8)
        let archive = work.appendingPathComponent("scan-\(token).mlens").path
        let progressFile = work.appendingPathComponent("scan-\(token).progress").path
        session.adminCancelFile = progressFile + ".cancel"
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let command = "\(q(cli)) lens \(q(root)) --archive \(q(archive)) --progress-file \(q(progressFile)) --owner \(getuid()) 2>&1"
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        // MACLEAN_LENS_ADMIN_DRYRUN runs the same pipeline without elevation (tests).
        let elevate = ProcessInfo.processInfo.environment["MACLEAN_LENS_ADMIN_DRYRUN"] == nil
        let script = elevate ? "do shell script \"\(escaped)\" with administrator privileges with prompt \"MacLean needs your password to measure system folders in a full-disk scan.\"" : "do shell script \"\(escaped)\""

        Task {
            var lastFiles = 0
            while session.state.isLoading {
                if let text = try? String(contentsOfFile: progressFile, encoding: .utf8) {
                    let parts = text.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
                    if parts.count == 5, let files = Int(parts[0]), let folders = Int(parts[1]), let bytes = Int64(parts[2]), let unreadable = Int(parts[3]) {
                        session.live = LensProgress.Snapshot(files: files, folders: folders, bytes: bytes, unreadable: unreadable, current: parts[4])
                        session.state = .loading("Scanning as administrator…")
                        session.rateHistory.append(Double(files - lastFiles) * 2)
                        session.bytesHistory.append(Double(bytes))
                        if session.rateHistory.count > 120 { session.rateHistory.removeFirst() }
                        if session.bytesHistory.count > 120 { session.bytesHistory.removeFirst() }
                        lastFiles = files
                    }
                }
                revision += 1
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        Task {
            let run = await engine(priority: .userInitiated) { ProcessRunner.run("/usr/bin/osascript", ["-e", script], timeout: 3_600) }
            let started = FileManager.default.fileExists(atPath: progressFile)
            let loaded = run.status == 0 ? await engine(priority: .userInitiated) { LensArchive.read(URL(fileURLWithPath: archive)) } : nil
            for path in [archive, progressFile, progressFile + ".cancel"] { try? FileManager.default.removeItem(atPath: path) }
            session.finished = Date()
            if let loaded {
                session.result = loaded.result
                session.scanned = Date()
                session.live = LensProgress.Snapshot(files: loaded.result.root.files, folders: loaded.result.root.folders, bytes: loaded.result.root.bytes, unreadable: loaded.result.root.unreadable, current: "")
                session.state = .loaded(Date())
                revision += 1
                save(root)
                return
            }
            let output = (run.stdout + run.stderr)
            sessions[root] = nil
            revision += 1
            if session.progress.isCancelled {
                return // the user pressed Cancel during the scan
            } else if !started {
                // Password prompt dismissed: scan what this user can read.
                startScan(root, note: "Scanned without administrator rights — system folders that need them are not measured.")
            } else {
                startScan(root, note: "Administrator scan failed (\(output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))); scanned without it.")
            }
        }
    }

    /// Loads a saved map from disk.
    func openSaved(_ root: String) {
        let session = Session(root: root)
        session.fromDisk = true
        session.state = .loading("Opening saved map…")
        sessions[root] = session
        revision += 1
        Task {
            let url = LensArchive.file(for: root)
            let loaded = await engine(priority: .userInitiated) { LensArchive.read(url) }
            session.finished = Date()
            if let loaded {
                session.result = loaded.result
                session.scanned = loaded.header.scanned
                session.state = .loaded(loaded.header.scanned)
            } else {
                sessions[root] = nil
                saved[root] = nil
                LensArchive.delete(root: root)
                scan(root, force: true)
            }
            revision += 1
        }
    }

    /// Saves a session's tree: encoded here (the tree belongs to the main
    /// actor), written to disk in the background. Coalesces bursts.
    func save(_ root: String) {
        guard pendingSaves.insert(root).inserted else { return }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            pendingSaves.remove(root)
            guard let session = sessions[root], let result = session.result else { return }
            let (data, url) = LensArchive.encode(result, scanned: session.scanned ?? Date())
            guard let data else { return }
            _ = await engine { LensArchive.store(data, to: url) }
            await refreshSaved()
        }
    }

    func cancel(_ path: String) {
        let session = sessions[Self.normalize(path)]
        session?.progress.cancel()
        if let file = session?.adminCancelFile { FileManager.default.createFile(atPath: file, contents: Data()) }
    }

    /// Drops a map from memory but keeps it on disk (used by tests and to free memory).
    func unload(_ root: String) {
        sessions[root] = nil
        revision += 1
    }

    func forget(_ root: String) {
        sessions[root]?.progress.cancel()
        sessions[root] = nil
        saved[root] = nil
        LensArchive.delete(root: root)
        revision += 1
    }

    /// Moves items to the Trash through the validating engine path; the trees
    /// are patched by `didRemove` when the removal succeeds.
    func remove(_ items: [LensItem], title: String) async -> RemovalSummary {
        let files = items.filter { !$0.isAggregate }.map {
            SpaceFile(path: $0.path, bytes: $0.bytes, modified: $0.modified, isDirectory: $0.isDirectory, files: max(1, $0.files))
        }
        return await SpaceStore.shared.trash(files, title: title)
    }

    func didRemove(_ removed: [SpaceFile]) {
        guard !removed.isEmpty else { return }
        for session in sessions.values {
            guard let root = session.result?.root else { continue }
            var changed = false
            for file in removed {
                let path = Self.normalize(file.path)
                if path == root.path || root.path.hasPrefix(path + "/") {
                    forget(session.root)
                    changed = false
                    break
                } else if let item = root.find(path) {
                    item.remove()
                    changed = true
                } else if let folder = root.find((path as NSString).deletingLastPathComponent), folder.children.contains(where: \.isAggregate) {
                    // The item was folded into "smaller items".
                    let kind = file.isDirectory ? nil : LensKind.classify(name: file.name, isPackage: false)
                    folder.removeFolded(bytes: file.bytes, files: file.isDirectory ? file.files : 1, folders: file.isDirectory ? 1 : 0, kind: kind)
                    changed = true
                }
            }
            if changed { save(session.root) }
        }
        revision += 1
    }

    /// Largest files below `path` from the scan that covers it.
    func largest(under path: String) -> [LensFile] {
        guard let session = session(covering: path), let result = session.result else { return [] }
        let target = Self.normalize(path)
        let prefix = target == "/" ? "/" : target + "/"
        return result.largest.filter { $0.path.hasPrefix(prefix) && FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Navigates to a Lens folder, reusing an existing screen in the stack.
    static func open(_ path: String, nav: Navigator) {
        let route = Route.space(.lens(path))
        if let index = nav.path.lastIndex(of: route) {
            nav.pop(toIndex: index)
        } else {
            nav.push(route)
        }
    }

    static func open(_ item: LensItem, nav: Navigator) {
        if item.isAggregate {
            if let parent = item.parent { nav.push(.space(.lensSmall(parent.path))) }
            return
        }
        if item.isDirectory { open(item.path, nav: nav) } else { nav.push(.space(.fileDetail(item.path))) }
    }
}
