import AppKit
import CryptoKit
import MacLeanCore
import SwiftUI
@preconcurrency import UserNotifications

/// Checks GitHub releases for a newer MacLean, tells the user (popup in the
/// window, notification, menu bar row) and installs it in place.
///
/// Every release carries `latest.txt` (version, file name, SHA-256, size). An
/// update downloads that file, verifies the checksum, unpacks it, then quits;
/// a small helper swaps the app, signs it locally (ad-hoc, no Developer ID
/// needed) and reopens it.
@MainActor
final class Updater: NSObject, ObservableObject {
    static let shared = Updater()
    static let repo = "hasan72341/maclean"

    struct Release: Equatable {
        var version: String
        var notes: String
        var downloadURL: URL
        var sha256: String
        var size: Int64?
        var pageURL: URL
        var date: String?
    }

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate(Date)
        case available
        case downloading(received: Int64, total: Int64, rate: Double)
        case verifying
        case installing
        case failed(String)

        var busy: Bool {
            switch self {
            case .checking, .downloading, .verifying, .installing: return true
            default: return false
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var release: Release?
    @Published var showPopup = false
    @Published var autoCheck: Bool {
        didSet { UserDefaults.standard.set(autoCheck, forKey: "update.autoCheck") }
    }
    @Published private(set) var lastChecked: Date?

    private var timer: Task<Void, Never>?
    private var downloadTask: URLSessionDownloadTask?
    private var downloadStarted = Date()
    private var session: URLSession?

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    private var baseURL: String {
        ProcessInfo.processInfo.environment["MACLEAN_UPDATE_BASE"] ?? "https://github.com/\(Self.repo)/releases/latest/download"
    }

    override init() {
        autoCheck = UserDefaults.standard.object(forKey: "update.autoCheck") as? Bool ?? true
        super.init()
    }

    var updateAvailable: Bool {
        guard let release else { return false }
        return Self.isNewer(release.version, than: Self.currentVersion)
    }

    // MARK: Checking

    /// Checks shortly after launch and then every 6 hours.
    func start() {
        guard timer == nil else { return }
        timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            while !Task.isCancelled {
                if self?.autoCheck == true { await self?.check(userInitiated: false) }
                try? await Task.sleep(nanoseconds: 6 * 3600 * 1_000_000_000)
            }
        }
    }

    func check(userInitiated: Bool) async {
        guard !phase.busy else { return }
        phase = .checking
        do {
            let manifestURL = URL(string: "\(baseURL)/latest.txt")!
            var request = URLRequest(url: manifestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.setValue("MacLean/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("The update server returned an error.") }
            let fields = Self.parse(String(decoding: data, as: UTF8.self))
            guard let version = fields["version"], let app = fields["app"], let sha = fields["app_sha256"] else {
                throw UpdateError("The release manifest is malformed.")
            }
            let base = fields["download_base"] ?? baseURL
            guard let download = URL(string: "\(base)/\(app)") else { throw UpdateError("Bad download address.") }
            lastChecked = Date()
            guard Self.isNewer(version, than: Self.currentVersion) else {
                release = nil
                phase = .upToDate(Date())
                if userInitiated { ToastCenter.shared.show("MacLean \(Self.currentVersion) is up to date") }
                return
            }
            let notes = await Self.releaseNotes(version: version)
            release = Release(version: version, notes: notes, downloadURL: download, sha256: sha,
                              size: fields["app_size"].flatMap { Int64($0) },
                              pageURL: URL(string: "https://github.com/\(Self.repo)/releases/tag/v\(version)")!,
                              date: fields["date"])
            phase = .available
            let skipped = UserDefaults.standard.string(forKey: "update.skipped") == version
            if userInitiated || !skipped {
                showPopup = true
                bringWindowForward()
            }
            notifyOnce(version: version)
            // Test hook: render the popup and press Update without a person at the keyboard.
            if let snapshot = ProcessInfo.processInfo.environment["MACLEAN_UPDATE_TEST_SNAPSHOT"] {
                let renderer = ImageRenderer(content: UpdateSheet())
                renderer.scale = 2
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: snapshot))
                }
                install()
            }
        } catch {
            phase = userInitiated ? .failed(Self.describe(error)) : .idle
        }
    }

    /// Release notes from GitHub (best effort; the API allows 60 requests an hour).
    static func releaseNotes(version: String) async -> String {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/tags/v\(version)") else { return "" }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        return (json["body"] as? String) ?? ""
    }

    func skipThisVersion() {
        if let release { UserDefaults.standard.set(release.version, forKey: "update.skipped") }
        showPopup = false
    }

    private func notifyOnce(version: String) {
        let key = "update.notified"
        guard UserDefaults.standard.string(forKey: key) != version else { return }
        UserDefaults.standard.set(version, forKey: key)
        Notifier.post(title: "MacLean \(version) is available",
                      body: "You have \(Self.currentVersion). Click Update to install it now.",
                      category: Notifier.updateCategory, identifier: "update-\(version)")
    }

    private func bringWindowForward() {
        guard NSApp.windows.contains(where: { $0.isVisible && ($0.identifier?.rawValue.hasPrefix("main") == true || $0.title == "MacLean") }) else { return }
        NSApp.requestUserAttention(.informationalRequest)
    }

    // MARK: Installing

    func install() {
        guard let release, !phase.busy else { return }
        showPopup = true
        phase = .downloading(received: 0, total: release.size ?? 0, rate: 0)
        downloadStarted = Date()
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: .main)
        self.session = session
        let task = session.downloadTask(with: release.downloadURL)
        downloadTask = task
        task.resume()
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        phase = .available
    }

    fileprivate func finishedDownload(at file: URL) {
        guard let release else { return }
        phase = .verifying
        Task {
            do {
                let work = FileManager.default.temporaryDirectory.appendingPathComponent("maclean-update-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                let package = work.appendingPathComponent("MacLean.tar.xz")
                try FileManager.default.moveItem(at: file, to: package)
                let digest = try await engine { try Self.sha256(of: package) }
                guard digest == release.sha256 else { throw UpdateError("The download is damaged (checksum mismatch). Try again.") }
                phase = .installing
                let unpack = await engine { ProcessRunner.run("/usr/bin/tar", ["-xJf", package.path, "-C", work.path], timeout: 120) }
                let newApp = work.appendingPathComponent("MacLean.app")
                guard unpack.status == 0, FileManager.default.fileExists(atPath: newApp.appendingPathComponent("Contents/MacOS/MacLeanApp").path) else {
                    throw UpdateError("Could not unpack the update.")
                }
                try launchSwapHelper(newApp: newApp, work: work)
                // Leave the helper to replace the app; it reopens the new version.
                // Close the sheet first (an open sheet can veto termination), and
                // make sure the process really exits.
                showPopup = false
                try? await Task.sleep(nanoseconds: 300_000_000)
                for window in NSApp.windows { window.sheets.forEach { window.endSheet($0) } }
                NSApp.terminate(nil)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                exit(0)
            } catch {
                phase = .failed(Self.describe(error))
            }
        }
    }

    /// A detached shell helper: waits for this process to exit, swaps the bundle,
    /// signs it ad-hoc, restarts the realtime agent if it belongs to this copy,
    /// and opens the new version. Rolls back if the copy fails.
    private func launchSwapHelper(newApp: URL, work: URL) throws {
        let destination = Bundle.main.bundlePath
        guard destination.hasSuffix(".app") else { throw UpdateError("MacLean is not running from an app bundle.") }
        let parent = (destination as NSString).deletingLastPathComponent
        guard FileManager.default.isWritableFile(atPath: parent) else {
            throw UpdateError("No permission to replace \(destination). Run the installer command from the README instead.")
        }
        let script = work.appendingPathComponent("swap.sh")
        let body = #"""
        #!/bin/bash
        PID="$1"; NEW="$2"; DEST="$3"; WORK="$4"
        for _ in $(seq 1 50); do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
        kill -TERM "$PID" 2>/dev/null; sleep 1
        kill -KILL "$PID" 2>/dev/null; sleep 0.2
        rm -rf "$DEST.previous"
        mv "$DEST" "$DEST.previous" || { open "$DEST"; exit 1; }
        if ditto "$NEW" "$DEST"; then
          xattr -cr "$DEST" 2>/dev/null
          find "$DEST/Contents/Resources/bin" "$DEST/Contents/MacOS" -type f -perm +111 -exec codesign --force --sign - {} \; 2>/dev/null
          codesign --force --sign - "$DEST" >/dev/null 2>&1
          rm -rf "$DEST.previous"
        else
          rm -rf "$DEST"; mv "$DEST.previous" "$DEST"
        fi
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" >/dev/null 2>&1
        PLIST="$HOME/Library/LaunchAgents/xyz.nyora.maclean.monitor.plist"
        if [ -f "$PLIST" ] && /usr/libexec/PlistBuddy -c "Print :ProgramArguments:0" "$PLIST" 2>/dev/null | grep -q "^$DEST/"; then
          launchctl bootout "gui/$(id -u)/xyz.nyora.maclean.monitor" >/dev/null 2>&1
          launchctl bootstrap "gui/$(id -u)" "$PLIST" >/dev/null 2>&1
        fi
        open "$DEST"
        rm -rf "$WORK"
        """#
        try body.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, String(getpid()), newApp.path, destination, work.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    // MARK: Helpers

    static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            out[String(line[..<eq]).trimmingCharacters(in: .whitespaces)] = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        }
        return out
    }

    /// Numeric comparison of dotted versions ("0.10.0" > "0.9.3").
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? UpdateError { return error.message }
        if (error as? URLError)?.code == .notConnectedToInternet { return "You are offline." }
        return error.localizedDescription
    }

    struct UpdateError: Error { let message: String; init(_ m: String) { message = m } }
}

extension Updater: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        MainActor.assumeIsolated {
            let elapsed = max(0.1, Date().timeIntervalSince(downloadStarted))
            let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : (release?.size ?? 0)
            phase = .downloading(received: totalBytesWritten, total: total, rate: Double(totalBytesWritten) / elapsed)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file is deleted when this returns: move it first.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("maclean-dl-\(UUID().uuidString).tar.xz")
        let moved = (try? FileManager.default.moveItem(at: location, to: kept)) != nil
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        MainActor.assumeIsolated {
            if moved, status == 200 { finishedDownload(at: kept) }
            else { phase = .failed("Download failed (HTTP \(status)).") }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, (error as? URLError)?.code != .cancelled else { return }
        MainActor.assumeIsolated { phase = .failed(Updater.describe(error)) }
    }
}

// MARK: - Popup

struct UpdateSheet: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(Type.display(22, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text("You have \(Updater.currentVersion)\(updater.release?.size.map { " · download \(Format.bytes($0))" } ?? "")")
                        .font(Type.mono(11)).foregroundStyle(Theme.muted)
                }
                Spacer()
            }

            if let notes = updater.release?.notes, !notes.isEmpty {
                ScrollView {
                    Text(Self.cleanNotes(notes)).font(Type.text(12)).foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .frame(maxHeight: 160)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.canvas))
            }

            progress

            HStack(spacing: 16) {
                if case .available = updater.phase {
                    Button("Skip This Version") { updater.skipThisVersion() }.buttonStyle(EditorialButtonStyle(kind: .inline))
                }
                if let page = updater.release?.pageURL {
                    Button("Release Notes") { NSWorkspace.shared.open(page) }.buttonStyle(EditorialButtonStyle(kind: .inline))
                }
                Spacer()
                switch updater.phase {
                case .downloading:
                    Button("Cancel") { updater.cancelDownload() }.buttonStyle(EditorialButtonStyle(kind: .secondary))
                case .verifying, .installing:
                    EmptyView()
                case .failed:
                    Button("Close") { updater.showPopup = false }.buttonStyle(EditorialButtonStyle(kind: .secondary))
                    Button("Try Again") { updater.install() }.buttonStyle(EditorialButtonStyle(kind: .primary))
                default:
                    Button("Later") { updater.showPopup = false }.buttonStyle(EditorialButtonStyle(kind: .secondary))
                    Button("Update Now") { updater.install() }.buttonStyle(EditorialButtonStyle(kind: .primary))
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22)
        .frame(width: 480)
        .background(Theme.paper)
    }

    private var title: String {
        guard let version = updater.release?.version else { return "MacLean update" }
        switch updater.phase {
        case .installing: return "Installing \(version)…"
        default: return "MacLean \(version) is available"
        }
    }

    @ViewBuilder private var progress: some View {
        switch updater.phase {
        case .downloading(let received, let total, let rate):
            UpdateProgressBar(received: received, total: total, rate: rate)
        case .verifying:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Verifying the download (SHA-256)…").font(Type.text(12)).foregroundStyle(Theme.muted) }
        case .installing:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Installing — MacLean will reopen by itself in a moment.").font(Type.text(12)).foregroundStyle(Theme.muted) }
        case .failed(let message):
            Text(message).font(Type.text(12)).foregroundStyle(Theme.danger)
        default:
            Text("The update downloads from GitHub, is checked against its published SHA-256, and replaces this copy of MacLean. Your settings and history are kept.")
                .font(Type.text(11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// GitHub release bodies are Markdown; show them as plain readable text.
    static func cleanNotes(_ notes: String) -> String {
        notes.replacingOccurrences(of: "```sh", with: "").replacingOccurrences(of: "```", with: "")
            .replacingOccurrences(of: "\\r", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct UpdateProgressBar: View {
    let received: Int64
    let total: Int64
    let rate: Double
    var compact = false

    var body: some View {
        let fraction = total > 0 ? min(1, Double(received) / Double(total)) : 0
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.line.opacity(0.6))
                    Capsule().fill(Theme.accent).frame(width: max(4, proxy.size.width * fraction))
                }
            }
            .frame(height: compact ? 5 : 8)
            .animation(.linear(duration: 0.2), value: fraction)
            HStack {
                Text(total > 0 ? "\(Int(fraction * 100))% · \(Format.bytes(received)) of \(Format.bytes(total))" : "\(Format.bytes(received)) downloaded")
                Spacer()
                if rate > 0 {
                    let remaining = total > received ? Double(total - received) / rate : 0
                    Text("\(Format.rate(rate)) · \(remaining < 1 ? "almost done" : "\(Int(remaining.rounded(.up)))s left")")
                }
            }
            .font(Type.mono(compact ? 9 : 11)).foregroundStyle(Theme.muted)
        }
    }
}
