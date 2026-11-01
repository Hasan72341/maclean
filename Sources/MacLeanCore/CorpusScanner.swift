import SQLite3
import CryptoKit
import Darwin
import Foundation

public struct CorpusScanResult: Sendable {
    public let findings: [ProtectionFinding]
    public let scannedFiles: Int
    public let info: CorpusInfo
    public let yara: YaraSummary?

    public init(
        findings: [ProtectionFinding],
        scannedFiles: Int,
        info: CorpusInfo,
        yara: YaraSummary? = nil
    ) {
        self.findings = findings
        self.scannedFiles = scannedFiles
        self.info = info
        self.yara = yara
    }
}

public final class CorpusScanner {
    private let corpus: PantherCorpus
    private let configuration: ScanConfiguration
    private let home: URL
    private let fileManager: FileManager
    private let runYara: Bool?
    private let yaraCacheDirectory: URL?
    private var regexCache: [String: NSRegularExpression] = [:]
    private var findings: [ProtectionFinding] = []
    private var seen = Set<String>()
    private var scannedFiles = 0
    private var yaraEnabled = false
    private var yaraCandidates: [URL] = []
    private var yaraSeen = Set<String>()
    private var excludedScanPaths = Set<String>()
    private let maxFiles = 200_000
    private let maxFindings = 5_000

    public init(
        corpus: PantherCorpus,
        configuration: ScanConfiguration,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        runYara: Bool? = nil,
        yaraCacheDirectory: URL? = nil
    ) {
        self.corpus = corpus
        self.configuration = configuration
        self.home = home
        self.fileManager = fileManager
        self.runYara = runYara
        self.yaraCacheDirectory = yaraCacheDirectory
    }

    public func scan(extraPaths: [URL] = []) -> CorpusScanResult {
        findings = []
        seen = []
        scannedFiles = 0
        yaraCandidates = []
        yaraSeen = []
        // MacLean's own state (alerts, reports, logs) quotes signature text.
        excludedScanPaths = [PathCanon.resolve(corpus.path), PathCanon.resolve(MonitorDefaults.supportDirectory.path)]
        if let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            excludedScanPaths.insert(
                PathCanon.resolve(caches.appendingPathComponent("maclean").path)
            )
        }
        if let yaraCacheDirectory {
            excludedScanPaths.insert(PathCanon.resolve(yaraCacheDirectory.path))
        }
        let onlyExplicitPaths = configuration.scanOption == [.diskURLs]
        yaraEnabled = runYara ?? (
            onlyExplicitPaths
                || configuration.scanMode == .protected
                || configuration.scanMode == .paranoid
        )

        var targets: [String: PantherCorpus.ScanTarget] = [:]
        if !onlyExplicitPaths {
            for target in corpus.scanTargets {
                if let existing = targets[target.path] {
                    targets[target.path] = PantherCorpus.ScanTarget(
                        pathID: existing.pathID,
                        path: existing.path,
                        riskScore: max(existing.riskScore, target.riskScore),
                        depthLimit: deeper(existing.depthLimit, target.depthLimit),
                        requiresRoot: existing.requiresRoot || target.requiresRoot,
                        exclusions: Array(Set(existing.exclusions + target.exclusions))
                    )
                } else {
                    targets[target.path] = target
                }
            }
        }

        for extra in extraPaths {
            let path = PathCanon.resolve(extra.path)
            let target = PantherCorpus.ScanTarget(
                pathID: "user",
                path: path,
                riskScore: 0,
                depthLimit: configuration.maxEnumerationDepth >= 0
                    ? configuration.maxEnumerationDepth
                    : nil,
                requiresRoot: false,
                exclusions: []
            )
            if let existing = targets[path] {
                targets[path] = PantherCorpus.ScanTarget(
                    pathID: existing.pathID,
                    path: path,
                    riskScore: existing.riskScore,
                    depthLimit: deeper(existing.depthLimit, target.depthLimit),
                    requiresRoot: existing.requiresRoot,
                    exclusions: existing.exclusions
                )
            } else {
                targets[path] = target
            }
        }

        let ordered = targets.values.sorted { $0.riskScore > $1.riskScore }
        for target in ordered {
            if target.requiresRoot, geteuid() != 0 { continue }
            if scannedFiles >= maxFiles || findings.count >= maxFindings { break }
            guard fileManager.fileExists(atPath: target.path) else { continue }

            let defaultDepth = configuration.maxEnumerationDepth
            let depth: Int
            if let targetDepth = target.depthLimit {
                depth = defaultDepth < 0 ? targetDepth : min(targetDepth, defaultDepth)
            } else {
                depth = defaultDepth
            }
            scanTarget(target, depth: depth)
        }

        if !onlyExplicitPaths {
            if configuration.scanOption.contains(.safariExtensions) {
                scanSafariExtensionRoots()
            }
            if configuration.scanOption.contains(.chromeExtensions) {
                scanChromeExtensionRoots()
            }
        }

        var yaraSummary: YaraSummary?
        if yaraEnabled, !corpus.yaraRules.isEmpty {
            do {
                let bundle = try CorpusYara.export(
                    corpus: corpus,
                    cacheDirectory: yaraCacheDirectory,
                    fileManager: fileManager
                )
                let cap: Int64 = configuration.scanMode == .paranoid
                    ? 300 * 1024 * 1024
                    : 50 * 1024 * 1024
                let result = CorpusYara.scan(
                    corpus: corpus,
                    bundle: bundle,
                    files: yaraCandidates,
                    maxFileSize: cap,
                    fileManager: fileManager
                )
                findings.append(contentsOf: result.findings)
                yaraSummary = result.summary
            } catch {
                yaraSummary = YaraSummary(
                    rulesPath: nil,
                    enginePath: nil,
                    matches: 0,
                    note: error.localizedDescription
                )
            }
        }

        scanHomepageRules()
        scanProfileRules()

        findings.sort {
            if $0.severity != $1.severity { return $0.severity.rank > $1.severity.rank }
            return $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
        }

        return CorpusScanResult(
            findings: Array(findings.prefix(maxFindings)),
            scannedFiles: scannedFiles,
            info: corpus.info,
            yara: yaraSummary
        )
    }

    private func deeper(_ lhs: Int?, _ rhs: Int?) -> Int? {
        switch (lhs, rhs) {
        case (nil, _): return nil
        case (_, nil): return nil
        case let (left?, right?): return max(left, right)
        }
    }

    private func scanTarget(_ target: PantherCorpus.ScanTarget, depth: Int) {
        let root = URL(fileURLWithPath: target.path)
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ]
        guard let rootValues = try? root.resourceValues(forKeys: keys) else { return }
        if rootValues.isSymbolicLink == true { return }

        if rootValues.isRegularFile == true {
            let path = PathCanon.resolve(root.path)
            guard !isExcluded(path, patterns: target.exclusions),
                  !isScanExcluded(path),
                  !isCorpusDatabase(root) else { return }
            scannedFiles += 1
            matchPathRules(path: path, name: root.lastPathComponent, requiresRoot: target.requiresRoot)
            matchHashRule(
                url: root,
                size: Int64(rootValues.fileSize ?? 0),
                requiresRoot: target.requiresRoot
            )
            matchMachORules(url: root, requiresRoot: target.requiresRoot)
            matchLaunchAgentRule(url: root, requiresRoot: target.requiresRoot)
            matchExtensionRules(url: root, requiresRoot: target.requiresRoot)
            addYaraCandidate(root)
            return
        }

        guard rootValues.isDirectory == true else { return }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else { return }

        let baseDepth = root.pathComponents.count

        for case let url as URL in enumerator {
            if scannedFiles >= maxFiles || findings.count >= maxFindings { break }

            let itemDepth = url.pathComponents.count - baseDepth
            if depth >= 0, itemDepth > depth {
                enumerator.skipDescendants()
                continue
            }

            let path = PathCanon.resolve(url.path)
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            if values.isSymbolicLink == true { continue }

            if isExcluded(path, patterns: target.exclusions) {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if isScanExcluded(path) {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }

            if values.isRegularFile == true, isCorpusDatabase(url) {
                continue
            }

            scannedFiles += 1
            matchPathRules(path: path, name: url.lastPathComponent, requiresRoot: target.requiresRoot)

            guard values.isRegularFile == true else { continue }

            matchHashRule(url: url, size: Int64(values.fileSize ?? 0), requiresRoot: target.requiresRoot)
            matchMachORules(url: url, requiresRoot: target.requiresRoot)
            matchLaunchAgentRule(url: url, requiresRoot: target.requiresRoot)
            matchExtensionRules(url: url, requiresRoot: target.requiresRoot)
            addYaraCandidate(url)
        }
    }

    private func addYaraCandidate(_ url: URL) {
        guard yaraEnabled, yaraCandidates.count < maxFiles else { return }
        let path = PathCanon.resolve(url.path)
        guard !isScanExcluded(path), !isCorpusDatabase(url) else { return }
        guard yaraSeen.insert(path).inserted else { return }
        yaraCandidates.append(URL(fileURLWithPath: path))
    }

    private func isCorpusDatabase(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard ext == "sqlite" || ext == "sqlite3" || ext == "db" else { return false }
        guard let handle = try? FileHandle(forReadingFrom: url),
              let head = try? handle.read(upToCount: 64 * 1024),
              head.count >= 16
        else { return false }
        try? handle.close()
        guard head.starts(with: Data("SQLite format 3\u{0}".utf8)) else { return false }
        let sample = String(decoding: head, as: UTF8.self)
        if sample.contains("MalwareRule") || sample.contains("CREATE TABLE Malware") { return true }
        // The schema can sit anywhere in the file; ask SQLite for the table names.
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return false }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let query = "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND (name = 'Malware' OR name LIKE 'MalwareRule%')"
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW else { return false }
        return sqlite3_column_int(statement, 0) >= 2
    }

    private func isScanExcluded(_ path: String) -> Bool {
        excludedScanPaths.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    private func isExcluded(_ path: String, patterns: [String]) -> Bool {
        patterns.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    private func matchPathRules(path: String, name: String, requiresRoot: Bool) {
        if let rules = corpus.exactPathRules[path] {
            for rule in rules {
                add(
                    path: path,
                    kind: "malware-path",
                    ruleID: rule.ruleID,
                    malwareID: rule.malwareID,
                    requiresRoot: requiresRoot
                )
            }
        }

        let parent = PathCanon.resolve(
            URL(fileURLWithPath: path).deletingLastPathComponent().path
        )
        if let rules = corpus.parentPathRules[parent] {
            for rule in rules where regexMatches(rule.nameRegex, name, anchored: true) {
                add(
                    path: path,
                    kind: "malware-path",
                    ruleID: rule.ruleID,
                    malwareID: rule.malwareID,
                    requiresRoot: requiresRoot
                )
            }
        }
    }

    private func matchHashRule(url: URL, size: Int64, requiresRoot: Bool) {
        guard size > 0, corpus.knownSizes.contains(size) else { return }
        guard let hash = DuplicateScanner.sha256(of: url),
              let rules = corpus.hashRulesBySizeAndHash[size]?[hash] else { return }
        for rule in rules {
            add(
                path: url.path,
                kind: "malware-hash",
                ruleID: rule.ruleID,
                malwareID: rule.malwareID,
                requiresRoot: requiresRoot,
                detail: "size \(size)"
            )
        }
    }

    private func matchMachORules(url: URL, requiresRoot: Bool) {
        guard !corpus.teamIDRules.isEmpty || !corpus.sectionRules.isEmpty else { return }
        guard let info = MachOAnalyzer.analyze(
            url: url,
            sectionKeys: corpus.sectionKeys,
            needTeamID: !corpus.teamIDRules.isEmpty
        ) else { return }

        if let teamID = info.teamID,
           let rules = corpus.teamIDRules[teamID.uppercased()] {
            for rule in rules {
                add(
                    path: url.path,
                    kind: "malware-team-id",
                    ruleID: rule.ruleID,
                    malwareID: rule.malwareID,
                    requiresRoot: requiresRoot,
                    detail: "team \(teamID)"
                )
            }
        }

        for section in info.sections {
            let key = MachOAnalyzer.sectionKey(
                segment: section.segment,
                section: section.section,
                size: section.size,
                hash: section.hash
            )
            guard let rules = corpus.sectionRules[key] else { continue }
            for rule in rules {
                add(
                    path: url.path,
                    kind: "malware-section",
                    ruleID: rule.ruleID,
                    malwareID: rule.malwareID,
                    requiresRoot: requiresRoot,
                    detail: "\(section.segment),\(section.section) size \(section.size)"
                )
            }
        }
    }

    private func matchLaunchAgentRule(url: URL, requiresRoot: Bool) {
        guard url.pathExtension == "plist", isLaunchItem(url) else { return }
        let plist = PlistReader.dictionary(at: url) ?? [:]
        let label = PlistReader.string("Label", in: plist) ?? url.lastPathComponent
        let baseName = url.deletingPathExtension().lastPathComponent
        let needsContents = corpus.launchAgentRules.contains { $0.contents != nil }
        let contents = needsContents ? readText(url, maxBytes: 1 << 20) : nil

        for rule in corpus.launchAgentRules {
            guard regexMatches(rule.regex, baseName, anchored: true) else { continue }
            if let pattern = rule.contents, !pattern.isEmpty {
                guard let contents,
                      regexMatches(pattern, contents, options: [.dotMatchesLineSeparators])
                else { continue }
            }
            add(
                path: url.path,
                kind: "malware-launch-item",
                ruleID: rule.ruleID,
                malwareID: rule.malwareID,
                requiresRoot: requiresRoot,
                detail: label
            )
        }
    }

    private func matchExtensionRules(url: URL, requiresRoot: Bool) {
        if url.path.contains("/Safari/Extensions/") {
            let name = url.lastPathComponent
            let base = url.deletingPathExtension().lastPathComponent
            for rule in corpus.safariExtensionRules where regexMatches(
                rule.regex,
                name,
                anchored: true
            ) || regexMatches(rule.regex, base, anchored: true) {
                add(
                    path: url.path,
                    kind: "malware-safari-extension",
                    ruleID: rule.ruleID,
                    malwareID: rule.malwareID,
                    requiresRoot: requiresRoot
                )
            }
        }

        guard url.lastPathComponent == "manifest.json",
              url.path.contains("/Extensions/") else { return }
        let components = url.pathComponents
        guard let index = components.lastIndex(of: "Extensions"),
              index + 1 < components.count else { return }
        let extensionID = components[index + 1]
        let contents = readText(url, maxBytes: 1 << 20)

        for rule in corpus.chromeExtensionRules where rule.extensionID == extensionID {
            if let pattern = rule.contentsRegex, !pattern.isEmpty {
                guard let contents,
                      regexMatches(pattern, contents, options: [.dotMatchesLineSeparators])
                else { continue }
            }
            add(
                path: url.path,
                kind: "malware-chrome-extension",
                ruleID: rule.ruleID,
                malwareID: rule.malwareID,
                requiresRoot: requiresRoot,
                detail: extensionID
            )
        }
    }

    private func scanSafariExtensionRoots() {
        let roots = [
            home.appendingPathComponent("Library/Safari/Extensions"),
            home.appendingPathComponent(
                "Library/Containers/com.apple.Safari/Data/Library/Safari/Extensions"
            ),
        ]
        for root in roots {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isSymbolicLinkKey],
                options: []
            ) else { continue }
            for entry in entries {
                if (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                    continue
                }
                scannedFiles += 1
                matchExtensionRules(url: entry, requiresRoot: false)
                addYaraCandidate(entry)
            }
        }
    }

    private func scanChromeExtensionRoots() {
        let roots = [
            home.appendingPathComponent("Library/Application Support/Google/Chrome"),
            home.appendingPathComponent("Library/Application Support/Microsoft Edge"),
            home.appendingPathComponent("Library/Application Support/BraveSoftware/Brave-Browser"),
            home.appendingPathComponent("Library/Application Support/Chromium"),
            home.appendingPathComponent("Library/Application Support/Arc/User Data"),
        ]
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]

        for root in roots {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [],
                errorHandler: { _, _ in true }
            ) else { continue }

            for case let url as URL in enumerator {
                guard url.lastPathComponent == "manifest.json",
                      url.path.contains("/Extensions/") else { continue }
                if (try? url.resourceValues(forKeys: keys))?.isSymbolicLink == true { continue }
                scannedFiles += 1
                matchExtensionRules(url: url, requiresRoot: false)
                addYaraCandidate(url)
            }
        }
    }

    private func scanHomepageRules() {
        guard !corpus.homepageRules.isEmpty else { return }
        let candidates = [
            home.appendingPathComponent("Library/Preferences/com.apple.Safari.plist"),
            home.appendingPathComponent(
                "Library/Containers/com.apple.Safari/Data/Library/Preferences/com.apple.Safari.plist"
            ),
        ]
        for candidate in candidates {
            guard let plist = PlistReader.dictionary(at: candidate) else { continue }
            let homepage = (plist["HomePage"] as? String)
                ?? (plist["HomePageURL"] as? String)
                ?? ""
            guard !homepage.isEmpty else { return }
            for rule in corpus.homepageRules where regexMatches(rule.regex, homepage) {
                add(
                    path: candidate.path,
                    kind: "malware-homepage",
                    ruleID: rule.ruleID,
                    malwareID: rule.malwareID,
                    requiresRoot: false,
                    detail: homepage
                )
            }
            return
        }
    }

    private func scanProfileRules() {
        guard !corpus.profileRules.isEmpty else { return }
        let result = ProcessRunner.run(
            "/usr/bin/profiles",
            ["show", "-type", "configuration"],
            timeout: 20
        )
        guard result.status == 0, !result.stdout.isEmpty else { return }
        for rule in corpus.profileRules where regexMatches(rule.regex, result.stdout) {
            add(
                path: "/",
                kind: "malware-profile",
                ruleID: rule.ruleID,
                malwareID: rule.malwareID,
                requiresRoot: false
            )
        }
    }

    private func isLaunchItem(_ url: URL) -> Bool {
        let components = url.pathComponents
        return components.contains("LaunchAgents") || components.contains("LaunchDaemons")
    }

    private func readText(_ url: URL, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    private func regexMatches(
        _ pattern: String?,
        _ text: String,
        options: NSRegularExpression.Options = [],
        anchored: Bool = false
    ) -> Bool {
        guard let pattern, !pattern.isEmpty else { return false }
        let finalPattern = anchored ? "^\(pattern)$" : pattern
        let key = "\(options.rawValue)|\(finalPattern)"
        let expression: NSRegularExpression?
        if let cached = regexCache[key] {
            expression = cached
        } else {
            expression = try? NSRegularExpression(pattern: finalPattern, options: options)
            regexCache[key] = expression
        }
        guard let expression else { return false }
        return expression.firstMatch(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        ) != nil
    }

    private func add(
        path: String,
        kind: String,
        ruleID: String,
        malwareID: Int,
        requiresRoot: Bool,
        detail: String = ""
    ) {
        guard findings.count < maxFindings else { return }
        let key = "\(kind)|\(path)|\(malwareID)|\(ruleID)"
        guard seen.insert(key).inserted else { return }

        let malware = corpus.malware[malwareID]
        let title = malware.map { "\($0.name) (\($0.type))" } ?? "Unknown malware (rule \(ruleID))"
        var text = "rule \(ruleID)"
        if let infoLink = malware?.infoLink, !infoLink.isEmpty {
            text += " · \(infoLink)"
        }
        if !detail.isEmpty {
            text += " · \(detail)"
        }

        findings.append(
            ProtectionFinding(
                path: path,
                kind: kind,
                title: title,
                detail: text,
                severity: .high,
                requiresRoot: requiresRoot
            )
        )
    }
}
