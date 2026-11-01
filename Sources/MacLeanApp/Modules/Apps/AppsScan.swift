import AppKit
import Foundation
import MacLeanCore

/// Blocking scanners used by AppsStore. Every function here runs inside engine{}.
enum AppsScan {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static func vendor(of bundleID: String?) -> String {
        guard let bundleID, !bundleID.isEmpty else { return "Unknown" }
        let parts = bundleID.split(separator: ".")
        guard parts.count >= 2 else { return bundleID }
        return parts.prefix(2).joined(separator: ".")
    }

    // MARK: Applications

    static func installedApps() -> [AppsApp] {
        let catalog = AppCatalog.installed()
        let userApps = home.appendingPathComponent("Applications").path + "/"
        let box = AppsBox<[AppsApp?]>(Array(repeating: nil, count: catalog.count))
        DispatchQueue.concurrentPerform(iterations: catalog.count) { index in
            let entry = catalog[index]
            let url = URL(fileURLWithPath: entry.path)
            let values = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey, .creationDateKey, .contentModificationDateKey])
            let info = PlistReader.dictionary(at: url.appendingPathComponent("Contents/Info.plist")) ?? [:]
            let app = AppsApp(
                name: entry.name,
                path: entry.path,
                bundleID: entry.bundleID,
                version: entry.version,
                bytes: entry.bytes,
                lastUsed: AppCatalog.lastUsed(at: url),
                added: values?.addedToDirectoryDate ?? values?.creationDate,
                modified: values?.contentModificationDate,
                isAppStore: FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/_MASReceipt/receipt").path),
                inUserFolder: entry.path.hasPrefix(userApps),
                executable: PlistReader.string("CFBundleExecutable", in: info)
            )
            box.mutate { $0[index] = app }
        }
        return box.value.compactMap { $0 }.sorted { $0.bytes > $1.bytes }
    }

    static func singleApp(path: String) -> AppsApp? {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let list = AppCatalog.list(directories: [url.deletingLastPathComponent()])
        guard let entry = list.first(where: { $0.path == path }) else { return nil }
        let values = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey, .creationDateKey, .contentModificationDateKey])
        let info = PlistReader.dictionary(at: url.appendingPathComponent("Contents/Info.plist")) ?? [:]
        return AppsApp(
            name: entry.name,
            path: entry.path,
            bundleID: entry.bundleID,
            version: entry.version,
            bytes: entry.bytes,
            lastUsed: AppCatalog.lastUsed(at: url),
            added: values?.addedToDirectoryDate ?? values?.creationDate,
            modified: values?.contentModificationDate,
            isAppStore: FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/_MASReceipt/receipt").path),
            inUserFolder: path.hasPrefix(home.appendingPathComponent("Applications").path + "/"),
            executable: PlistReader.string("CFBundleExecutable", in: info)
        )
    }

    static func executablePath(appPath: String) -> String? {
        let url = URL(fileURLWithPath: appPath)
        let info = PlistReader.dictionary(at: url.appendingPathComponent("Contents/Info.plist")) ?? [:]
        guard let exe = PlistReader.string("CFBundleExecutable", in: info) else { return nil }
        let path = url.appendingPathComponent("Contents/MacOS/\(exe)").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    static func architectures(executable: String) -> [String] {
        let result = ProcessRunner.run("/usr/bin/lipo", ["-archs", executable], timeout: 10)
        guard result.status == 0 else { return [] }
        return result.stdout.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
    }

    static func architectureClass(_ archs: [String]) -> String {
        let hasArm = archs.contains { $0.hasPrefix("arm64") }
        let hasIntel = archs.contains { $0.hasPrefix("x86_64") || $0 == "i386" }
        if hasArm && hasIntel { return "Universal" }
        if hasArm { return "Apple Silicon" }
        if hasIntel { return "Intel" }
        return "Unknown"
    }

    static func architectureMap(paths: [String]) -> [String: [String]] {
        let box = AppsBox<[String: [String]]>([:])
        DispatchQueue.concurrentPerform(iterations: paths.count) { index in
            let path = paths[index]
            let archs = executablePath(appPath: path).map(architectures(executable:)) ?? []
            box.mutate { $0[path] = archs }
        }
        return box.value
    }

    static func isRunningByPS(appPath: String) -> Bool {
        let processes = ProcessRunner.run("/bin/ps", ["-axo", "comm="], timeout: 10)
        return processes.stdout.lowercased().contains(appPath.lowercased())
    }

    // MARK: Bundle details

    static func bundleInfo(path: String) -> AppsBundleInfo {
        var result = AppsBundleInfo()
        let url = URL(fileURLWithPath: path)
        let fm = FileManager.default
        let info = PlistReader.dictionary(at: url.appendingPathComponent("Contents/Info.plist")) ?? [:]
        result.build = PlistReader.string("CFBundleVersion", in: info)
        result.minimumOS = PlistReader.string("LSMinimumSystemVersion", in: info)
        result.category = PlistReader.string("LSApplicationCategoryType", in: info)?
            .replacingOccurrences(of: "public.app-category.", with: "")
        result.copyright = PlistReader.string("NSHumanReadableCopyright", in: info)
        result.hasReceipt = fm.fileExists(atPath: url.appendingPathComponent("Contents/_MASReceipt/receipt").path)
        if let exe = executablePath(appPath: path) {
            result.executablePath = exe
            result.executableBytes = FileSizer.measure(URL(fileURLWithPath: exe)).bytes
            result.architectures = architectures(executable: exe)
        }

        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        result.created = values?.creationDate
        result.modified = values?.contentModificationDate

        let codesign = ProcessRunner.run("/usr/bin/codesign", ["-dv", "--verbose=2", path], timeout: 30)
        let signText = codesign.stderr + codesign.stdout
        if codesign.status == 0 {
            result.signed = true
            for raw in signText.split(separator: "\n") {
                let line = String(raw)
                guard let eq = line.firstIndex(of: "=") else { continue }
                let key = String(line[..<eq])
                let value = String(line[line.index(after: eq)...])
                switch key {
                case "Authority": result.authorities.append(value)
                case "TeamIdentifier": result.teamID = value
                case "Identifier": result.signingIdentifier = value
                case "CodeDirectory v":
                    if value.contains("(runtime)") { result.hardenedRuntime = true }
                    if let flagsRange = value.range(of: "flags=") {
                        result.signatureLines.append(("Flags", String(value[flagsRange.upperBound...]).components(separatedBy: " ").first ?? ""))
                    }
                case "Format", "Timestamp", "Signed Time", "Runtime Version", "Signature size", "Sealed Resources version", "Notarization Ticket":
                    result.signatureLines.append((key, value))
                default: break
                }
            }
        } else {
            result.signatureError = signText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let ents = ProcessRunner.run("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", path], timeout: 30)
        let entText = ents.stdout + ents.stderr
        if let start = entText.range(of: "<?xml"), let data = String(entText[start.lowerBound...]).data(using: .utf8),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
            result.entitlementKeys = plist.keys.sorted()
            result.sandboxed = (plist["com.apple.security.app-sandbox"] as? Bool) == true
        }

        let spctl = ProcessRunner.run("/usr/sbin/spctl", ["-a", "-vv", "-t", "exec", path], timeout: 45)
        let spText = (spctl.stderr + spctl.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
        result.gatekeeperAccepted = spctl.status == 0
        if let source = spText.split(separator: "\n").first(where: { $0.hasPrefix("source=") }) {
            result.gatekeeper = String(source.dropFirst("source=".count))
        } else {
            result.gatekeeper = spText.split(separator: "\n").last.map(String.init) ?? "No assessment"
        }

        let contents = url.appendingPathComponent("Contents")
        if let entries = try? fm.contentsOfDirectory(at: contents, includingPropertiesForKeys: nil) {
            for entry in entries {
                let size = FileSizer.measure(entry)
                result.parts.append(AppsPart(name: entry.lastPathComponent, path: entry.path, bytes: size.bytes, files: size.files))
                result.files += size.files
            }
            result.parts.sort { $0.bytes > $1.bytes }
        }
        if let resources = try? fm.contentsOfDirectory(atPath: contents.appendingPathComponent("Resources").path) {
            result.localizations = resources.filter { $0.hasSuffix(".lproj") }
                .map { ($0 as NSString).deletingPathExtension }
                .sorted()
        }
        for folder in ["PlugIns", "Library/QuickLook", "Library/Spotlight", "Extensions", "XPCServices", "Helpers"] {
            let dir = contents.appendingPathComponent(folder)
            guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for entry in entries {
                let size = FileSizer.measure(entry)
                result.plugins.append(AppsPart(name: "\(folder)/\(entry.lastPathComponent)", path: entry.path, bytes: size.bytes, files: size.files))
            }
        }
        result.plugins.sort { $0.bytes > $1.bytes }
        if let helpers = try? fm.contentsOfDirectory(atPath: contents.appendingPathComponent("Library/LoginItems").path) {
            result.loginHelpers = helpers.sorted()
        }
        return result
    }

    // MARK: System apps

    /// Bundle IDs of apps that ship with macOS, so their data is never a leftover.
    static func systemBundleIDs() -> Set<String> {
        var ids = Set<String>()
        let dirs = ["/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities", "/System/Library/CoreServices", "/System/Library/CoreServices/Applications"]
        for dir in dirs {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let info = PlistReader.dictionary(at: URL(fileURLWithPath: "\(dir)/\(entry)/Contents/Info.plist")) ?? [:]
                if let id = PlistReader.string("CFBundleIdentifier", in: info) { ids.insert(id) }
            }
        }
        if let own = Bundle.main.bundleIdentifier { ids.insert(own) }
        return ids
    }

    static func listChildren(path: String, limit: Int = 200) -> [AppsPart] {
        let url = URL(fileURLWithPath: path)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else { return [] }
        return entries.prefix(limit).map { entry in
            let size = FileSizer.measure(entry)
            return AppsPart(name: entry.lastPathComponent, path: entry.path, bytes: size.bytes, files: size.files)
        }.sorted { $0.bytes > $1.bytes }
    }

    // MARK: Extensions

    static let extensionKinds: [(kind: String, relative: String, exts: [String], icon: String)] = [
        ("Preference Panes", "Library/PreferencePanes", ["prefpane"], "slider.horizontal.3"),
        ("QuickLook Plug-ins", "Library/QuickLook", ["qlgenerator"], "eye"),
        ("Spotlight Importers", "Library/Spotlight", ["mdimporter"], "magnifyingglass"),
        ("Internet Plug-ins", "Library/Internet Plug-Ins", ["plugin", "webplugin"], "globe"),
        ("Screen Savers", "Library/Screen Savers", ["saver", "qtz"], "sparkles.tv"),
        ("Audio Units", "Library/Audio/Plug-Ins/Components", ["component"], "waveform"),
        ("Services", "Library/Services", ["workflow", "service"], "gearshape.2"),
    ]

    static func extensionIcon(_ kind: String) -> String {
        extensionKinds.first { $0.kind == kind }?.icon ?? "puzzlepiece.extension"
    }

    static func extensions() -> [AppsExtension] {
        var found: [(String, String, Bool)] = []
        let fm = FileManager.default
        for spec in extensionKinds {
            for (base, isSystem) in [(home.path, false), ("", true)] {
                let dir = base + "/" + spec.relative
                guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
                for entry in entries where spec.exts.contains((entry as NSString).pathExtension.lowercased()) {
                    found.append(("\(dir)/\(entry)", spec.kind, isSystem))
                }
            }
        }
        let frozen = found
        let box = AppsBox<[AppsExtension?]>(Array(repeating: nil, count: frozen.count))
        DispatchQueue.concurrentPerform(iterations: frozen.count) { index in
            let (path, kind, isSystem) = frozen[index]
            let url = URL(fileURLWithPath: path)
            let size = FileSizer.measure(url)
            guard !size.isSymbolicLink else { return }
            let info = PlistReader.dictionary(at: url.appendingPathComponent("Contents/Info.plist")) ?? [:]
            let item = AppsExtension(
                path: path,
                name: PlistReader.string("CFBundleName", in: info) ?? (url.lastPathComponent as NSString).deletingPathExtension,
                kind: kind,
                isSystem: isSystem,
                bytes: size.bytes,
                files: size.files,
                bundleID: PlistReader.string("CFBundleIdentifier", in: info),
                version: PlistReader.string("CFBundleShortVersionString", in: info) ?? PlistReader.string("CFBundleVersion", in: info),
                modified: size.modified
            )
            box.mutate { $0[index] = item }
        }
        return box.value.compactMap { $0 }.sorted { $0.bytes > $1.bytes }
    }

    // MARK: Updates

    static func updateHistory() -> [String] {
        let result = ProcessRunner.run("/usr/sbin/softwareupdate", ["--history"], timeout: 30)
        guard result.status == 0 else { return [] }
        return result.stdout.split(separator: "\n").dropFirst(2).map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
    }
}

/// Root-only removals: either the macOS password prompt via osascript or a
/// copyable sudo command. Restricted to direct children of known system folders.
enum AppsAdmin {
    static let allowedParents: Set<String> = [
        "/Applications",
        "/Library/Application Support",
        "/Library/Caches",
        "/Library/Preferences",
        "/Library/LaunchAgents",
        "/Library/LaunchDaemons",
        "/Library/PrivilegedHelperTools",
        "/var/db/receipts",
        "/private/var/db/receipts",
        "/Library/PreferencePanes",
        "/Library/QuickLook",
        "/Library/Spotlight",
        "/Library/Internet Plug-Ins",
        "/Library/Screen Savers",
        "/Library/Audio/Plug-Ins/Components",
        "/Library/Services",
    ]

    static func isEligible(_ path: String) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        guard allowedParents.contains(parent) else { return false }
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        if parent == "/Applications" && !name.hasSuffix(".app") { return false }
        if name.lowercased().hasPrefix("com.apple.") { return false }
        return true
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func commands(for paths: [String]) -> [String] {
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash").path
        let stamp = Int(Date().timeIntervalSince1970)
        return paths.filter(isEligible).map { path in
            let name = (path as NSString).lastPathComponent
            let dest = "\(trash)/\(stamp)-\(name)"
            var line = ""
            if path.hasPrefix("/Library/LaunchDaemons/") || path.hasPrefix("/Library/LaunchAgents/") {
                line += "/bin/launchctl bootout system \(quote(path)) 2>/dev/null; "
            }
            line += "/bin/mv \(quote(path)) \(quote(dest))"
            return line
        }
    }

    static func sudoText(for paths: [String]) -> String {
        commands(for: paths).map { "sudo sh -c \(quote($0))" }.joined(separator: "\n")
    }

    /// Runs with the macOS administrator prompt. Returns (success, output).
    static func moveToTrash(_ paths: [String]) -> (Bool, String) {
        let cmds = commands(for: paths)
        guard !cmds.isEmpty else { return (false, "No eligible system paths.") }
        let shell = cmds.joined(separator: " && ")
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        let result = ProcessRunner.run("/usr/bin/osascript", ["-e", script], timeout: 300)
        let output = (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        return (result.status == 0, output.isEmpty ? (result.status == 0 ? "Moved \(cmds.count) item(s) to the Trash." : "osascript exited \(result.status)") : output)
    }
}
