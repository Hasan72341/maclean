import XCTest
@testable import MacLeanCore

final class QuarantineTests: XCTestCase {
    private let fileManager = FileManager.default
    private var home: URL!
    private var quarantineRoot: URL!

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("maclean-quarantine-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        home = base
        quarantineRoot = base.appendingPathComponent("Quarantine", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: home)
    }

    func testQuarantineMovesFileAndWritesMetadata() throws {
        let file = home.appendingPathComponent("Library/Caches/evil.bin")
        try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 64).write(to: file)

        let record = try QuarantineManager.quarantine(
            path: file.path,
            reason: "unit test",
            home: home,
            fileManager: fileManager,
            root: quarantineRoot
        )

        XCTAssertFalse(fileManager.fileExists(atPath: file.path))
        XCTAssertTrue(fileManager.fileExists(atPath: record.quarantinedPath))
        XCTAssertTrue(record.quarantinedPath.hasPrefix(quarantineRoot.path))
        XCTAssertTrue(record.originalPath.hasSuffix("evil.bin"))
        XCTAssertEqual(record.reason, "unit test")

        let records = QuarantineManager.records(
            fileManager: fileManager,
            root: quarantineRoot
        )
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].id, record.id)
    }

    func testQuarantineRejectsOutsideHome() {
        XCTAssertThrowsError(
            try QuarantineManager.quarantine(
                path: "/etc/hosts",
                reason: "unit test",
                home: home,
                fileManager: fileManager,
                root: quarantineRoot
            )
        )
        XCTAssertTrue(fileManager.fileExists(atPath: "/etc/hosts"))
    }
}
