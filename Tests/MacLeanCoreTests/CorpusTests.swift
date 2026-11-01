import XCTest
import CryptoKit
import SQLite3
@testable import MacLeanCore

final class PantherCorpusTests: XCTestCase {
    private let fileManager = FileManager.default
    private var home: URL!
    private var corpusURL: URL!

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("maclean-corpus-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        home = base.resolvingSymlinksInPath()
        corpusURL = home.appendingPathComponent("corpus.sqlite")
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: home)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func exec(_ sql: String) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(corpusURL.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        var error: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(handle, sql, nil, nil, &error)
        if result != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "unknown"
            XCTFail("sqlite: \(message)")
        }
        sqlite3_free(error)
    }

    private func createCorpus(payload: Data, malwareID: Int) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(corpusURL.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }

        let library = home.appendingPathComponent("Library").path
        let evilDir = home.appendingPathComponent("Library/EvilDir").path
        let launchAgent = home.appendingPathComponent("Library/LaunchAgents/com.evil.agent.plist").path
        let extensionID = "abcdefghijklmnopabcdefghijklmnop"
        let hash = sha256(payload)

        let sql = """
        CREATE TABLE Metadata (Version TEXT PRIMARY KEY, IsDumpFull INTEGER, UpdateDate TEXT);
        CREATE TABLE Malware (ID INTEGER PRIMARY KEY, Name TEXT, Type TEXT, InfoLink TEXT);
        CREATE TABLE MalwareRuleHash (RuleID TEXT PRIMARY KEY, BaseVersion TEXT, MalwareID INTEGER, Size INTEGER, Hash TEXT);
        CREATE TABLE MalwareRulePath (RuleID TEXT PRIMARY KEY, BaseVersion TEXT, MalwareID INTEGER, Path TEXT, NameRegex TEXT, ContentsRegex TEXT);
        CREATE TABLE MalwareRuleLaunchAgent (RuleID TEXT PRIMARY KEY, BaseVersion TEXT, MalwareID INTEGER, Regex TEXT, Contents TEXT);
        CREATE TABLE MalwareRuleSafariExtension (RuleID TEXT PRIMARY KEY, BaseVersion TEXT, MalwareID INTEGER, Regex TEXT);
        CREATE TABLE MalwareRuleChromeExtension (RuleID TEXT PRIMARY KEY, BaseVersion TEXT, MalwareID INTEGER, ExtensionID TEXT, ContentsRegex TEXT);
        CREATE TABLE MalwareRuleHomepage (RuleID TEXT PRIMARY KEY, BaseVersion TEXT, MalwareID INTEGER, Regex TEXT);
        CREATE TABLE MalwareRuleProfile (RuleID TEXT PRIMARY KEY, BaseVersion TEXT, MalwareID INTEGER, IdentifierRegex TEXT);
        CREATE TABLE MalwareRuleTeamID (RuleID TEXT PRIMARY KEY, BaseVersion TEXT, MalwareID INTEGER, TeamID TEXT, Info TEXT);
        CREATE TABLE MalwareRuleSectionHash (RuleID TEXT PRIMARY KEY, BaseVersion TEXT, MalwareID INTEGER);
        CREATE TABLE MalwareRuleSectionHashData (SectionID INTEGER PRIMARY KEY, RuleID TEXT, Segment TEXT, Section TEXT, Size INTEGER, Hash TEXT);
        CREATE TABLE MalwareRuleYara (RuleID TEXT PRIMARY KEY, BaseVersion TEXT, MalwareID INTEGER, Category TEXT, YaraRule TEXT, YaraVersion TEXT);
        CREATE TABLE MalwareRuleYaraDependencies (Category TEXT, Dependency TEXT);
        CREATE TABLE ScanTargetPath (PathID TEXT PRIMARY KEY, PathPattern TEXT, RiskScore INTEGER, ScanDepthLimit INTEGER, EnumerationStrategy INTEGER, IsRootRequired INTEGER, BaseVersion TEXT, MinEngineFullVersion TEXT, MinEngineLiteVersion TEXT, MinSystemVersion TEXT, DetectionMethod INTEGER, Description TEXT);
        CREATE TABLE ScanExclusionPath (ID INTEGER PRIMARY KEY AUTOINCREMENT, ScanPathID TEXT, ExclusionPatterns TEXT, ExclusionDescription TEXT, BaseVersion TEXT);

        INSERT INTO Metadata VALUES ('test-1', 1, '2026-01-01');
        INSERT INTO Malware VALUES (\(malwareID), 'TestMalware', 'trojan', 'https://example.invalid/test');
        INSERT INTO MalwareRuleHash VALUES ('H1', 'test', \(malwareID), \(payload.count), '\(hash)');
        INSERT INTO MalwareRulePath VALUES ('P1', 'test', \(malwareID), '\(evilDir)', '', '');
        INSERT INTO MalwareRuleLaunchAgent VALUES ('L1', 'test', \(malwareID), 'com\\.evil\\.agent', '');
        INSERT INTO MalwareRuleChromeExtension VALUES ('C1', 'test', \(malwareID), '\(extensionID)', '');
        INSERT INTO ScanTargetPath VALUES ('T1', '\(library)', 70, 10, 0, 0, 'test', '', '', '', 15, 'test target');
        """

        var error: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(handle, sql, nil, nil, &error)
        if result != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "unknown"
            XCTFail("sqlite: \(message)")
        }
        sqlite3_free(error)

        try fileManager.createDirectory(
            at: home.appendingPathComponent("Library/Caches"),
            withIntermediateDirectories: true
        )
        try payload.write(to: home.appendingPathComponent("Library/Caches/bad.bin"))
        try fileManager.createDirectory(
            at: home.appendingPathComponent("Library/EvilDir"),
            withIntermediateDirectories: true
        )

        let launchAgentURL = URL(fileURLWithPath: launchAgent)
        try fileManager.createDirectory(
            at: launchAgentURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let plist: [String: Any] = ["Label": "com.evil.agent", "Program": "/bin/true"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: launchAgentURL)

        let manifest = home.appendingPathComponent(
            "Library/Application Support/Google/Chrome/Default/Extensions/\(extensionID)/1.0/manifest.json"
        )
        try fileManager.createDirectory(
            at: manifest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONSerialization.data(withJSONObject: ["name": "Bad", "version": "1.0"])
            .write(to: manifest)
    }

    func testHashPathLaunchAndExtensionRules() throws {
        let payload = Data("not-really-malware".utf8)
        try createCorpus(payload: payload, malwareID: 1)

        let corpus = try PantherCorpus(path: corpusURL.path, home: home)
        XCTAssertEqual(corpus.info.hashRules, 1)
        XCTAssertEqual(corpus.info.pathRules, 1)
        XCTAssertEqual(corpus.info.launchAgentRules, 1)
        XCTAssertEqual(corpus.info.chromeExtensionRules, 1)
        XCTAssertEqual(corpus.info.scanTargets, 1)

        var configuration = ScanConfiguration.fast()
        configuration.scanOption.insert(.chromeExtensions)
        configuration.maxEnumerationDepth = 10
        let result = CorpusScanner(
            corpus: corpus,
            configuration: configuration,
            home: home,
            fileManager: fileManager
        ).scan()

        let kinds = Set(result.findings.map(\.kind))
        XCTAssertTrue(kinds.contains("malware-hash"))
        XCTAssertTrue(kinds.contains("malware-path"))
        XCTAssertTrue(kinds.contains("malware-launch-item"))
        XCTAssertTrue(kinds.contains("malware-chrome-extension"))
        XCTAssertTrue(result.findings.allSatisfy { $0.severity == .high })
    }

    func testScansExplicitFileTarget() throws {
        try createCorpus(payload: Data("payload".utf8), malwareID: 1)
        let file = home.appendingPathComponent("Library/Caches/explicit-target.bin")
        try Data("YARANEEDLE".utf8).write(to: file)
        try exec("""
        INSERT INTO MalwareRuleYara VALUES ('Y2', 'test', 1, 'macho', 'rule ExplicitYara { strings: $a = "YARANEEDLE" condition: $a }', '');
        """)

        let corpus = try PantherCorpus(path: corpusURL.path, home: home)
        let configuration = ScanConfiguration.protectedWithDirectories([file])
        let result = CorpusScanner(
            corpus: corpus,
            configuration: configuration,
            home: home,
            fileManager: fileManager,
            runYara: true,
            yaraCacheDirectory: home.appendingPathComponent("yara-cache")
        ).scan(extraPaths: [file])

        XCTAssertTrue(result.findings.contains { $0.kind == "malware-yara" })
    }

    func testSectionHashRuleMatchesMachO() throws {
        let system = URL(fileURLWithPath: "/usr/bin/true")
        guard fileManager.fileExists(atPath: system.path) else {
            throw XCTSkip("/usr/bin/true not available")
        }

        try createCorpus(payload: Data("payload".utf8), malwareID: 1)
        let bin = home.appendingPathComponent("bin")
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        let copy = bin.appendingPathComponent("true")
        try fileManager.copyItem(at: system, to: copy)

        let info = try XCTUnwrap(
            MachOAnalyzer.analyze(url: copy, sectionKeys: nil, needTeamID: false)
        )
        let section = try XCTUnwrap(
            info.sections.first { $0.section == "__text" } ?? info.sections.first
        )

        try exec("""
        INSERT INTO MalwareRuleSectionHash VALUES ('S1', 'test', 1);
        INSERT INTO MalwareRuleSectionHashData VALUES (1, 'S1', '\(section.segment)', '\(section.section)', \(section.size), '\(section.hash)');
        INSERT INTO ScanTargetPath VALUES ('T2', '\(bin.path)', 70, 2, 0, 0, 'test', '', '', '', 15, '');
        """)

        let corpus = try PantherCorpus(path: corpusURL.path, home: home)
        var configuration = ScanConfiguration.fast()
        configuration.maxEnumerationDepth = 3
        let result = CorpusScanner(
            corpus: corpus,
            configuration: configuration,
            home: home,
            fileManager: fileManager
        ).scan()

        XCTAssertTrue(result.findings.contains { $0.kind == "malware-section" })
    }

    func testCorpusYaraRuleMatch() throws {
        try createCorpus(payload: Data("payload".utf8), malwareID: 1)
        try Data("prefix YARANEEDLE suffix".utf8).write(
            to: home.appendingPathComponent("Library/Caches/yara\nneedle 数据.bin")
        )
        try exec("""
        INSERT INTO MalwareRuleYara VALUES ('Y1', 'test', 1, 'macho', 'rule TestYara { strings: $a = "YARANEEDLE" condition: $a }', '');
        """)

        let corpus = try PantherCorpus(path: corpusURL.path, home: home)
        var configuration = ScanConfiguration.fast()
        configuration.maxEnumerationDepth = 10
        let yaraCache = home.appendingPathComponent("yara-cache")
        let result = CorpusScanner(
            corpus: corpus,
            configuration: configuration,
            home: home,
            fileManager: fileManager,
            runYara: true,
            yaraCacheDirectory: yaraCache
        ).scan()

        XCTAssertTrue(result.findings.contains { $0.kind == "malware-yara" })
        XCTAssertNotNil(result.yara)
    }

    func testExclusionsSkipPathRules() throws {
        let payload = Data("payload".utf8)
        try createCorpus(payload: payload, malwareID: 1)

        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(corpusURL.path, &handle), SQLITE_OK)
        let evilDir = home.appendingPathComponent("Library/EvilDir").path
        XCTAssertEqual(
            sqlite3_exec(
                handle,
                "INSERT INTO ScanExclusionPath (ScanPathID, ExclusionPatterns) VALUES ('T1', '\(evilDir)');",
                nil, nil, nil
            ),
            SQLITE_OK
        )
        sqlite3_close(handle)

        let corpus = try PantherCorpus(path: corpusURL.path, home: home)
        let configuration = ScanConfiguration.fast()
        let result = CorpusScanner(
            corpus: corpus,
            configuration: configuration,
            home: home,
            fileManager: fileManager
        ).scan()

        XCTAssertFalse(result.findings.contains { $0.kind == "malware-path" })
        XCTAssertTrue(result.findings.contains { $0.kind == "malware-hash" })
    }
}
