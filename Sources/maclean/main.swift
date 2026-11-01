import Darwin
import Foundation
import MacLeanCore

let version = "0.3.0"
let stdoutIsTTY = isatty(STDOUT_FILENO) == 1

struct CLIError: Error {
    let message: String
    let code: Int32

    init(_ message: String, code: Int32 = 1) {
        self.message = message
        self.code = code
    }
}

struct ParsedArgs {
    var command: String?
    var flags: Set<String> = []
    var values: [String: [String]] = [:]
    var positionals: [String] = []

    static func parse(_ raw: [String]) throws -> ParsedArgs {
        let valueFlags: Set<String> = [
            "--category", "--categories", "--min-size", "--remove", "--path",
            "--depth", "--top", "--older-than", "--max-distance", "--profile",
            "--yara-rules", "--clamav-db", "--corpus", "--reason", "--unused-days",
            "--service", "--bundle", "--library", "--reset", "--include", "--thin",
            "--archive", "--progress-file", "--owner",
        ]
        var parsed = ParsedArgs()
        var index = 0

        while index < raw.count {
            let arg = raw[index]
            if arg == "-h" || arg == "--help" {
                parsed.flags.insert("--help")
            } else if arg.hasPrefix("--") {
                if let separator = arg.firstIndex(of: "=") {
                    let name = String(arg[..<separator])
                    let value = String(arg[arg.index(after: separator)...])
                    parsed.values[name, default: []].append(value)
                } else if valueFlags.contains(arg) {
                    guard index + 1 < raw.count else {
                        throw CLIError("missing value for \(arg)", code: 2)
                    }
                    parsed.values[arg, default: []].append(raw[index + 1])
                    index += 1
                } else {
                    parsed.flags.insert(arg)
                }
            } else if parsed.command == nil {
                parsed.command = arg
            } else {
                parsed.positionals.append(arg)
            }
            index += 1
        }
        return parsed
    }
}

func color(_ code: String, _ text: String) -> String {
    guard stdoutIsTTY else { return text }
    return "\u{001B}[\(code)m\(text)\u{001B}[0m"
}

func humanBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowsNonnumericFormatting = false
    return formatter.string(fromByteCount: bytes)
}

func abbreviated(_ path: String, home: URL) -> String {
    let homePath = home.standardizedFileURL.path
    if path == homePath { return "~" }
    if path.hasPrefix(homePath + "/") {
        return "~" + path.dropFirst(homePath.count)
    }
    return path
}

func padded(_ text: String, to width: Int) -> String {
    if text.count >= width { return text }
    return String(repeating: " ", count: width - text.count) + text
}

func parseCategories(_ args: ParsedArgs) throws -> Set<JunkCategory>? {
    let raw = args.values["--category"] ?? args.values["--categories"]
    guard let raw else { return nil }

    var categories = Set<JunkCategory>()
    for chunk in raw.joined(separator: ",").split(separator: ",") {
        let name = chunk.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let category = JunkCategory(rawValue: name) else {
            throw CLIError(
                "unknown category '\(name)'. Valid categories: \(JunkCategory.allCases.map(\.rawValue).joined(separator: ", "))",
                code: 2
            )
        }
        categories.insert(category)
    }
    return categories
}

func parseMinBytes(_ args: ParsedArgs) throws -> Int64 {
    guard let raw = args.values["--min-size"]?.last else { return 0 }
    guard let megabytes = Int64(raw), megabytes >= 0 else {
        throw CLIError("--min-size expects a non-negative integer number of MB", code: 2)
    }
    return megabytes * 1024 * 1024
}

func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

struct ScanPayload: Encodable {
    let totalBytes: Int64
    let totalFiles: Int
    let items: [JunkItem]
}

struct FailurePayload: Encodable {
    let path: String
    let reason: String
}

struct CleanPayload: Encodable {
    let apply: Bool
    let reclaimedBytes: Int64
    let trashedBytes: Int64
    let planned: [String]
    let movedToTrash: [String]
    let deleted: [String]
    let skipped: [FailurePayload]
    let failed: [FailurePayload]
}

struct AppsPayload: Encodable {
    let totalBytes: Int64
    let apps: [InstalledApp]
}

struct RulePayload: Encodable {
    let id: String
    let title: String
    let category: JunkCategory
    let risk: Risk
    let autoselect: Bool
    let requiresRoot: Bool
    let scanOnly: Bool
}

func printScanReport(_ report: ScanReport, home: URL) {
    guard !report.items.isEmpty else {
        print("Nothing to clean.")
        return
    }

    for category in JunkCategory.allCases {
        let items = report.items(in: category)
        guard !items.isEmpty else { continue }

        let bytes = items.reduce(0) { $0 + $1.bytes }
        print("")
        let summary = "— \(humanBytes(bytes)), \(items.count) items"
        print(color("1;36", category.title) + " " + color("2", summary))

        let visible = items.prefix(20)
        for item in visible {
            let marker = item.autoselect ? color("32", "●") : color("33", "○")
            let size = padded(humanBytes(item.bytes), to: 10)
            let note = item.autoselect ? "" : color("33", "  review")
            print("  \(marker) \(size)  \(abbreviated(item.path, home: home))\(note)")
            print("      " + color("2", item.ruleTitle))
        }
        if items.count > visible.count {
            let more = "… and \(items.count - visible.count) more (use --json for the full list)"
            print("  " + color("2", more))
        }
    }

    print("")
    print("\(color("1", "Total:")) \(humanBytes(report.totalBytes)) across \(report.items.count) items")
    if !report.autoselectedItems.isEmpty {
        print("\(color("1", "Auto-selected:")) \(humanBytes(report.autoselectedBytes)) across \(report.autoselectedItems.count) items")
    }
    print(color("2", "Run `maclean clean --apply --yes` to move auto-selected items to the Trash."))
}

/// `--verbose` / `-v` streams scanner events to stderr; `--trace` adds every measured path.
func verboseObserver(_ args: ParsedArgs) -> (@Sendable (ScanEvent) -> Void)? {
    let trace = args.flags.contains("--trace")
    guard trace || args.flags.contains("--verbose") || args.flags.contains("-v") else { return nil }
    let started = Date()
    return { event in
        let t = String(format: "%7.2fs", Date().timeIntervalSince(started))
        let line: String?
        switch event {
        case .ruleStarted(let id, let title, let category, let roots):
            line = "RULE  \(title) [\(id)] · \(category.rawValue) · \(roots) root(s)"
        case .ruleSkipped(let id, _, let reason):
            line = "SKIP  rule \(id): \(reason)"
        case .rootMissing(_, let path):
            line = "MISS  \(path)"
        case .rootEntered(_, let path, let entries):
            line = "DIR   \(path) (\(entries) entries)"
        case .measuring(_, let path):
            line = trace ? "SIZE  \(path)" : nil
        case .entrySkipped(_, let path, let reason):
            line = "SKIP  \(path): \(reason.text)"
        case .itemFound(let item):
            line = "FOUND \(item.path) \(humanBytes(item.bytes)) (\(item.files) files)"
        case .ruleFinished(let id, _, let items, _, let bytes, let examined, let seconds):
            line = String(format: "DONE  %@ in %.2fs · %d items · %@ · %d examined", id, seconds, items, humanBytes(bytes), examined)
        case .cancelled:
            line = "STOP  cancelled"
        }
        if let line {
            FileHandle.standardError.write(Data("\(t)  \(line)\n".utf8))
        }
    }
}

func scanCommand(_ args: ParsedArgs) throws -> Int32 {
    let categories = try parseCategories(args)
    let minBytes = try parseMinBytes(args)
    let scanner = JunkScanner()
    let report = scanner.scan(
        categories: categories,
        minBytes: minBytes,
        observer: verboseObserver(args)
    )

    if args.flags.contains("--json") {
        try printJSON(ScanPayload(
            totalBytes: report.totalBytes,
            totalFiles: report.totalFiles,
            items: report.items
        ))
    } else {
        printScanReport(report, home: FileManager.default.homeDirectoryForCurrentUser)
    }
    return 0
}

func cleanCommand(_ args: ParsedArgs) throws -> Int32 {
    let apply = args.flags.contains("--apply")
    let confirmed = args.flags.contains("--yes")
    let permanent = args.flags.contains("--permanent")
    let includeCaution = args.flags.contains("--include-caution")
    let json = args.flags.contains("--json")
    let categories = try parseCategories(args)
    let minBytes = try parseMinBytes(args)

    if apply, !confirmed {
        throw CLIError("--apply requires --yes. Run without --apply for a dry run.", code: 2)
    }

    let scanner = JunkScanner()
    let report = scanner.scan(
        categories: categories,
        minBytes: minBytes,
        observer: verboseObserver(args)
    )
    let options = CleanOptions(
        apply: apply,
        permanent: permanent,
        includeCaution: includeCaution,
        categories: categories
    )
    let selection = options.select(from: report)

    guard !selection.isEmpty else {
        if json {
            try printJSON(CleanPayload(
                apply: apply, reclaimedBytes: 0, trashedBytes: 0,
                planned: [], movedToTrash: [], deleted: [], skipped: [], failed: []
            ))
        } else {
            print("Nothing selected.")
            if !includeCaution {
                print(color("2", "Some items need review; pass --include-caution to include them."))
            }
        }
        return 0
    }

    let cleaner = Cleaner()
    let result = cleaner.clean(selection, options: options)
    let home = FileManager.default.homeDirectoryForCurrentUser

    if json {
        try printJSON(CleanPayload(
            apply: apply,
            reclaimedBytes: result.reclaimedBytes,
            trashedBytes: result.trashedBytes,
            planned: result.planned.map(\.path),
            movedToTrash: result.movedToTrash.map(\.path),
            deleted: result.deleted.map(\.path),
            skipped: result.skipped.map { FailurePayload(path: $0.path, reason: $0.reason) },
            failed: result.failed.map { FailurePayload(path: $0.path, reason: $0.reason) }
        ))
    } else if apply {
        let targets = result.movedToTrash + result.deleted
        print("\(color("1", "Cleaned \(targets.count) items"))")
        if permanent || !result.deleted.isEmpty {
            print("  Reclaimed: \(humanBytes(result.reclaimedBytes))")
        }
        if !result.movedToTrash.isEmpty {
            print("  Moved to Trash: \(humanBytes(result.trashedBytes))")
            print(color("2", "  Empty the Trash to reclaim that space."))
        }
        if !result.skipped.isEmpty {
            print("  Skipped: \(result.skipped.count)")
            for failure in result.skipped.prefix(10) {
                print("    \(color("33", abbreviated(failure.path, home: home))) — \(failure.reason)")
            }
        }
        if !result.failed.isEmpty {
            print("  Failed: \(result.failed.count)")
            for failure in result.failed.prefix(10) {
                print("    \(color("31", abbreviated(failure.path, home: home))) — \(failure.reason)")
            }
        }
    } else {
        var bytes: Int64 = 0
        for item in result.planned {
            bytes += item.bytes
            print("  \(padded(humanBytes(item.bytes), to: 10))  \(abbreviated(item.path, home: home))")
        }
        print("")
        print("\(color("1", "Dry run:")) \(result.planned.count) items, \(humanBytes(bytes)). Nothing was changed.")
        print(color("2", "Re-run with --apply --yes to move them to the Trash (or add --permanent to delete)."))
    }

    return result.failed.isEmpty ? 0 : 1
}

func appsCommand(_ args: ParsedArgs) throws -> Int32 {
    let apps: [InstalledApp]
    if let rawDays = args.values["--unused-days"]?.last {
        guard let days = Int(rawDays), days >= 0 else {
            throw CLIError("--unused-days expects a non-negative integer", code: 2)
        }
        apps = AppCatalog.unused(days: days)
    } else {
        apps = AppCatalog.installed()
    }
    if args.flags.contains("--json") {
        try printJSON(AppsPayload(totalBytes: apps.reduce(0) { $0 + $1.bytes }, apps: apps))
        return 0
    }

    guard !apps.isEmpty else {
        print("No applications found.")
        return 0
    }

    print("\(color("1;36", "Applications")) \(color("2", "— \(apps.count) apps, \(humanBytes(apps.reduce(0) { $0 + $1.bytes }))"))")
    for app in apps {
        let identifier = app.bundleID ?? "unknown bundle id"
        let versionText = app.version.map { " v\($0)" } ?? ""
        let used = app.lastUsed.map { " · last used \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""
        print("  \(padded(humanBytes(app.bytes), to: 10))  \(app.name)\(versionText)  \(color("2", identifier + used))")
        print("      \(color("2", app.path))")
    }
    return 0
}

struct LeftoverPayload: Encodable {
    let appID: String
    let name: String
    let confidence: String
    let bytes: Int64
    let reasons: [String]
    let items: [Artifact]
}

/// Lists leftovers of apps that are no longer installed (read-only).
func leftoversCommand(_ args: ParsedArgs) throws -> Int32 {
    let installed = Leftovers.installedBundleIDs().union(Uninstaller.apps().compactMap(\.bundleID))
    let groups = Leftovers.orphans(installedIDs: installed)
    if args.flags.contains("--json") {
        try printJSON(groups.map { LeftoverPayload(appID: $0.appID, name: $0.displayName, confidence: $0.confidence.title, bytes: $0.bytes, reasons: $0.reasons, items: $0.items) })
        return 0
    }
    let total = groups.reduce(Int64(0)) { $0 + $1.bytes }
    print("\(color("1;36", "Leftovers of removed apps")) \(color("2", "— \(groups.count) apps · \(humanBytes(total))"))")
    for group in groups {
        print("  \(padded(humanBytes(group.bytes), to: 10))  \(group.displayName)  \(color("2", group.appID))  [\(group.confidence.title)]")
        for item in group.items {
            print("      \(color("2", padded(item.group, to: 22))) \(abbreviated(item.path, home: FileManager.default.homeDirectoryForCurrentUser))  \(humanBytes(item.bytes))")
        }
    }
    print(color("2", "Read-only. Remove them from the app: Applications › Leftovers."))
    return 0
}

func rulesCommand(_ args: ParsedArgs) throws -> Int32 {
    let payload = Rules.all.map {
        RulePayload(
            id: $0.id,
            title: $0.title,
            category: $0.category,
            risk: $0.risk,
            autoselect: $0.autoselect,
            requiresRoot: $0.requiresRoot,
            scanOnly: $0.scanOnly
        )
    }

    if args.flags.contains("--json") {
        try printJSON(payload)
        return 0
    }

    let resolved = Rules.resolved
    print("\(color("1;36", "Scan rules")) \(color("2", "— \(payload.count) active of \(resolved.count) · \(RuleBook.shared.url.path)"))")
    for rule in resolved {
        let mode = rule.scanOnly ? "scan-only" : (rule.autoselect ? "auto" : "review")
        let root = rule.requiresRoot ? " (root)" : ""
        var state = ""
        if !RuleBook.shared.isEnabled(rule.id) { state = color("2", " [off]") }
        else if rule.origin == .custom { state = color("33", " [custom]") }
        else if rule.origin == .edited { state = color("36", " [edited]") }
        print("  \(padded(rule.category.rawValue, to: 8)) \(padded(rule.id, to: 26)) \(rule.title)\(root)  \(color("2", mode))\(state)")
    }
    return 0
}

func printHelp() {
    print("""
    maclean \(version) — a safe, open-source macOS cleaner

    USAGE
      maclean scan  [--category <list>] [--min-size <MB>] [--json] [--verbose | --trace]
      maclean leftovers [--json]
      maclean clean [--apply --yes] [--permanent] [--include-caution]
                    [--category <list>] [--min-size <MB>] [--json]
      maclean uninstall <app> [--apply --yes] [--permanent] [--include-caution] [--force] [--json]
      maclean privacy [--apply --yes] [--permanent] [--include-caution] [--force] [--json]
      maclean performance [--json] [--flush-dns --yes]
                          [--remove <plist> --yes [--permanent]]
      maclean duplicates [--path <dir>]... [--min-size <MB>] [--similar-images]
                         [--include-caution] [--apply --yes] [--permanent] [--json]
      maclean lens [path] [--depth <n>] [--top <n>] [--json]
      maclean mail [--trash] [--apply --yes] [--permanent] [--include-caution] [--force] [--json]
      maclean permissions [--json]
      maclean permissions --reset <service> --bundle <bundle> --apply --yes
      maclean photos [--similar] [--library <photoslibrary>]... [--apply --yes] [--permanent] [--json]
      maclean system [--json]
      maclean system --apply --yes --permanent [--include <kind>]... [--json]
      maclean system --thin <arch> [--no-resign] [--apply --yes] [--json]
      maclean deep [--no-permissions] [--no-photos] [--no-mail] [--no-system] [--no-document-versions] [--json]
      maclean documentversions [--apply --yes] [--json]
      maclean diskimages [--min-size <MB>] [--older-than <days>]
                         [--apply --yes] [--permanent] [--include-caution] [--json]
      maclean cloud [--min-size <MB>] [--json]
      maclean updates [--json]
      maclean protection [--profile fast|default|smart|protected|protected-dirs|paranoid]
                         [--path <dir>]... [--yara-rules <file|dir>]
                         [--bundled-rules | --no-bundled-rules]
                         [--clamav [--clamav-db <dir>]] [--corpus <sqlite|url> [--corpus-refresh]]
                         [--corpus-yara | --no-corpus-yara] [--json]
      maclean apps  [--unused-days <n>] [--json]
      maclean quarantine <path> [--reason <text>] [--json]
      maclean rules [--json]
      maclean help
      maclean version

    CATEGORIES
      system   User/system/sandbox caches, logs, crash reports, saved state, mail downloads
      dev      Xcode DerivedData, archives, DeviceSupport, SwiftPM/npm/Homebrew caches
      browser  Chrome, Firefox, Safari, Edge, Brave and Arc caches
      ai       Ollama/Hugging Face/PyTorch/Whisper/LM Studio models, Cursor/Claude/ChatGPT caches
      updates  Software Update/Sparkle caches and downloaded system updates
      trash    ~/.Trash and mounted volume Trash bins
      large    Files above 500 MB in Downloads, Desktop, Documents and Movies

    SAFETY
      scan never modifies anything.
      clean is a dry run unless --apply --yes is passed.
      Items are moved to the Trash by default; --permanent deletes immediately.
      Trash contents are always deleted permanently.
      Symbolic links, protected system paths and unknown rules are refused.

    EXAMPLES
      maclean scan
      maclean scan --category dev --min-size 50
      maclean clean
      maclean clean --apply --yes
      maclean clean --category system --apply --yes --permanent
      maclean scan --json | jq '.items[0]'
    """)
}

func run(_ raw: [String]) throws {
    let args = try ParsedArgs.parse(raw)

    if args.flags.contains("--help") || args.command == "help" || args.command == nil {
        printHelp()
        return
    }

    let code: Int32
    switch args.command {
    case "version", "--version":
        print("maclean \(version)")
        code = 0
    case "scan":
        code = try scanCommand(args)
    case "clean":
        code = try cleanCommand(args)
    case "apps":
        code = try appsCommand(args)
    case "rules":
        code = try rulesCommand(args)
    case "leftovers":
        code = try leftoversCommand(args)
    case "uninstall":
        code = try uninstallCommand(args)
    case "privacy":
        code = try privacyCommand(args)
    case "performance":
        code = try performanceCommand(args)
    case "duplicates":
        code = try duplicatesCommand(args)
    case "lens":
        code = try lensCommand(args)
    case "mail":
        code = try mailCommand(args)
    case "diskimages":
        code = try diskImagesCommand(args)
    case "cloud":
        code = try cloudCommand(args)
    case "updates":
        code = try updatesCommand(args)
    case "protection":
        code = try protectionCommand(args)
    case "permissions":
        code = try permissionsCommand(args)
    case "photos":
        code = try photosCommand(args)
    case "system":
        code = try systemCommand(args)
    case "deep":
        code = try deepCommand(args)
    case "documentversions":
        code = try documentVersionsCommand(args)
    case "quarantine":
        code = try quarantineCommand(args)
    default:
        throw CLIError("unknown command '\(args.command ?? "")'. Try `maclean help`.", code: 2)
    }

    if code != 0 {
        exit(code)
    }
}

do {
    try run(Array(CommandLine.arguments.dropFirst()))
} catch let error as CLIError {
    fputs("maclean: \(error.message)\n", stderr)
    exit(error.code)
} catch {
    fputs("maclean: \(error.localizedDescription)\n", stderr)
    exit(1)
}
