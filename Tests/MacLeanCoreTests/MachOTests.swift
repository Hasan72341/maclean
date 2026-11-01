import XCTest
@testable import MacLeanCore

final class MachOAnalyzerTests: XCTestCase {
    private let fileManager = FileManager.default

    func testParsesUniversalSystemBinary() throws {
        let url = URL(fileURLWithPath: "/usr/bin/true")
        guard fileManager.fileExists(atPath: url.path) else {
            throw XCTSkip("/usr/bin/true not available")
        }

        let info = try XCTUnwrap(
            MachOAnalyzer.analyze(url: url, sectionKeys: nil, needTeamID: true)
        )

        XCTAssertTrue(info.isMachO)
        XCTAssertGreaterThan(info.sliceCount, 0)
        XCTAssertTrue(
            info.sections.contains { $0.segment == "__TEXT" && $0.section == "__text" },
            "expected a __TEXT,__text section"
        )
        XCTAssertTrue(info.sections.allSatisfy { $0.hash.count == 64 })
    }

    func testParsesTeamIdentifierFromSignedApplication() throws {
        let url = URL(
            fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        )
        guard fileManager.fileExists(atPath: url.path) else {
            throw XCTSkip("Google Chrome not installed")
        }

        let info = try XCTUnwrap(
            MachOAnalyzer.analyze(url: url, sectionKeys: [], needTeamID: true)
        )
        XCTAssertNotNil(info.teamID)
    }

    func testNonMachOFileReturnsNil() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macho-test-\(UUID().uuidString).txt")
        try Data("not a mach-o".utf8).write(to: url)
        defer { try? fileManager.removeItem(at: url) }

        XCTAssertNil(MachOAnalyzer.analyze(url: url, sectionKeys: nil, needTeamID: true))
    }
}
