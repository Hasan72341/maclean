import XCTest
@testable import MacLeanCore

final class ProtectionConfigTests: XCTestCase {
    func testFastProfileMatchesReference() {
        let configuration = ScanConfiguration.fast()
        XCTAssertEqual(configuration.scanMode, .fast)
        XCTAssertEqual(configuration.scanOption.rawValue, 0x7)
        XCTAssertEqual(configuration.cloudFilesProcessMode, 0)
        XCTAssertTrue(configuration.isDMGScanEnabled)
        XCTAssertFalse(configuration.isPKGScanEnabled)
        XCTAssertFalse(configuration.isArchiveScanEnabled)
        XCTAssertEqual(configuration.maxEnumerationDepth, 2)
        XCTAssertFalse(configuration.extendedRulesUsageEnabled)
    }

    func testDefaultAndSmartProfilesMatchReference() {
        for configuration in [ScanConfiguration.standard(), ScanConfiguration.smart()] {
            XCTAssertEqual(configuration.scanOption.rawValue, 0x1EF)
            XCTAssertTrue(configuration.isDMGScanEnabled)
            XCTAssertTrue(configuration.isPKGScanEnabled)
            XCTAssertFalse(configuration.isArchiveScanEnabled)
            XCTAssertEqual(configuration.maxEnumerationDepth, 3)
            XCTAssertFalse(configuration.extendedRulesUsageEnabled)
        }
        XCTAssertEqual(ScanConfiguration.standard().scanMode, .standard)
        XCTAssertEqual(ScanConfiguration.smart().scanMode, .smart)
    }

    func testProtectedProfileMatchesReference() {
        let configuration = ScanConfiguration.protectedScan()
        XCTAssertEqual(configuration.scanMode, .protected)
        XCTAssertEqual(configuration.scanOption.rawValue, 0x1FFF)
        XCTAssertTrue(configuration.isDMGScanEnabled)
        XCTAssertTrue(configuration.isPKGScanEnabled)
        XCTAssertTrue(configuration.isArchiveScanEnabled)
        XCTAssertEqual(configuration.maxEnumerationDepth, 5)
        XCTAssertFalse(configuration.extendedRulesUsageEnabled)
    }

    func testProtectedWithDirectoriesMatchesReference() {
        let urls = [URL(fileURLWithPath: "/tmp/a"), URL(fileURLWithPath: "/tmp/b")]
        let configuration = ScanConfiguration.protectedWithDirectories(urls)
        XCTAssertEqual(configuration.scanMode, .protected)
        XCTAssertEqual(configuration.scanOption.rawValue, 0x4)
        XCTAssertEqual(configuration.diskScanURLs, urls.map(\.path))
        XCTAssertEqual(configuration.maxEnumerationDepth, 5)
        XCTAssertEqual(configuration.maxArchiveCompressionRatio, 1000)
        XCTAssertEqual(configuration.maxArchiveExtractedFilesCount, 30_000)
        XCTAssertEqual(configuration.maxArchiveNestingDepth, 10)
    }

    func testParanoidProfileMatchesReference() {
        let configuration = ScanConfiguration.paranoid()
        XCTAssertEqual(configuration.scanMode, .paranoid)
        XCTAssertEqual(configuration.scanOption.rawValue, 0x1FFF)
        XCTAssertEqual(configuration.maxArchiveNestingDepth, 20)
        XCTAssertEqual(configuration.maxArchiveFileSize, 512 * 1024 * 1024)
        XCTAssertEqual(configuration.maxEnumerationDepth, -1)
        XCTAssertEqual(configuration.maxPackageEnumerationDepth, -1)
        XCTAssertEqual(configuration.enumerationSpecialMode, 1)
        XCTAssertTrue(configuration.extendedRulesUsageEnabled)
        XCTAssertTrue(configuration.isLicensedDmgSupportEnabled)
    }

    func testPrivilegedAuthorizationGate() {
        XCTAssertFalse(ScanMode.fast.canAskPrivilegedAgentAuthorizationOnScan)
        XCTAssertTrue(ScanMode.standard.canAskPrivilegedAgentAuthorizationOnScan)
        XCTAssertTrue(ScanMode.protected.canAskPrivilegedAgentAuthorizationOnScan)
        XCTAssertTrue(ScanMode.paranoid.canAskPrivilegedAgentAuthorizationOnScan)
        XCTAssertFalse(ScanMode.smart.canAskPrivilegedAgentAuthorizationOnScan)
    }

    func testOptionBitsMatchReference() {
        XCTAssertEqual(ScanOption.launchItems.rawValue, 0x0001)
        XCTAssertEqual(ScanOption.predefinedPaths.rawValue, 0x0002)
        XCTAssertEqual(ScanOption.diskURLs.rawValue, 0x0004)
        XCTAssertEqual(ScanOption.safariExtensions.rawValue, 0x0008)
        XCTAssertEqual(ScanOption.securityIssues.rawValue, 0x0010)
        XCTAssertEqual(ScanOption.cronJobs.rawValue, 0x0020)
        XCTAssertEqual(ScanOption.configurationProfiles.rawValue, 0x0040)
        XCTAssertEqual(ScanOption.runningProcesses.rawValue, 0x0080)
        XCTAssertEqual(ScanOption.safariHomepage.rawValue, 0x0100)
        XCTAssertEqual(ScanOption.privilegedURLs.rawValue, 0x0200)
        XCTAssertEqual(ScanOption.externalDrives.rawValue, 0x0400)
        XCTAssertEqual(ScanOption.mailAttachments.rawValue, 0x0800)
        XCTAssertEqual(ScanOption.chromeExtensions.rawValue, 0x1000)
        XCTAssertEqual(ScanOption.all.rawValue, 0x1FFF)
    }

    func testConfigurationCodableRoundTrip() throws {
        let configuration = ScanConfiguration.paranoid()
        let data = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(ScanConfiguration.self, from: data)
        XCTAssertEqual(decoded.scanMode, configuration.scanMode)
        XCTAssertEqual(decoded.scanOption, configuration.scanOption)
        XCTAssertEqual(decoded.maxEnumerationDepth, configuration.maxEnumerationDepth)
        XCTAssertEqual(decoded.maxArchiveNestingDepth, configuration.maxArchiveNestingDepth)
    }
}

final class ProtectionScannerTests: XCTestCase {
    private let fileManager = FileManager.default
    private var home: URL!

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("maclean-protection-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        home = base.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: home)
    }

    private func configuration(_ options: ScanOption) -> ScanConfiguration {
        var configuration = ScanConfiguration()
        configuration.scanOption = options
        return configuration
    }

    func testLaunchItemWithMissingProgram() throws {
        let url = home.appendingPathComponent("Library/LaunchAgents/com.example.missing.plist")
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "Label": "com.example.missing",
            "Program": "/Applications/DefinitelyMissing.app/Contents/MacOS/DefinitelyMissing",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url)

        let report = ProtectionScanner(
            configuration: configuration([.launchItems]),
            home: home,
            fileManager: fileManager
        ).scan()

        let finding = try XCTUnwrap(report.findings.first { $0.kind == "launch-item" && $0.path.hasSuffix("com.example.missing.plist") })
        XCTAssertEqual(finding.severity, .medium)
        XCTAssertTrue(finding.title.contains("missing program"))
    }

    func testSafariExtensionFinding() throws {
        let url = home.appendingPathComponent("Library/Safari/Extensions/example.safariextz")
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 32).write(to: url)

        let report = ProtectionScanner(
            configuration: configuration([.safariExtensions]),
            home: home,
            fileManager: fileManager
        ).scan()

        XCTAssertTrue(report.findings.contains { $0.kind == "safari-extension" && $0.path.hasSuffix("example.safariextz") })
    }

    func testChromeExtensionFinding() throws {
        let manifest = home.appendingPathComponent(
            "Library/Application Support/Google/Chrome/Default/Extensions/abc/1.0/manifest.json"
        )
        try fileManager.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json: [String: Any] = [
            "name": "Bad Extension",
            "version": "1.0",
            "permissions": ["nativeMessaging"],
        ]
        try JSONSerialization.data(withJSONObject: json).write(to: manifest)

        let report = ProtectionScanner(
            configuration: configuration([.chromeExtensions]),
            home: home,
            fileManager: fileManager
        ).scan()

        let finding = try XCTUnwrap(report.findings.first { $0.kind == "chrome-extension" })
        XCTAssertTrue(finding.title.contains("Bad Extension"))
        XCTAssertEqual(finding.severity, .medium)
        XCTAssertTrue(finding.detail.contains("nativeMessaging"))
    }

    func testDangerousMailAttachmentFinding() throws {
        let attachment = home.appendingPathComponent("Library/Mail/V10/ACCOUNT/MailData/Attachments/evil.command")
        try fileManager.createDirectory(at: attachment.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 2, count: 64).write(to: attachment)

        let report = ProtectionScanner(
            configuration: configuration([.mailAttachments]),
            home: home,
            fileManager: fileManager
        ).scan()

        XCTAssertTrue(report.findings.contains { $0.kind == "mail-attachment" && $0.path.hasSuffix("evil.command") })
    }

    func testEmptyOptionSetProducesNoFindings() {
        var configuration = ScanConfiguration()
        configuration.scanOption = []
        let report = ProtectionScanner(
            configuration: configuration,
            home: home,
            fileManager: fileManager
        ).scan()

        XCTAssertTrue(report.findings.isEmpty)
        XCTAssertEqual(report.scannedFiles, 0)
    }
}

final class YaraScannerTests: XCTestCase {
    func testMissingRulesFileIsReported() {
        let rules = URL(fileURLWithPath: "/nonexistent/rules.yar")
        let result = YaraScanner.run(
            rules: rules,
            paths: [URL(fileURLWithPath: "/tmp")],
            maxFileSize: 1024
        )
        XCTAssertTrue(result.findings.isEmpty)
        XCTAssertEqual(result.summary.matches, 0)
        XCTAssertNotNil(result.summary.note)
    }

    func testRuleDirectoryEnumeration() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("maclean-yara-\(UUID().uuidString)", isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        try Data("rule a {}".utf8).write(to: directory.appendingPathComponent("a.yar"))
        try Data("rule b {}".utf8).write(to: directory.appendingPathComponent("b.yara"))
        try Data("not a rule".utf8).write(to: directory.appendingPathComponent("c.txt"))

        let rules = YaraScanner.ruleFiles(at: directory, fileManager: fileManager)
        XCTAssertEqual(rules.map(\.lastPathComponent), ["a.yar", "b.yara"])
    }

    func testMatchLineRetainsMetadata() {
        let match = YaraScanner.parseMatchLine(
            #"OsxRule [author="Florian Roth",description="tests"] /tmp/sample.bin"#
        )
        XCTAssertEqual(match?.rule, "OsxRule")
        XCTAssertEqual(match?.path, "/tmp/sample.bin")
        XCTAssertTrue(match?.metadata.contains("author=") == true)
    }

    func testPerFileAliasesAreApplied() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("maclean-yara-alias-\(UUID().uuidString)", isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let rules = directory.appendingPathComponent("rules.yar")
        let sample = directory.appendingPathComponent("sample.needle")
        try Data("""
        rule AliasName {
          condition: filename == "sample.needle"
        }
        rule AliasPath {
          condition: filepath matches /sample.needle/
        }
        rule AliasType {
          condition: filetype == "needle" and extension == "needle"
        }
        """.utf8).write(to: rules)
        try Data("sample".utf8).write(to: sample)

        let result = YaraScanner.run(
            rules: rules,
            paths: [directory],
            maxFileSize: 1_000_000,
            fileManager: fileManager
        )
        XCTAssertTrue(result.findings.contains { $0.title.contains("AliasName") })
        XCTAssertTrue(result.findings.contains { $0.title.contains("AliasPath") })
        XCTAssertTrue(result.findings.contains { $0.title.contains("AliasType") })
    }
}

final class ClamAVScannerTests: XCTestCase {
    func testParsesDetectionLines() {
        let output = """
        /tmp/evil.bin: Osx.Trojan.Test FOUND
        /tmp/clean.bin: OK
        /tmp/other.bin: Unix.Malware.Example-1 FOUND
        """

        let findings = ClamAVScanner.parse(output: output, engine: "/usr/bin/clamscan")

        XCTAssertEqual(findings.count, 2)
        XCTAssertEqual(findings[0].path, "/tmp/evil.bin")
        XCTAssertTrue(findings[0].title.contains("Osx.Trojan.Test"))
        XCTAssertEqual(findings[0].severity, .high)
        XCTAssertEqual(findings[1].path, "/tmp/other.bin")
    }

    func testNoPathsProducesNote() {
        let result = ClamAVScanner.run(paths: [])
        XCTAssertTrue(result.findings.isEmpty)
        XCTAssertNotNil(result.summary.note)
    }
}
