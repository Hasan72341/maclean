import CoreServices
import Foundation

/// What this Mac itself says is installed, independent of where apps live,
/// whether Spotlight is enabled, or which macOS version is running.
public final class SystemRegistry: @unchecked Sendable {
    public static let shared = SystemRegistry()

    private let lock = NSLock()
    private var cache: [String: Bool] = [:]
    private var labels: Set<String>?
    private var namespaces: Set<String>?

    public init() {}

    /// Is an app with this bundle ID registered with Launch Services and still
    /// on disk outside the Trash? Covers every volume and folder an app was
    /// ever launched or registered from.
    public func isRegisteredApp(_ bundleID: String) -> Bool {
        let key = bundleID.lowercased()
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()
        var found = false
        if let urls = LSCopyApplicationURLsForBundleIdentifier(bundleID as CFString, nil)?.takeRetainedValue() as? [URL] {
            found = urls.contains { url in
                !url.path.contains("/.Trash/") && FileManager.default.fileExists(atPath: url.path)
            }
        }
        lock.lock(); cache[key] = found; lock.unlock()
        return found
    }

    /// Labels of launchd jobs that are loaded now, or whose plist points at a
    /// program that still exists. Background-only tools (agents, daemons,
    /// CLI helpers) have no app bundle but still own their Library data.
    public func liveLaunchLabels(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Set<String> {
        lock.lock()
        if let labels { lock.unlock(); return labels }
        lock.unlock()
        var out = Set<String>()
        let listed = ProcessRunner.run("/bin/launchctl", ["list"], timeout: 10)
        if listed.status == 0 {
            for line in listed.stdout.split(separator: "\n").dropFirst() {
                if let label = line.split(separator: "\t").last.map(String.init), label.contains(".") {
                    out.insert(label)
                }
            }
        }
        let dirs = [home.appendingPathComponent("Library/LaunchAgents").path, "/Library/LaunchAgents", "/Library/LaunchDaemons"]
        for dir in dirs {
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where entry.hasSuffix(".plist") {
                let plist = PlistReader.dictionary(at: URL(fileURLWithPath: "\(dir)/\(entry)")) ?? [:]
                guard let label = PlistReader.string("Label", in: plist) else { continue }
                let program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first
                if let program, FileManager.default.fileExists(atPath: program) { out.insert(label) }
            }
        }
        lock.lock(); labels = out; lock.unlock()
        return out
    }

    /// Reverse-DNS namespaces (`org.cups`, `com.openssh`) used by services that
    /// ship with macOS itself, read from the sealed system's launchd folders.
    public func osNamespaces() -> Set<String> {
        lock.lock()
        if let namespaces { lock.unlock(); return namespaces }
        lock.unlock()
        var out = Set<String>()
        for dir in ["/System/Library/LaunchDaemons", "/System/Library/LaunchAgents"] {
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where entry.hasSuffix(".plist") {
                let parts = entry.dropLast(6).lowercased().split(separator: ".")
                if parts.count >= 3 { out.insert(parts.prefix(2).joined(separator: ".")) }
            }
        }
        out.remove("com.apple") // handled separately; keeps the set small
        lock.lock(); namespaces = out; lock.unlock()
        return out
    }

    /// Whether Spotlight indexing is on for the boot volume.
    public static var spotlightEnabled: Bool {
        let result = ProcessRunner.run("/usr/bin/mdutil", ["-s", "/"], timeout: 5)
        return result.status == 0 && result.stdout.lowercased().contains("enabled")
    }

    /// Folders that hold apps on this Mac: the standard ones plus an
    /// `Applications` folder at the root of every mounted volume.
    public static func applicationRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        var roots = ["/Applications", home.appendingPathComponent("Applications").path, "/System/Applications",
                     "/System/Library/CoreServices", "/Library/Application Support",
                     home.appendingPathComponent("Library/Application Support").path]
        for volume in (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? [] {
            let path = "/Volumes/\(volume)/Applications"
            if FileManager.default.fileExists(atPath: path) { roots.append(path) }
        }
        return roots
    }
}
