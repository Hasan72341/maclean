import XCTest
@testable import MacLeanCore

final class BundledYaraTests: XCTestCase {
    private let fileManager = FileManager.default

    func testBundledBinariesExist() {
        XCTAssertNotNil(YaraEngine.binary(named: "yara"))
        XCTAssertNotNil(YaraEngine.binary(named: "maclean-yara"))
    }

    func testBundledRulesExist() throws {
        guard let rules = BundledRules.directory() else {
            throw XCTSkip("bundled signature-base rules not found")
        }
        let files = YaraScanner.ruleFiles(at: rules)
        XCTAssertGreaterThanOrEqual(files.count, 20)
        XCTAssertTrue(files.contains { $0.lastPathComponent == "gen_osx_evilosx.yar" })
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: rules.appendingPathComponent("LICENSE").path
            )
        )
    }

    func testHelperAppliesPerFileExternals() throws {
        guard let helper = YaraEngine.binary(named: "maclean-yara") else {
            throw XCTSkip("bundled maclean-yara not available")
        }

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("maclean-yara-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let rules = directory.appendingPathComponent("rules.yar")
        let file = directory.appendingPathComponent("needle-path/sample.needle")
        let list = directory.appendingPathComponent("files.list")

        try fileManager.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("before MAGICNEEDLE after".utf8).write(to: file)
        try Data("""
        rule NeedleContent {
          strings: $a = "MAGICNEEDLE"
          condition: $a
        }
        rule NeedlePath {
          condition: file_path matches /needle-path/
        }
        rule NeedleExtension {
          condition: file_extension == "needle"
        }
        rule NeedleFilename {
          condition: filename == "sample.needle"
        }
        rule NeedleFilepath {
          condition: filepath matches /needle-path/
        }
        rule NeedleFiletype {
          condition: filetype == "needle"
        }
        rule NeedleAlias {
          condition: extension == "needle"
        }
        """.utf8).write(to: rules)

        var listData = Data()
        listData.append(contentsOf: file.path.utf8)
        listData.append(0)
        try listData.write(to: list)

        let result = ProcessRunner.run(helper, [rules.path, list.path, "0"], timeout: 30)
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stdout.contains("NeedleContent"))
        XCTAssertTrue(result.stdout.contains("NeedlePath"))
        XCTAssertTrue(result.stdout.contains("NeedleExtension"))
        XCTAssertTrue(result.stdout.contains("NeedleFilename"))
        XCTAssertTrue(result.stdout.contains("NeedleFilepath"))
        XCTAssertTrue(result.stdout.contains("NeedleFiletype"))
        XCTAssertTrue(result.stdout.contains("NeedleAlias"))
    }
}
