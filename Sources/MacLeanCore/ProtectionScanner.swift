import Foundation

public enum Severity: String, Codable, Sendable, Comparable {
    case info
    case low
    case medium
    case high

    public var rank: Int {
        switch self {
        case .info: return 0
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        }
    }

    public static func < (lhs: Severity, rhs: Severity) -> Bool {
        lhs.rank < rhs.rank
    }

    public var label: String {
        rawValue.uppercased()
    }
}

public struct ProtectionFinding: Codable, Sendable, Hashable {
    public let path: String
    public let kind: String
    public let title: String
    public let detail: String
    public let severity: Severity
    public let requiresRoot: Bool

    public init(
        path: String,
        kind: String,
        title: String,
        detail: String,
        severity: Severity,
        requiresRoot: Bool
    ) {
        self.path = path
        self.kind = kind
        self.title = title
        self.detail = detail
        self.severity = severity
        self.requiresRoot = requiresRoot
    }
}

public struct ProtectionReport: Codable, Sendable {
    public let configuration: ScanConfiguration
    public let findings: [ProtectionFinding]
    public let scannedFiles: Int
    public let yara: YaraSummary?
    public let clamav: ClamAVSummary?
    public let corpus: CorpusInfo?
    public let corpusYara: YaraSummary?

    public init(
        configuration: ScanConfiguration,
        findings: [ProtectionFinding],
        scannedFiles: Int,
        yara: YaraSummary?,
        clamav: ClamAVSummary? = nil,
        corpus: CorpusInfo? = nil,
        corpusYara: YaraSummary? = nil
    ) {
        self.configuration = configuration
        self.findings = findings
        self.scannedFiles = scannedFiles
        self.yara = yara
        self.clamav = clamav
        self.corpus = corpus
        self.corpusYara = corpusYara
    }
}

public final class ProtectionScanner {
    private let configuration: ScanConfiguration
    private let home: URL
    private let fileManager: FileManager
    private var findings: [ProtectionFinding] = []
    private var scannedFiles = 0

    public init(
        configuration: ScanConfiguration,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        self.configuration = configuration
        self.home = home
        self.fileManager = fileManager
    }

    public func scan(
        extraPaths: [URL] = [],
        yaraRules: URL? = nil,
        useClamAV: Bool = false,
        clamAVDatabase: URL? = nil,
        corpus: PantherCorpus? = nil,
        corpusYara: Bool? = nil
    ) -> ProtectionReport {
        findings = []
        scannedFiles = 0

        var paths = extraPaths
        paths.append(contentsOf: configuration.diskScanURLs.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
        })
        var seenPaths = Set<String>()
        paths = paths.filter { seenPaths.insert(PathCanon.resolve($0.path)).inserted }

        if configuration.scanOption.contains(.launchItems) {
            scanLaunchItems()
        }
        if configuration.scanOption.contains(.predefinedPaths) {
            scanPredefinedPaths()
        }
        if configuration.scanOption.contains(.diskURLs), !paths.isEmpty {
            scanDiskURLs(paths)
        }
        if configuration.scanOption.contains(.safariExtensions) {
            scanSafariExtensions()
        }
        if configuration.scanOption.contains(.securityIssues) {
            scanSecurityIssues()
        }
        if configuration.scanOption.contains(.cronJobs) {
            scanCronJobs()
        }
        if configuration.scanOption.contains(.configurationProfiles) {
            scanConfigurationProfiles()
        }
        if configuration.scanOption.contains(.runningProcesses) {
            scanRunningProcesses()
        }
        if configuration.scanOption.contains(.safariHomepage) {
            scanSafariHomepage()
        }
        if configuration.scanOption.contains(.privilegedURLs) {
            scanPrivilegedAccess()
        }
        if configuration.scanOption.contains(.externalDrives) {
            scanExternalDrives()
        }
        if configuration.scanOption.contains(.mailAttachments) {
            scanMailAttachments()
        }
        if configuration.scanOption.contains(.chromeExtensions) {
            scanChromeExtensions()
        }

        var yaraSummary: YaraSummary?
        if let yaraRules {
            let cap: Int64 = configuration.scanMode == .paranoid
                ? 300 * 1024 * 1024
                : 50 * 1024 * 1024
            let result = YaraScanner.run(
                rules: yaraRules,
                paths: paths,
                maxFileSize: cap,
                fileManager: fileManager
            )
            findings.append(contentsOf: result.findings)
            scannedFiles += result.scannedFiles
            yaraSummary = result.summary
        }

        var clamavSummary: ClamAVSummary?
        if useClamAV {
            let cap: Int64 = configuration.scanMode == .paranoid
                ? 300 * 1024 * 1024
                : 50 * 1024 * 1024
            let result = ClamAVScanner.run(
                paths: paths,
                database: clamAVDatabase,
                maxFileSize: cap,
                fileManager: fileManager
            )
            findings.append(contentsOf: result.findings)
            clamavSummary = result.summary
        }

        var corpusInfo: CorpusInfo?
        var corpusYaraSummary: YaraSummary?
        if let corpus {
            let result = CorpusScanner(
                corpus: corpus,
                configuration: configuration,
                home: home,
                fileManager: fileManager,
                runYara: corpusYara
            ).scan(extraPaths: paths)
            findings.append(contentsOf: result.findings)
            scannedFiles += result.scannedFiles
            corpusInfo = result.info
            corpusYaraSummary = result.yara
        }

        findings.sort {
            if $0.severity != $1.severity { return $0.severity.rank > $1.severity.rank }
            return $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
        }

        return ProtectionReport(
            configuration: configuration,
            findings: findings,
            scannedFiles: scannedFiles,
            yara: yaraSummary,
            clamav: clamavSummary,
            corpus: corpusInfo,
            corpusYara: corpusYaraSummary
        )
    }

    private func add(
        _ path: String,
        kind: String,
        title: String,
        detail: String = "",
        severity: Severity,
        requiresRoot: Bool = false
    ) {
        findings.append(
            ProtectionFinding(
                path: path,
                kind: kind,
                title: title,
                detail: detail,
                severity: severity,
                requiresRoot: requiresRoot
            )
        )
    }

    private func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    private func isWorldWritable(_ path: String) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              let permissions = attributes[.posixPermissions] as? NSNumber else {
            return false
        }
        return permissions.intValue & 0o002 != 0
    }

    private func isSuspiciousLocation(_ path: String) -> Bool {
        let lower = path.lowercased()
        return [
            "/tmp/", "/var/tmp/", "/private/tmp/", "/private/var/tmp/", "/users/shared/",
        ].contains { lower.hasPrefix($0) || lower.contains($0) }
    }

    private func scanLaunchItems() {
        let directories: [(URL, Bool)] = [
            (home.appendingPathComponent("Library/LaunchAgents"), false),
            (URL(fileURLWithPath: "/Library/LaunchAgents"), true),
            (URL(fileURLWithPath: "/Library/LaunchDaemons"), true),
        ]

        for (directory, requiresRoot) in directories {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            ) else { continue }

            for entry in entries where entry.pathExtension == "plist" {
                scannedFiles += 1
                let plist = PlistReader.dictionary(at: entry) ?? [:]
                let label = PlistReader.string("Label", in: plist)
                    ?? entry.deletingPathExtension().lastPathComponent
                let program = PlistReader.string("Program", in: plist)
                    ?? PlistReader.strings("ProgramArguments", in: plist).first
                    ?? ""

                if isWorldWritable(entry.path) {
                    add(
                        entry.path,
                        kind: "launch-item",
                        title: "World-writable launch item",
                        detail: label,
                        severity: .medium,
                        requiresRoot: requiresRoot
                    )
                }

                guard program.hasPrefix("/") else { continue }

                if !fileManager.fileExists(atPath: program) {
                    add(
                        entry.path,
                        kind: "launch-item",
                        title: "Launch item points to a missing program",
                        detail: "\(label): \(program)",
                        severity: .medium,
                        requiresRoot: requiresRoot
                    )
                    continue
                }

                if isSuspiciousLocation(program) {
                    add(
                        entry.path,
                        kind: "launch-item",
                        title: "Launch item runs from a temporary or shared location",
                        detail: "\(label): \(program)",
                        severity: .high,
                        requiresRoot: requiresRoot
                    )
                }

                if isWorldWritable(program) {
                    add(
                        entry.path,
                        kind: "launch-item",
                        title: "Launch item program is world-writable",
                        detail: "\(label): \(program)",
                        severity: .medium,
                        requiresRoot: requiresRoot
                    )
                }

                if configuration.extendedRulesUsageEnabled {
                    let signature = ProcessRunner.run(
                        "/usr/bin/codesign",
                        ["--verify", "--strict", program],
                        timeout: configuration.externalUtilityExecutionTimeout
                    )
                    if signature.status != 0 {
                        add(
                            entry.path,
                            kind: "launch-item",
                            title: "Launch item program has an invalid signature",
                            detail: "\(label): \(program)",
                            severity: .medium,
                            requiresRoot: requiresRoot
                        )
                    }
                }
            }
        }
    }

    private func scanPredefinedPaths() {
        let directories = ["/tmp", "/var/tmp", "/Users/Shared"]
        var count = 0
        for directory in directories {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: URL(fileURLWithPath: directory),
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: []
            ) else { continue }

            for entry in entries {
                guard count < 100 else { return }
                scannedFiles += 1
                guard let values = try? entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                      values.isRegularFile == true,
                      values.isSymbolicLink != true else { continue }
                guard fileManager.isExecutableFile(atPath: entry.path) else { continue }
                add(
                    entry.path,
                    kind: "predefined-path",
                    title: "Executable in a shared or temporary location",
                    detail: directory,
                    severity: .low
                )
                count += 1
            }
        }
    }

    private func scanDiskURLs(_ paths: [URL]) {
        var count = 0
        for root in paths {
            guard fileManager.fileExists(atPath: root.path) else { continue }
            scannedFiles += walk(root, maxDepth: configuration.maxEnumerationDepth) { url in
                guard count < 100 else { return }
                if fileManager.isExecutableFile(atPath: url.path) {
                    add(
                        url.path,
                        kind: "executable",
                        title: "Executable in a scanned directory",
                        detail: root.path,
                        severity: .low
                    )
                    count += 1
                }
            }
        }
    }

    private func scanSafariExtensions() {
        let directories = [
            home.appendingPathComponent("Library/Safari/Extensions"),
            home.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Safari/Extensions"),
        ]
        for directory in directories {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            ) else { continue }
            for entry in entries {
                scannedFiles += 1
                add(
                    entry.path,
                    kind: "safari-extension",
                    title: "Safari extension installed",
                    detail: entry.lastPathComponent,
                    severity: .low
                )
            }
        }
    }

    private func scanSecurityIssues() {
        let sip = ProcessRunner.run("/usr/bin/csrutil", ["status"], timeout: 10)
        if sip.status == 0, sip.stdout.lowercased().contains("disabled") {
            add(
                "/",
                kind: "security",
                title: "System Integrity Protection is disabled",
                detail: sip.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                severity: .high
            )
        }

        let fileVault = ProcessRunner.run("/usr/bin/fdesetup", ["status"], timeout: 10)
        if fileVault.status == 0, fileVault.stdout.contains("Off") {
            add(
                "/",
                kind: "security",
                title: "FileVault is off",
                detail: fileVault.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                severity: .medium
            )
        }

        let firewall = ProcessRunner.run(
            "/usr/libexec/ApplicationFirewall/socketfilterfw",
            ["--getglobalstate"],
            timeout: 10
        )
        if firewall.status == 0, firewall.stdout.lowercased().contains("disabled") {
            add(
                "/",
                kind: "security",
                title: "Application firewall is disabled",
                detail: firewall.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                severity: .medium
            )
        }

        let gatekeeper = ProcessRunner.run("/usr/sbin/spctl", ["--status"], timeout: 10)
        if gatekeeper.status == 0, gatekeeper.stdout.lowercased().contains("disabled") {
            add(
                "/",
                kind: "security",
                title: "Gatekeeper assessments are disabled",
                detail: gatekeeper.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                severity: .medium
            )
        }

        let guest = ProcessRunner.run(
            "/usr/bin/defaults",
            ["read", "/Library/Preferences/com.apple.loginwindow", "GuestEnabled"],
            timeout: 10
        )
        if guest.status == 0, guest.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
            add(
                "/Library/Preferences/com.apple.loginwindow",
                kind: "security",
                title: "Guest account is enabled",
                detail: "GuestEnabled = 1",
                severity: .medium
            )
        }

        let autoLogin = ProcessRunner.run(
            "/usr/bin/defaults",
            ["read", "/Library/Preferences/com.apple.loginwindow", "autoLoginUser"],
            timeout: 10
        )
        let autoLoginUser = autoLogin.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if autoLogin.status == 0, !autoLoginUser.isEmpty {
            add(
                "/Library/Preferences/com.apple.loginwindow",
                kind: "security",
                title: "Automatic login is enabled",
                detail: "autoLoginUser = \(autoLoginUser)",
                severity: .medium
            )
        }
    }

    private func scanCronJobs() {
        var sources: [(String, String, Bool)] = []
        let systemPaths = [
            "/etc/crontab",
            "/var/at/tabs",
            "/usr/lib/cron/tabs",
        ]

        for path in systemPaths {
            if let content = try? String(contentsOfFile: path, encoding: .utf8) {
                sources.append((path, content, true))
            }
        }

        if let entries = try? fileManager.contentsOfDirectory(
            at: URL(fileURLWithPath: "/etc/cron.d"),
            includingPropertiesForKeys: nil,
            options: []
        ) {
            for entry in entries {
                if let content = try? String(contentsOfFile: entry.path, encoding: .utf8) {
                    sources.append((entry.path, content, true))
                }
            }
        }

        let userCron = ProcessRunner.run("/usr/bin/crontab", ["-l"], timeout: 10)
        if userCron.status == 0, !userCron.stdout.isEmpty {
            sources.append(("user crontab", userCron.stdout, false))
        }

        let suspicious = [
            "/tmp/", "/var/tmp/", "/private/tmp/", "/users/shared/",
            "curl ", "wget ", "base64 ", "python -c", "perl -e",
            "osascript", "nc -e", "bash -i", "sh -i",
        ]

        for (path, content, requiresRoot) in sources {
            let lines = content.split(separator: "\n")
            for rawLine in lines {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, !line.hasPrefix("#") else { continue }
                let lower = line.lowercased()
                guard suspicious.contains(where: { lower.contains($0) }) else { continue }
                let severity: Severity = lower.contains("| sh") || lower.contains("| bash")
                    || lower.contains("base64")
                    ? .high
                    : .medium
                add(
                    path,
                    kind: "cron",
                    title: "Suspicious cron job",
                    detail: String(line.prefix(300)),
                    severity: severity,
                    requiresRoot: requiresRoot
                )
            }
        }
    }

    private func scanConfigurationProfiles() {
        let result = ProcessRunner.run(
            "/usr/bin/profiles",
            ["show", "-type", "configuration"],
            timeout: 20
        )

        if result.status == 0 {
            for rawLine in result.stdout.split(separator: "\n") {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("attribute: name:") else { continue }
                let name = line.replacingOccurrences(of: "attribute: name:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    add(
                        "/",
                        kind: "configuration-profile",
                        title: "Configuration profile installed",
                        detail: name,
                        severity: .info
                    )
                }
            }
        } else if let entries = try? fileManager.contentsOfDirectory(
            atPath: "/Library/Managed Preferences"
        ), !entries.isEmpty {
            add(
                "/Library/Managed Preferences",
                kind: "configuration-profile",
                title: "Managed preferences are present",
                detail: "Run `profiles show -type configuration` as root for details.",
                severity: .info,
                requiresRoot: true
            )
        }
    }

    private func scanRunningProcesses() {
        let result = ProcessRunner.run(
            "/bin/ps",
            ["-axo", "pid=,comm=,args="],
            timeout: 15
        )
        guard result.status == 0 else { return }

        var count = 0
        for rawLine in result.stdout.split(separator: "\n") {
            guard count < 50 else { break }
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            let command = String(parts[1])
            let arguments = parts.count > 2 ? String(parts[2]) : ""
            let lower = (command + " " + arguments).lowercased()
            let suspicious = isSuspiciousLocation(command)
                || isSuspiciousLocation(arguments)
                || lower.contains("curl ") && lower.contains("| sh")
                || lower.contains("base64 -d")
                || lower.contains("python -c")
            guard suspicious else { continue }
            add(
                command,
                kind: "process",
                title: "Process running from a suspicious location or command line",
                detail: String(line.prefix(300)),
                severity: .medium
            )
            count += 1
        }
    }

    private func scanSafariHomepage() {
        let candidates = [
            home.appendingPathComponent("Library/Preferences/com.apple.Safari.plist"),
            home.appendingPathComponent(
                "Library/Containers/com.apple.Safari/Data/Library/Preferences/com.apple.Safari.plist"
            ),
        ]

        for path in candidates {
            guard let plist = PlistReader.dictionary(at: path) else { continue }
            let homepage = (plist["HomePage"] as? String)
                ?? (plist["HomePageURL"] as? String)
                ?? ""
            if !homepage.isEmpty, homepage != "about:blank" {
                add(
                    path.path,
                    kind: "safari-homepage",
                    title: "Custom Safari homepage",
                    detail: homepage,
                    severity: .low
                )
            }
            return
        }
    }

    private func scanPrivilegedAccess() {
        var files = ["/etc/sudoers"]
        if let entries = try? fileManager.contentsOfDirectory(
            at: URL(fileURLWithPath: "/etc/sudoers.d"),
            includingPropertiesForKeys: nil,
            options: []
        ) {
            files.append(contentsOf: entries.map(\.path))
        }

        for file in files {
            guard let content = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            for rawLine in content.split(separator: "\n") {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, !line.hasPrefix("#"), line.contains("NOPASSWD") else { continue }
                add(
                    file,
                    kind: "privileged-access",
                    title: "Passwordless sudo rule",
                    detail: String(line.prefix(300)),
                    severity: .high,
                    requiresRoot: true
                )
            }
        }
    }

    private func scanExternalDrives() {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeIsInternalKey,
            .volumeTotalCapacityKey,
        ]
        guard let volumes = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) else { return }

        for volume in volumes where volume.path.hasPrefix("/Volumes/") {
            let values = try? volume.resourceValues(forKeys: Set(keys))
            let total = Int64(values?.volumeTotalCapacity ?? 0)
            if configuration.maxExternalDriveSize >= 0, total > configuration.maxExternalDriveSize {
                continue
            }
            let name = values?.volumeName ?? volume.lastPathComponent
            add(
                volume.path,
                kind: "external-volume",
                title: "External volume mounted: \(name)",
                detail: "\(total) bytes",
                severity: .info
            )
        }
    }

    private func scanMailAttachments() {
        let dangerous: Set<String> = [
            "app", "pkg", "dmg", "zip", "rar", "7z", "exe", "command",
            "sh", "js", "scpt", "workflow", "webloc", "iso", "sparseimage",
        ]
        let artifacts = MailScanner.scan(home: home, fileManager: fileManager)
        for artifact in artifacts where dangerous.contains(
            URL(fileURLWithPath: artifact.path).pathExtension.lowercased()
        ) {
            add(
                artifact.path,
                kind: "mail-attachment",
                title: "Mail attachment with executable content",
                detail: "\(artifact.bytes) bytes",
                severity: .medium
            )
        }
    }

    private func scanChromeExtensions() {
        let roots = [
            home.appendingPathComponent("Library/Application Support/Google/Chrome"),
            home.appendingPathComponent("Library/Application Support/Microsoft Edge"),
            home.appendingPathComponent("Library/Application Support/BraveSoftware/Brave-Browser"),
            home.appendingPathComponent("Library/Application Support/Chromium"),
            home.appendingPathComponent("Library/Application Support/Arc/User Data"),
        ]

        var count = 0
        for root in roots {
            guard let profiles = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            ) else { continue }

            for profile in profiles {
                let extensionsRoot = profile.appendingPathComponent("Extensions")
                guard let extensionDirectories = try? fileManager.contentsOfDirectory(
                    at: extensionsRoot,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: []
                ) else { continue }

                for extensionDirectory in extensionDirectories {
                    guard let versions = try? fileManager.contentsOfDirectory(
                        at: extensionDirectory,
                        includingPropertiesForKeys: [.isDirectoryKey],
                        options: []
                    ) else { continue }

                    for version in versions {
                        guard count < 200 else { return }
                        let manifest = version.appendingPathComponent("manifest.json")
                        guard let data = try? Data(contentsOf: manifest),
                              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }

                        scannedFiles += 1
                        let name = extensionDisplayName(
                            object: object,
                            versionURL: version,
                            fallback: extensionDirectory.lastPathComponent
                        )
                        let permissions = (object["permissions"] as? [String] ?? [])
                            + (object["host_permissions"] as? [String] ?? [])
                        let risky = permissions.contains {
                            ["nativeMessaging", "debugger", "management", "proxy", "<all_urls>", "*://*/*"]
                                .contains($0)
                        }
                        add(
                            manifest.path,
                            kind: "chrome-extension",
                            title: "Browser extension: \(name)",
                            detail: permissions.joined(separator: ", "),
                            severity: risky ? .medium : .info
                        )
                        count += 1
                    }
                }
            }
        }
    }

    private func extensionDisplayName(
        object: [String: Any],
        versionURL: URL,
        fallback: String
    ) -> String {
        guard let raw = object["name"] as? String else { return fallback }
        guard raw.hasPrefix("__MSG_"), raw.hasSuffix("__") else { return raw }

        let key = String(raw.dropFirst(6).dropLast(2))
        for locale in ["en", "en_US", "en_GB"] {
            let messages = versionURL.appendingPathComponent("_locales/\(locale)/messages.json")
            guard let data = try? Data(contentsOf: messages),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entry = json[key] as? [String: Any],
                  let message = entry["message"] as? String
            else { continue }
            return message
        }
        return raw
    }

    @discardableResult
    private func walk(
        _ root: URL,
        maxDepth: Int,
        body: (URL) -> Void
    ) -> Int {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }

        let baseDepth = root.pathComponents.count
        var count = 0

        for case let url as URL in enumerator {
            let depth = url.pathComponents.count - baseDepth
            if maxDepth >= 0, depth > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            if values.isSymbolicLink == true { continue }
            if values.isRegularFile == true {
                count += 1
                body(url)
            }
        }
        return count
    }
}
