import CoreServices
import Foundation
import MacLeanCore

final class MonitorEngine: @unchecked Sendable {
    private struct SendableBox<Value>: @unchecked Sendable {
        let value: Value
    }

    private let queue = DispatchQueue(label: "xyz.nyora.maclean.monitor.engine")
    private let corpusSource: String
    private let watchPaths: [URL]
    private let stateDirectory: URL
    private let alertsURL: URL
    private let logURL: URL

    private var stream: FSEventStreamRef?
    private var corpus: PantherCorpus? { didSet { markChanged() } }
    private var alerts: [MonitorAlert] = [] { didSet { markChanged() } }
    private var alertKeys = Set<String>()
    private var pendingPaths = Set<String>()
    private var pendingWork: DispatchWorkItem?
    private var running = false { didSet { markChanged() } }
    private var scanning = false
    private var lastScan: Date? { didSet { markChanged() } }
    private var errorMessage: String? { didSet { markChanged() } }

    // Status and alerts as last published. XPC replies read these under a
    // lock instead of waiting on `queue`, which can be busy scanning for
    // seconds at a time (the app then showed the agent as unreachable).
    private let snapshotLock = NSLock()
    private var statusSnapshot = Data()
    private var alertsSnapshot = Data("[]".utf8)
    private var publishScheduled = false
    private let maxAlerts = 500

    init(corpusSource: String, watchPaths: [URL], stateDirectory: URL) {
        self.corpusSource = corpusSource
        self.watchPaths = watchPaths
        self.stateDirectory = stateDirectory
        self.alertsURL = stateDirectory.appendingPathComponent("alerts.json")
        self.logURL = stateDirectory.appendingPathComponent("monitor.log")
        loadAlerts()
        publishNow()
    }

    /// Called on `queue` when state changes; publishes once the current work finishes.
    private func markChanged() {
        guard !publishScheduled else { return }
        publishScheduled = true
        queue.async { [weak self] in
            self?.publishScheduled = false
            self?.publishNow()
        }
    }

    private func publishNow() {
        let status = encode(MonitorStatus(running: running, watchedPaths: watchPaths.map(\.path), alertCount: alerts.count,
                                          corpusVersion: corpus?.info.version, lastScan: lastScan, error: errorMessage))
        let alertData = encode(alerts)
        snapshotLock.lock()
        statusSnapshot = status
        alertsSnapshot = alertData
        snapshotLock.unlock()
    }

    deinit {
        stopStream()
    }

    func start(completion: @escaping (String) -> Void) {
        let reply = SendableBox(value: completion)
        queue.async { [weak self] in
            guard let self else { return }
            if self.running {
                reply.value("Monitoring is already running.")
                return
            }
            do {
                try self.ensureStateDirectory()
                let resolved = try CorpusFetcher.resolve(self.corpusSource)
                self.corpus = try PantherCorpus(path: resolved.path)
                self.errorMessage = nil
            } catch {
                self.errorMessage = error.localizedDescription
                reply.value("Could not load corpus: \(error.localizedDescription)")
                return
            }

            guard self.startStream() else {
                self.errorMessage = "Could not start the file watcher."
                self.log("failed to start FSEvents")
                reply.value("Could not start the file watcher.")
                return
            }
            self.running = true
            self.setEnabled(true)
            self.log("monitoring \(self.watchPaths.map(\.path).joined(separator: ", "))")
            reply.value("Monitoring \(self.watchPaths.count) locations.")
        }
    }

    /// Remembers that the user switched monitoring on, so it resumes after a
    /// restart, logout or agent relaunch.
    private var enabledURL: URL { stateDirectory.appendingPathComponent("monitor-enabled") }
    var wasEnabled: Bool { FileManager.default.fileExists(atPath: enabledURL.path) }
    private func setEnabled(_ on: Bool) {
        if on { FileManager.default.createFile(atPath: enabledURL.path, contents: Data()) }
        else { try? FileManager.default.removeItem(at: enabledURL) }
    }

    func stop(completion: @escaping (String) -> Void) {
        let reply = SendableBox(value: completion)
        queue.async { [weak self] in
            guard let self else { return }
            self.stopStream()
            self.pendingWork?.cancel()
            self.pendingWork = nil
            self.pendingPaths.removeAll()
            self.running = false
            self.setEnabled(false)
            self.log("monitoring stopped")
            reply.value("Monitoring stopped.")
        }
    }

    func statusData() -> Data {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        return statusSnapshot
    }

    func alertsData() -> Data {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        return alertsSnapshot
    }

    func scan(paths: [String], completion: @escaping (Data) -> Void) {
        let reply = SendableBox(value: completion)
        queue.async { [weak self] in
            guard let self else { return }
            self.scanBatch(paths)
            reply.value(self.alertsDataFromQueue())
        }
    }

    func clearAlerts(completion: @escaping (Data) -> Void) {
        let reply = SendableBox(value: completion)
        queue.async { [weak self] in
            guard let self else { return }
            self.alerts.removeAll()
            self.alertKeys.removeAll()
            self.saveAlerts()
            reply.value(self.alertsDataFromQueue())
        }
    }

    func quarantine(path: String, reason: String, completion: @escaping (Data) -> Void) {
        let reply = SendableBox(value: completion)
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let record = try QuarantineManager.quarantine(
                    path: path,
                    reason: reason
                )
                self.alerts.removeAll { $0.path == path }
                self.alertKeys = Set(self.alerts.map { "\($0.path)|\($0.kind)|\($0.title)" })
                self.saveAlerts()
                reply.value(self.encode(record))
            } catch {
                reply.value(self.encode(["error": error.localizedDescription]))
            }
        }
    }

    fileprivate func ingest(_ paths: [String]) {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            for path in paths where !self.shouldIgnore(path) {
                self.pendingPaths.insert(path)
                if self.pendingPaths.count >= 500 { break }
            }
            guard !self.pendingPaths.isEmpty else { return }
            // Debounce with a deadline: the first change schedules the scan and
            // later changes join it. (Re-arming on every event starved the scan
            // forever on folders that change every second.)
            guard self.pendingWork == nil else { return }
            self.log("queued \(self.pendingPaths.count) changed paths")
            let work = DispatchWorkItem { [weak self] in
                self?.pendingWork = nil
                self?.flush()
            }
            self.pendingWork = work
            self.queue.asyncAfter(deadline: .now() + 1.5, execute: work)
        }
    }

    private func flush() {
        guard running else {
            pendingPaths.removeAll()
            return
        }
        guard !scanning, !pendingPaths.isEmpty else {
            if !pendingPaths.isEmpty, !scanning {
                let work = DispatchWorkItem { [weak self] in self?.pendingWork = nil; self?.flush() }
                pendingWork = work
                queue.asyncAfter(deadline: .now() + 1.5, execute: work)
            }
            return
        }
        let paths = Array(pendingPaths)
        pendingPaths.removeAll()
        scanBatch(paths)
        if !pendingPaths.isEmpty, pendingWork == nil {
            let work = DispatchWorkItem { [weak self] in self?.pendingWork = nil; self?.flush() }
            pendingWork = work
            queue.asyncAfter(deadline: .now() + 1.5, execute: work)
        }
    }

    private func scanBatch(_ paths: [String]) {
        guard let corpus, !paths.isEmpty else { return }
        scanning = true
        defer { scanning = false }

        let urls = paths
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty else { return }

        var configuration = ScanConfiguration.protectedWithDirectories(urls)
        configuration.maxEnumerationDepth = 2
        let scanner = CorpusScanner(
            corpus: corpus,
            configuration: configuration,
            runYara: true
        )
        let result = scanner.scan(extraPaths: urls)
        let date = Date()
        lastScan = date
        self.log("scanned \(urls.count) paths, \(result.findings.count) findings")

        for finding in result.findings {
            let key = "\(finding.path)|\(finding.kind)|\(finding.title)"
            guard alertKeys.insert(key).inserted else { continue }
            alerts.append(
                MonitorAlert(
                    date: date,
                    path: finding.path,
                    title: finding.title,
                    detail: finding.detail,
                    severity: finding.severity,
                    kind: finding.kind
                )
            )
        }

        alerts.sort { $0.date > $1.date }
        if alerts.count > maxAlerts {
            alerts = Array(alerts.prefix(maxAlerts))
            alertKeys = Set(alerts.map { "\($0.path)|\($0.kind)|\($0.title)" })
        }
        if !result.findings.isEmpty {
            saveAlerts()
        }
    }

    private func shouldIgnore(_ path: String) -> Bool {
        let lower = path.lowercased()
        let state = stateDirectory.path.lowercased()
        if lower.hasPrefix(state) { return true }
        if lower.contains("/library/caches/maclean/") { return true }
        if lower.contains("/.trash/") { return true }
        if lower.contains("/application support/maclean/") { return true }
        return false
    }

    private func startStream() -> Bool {
        guard stream == nil else { return true }
        let existing = watchPaths.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return false }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
        )
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            fseventsCallback,
            &context,
            existing.map(\.path) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            flags
        ) else {
            return false
        }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        return FSEventStreamStart(created)
    }

    private func stopStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }

    private func alertsDataFromQueue() -> Data {
        encode(alerts)
    }

    private func ensureStateDirectory() throws {
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true
        )
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: stateDirectory.path
        )
    }

    private func loadAlerts() {
        guard let data = try? Data(contentsOf: alertsURL),
              let decoded = try? JSONDecoder().decode([MonitorAlert].self, from: data)
        else { return }
        alerts = decoded.sorted { $0.date > $1.date }
        alertKeys = Set(alerts.map { "\($0.path)|\($0.kind)|\($0.title)" })
    }

    private func saveAlerts() {
        do {
            try ensureStateDirectory()
            let data = try JSONEncoder().encode(alerts)
            try data.write(to: alertsURL, options: [.atomic])
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: alertsURL.path
            )
        } catch {
            errorMessage = "Could not save alerts: \(error.localizedDescription)"
        }
    }

    private func log(_ message: String) {
        do {
            try ensureStateDirectory()
            let line = "\(Date()) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: logURL.path
                )
            }
            let handle = try FileHandle(forWritingTo: logURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            // Logging must never take down the monitor.
        }
    }
}

private let fseventsCallback: FSEventStreamCallback = {
    _, info, _, eventPaths, _, _ in
    guard let info else { return }
    let engine = Unmanaged<MonitorEngine>.fromOpaque(info).takeUnretainedValue()
    let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
    engine.ingest(paths)
}
