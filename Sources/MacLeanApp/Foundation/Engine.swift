import AppKit
import Foundation
import MacLeanCore

/// Runs blocking MacLeanCore work off the main actor.
func engine<T: Sendable>(
    priority: TaskPriority = .userInitiated,
    _ work: @escaping @Sendable () throws -> T
) async throws -> T {
    try await Task.detached(priority: priority) { try work() }.value
}

func engine<T: Sendable>(
    priority: TaskPriority = .userInitiated,
    _ work: @escaping @Sendable () -> T
) async -> T {
    await Task.detached(priority: priority) { work() }.value
}

/// Generic async-load state used by every screen.
enum LoadState: Equatable {
    case idle
    case loading(String)
    case loaded(Date)
    case failed(String)

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var loadedAt: Date? {
        if case .loaded(let date) = self { return date }
        return nil
    }
}

/// Outcome of a removal performed from any screen.
struct RemovalSummary: Sendable {
    var removed: Int = 0
    var bytes: Int64 = 0
    var failures: [(path: String, reason: String)] = []

    var message: String {
        if failures.isEmpty {
            return "Removed \(removed) item\(removed == 1 ? "" : "s") · \(Format.bytes(bytes)) freed"
        }
        return "Removed \(removed), \(failures.count) failed · \(Format.bytes(bytes)) freed"
    }
}

enum EngineActions {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Clean scanner `JunkItem`s through the engine's `Cleaner`, which
    /// re-validates every path against its rule roots and file identity.
    static func cleanJunk(_ items: [JunkItem], permanent: Bool = false) async -> RemovalSummary {
        let result = await engine {
            Cleaner().clean(items, options: CleanOptions(apply: true, permanent: permanent, includeCaution: true))
        }
        var summary = RemovalSummary()
        summary.removed = result.movedToTrash.count + result.deleted.count
        summary.bytes = result.trashedBytes + result.reclaimedBytes
        summary.failures = (result.failed + result.skipped).map { ($0.path, $0.reason) }
        return summary
    }

    /// Clean `Artifact`s (privacy, uninstall leftovers, mail, etc.) through
    /// `ArtifactCleaner`, which validates each against its allowed root.
    static func cleanArtifacts(_ artifacts: [Artifact], permanent: Bool = false) async -> RemovalSummary {
        let result = await engine {
            ArtifactCleaner().clean(artifacts, apply: true, permanent: permanent, includeCaution: true)
        }
        var summary = RemovalSummary()
        summary.removed = result.movedToTrash.count + result.deleted.count
        summary.bytes = result.trashedBytes + result.reclaimedBytes
        summary.failures = (result.failed + result.skipped).map { ($0.path, $0.reason) }
        return summary
    }

    /// Move arbitrary user-chosen files (duplicates, large files, disk images)
    /// to the Trash. Refuses system locations and anything outside the user's
    /// home, /Applications, or mounted volumes.
    static func trashFiles(_ paths: [String], bytes: [String: Int64] = [:]) async -> RemovalSummary {
        await engine {
            var summary = RemovalSummary()
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            for path in paths {
                let resolved = PathCanon.resolve(path)
                let allowed = resolved.hasPrefix(home + "/") || resolved.hasPrefix("/Applications/") || resolved.hasPrefix("/Volumes/") || resolved.hasPrefix("/Users/Shared/")
                let forbidden = [home, home + "/Library", home + "/Desktop", home + "/Documents", home + "/Downloads"].contains(resolved)
                guard allowed, !forbidden else {
                    summary.failures.append((path, "outside the locations MacLean may remove"))
                    continue
                }
                let size = bytes[path] ?? FileSizer.measure(URL(fileURLWithPath: resolved)).bytes
                do {
                    _ = try Removal.remove(path: resolved, permanent: false, home: FileManager.default.homeDirectoryForCurrentUser)
                    summary.removed += 1
                    summary.bytes += size
                } catch {
                    summary.failures.append((path, error.localizedDescription))
                }
            }
            return summary
        }
    }

    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    static func open(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    static func emptyTrash() async -> RemovalSummary {
        let trash = home.appendingPathComponent(".Trash")
        return await engine {
            var summary = RemovalSummary()
            let fm = FileManager.default
            let entries = (try? fm.contentsOfDirectory(atPath: trash.path)) ?? []
            for entry in entries {
                let path = trash.appendingPathComponent(entry).path
                let size = FileSizer.measure(URL(fileURLWithPath: path)).bytes
                do {
                    try fm.removeItem(atPath: path)
                    summary.removed += 1
                    summary.bytes += size
                } catch {
                    summary.failures.append((path, error.localizedDescription))
                }
            }
            return summary
        }
    }
}

// MARK: - Activity log (persisted)

struct ActivityEntry: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var date = Date()
    var module: String
    var title: String
    var items: Int
    var bytes: Int64
    var failures: Int
    var detail: String = ""
}

@MainActor
final class ActivityLog: ObservableObject {
    static let shared = ActivityLog()

    @Published private(set) var entries: [ActivityEntry] = []

    var totalFreed: Int64 { entries.reduce(0) { $0 + $1.bytes } }

    private var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacLean/activity.json")
    }

    init() {
        if let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            entries = (try? decoder.decode([ActivityEntry].self, from: data)) ?? []
        }
    }

    /// Records a removal, shows a toast, and returns the summary for chaining.
    @discardableResult
    func record(_ module: String, _ title: String, _ summary: RemovalSummary, detail: String = "") -> RemovalSummary {
        add(ActivityEntry(module: module, title: title, items: summary.removed, bytes: summary.bytes, failures: summary.failures.count, detail: detail))
        ToastCenter.shared.show("\(title): \(summary.message)", error: !summary.failures.isEmpty && summary.removed == 0)
        if !summary.failures.isEmpty {
            RemovalRescue.shared.offer(module: module, title: title, failures: summary.failures)
        }
        return summary
    }

    func add(_ entry: ActivityEntry) {
        entries.insert(entry, at: 0)
        if entries.count > 500 { entries.removeLast(entries.count - 500) }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Formatting helpers

extension Format {
    static func rate(_ bytesPerSecond: Double) -> String {
        bytes(Int64(bytesPerSecond)) + "/s"
    }

    static func percent(_ fraction: Double, digits: Int = 0) -> String {
        String(format: "%.\(digits)f%%", fraction * 100)
    }

    static func count(_ value: Int) -> String {
        CountFormat.string(value)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        let days = s / 86_400
        let hours = (s % 86_400) / 3_600
        let minutes = (s % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h \(minutes)m" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m \(s % 60)s"
    }

    static func relative(_ date: Date?) -> String {
        guard let date else { return "—" }
        if abs(date.timeIntervalSinceNow) < 45 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func date(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
