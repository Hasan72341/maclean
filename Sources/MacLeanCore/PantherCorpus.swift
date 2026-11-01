import Foundation
import SQLite3

public enum PantherCorpusError: LocalizedError {
    case open(String)
    case query(String)

    public var errorDescription: String? {
        switch self {
        case .open(let message): return "could not open corpus: \(message)"
        case .query(let message): return "corpus query failed: \(message)"
        }
    }
}

public struct CorpusInfo: Codable, Sendable {
    public let path: String
    public let version: String?
    public let updateDate: String?
    public let hashRules: Int
    public let pathRules: Int
    public let launchAgentRules: Int
    public let safariExtensionRules: Int
    public let chromeExtensionRules: Int
    public let homepageRules: Int
    public let profileRules: Int
    public let teamIDRules: Int
    public let sectionHashRules: Int
    public let yaraRules: Int
    public let scanTargets: Int

    public init(
        path: String,
        version: String?,
        updateDate: String?,
        hashRules: Int,
        pathRules: Int,
        launchAgentRules: Int,
        safariExtensionRules: Int,
        chromeExtensionRules: Int,
        homepageRules: Int,
        profileRules: Int,
        teamIDRules: Int,
        sectionHashRules: Int,
        yaraRules: Int,
        scanTargets: Int
    ) {
        self.path = path
        self.version = version
        self.updateDate = updateDate
        self.hashRules = hashRules
        self.pathRules = pathRules
        self.launchAgentRules = launchAgentRules
        self.safariExtensionRules = safariExtensionRules
        self.chromeExtensionRules = chromeExtensionRules
        self.homepageRules = homepageRules
        self.profileRules = profileRules
        self.teamIDRules = teamIDRules
        self.sectionHashRules = sectionHashRules
        self.yaraRules = yaraRules
        self.scanTargets = scanTargets
    }
}

public struct PantherCorpus {
    public struct MalwareInfo: Sendable {
        public let name: String
        public let type: String
        public let infoLink: String?
    }

    public struct HashRule: Sendable {
        public let ruleID: String
        public let size: Int64
        public let hash: String
        public let malwareID: Int
    }

    public struct PathRule: Sendable {
        public let ruleID: String
        public let path: String
        public let nameRegex: String?
        public let malwareID: Int
    }

    public struct LaunchAgentRule: Sendable {
        public let ruleID: String
        public let regex: String
        public let contents: String?
        public let malwareID: Int
    }

    public struct SafariExtensionRule: Sendable {
        public let ruleID: String
        public let regex: String
        public let malwareID: Int
    }

    public struct ChromeExtensionRule: Sendable {
        public let ruleID: String
        public let extensionID: String
        public let contentsRegex: String?
        public let malwareID: Int
    }

    public struct HomepageRule: Sendable {
        public let ruleID: String
        public let regex: String
        public let malwareID: Int
    }

    public struct ProfileRule: Sendable {
        public let ruleID: String
        public let regex: String
        public let malwareID: Int
    }

    public struct TeamIDRule: Sendable {
        public let ruleID: String
        public let teamID: String
        public let malwareID: Int
    }

    public struct SectionHashRule: Sendable {
        public let ruleID: String
        public let segment: String
        public let section: String
        public let size: Int64
        public let hash: String
        public let malwareID: Int
    }

    public struct YaraRule: Sendable {
        public let ruleID: String
        public let category: String
        public let text: String
        public let malwareID: Int
    }

    public struct ScanTarget: Sendable {
        public let pathID: String
        public let path: String
        public let riskScore: Int
        public let depthLimit: Int?
        public let requiresRoot: Bool
        public let exclusions: [String]
    }

    public let path: String
    public let version: String?
    public let updateDate: String?
    public let malware: [Int: MalwareInfo]
    public let knownSizes: Set<Int64>
    public let hashRulesBySizeAndHash: [Int64: [String: [HashRule]]]
    public let exactPathRules: [String: [PathRule]]
    public let parentPathRules: [String: [PathRule]]
    public let launchAgentRules: [LaunchAgentRule]
    public let safariExtensionRules: [SafariExtensionRule]
    public let chromeExtensionRules: [ChromeExtensionRule]
    public let homepageRules: [HomepageRule]
    public let profileRules: [ProfileRule]
    public let teamIDRules: [String: [TeamIDRule]]
    public let sectionRules: [String: [SectionHashRule]]
    public let sectionKeys: Set<String>
    public let yaraRules: [YaraRule]
    public let yaraDependencies: [String]
    public let scanTargets: [ScanTarget]
    public let info: CorpusInfo

    public init(
        path: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        includeExtended: Bool = false
    ) throws {
        self.path = path
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            throw PantherCorpusError.open(message)
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 2000)

        var malware: [Int: MalwareInfo] = [:]
        try Self.rows(handle, "SELECT ID, Name, Type, InfoLink FROM Malware") { row in
            guard let id = Self.int(row, 0) else { return }
            malware[Int(id)] = MalwareInfo(
                name: Self.text(row, 1) ?? "Unknown",
                type: Self.text(row, 2) ?? "unknown",
                infoLink: Self.text(row, 3)
            )
        }

        var knownSizes = Set<Int64>()
        var hashIndex: [Int64: [String: [HashRule]]] = [:]

        func loadHashes(_ table: String) throws {
            try Self.rows(handle, "SELECT RuleID, Size, Hash, MalwareID FROM \(table)") { row in
                guard let size = Self.int(row, 1), size > 0,
                      let rawHash = Self.text(row, 2),
                      let malwareID = Self.int(row, 3) else { return }
                let hash = rawHash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else { return }
                let rule = HashRule(
                    ruleID: Self.text(row, 0) ?? "",
                    size: size,
                    hash: hash,
                    malwareID: Int(malwareID)
                )
                knownSizes.insert(size)
                hashIndex[size, default: [:]][hash, default: []].append(rule)
            }
        }

        try loadHashes("MalwareRuleHash")
        if includeExtended {
            try loadHashes("MalwareRuleHash_Extended")
        }

        var exactPathRules: [String: [PathRule]] = [:]
        var parentPathRules: [String: [PathRule]] = [:]

        func loadPaths(_ table: String) throws {
            try Self.rows(handle, "SELECT RuleID, Path, NameRegex, MalwareID FROM \(table)") { row in
                guard let rawPath = Self.text(row, 1), !rawPath.isEmpty,
                      let malwareID = Self.int(row, 3) else { return }
                let normalized = Self.normalizePath(rawPath, home: home)
                let nameRegex = Self.text(row, 2).flatMap { $0.isEmpty ? nil : $0 }
                let rule = PathRule(
                    ruleID: Self.text(row, 0) ?? "",
                    path: normalized,
                    nameRegex: nameRegex,
                    malwareID: Int(malwareID)
                )
                if nameRegex == nil {
                    exactPathRules[normalized, default: []].append(rule)
                } else {
                    parentPathRules[normalized, default: []].append(rule)
                }
            }
        }

        try loadPaths("MalwareRulePath")
        if includeExtended {
            try loadPaths("MalwareRulePath_Extended")
        }

        var launchAgentRules: [LaunchAgentRule] = []
        func loadLaunchAgents(_ table: String) throws {
            try Self.rows(handle, "SELECT RuleID, Regex, Contents, MalwareID FROM \(table)") { row in
                guard let regex = Self.text(row, 1), !regex.isEmpty,
                      let malwareID = Self.int(row, 3) else { return }
                launchAgentRules.append(
                    LaunchAgentRule(
                        ruleID: Self.text(row, 0) ?? "",
                        regex: regex,
                        contents: Self.text(row, 2).flatMap { $0.isEmpty ? nil : $0 },
                        malwareID: Int(malwareID)
                    )
                )
            }
        }

        try loadLaunchAgents("MalwareRuleLaunchAgent")
        if includeExtended {
            try loadLaunchAgents("MalwareRuleLaunchAgent_Extended")
        }

        var safariExtensionRules: [SafariExtensionRule] = []
        func loadSafariExtensions(_ table: String) throws {
            try Self.rows(handle, "SELECT RuleID, Regex, MalwareID FROM \(table)") { row in
                guard let regex = Self.text(row, 1), !regex.isEmpty,
                      let malwareID = Self.int(row, 2) else { return }
                safariExtensionRules.append(
                    SafariExtensionRule(
                        ruleID: Self.text(row, 0) ?? "",
                        regex: regex,
                        malwareID: Int(malwareID)
                    )
                )
            }
        }

        try loadSafariExtensions("MalwareRuleSafariExtension")
        if includeExtended {
            try loadSafariExtensions("MalwareRuleSafariExtension_Extended")
        }

        var chromeExtensionRules: [ChromeExtensionRule] = []
        func loadChromeExtensions(_ table: String) throws {
            try Self.rows(handle, "SELECT RuleID, ExtensionID, ContentsRegex, MalwareID FROM \(table)") { row in
                guard let extensionID = Self.text(row, 1), !extensionID.isEmpty,
                      let malwareID = Self.int(row, 3) else { return }
                chromeExtensionRules.append(
                    ChromeExtensionRule(
                        ruleID: Self.text(row, 0) ?? "",
                        extensionID: extensionID,
                        contentsRegex: Self.text(row, 2).flatMap { $0.isEmpty ? nil : $0 },
                        malwareID: Int(malwareID)
                    )
                )
            }
        }

        try loadChromeExtensions("MalwareRuleChromeExtension")
        if includeExtended {
            try loadChromeExtensions("MalwareRuleChromeExtension_Extended")
        }

        var homepageRules: [HomepageRule] = []
        func loadHomepages(_ table: String) throws {
            try Self.rows(handle, "SELECT RuleID, Regex, MalwareID FROM \(table)") { row in
                guard let regex = Self.text(row, 1), !regex.isEmpty,
                      let malwareID = Self.int(row, 2) else { return }
                homepageRules.append(
                    HomepageRule(
                        ruleID: Self.text(row, 0) ?? "",
                        regex: regex,
                        malwareID: Int(malwareID)
                    )
                )
            }
        }

        try loadHomepages("MalwareRuleHomepage")
        if includeExtended {
            try loadHomepages("MalwareRuleHomepage_Extended")
        }

        var profileRules: [ProfileRule] = []
        func loadProfiles(_ table: String) throws {
            try Self.rows(handle, "SELECT RuleID, IdentifierRegex, MalwareID FROM \(table)") { row in
                guard let regex = Self.text(row, 1), !regex.isEmpty,
                      let malwareID = Self.int(row, 2) else { return }
                profileRules.append(
                    ProfileRule(
                        ruleID: Self.text(row, 0) ?? "",
                        regex: regex,
                        malwareID: Int(malwareID)
                    )
                )
            }
        }

        try loadProfiles("MalwareRuleProfile")
        if includeExtended {
            try loadProfiles("MalwareRuleProfile_Extended")
        }

        var teamIDRules: [String: [TeamIDRule]] = [:]
        func loadTeamIDs(_ table: String) throws {
            try Self.rows(handle, "SELECT RuleID, TeamID, MalwareID FROM \(table)") { row in
                guard let teamID = Self.text(row, 1), !teamID.isEmpty,
                      let malwareID = Self.int(row, 2) else { return }
                let normalized = teamID.uppercased()
                teamIDRules[normalized, default: []].append(
                    TeamIDRule(
                        ruleID: Self.text(row, 0) ?? "",
                        teamID: normalized,
                        malwareID: Int(malwareID)
                    )
                )
            }
        }

        try loadTeamIDs("MalwareRuleTeamID")
        if includeExtended {
            try loadTeamIDs("MalwareRuleTeamID_Extended")
        }

        var sectionRules: [String: [SectionHashRule]] = [:]
        var sectionKeys = Set<String>()

        func loadSections(_ dataTable: String, _ ruleTable: String) throws {
            try Self.rows(
                handle,
                """
                SELECT d.RuleID, d.Segment, d.Section, d.Size, d.Hash, r.MalwareID
                FROM \(dataTable) d
                LEFT JOIN \(ruleTable) r ON r.RuleID = d.RuleID
                """
            ) { row in
                guard let segment = Self.text(row, 1), !segment.isEmpty,
                      let section = Self.text(row, 2), !section.isEmpty,
                      let size = Self.int(row, 3), size > 0,
                      let rawHash = Self.text(row, 4),
                      let malwareID = Self.int(row, 5) else { return }
                let hash = rawHash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else { return }

                let rule = SectionHashRule(
                    ruleID: Self.text(row, 0) ?? "",
                    segment: segment,
                    section: section,
                    size: size,
                    hash: hash,
                    malwareID: Int(malwareID)
                )
                sectionRules[
                    MachOAnalyzer.sectionKey(
                        segment: segment,
                        section: section,
                        size: size,
                        hash: hash
                    ),
                    default: []
                ].append(rule)
                sectionKeys.insert(
                    MachOAnalyzer.sectionKey(
                        segment: segment,
                        section: section,
                        size: size
                    )
                )
            }
        }

        try loadSections("MalwareRuleSectionHashData", "MalwareRuleSectionHash")
        if includeExtended {
            try loadSections(
                "MalwareRuleSectionHashData_Extended",
                "MalwareRuleSectionHash_Extended"
            )
        }

        var yaraRules: [YaraRule] = []
        func loadYara(_ table: String) throws {
            try Self.rows(
                handle,
                "SELECT RuleID, Category, YaraRule, MalwareID FROM \(table)"
            ) { row in
                guard let text = Self.text(row, 2), !text.isEmpty,
                      let malwareID = Self.int(row, 3) else { return }
                yaraRules.append(
                    YaraRule(
                        ruleID: Self.text(row, 0) ?? "",
                        category: Self.text(row, 1) ?? "",
                        text: text,
                        malwareID: Int(malwareID)
                    )
                )
            }
        }

        try loadYara("MalwareRuleYara")
        if includeExtended {
            try loadYara("MalwareRuleYara_Extended")
        }

        var yaraDependencies: [String] = []
        var seenDependencies = Set<String>()
        try Self.rows(
            handle,
            "SELECT Dependency FROM MalwareRuleYaraDependencies"
        ) { row in
            guard let dependency = Self.text(row, 0) else { return }
            let trimmed = dependency.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seenDependencies.insert(trimmed).inserted else { return }
            yaraDependencies.append(trimmed)
        }

        var exclusions: [String: [String]] = [:]
        try Self.rows(handle, "SELECT ScanPathID, ExclusionPatterns FROM ScanExclusionPath") { row in
            guard let pathID = Self.text(row, 0),
                  let pattern = Self.text(row, 1), !pattern.isEmpty else { return }
            exclusions[pathID, default: []].append(Self.normalizePath(pattern, home: home))
        }

        var scanTargets: [ScanTarget] = []
        try Self.rows(
            handle,
            "SELECT PathID, PathPattern, RiskScore, ScanDepthLimit, IsRootRequired FROM ScanTargetPath"
        ) { row in
            guard let pathID = Self.text(row, 0),
                  let rawPath = Self.text(row, 1), !rawPath.isEmpty else { return }
            let depth: Int? = sqlite3_column_type(row, 3) == SQLITE_NULL
                ? nil
                : Self.int(row, 3).map(Int.init)
            scanTargets.append(
                ScanTarget(
                    pathID: pathID,
                    path: Self.normalizePath(rawPath, home: home),
                    riskScore: Self.int(row, 2).map(Int.init) ?? 0,
                    depthLimit: depth,
                    requiresRoot: (Self.int(row, 4) ?? 0) != 0,
                    exclusions: exclusions[pathID] ?? []
                )
            )
        }

        var version: String?
        var updateDate: String?
        try Self.rows(handle, "SELECT Version, UpdateDate FROM Metadata LIMIT 1") { row in
            version = Self.text(row, 0)
            updateDate = Self.text(row, 1)
        }

        let info = CorpusInfo(
            path: path,
            version: version,
            updateDate: updateDate,
            hashRules: hashIndex.values.reduce(0) { $0 + $1.values.reduce(0) { $0 + $1.count } },
            pathRules: exactPathRules.values.reduce(0) { $0 + $1.count }
                + parentPathRules.values.reduce(0) { $0 + $1.count },
            launchAgentRules: launchAgentRules.count,
            safariExtensionRules: safariExtensionRules.count,
            chromeExtensionRules: chromeExtensionRules.count,
            homepageRules: homepageRules.count,
            profileRules: profileRules.count,
            teamIDRules: teamIDRules.values.reduce(0) { $0 + $1.count },
            sectionHashRules: sectionRules.values.reduce(0) { $0 + $1.count },
            yaraRules: yaraRules.count,
            scanTargets: scanTargets.count
        )

        self.version = version
        self.updateDate = updateDate
        self.malware = malware
        self.knownSizes = knownSizes
        self.hashRulesBySizeAndHash = hashIndex
        self.exactPathRules = exactPathRules
        self.parentPathRules = parentPathRules
        self.launchAgentRules = launchAgentRules
        self.safariExtensionRules = safariExtensionRules
        self.chromeExtensionRules = chromeExtensionRules
        self.homepageRules = homepageRules
        self.profileRules = profileRules
        self.teamIDRules = teamIDRules
        self.sectionRules = sectionRules
        self.sectionKeys = sectionKeys
        self.yaraRules = yaraRules
        self.yaraDependencies = yaraDependencies
        self.scanTargets = scanTargets.sorted { $0.riskScore > $1.riskScore }
        self.info = info
    }

    private static func rows(
        _ handle: OpaquePointer?,
        _ sql: String,
        _ body: (OpaquePointer) -> Void
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            throw PantherCorpusError.query(message)
        }
        defer { sqlite3_finalize(statement) }

        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                body(statement!)
            case SQLITE_DONE:
                return
            default:
                let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
                throw PantherCorpusError.query(message)
            }
        }
    }

    private static func text(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    private static func int(_ statement: OpaquePointer?, _ index: Int32) -> Int64? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, index)
    }

    private static func normalizePath(_ path: String, home: URL) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return PathCanon.resolve(expanded)
    }
}
