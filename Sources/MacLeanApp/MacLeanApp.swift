import Foundation
import MacLeanCore
import SwiftUI

struct CLIOutput: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String
}

struct CLIError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

enum CLI {
    static func locate() -> URL? {
        let fileManager = FileManager.default
        var candidates: [URL] = []

        if let executable = Bundle.main.executableURL {
            let directory = executable.deletingLastPathComponent()
            candidates.append(directory.appendingPathComponent("maclean"))
            candidates.append(directory.appendingPathComponent("maclean-cli"))
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("maclean"))
            candidates.append(resources.appendingPathComponent("bin/maclean"))
        }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for directory in path.split(separator: ":") {
                candidates.append(URL(fileURLWithPath: String(directory)).appendingPathComponent("maclean"))
            }
        }
        let working = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        candidates.append(working.appendingPathComponent(".build/release/maclean"))
        candidates.append(working.appendingPathComponent(".build/debug/maclean"))

        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    static func run(_ arguments: [String], timeout: TimeInterval = 900) async throws -> CLIOutput {
        guard let executable = locate() else {
            throw CLIError(
                message: "maclean CLI not found. Build it with `swift build -c release`, or reinstall the app bundle."
            )
        }
        let path = executable.path
        let result = await Task.detached(priority: .userInitiated) {
            ProcessRunner.run(path, arguments, timeout: timeout)
        }.value
        return CLIOutput(status: result.status, stdout: result.stdout, stderr: result.stderr)
    }

    static func decode<T: Decodable>(
        _ type: T.Type,
        from output: CLIOutput,
        requiringSuccess: Bool = true
    ) throws -> T {
        if requiringSuccess, output.status != 0 {
            let message = [output.stderr, output.stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? "maclean exited \(output.status)"
            throw CLIError(message: message)
        }
        guard let data = output.stdout.data(using: .utf8) else {
            throw CLIError(message: "maclean returned no output")
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(type, from: data)
        } catch {
            throw CLIError(message: "Could not parse maclean output: \(error.localizedDescription)")
        }
    }
}

struct ScanPayload: Decodable {
    let totalBytes: Int64
    let totalFiles: Int
    let items: [JunkItem]
}

struct AppsPayload: Decodable {
    let totalBytes: Int64
    let apps: [InstalledApp]
}

struct FailureJSON: Decodable {
    let path: String
    let reason: String
}

struct ArtifactPayload: Decodable {
    let title: String
    let apply: Bool
    let totalBytes: Int64
    let artifacts: [Artifact]
    let planned: [String]
    let movedToTrash: [String]
    let deleted: [String]
    let skipped: [FailureJSON]
    let failed: [FailureJSON]
    let reclaimedBytes: Int64
    let trashedBytes: Int64
}

struct UninstallPayload: Decodable {
    let app: AppInfo
    let result: ArtifactPayload
}

struct CleanPayloadJSON: Decodable {
    let apply: Bool
    let reclaimedBytes: Int64
    let trashedBytes: Int64
    let planned: [String]
    let movedToTrash: [String]
    let deleted: [String]
    let skipped: [FailureJSON]
    let failed: [FailureJSON]
}

struct PerformancePayload: Decodable {
    let startupItems: [StartupItem]
    let localSnapshots: [String]
    let memory: MemoryStats?
}

struct ProtectionPayload: Decodable {
    let findings: [ProtectionFinding]
    let scannedFiles: Int
    let corpus: CorpusInfo?
    let yara: YaraSummary?
    let corpusYara: YaraSummary?
}

enum Format {
    static func bytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: value)
    }

    static func bytes(_ value: UInt64) -> String {
        bytes(Int64(clamping: value))
    }

    static func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

@main
@MainActor
struct MacLeanApp: App {
    @NSApplicationDelegateAdaptor(MacLeanAppDelegate.self) private var delegate
    @ObservedObject private var menuSettings = MenuBarSettings.shared

    init() {
        // Live numbers for the menu bar even before a window opens.
        DispatchQueue.main.async { SystemMonitor.shared.start() }
        if SmokeTest.directory != nil {
            DispatchQueue.main.async { SmokeTest.runIfRequested() }
        }
    }

    var body: some Scene {
        WindowGroup("MacLean", id: "main") {
            RootShell()
                .frame(minWidth: 1100, minHeight: 720)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 800)
        .commands {
            // MacLean › Settings… (⌘,) opens MacLean's own Settings section.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { Navigator.shared.go(.settings) }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("Go") {
                ForEach(AppSection.allCases) { section in
                    Button(section.title) { Navigator.shared.go(section) }
                }
                Divider()
                Button("Back") { Navigator.shared.pop() }
                    .keyboardShortcut("[", modifiers: .command)
                Divider()
                Button("System Settings › Full Disk Access") { SystemPane.privacy(.fullDiskAccess).open() }
                Button("System Settings › Login Items & Extensions") { SystemPane.loginItems.open() }
                Button("System Settings › Privacy & Security") { SystemPane.privacySecurity.open() }
            }
        }

        // Only write when the value really changes: MenuBarExtra sets this
        // binding during updates, and an unconditional write re-renders forever.
        MenuBarExtra(isInserted: Binding(
            get: { menuSettings.showInMenuBar },
            set: { if $0 != menuSettings.showInMenuBar { menuSettings.showInMenuBar = $0 } }
        )) {
            MenuBarPanel()
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)
    }
}


/// Keeps MacLean (and its menu bar item) running after the last window closes;
/// clicking the Dock icon reopens the window.
final class MacLeanAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated { !MenuBarSettings.shared.runInBackground }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            let settings = MenuBarSettings.shared
            settings.applyActivationPolicy()
            ThreatWatcher.shared.start()
            Notifier.configure()
            if SmokeTest.directory == nil { Updater.shared.start() }
            // Start quietly in the menu bar when asked to (never during smoke tests).
            if !settings.openWindowAtLaunch, settings.showInMenuBar, SmokeTest.directory == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    for window in NSApp.windows where window.identifier?.rawValue.hasPrefix("main") == true || window.title == "MacLean" {
                        window.close()
                    }
                }
            }
        }
    }

    /// Dock icon clicked with no window open: bring the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { true }
}
