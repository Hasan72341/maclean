import Foundation

public struct StartupItem: Codable, Sendable, Hashable {
    public let label: String
    public let path: String
    public let program: String
    public let kind: String
    public let scope: String
    public let requiresRoot: Bool
    public let broken: Bool

    public init(
        label: String,
        path: String,
        program: String,
        kind: String,
        scope: String,
        requiresRoot: Bool,
        broken: Bool
    ) {
        self.label = label
        self.path = path
        self.program = program
        self.kind = kind
        self.scope = scope
        self.requiresRoot = requiresRoot
        self.broken = broken
    }
}

public struct MemoryStats: Codable, Sendable {
    public let totalBytes: UInt64
    public let freeBytes: UInt64
    public let wiredBytes: UInt64
    public let compressedBytes: UInt64
    public let pageSize: UInt64

    public init(totalBytes: UInt64, freeBytes: UInt64, wiredBytes: UInt64, compressedBytes: UInt64, pageSize: UInt64) {
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.pageSize = pageSize
    }
}

public enum PerformanceScanner {
    public static func startupItems(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        includeSystemPaths: Bool = true
    ) -> [StartupItem] {
        var directories: [(URL, String, String, Bool)] = [
            (home.appendingPathComponent("Library/LaunchAgents"), "Login item", "user", false),
        ]
        if includeSystemPaths {
            directories.append(contentsOf: [
                (URL(fileURLWithPath: "/Library/LaunchAgents"), "Launch agent", "system", false),
                (home.appendingPathComponent("Library/LaunchDaemons"), "Launch daemon", "user", true),
                (URL(fileURLWithPath: "/Library/LaunchDaemons"), "Launch daemon", "system", true),
            ])
        }

        var items: [StartupItem] = []

        for (directory, kind, scope, requiresRoot) in directories {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            ) else { continue }

            for entry in entries where entry.pathExtension == "plist" {
                let plist = PlistReader.dictionary(at: entry) ?? [:]
                let label = PlistReader.string("Label", in: plist)
                    ?? entry.deletingPathExtension().lastPathComponent
                let program = PlistReader.string("Program", in: plist)
                    ?? PlistReader.strings("ProgramArguments", in: plist).first
                    ?? ""
                let broken = program.hasPrefix("/")
                    && !program.contains("$")
                    && !fileManager.fileExists(atPath: program)

                items.append(
                    StartupItem(
                        label: label,
                        path: entry.path,
                        program: program,
                        kind: kind,
                        scope: scope,
                        requiresRoot: requiresRoot,
                        broken: broken
                    )
                )
            }
        }

        return items.sorted {
            if $0.broken != $1.broken { return $0.broken && !$1.broken }
            return $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
    }

    public static func localSnapshots() -> [String] {
        let result = ProcessRunner.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"], timeout: 20)
        return result.stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("com.apple.TimeMachine.") }
    }

    public static func memory() -> MemoryStats? {
        let result = ProcessRunner.run("/usr/bin/vm_stat", [], timeout: 10)
        guard result.status == 0 else { return nil }

        var pageSize: UInt64 = 4096
        var values: [String: UInt64] = [:]
        for line in result.stdout.split(separator: "\n") {
            if line.contains("page size of") {
                let parts = line.split(separator: " ")
                if let index = parts.firstIndex(of: "of"), index + 1 < parts.count,
                   let size = UInt64(parts[index + 1]) {
                    pageSize = size
                }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let valueText = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: ".", with: "")
            if let value = UInt64(valueText) {
                values[key] = value
            }
        }

        let freePages = (values["Pages free"] ?? 0)
            + (values["Pages inactive"] ?? 0)
            + (values["Pages speculative"] ?? 0)
        let wiredPages = values["Pages wired down"] ?? 0
        let compressedPages = values["Pages occupied by compressor"] ?? 0

        let total = ProcessRunner.run("/usr/sbin/sysctl", ["-n", "hw.memsize"], timeout: 5)
        let totalBytes = UInt64(total.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0

        return MemoryStats(
            totalBytes: totalBytes,
            freeBytes: freePages * pageSize,
            wiredBytes: wiredPages * pageSize,
            compressedBytes: compressedPages * pageSize,
            pageSize: pageSize
        )
    }

    public static func flushDNS() -> String {
        var lines: [String] = []
        let flush = ProcessRunner.run("/usr/bin/dscacheutil", ["-flushcache"], timeout: 20)
        lines.append("dscacheutil exit \(flush.status)")
        if !flush.stderr.isEmpty { lines.append(flush.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }

        let restart = ProcessRunner.run("/usr/bin/killall", ["-HUP", "mDNSResponder"], timeout: 20)
        lines.append("mDNSResponder restart exit \(restart.status)")
        if restart.status != 0 {
            lines.append(restart.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
