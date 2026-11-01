import XCTest
@testable import MacLeanCore

final class RuleBookTests: XCTestCase {
    private let fm = FileManager.default
    private var home: URL!
    private var book: RuleBook!

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("maclean-rulebook-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        home = base.resolvingSymlinksInPath()
        book = RuleBook(url: home.appendingPathComponent("rules.json"))
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: home)
    }

    private func write(_ relative: String, bytes: Int) throws {
        let url = home.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    func testEmptyBookMatchesBundledRules() {
        XCTAssertEqual(book.activeRules().map(\.id), Rules.bundled.map(\.id))
        XCTAssertTrue(book.resolvedRules().allSatisfy { $0.origin == .bundled })
    }

    func testDisablingRemovesRuleFromActiveSet() throws {
        try book.setEnabled(false, for: "user-caches")
        XCTAssertFalse(book.activeRules().contains { $0.id == "user-caches" })
        XCTAssertTrue(book.resolvedRules().contains { $0.id == "user-caches" })
        try book.setEnabled(true, for: "user-caches")
        XCTAssertTrue(book.activeRules().contains { $0.id == "user-caches" })
        XCTAssertNil(book.override(for: "user-caches"))
    }

    func testOverrideAppliesAndPersists() throws {
        try book.setOverride(RuleOverride(title: "My caches", risk: .caution, autoselect: false, excludes: ["Keep*"]), for: "user-caches")
        let reopened = RuleBook(url: book.url)
        let rule = try XCTUnwrap(reopened.resolvedRules().first { $0.id == "user-caches" })
        XCTAssertEqual(rule.title, "My caches")
        XCTAssertEqual(rule.risk, .caution)
        XCTAssertFalse(rule.autoselect)
        XCTAssertEqual(rule.excludes, ["Keep*"])
        XCTAssertEqual(rule.origin, .edited)
        XCTAssertTrue(rule.isExcluded("KeepMe"))
    }

    func testOverrideCannotMakeReportOnlyRuleAutoselect() throws {
        let reportOnly = try XCTUnwrap(Rules.bundled.first { $0.scanOnly })
        try book.setOverride(RuleOverride(autoselect: true), for: reportOnly.id)
        let rule = try XCTUnwrap(book.resolvedRules().first { $0.id == reportOnly.id })
        XCTAssertEqual(rule.autoselect, reportOnly.autoselect)
        XCTAssertTrue(rule.scanOnly)
    }

    func testCustomRuleValidation() {
        func check(_ path: String, _ mode: CustomRuleMode = .contents) -> Bool {
            (try? RuleBook.validate(CustomRule(title: "t", relativePath: path, mode: mode), home: home)) != nil
        }
        XCTAssertTrue(check("~/Library/Caches/com.example.app"))
        XCTAssertTrue(check("Library/Caches/com.example.app", .whole))
        XCTAssertTrue(check("~/.npm"))
        XCTAssertTrue(check("~/Downloads", .largeFiles))
        XCTAssertFalse(check("~"))
        XCTAssertFalse(check("~/Documents"))
        XCTAssertFalse(check("~/Library/Caches"))
        XCTAssertFalse(check("~/Library/Keychains/x"))
        XCTAssertFalse(check("~/Library/Mail/V10"))
        XCTAssertFalse(check("~/.ssh"))
        XCTAssertFalse(check("/etc/hosts"))
        XCTAssertFalse(check("~/../other"))
        XCTAssertFalse(check("~/Projects"))
        XCTAssertFalse(check("~/Library/Caches/x", .contents) && !check("~/Library/Caches/x", .whole))
        XCTAssertThrowsError(try RuleBook.validate(CustomRule(title: " ", relativePath: "~/Library/Caches/x"), home: home))
    }

    func testCustomRuleScansThroughEngine() throws {
        try write("Library/Caches/com.example.tool/a.bin", bytes: 4096)
        try write("Library/Caches/com.example.tool/keep.bin", bytes: 4096)
        var custom = CustomRule(title: "Example tool", relativePath: "~/Library/Caches/com.example.tool", mode: .contents, excludes: ["keep*"], risk: .safe, autoselect: true)
        try book.upsert(custom, home: home)
        custom = try XCTUnwrap(book.customRules.first)
        XCTAssertEqual(custom.relativePath, "Library/Caches/com.example.tool")

        let rule = try XCTUnwrap(book.activeRules().first { $0.id == custom.id })
        XCTAssertEqual(rule.origin, .custom)
        XCTAssertFalse(rule.requiresRoot)

        final class Events: @unchecked Sendable {
            var list: [ScanEvent] = []
            let lock = NSLock()
        }
        let events = Events()
        let report = JunkScanner(home: home, includeSystemPaths: false).scan(rules: [rule], observer: { event in
            events.lock.lock(); events.list.append(event); events.lock.unlock()
        })
        XCTAssertEqual(report.items.map { ($0.path as NSString).lastPathComponent }, ["a.bin"])
        XCTAssertTrue(events.list.contains { if case .ruleStarted = $0 { return true }; return false })
        XCTAssertTrue(events.list.contains { if case .entrySkipped(_, _, .excluded) = $0 { return true }; return false })
        XCTAssertTrue(events.list.contains { if case .itemFound = $0 { return true }; return false })
        XCTAssertTrue(events.list.contains { if case .ruleFinished(_, _, 1, _, _, 2, _) = $0 { return true }; return false })
    }

    func testCancelStopsScan() {
        let report = JunkScanner(home: home, includeSystemPaths: false).scan(rules: Rules.bundled, observer: nil, isCancelled: { true })
        XCTAssertTrue(report.items.isEmpty)
    }

    func testImportRejectsUnsafeCustomRule() throws {
        var file = RuleBook.File()
        file.custom = [CustomRule(title: "bad", relativePath: "~/Documents")]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        XCTAssertThrowsError(try book.importData(encoder.encode(file), home: home))
        XCTAssertTrue(book.customRules.isEmpty)
    }

    func testDeleteAndReset() throws {
        try book.upsert(CustomRule(title: "x", relativePath: "~/Library/Caches/x"), home: home)
        try book.setEnabled(false, for: "user-caches")
        XCTAssertEqual(book.customRules.count, 1)
        try book.deleteCustom(id: book.customRules[0].id)
        XCTAssertTrue(book.customRules.isEmpty)
        try book.resetAll()
        XCTAssertEqual(book.snapshot, RuleBook.File())
    }
}
