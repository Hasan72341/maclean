import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MacLeanCore

final class JunkScannerTests: XCTestCase {
    private let fileManager = FileManager.default
    private var home: URL!

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("maclean-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        home = base.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: home)
    }

    @discardableResult
    private func write(_ relative: String, bytes: Int) throws -> URL {
        let url = home.appendingPathComponent(relative)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    func testScanMeasuresCacheDirectories() throws {
        try write("Library/Caches/com.example.app/blob.bin", bytes: 100)
        try write("Library/Caches/com.example.app/nested/more.bin", bytes: 50)

        let report = JunkScanner(home: home, includeSystemPaths: false).scan(categories: [.system])

        XCTAssertEqual(report.items.count, 1)
        let item = try XCTUnwrap(report.items.first)
        XCTAssertEqual(item.ruleID, "user-caches")
        XCTAssertEqual(item.category, .system)
        XCTAssertEqual(item.files, 2)
        XCTAssertGreaterThanOrEqual(item.bytes, 150)
        XCTAssertTrue(item.autoselect)
        XCTAssertTrue(item.path.hasSuffix("Library/Caches/com.example.app"))
    }

    func testBrowserCachesAreSeparateFromUserCaches() throws {
        try write("Library/Caches/Google/Chrome/Default/Cache/data.bin", bytes: 200)

        let system = JunkScanner(home: home, includeSystemPaths: false).scan(categories: [.system])
        XCTAssertTrue(system.items.isEmpty)

        let browser = JunkScanner(home: home, includeSystemPaths: false).scan(categories: [.browser])
        XCTAssertEqual(browser.items.count, 1)
        XCTAssertEqual(browser.items.first?.ruleID, "chrome-cache")
    }

    func testSymlinksAreSkipped() throws {
        let outside = home.appendingPathComponent("outside")
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: outside.appendingPathComponent("big.bin"))

        let link = home.appendingPathComponent("Library/Caches/com.example.app")
        try fileManager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: link, withDestinationURL: outside)

        let report = JunkScanner(home: home, includeSystemPaths: false).scan(categories: [.system])
        XCTAssertTrue(report.items.isEmpty)
    }

    func testUserTrashIsScanned() throws {
        try write(".Trash/old.bin", bytes: 300)

        let report = JunkScanner(home: home, includeSystemPaths: false).scan(categories: [.trash])

        XCTAssertEqual(report.items.count, 1)
        XCTAssertEqual(report.items.first?.ruleID, "user-trash")
    }

    func testLargeFilesThreshold() throws {
        try write("Downloads/big.bin", bytes: 2 * 1024 * 1024)
        try write("Downloads/small.bin", bytes: 1024)

        let scanner = JunkScanner(
            home: home,
            includeSystemPaths: false,
            largeFileThreshold: 1024 * 1024
        )
        let report = scanner.scan(categories: [.large])

        XCTAssertEqual(report.items.count, 1)
        XCTAssertEqual(report.items.first?.ruleID, "large-downloads")
        XCTAssertTrue(try XCTUnwrap(report.items.first).path.hasSuffix("big.bin"))
    }

    func testMinSizeFiltersItems() throws {
        try write("Library/Caches/small.app/a.bin", bytes: 100)

        let report = JunkScanner(home: home, includeSystemPaths: false)
            .scan(categories: [.system], minBytes: 10 * 1024 * 1024)

        XCTAssertTrue(report.items.isEmpty)
    }

    func testScansSandboxContainerCaches() throws {
        try write(
            "Library/Containers/com.example.app/Data/Library/Caches/com.example.cache/blob.bin",
            bytes: 128
        )

        let report = JunkScanner(home: home, includeSystemPaths: false).scan(categories: [.system])
        let item = try XCTUnwrap(report.items.first { $0.ruleID == "sandbox-container-caches" })

        XCTAssertTrue(item.path.hasSuffix("Caches/com.example.cache"))
        XCTAssertEqual(item.category, .system)
    }

    func testUnreadableDirectoryIsSkipped() throws {
        let directory = home.appendingPathComponent("Library/Caches/locked.app")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 128).write(to: directory.appendingPathComponent("blob.bin"))
        try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.path)
        defer {
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        }

        let report = JunkScanner(home: home, includeSystemPaths: false).scan(categories: [.system])

        XCTAssertFalse(report.items.contains { $0.path.hasSuffix("locked.app") })
    }
}

final class CleanerTests: XCTestCase {
    private let fileManager = FileManager.default
    private var home: URL!

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("maclean-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        home = base.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: home)
    }

    @discardableResult
    private func write(_ relative: String, bytes: Int) throws -> URL {
        let url = home.appendingPathComponent(relative)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    private func item(ruleID: String) -> JunkItem {
        let rule = Rules.rule(id: ruleID)!
        return JunkItem(
            path: "/tmp/unused",
            bytes: 1,
            files: 1,
            ruleID: rule.id,
            ruleTitle: rule.title,
            category: rule.category,
            risk: rule.risk,
            autoselect: rule.autoselect,
            requiresRoot: rule.requiresRoot,
            isDirectory: false,
            modified: nil
        )
    }

    func testDryRunDoesNotDeleteAnything() throws {
        try write("Library/Caches/com.example.app/blob.bin", bytes: 100)
        let report = JunkScanner(home: home, includeSystemPaths: false).scan(categories: [.system])
        let target = try XCTUnwrap(report.items.first)

        let result = Cleaner(home: home, includeSystemPaths: false).clean(
            report.items,
            options: CleanOptions(apply: false, permanent: true)
        )

        XCTAssertEqual(result.planned.count, 1)
        XCTAssertTrue(result.deleted.isEmpty)
        XCTAssertTrue(fileManager.fileExists(atPath: target.path))
    }

    func testPermanentDeleteRemovesItem() throws {
        try write("Library/Caches/com.example.app/blob.bin", bytes: 100)
        let report = JunkScanner(home: home, includeSystemPaths: false).scan(categories: [.system])
        let target = try XCTUnwrap(report.items.first)

        let result = Cleaner(home: home, includeSystemPaths: false).clean(
            report.items,
            options: CleanOptions(apply: true, permanent: true)
        )

        XCTAssertEqual(result.deleted.count, 1)
        XCTAssertFalse(fileManager.fileExists(atPath: target.path))
    }

    func testCleanerRefusesPathsOutsideRuleRoots() throws {
        let rule = Rules.rule(id: "user-caches")!
        let dangerous = JunkItem(
            path: "/etc/hosts",
            bytes: 1,
            files: 1,
            ruleID: rule.id,
            ruleTitle: rule.title,
            category: rule.category,
            risk: rule.risk,
            autoselect: true,
            requiresRoot: false,
            isDirectory: false,
            modified: nil
        )

        let result = Cleaner(home: home, includeSystemPaths: false).clean(
            [dangerous],
            options: CleanOptions(apply: true, permanent: true)
        )

        XCTAssertEqual(result.skipped.count, 1)
        XCTAssertTrue(result.deleted.isEmpty)
        XCTAssertTrue(result.failed.isEmpty)
    }

    func testWholeDirectoryRulesCanDeleteTheRoot() throws {
        let cache = home.appendingPathComponent(".npm/_cacache")
        try fileManager.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data(repeating: 3, count: 256).write(to: cache.appendingPathComponent("index.bin"))

        let report = JunkScanner(home: home, includeSystemPaths: false).scan(categories: [.dev])
        XCTAssertEqual(report.items.count, 1)
        XCTAssertEqual(report.items.first?.ruleID, "npm-cache")

        let result = Cleaner(home: home, includeSystemPaths: false).clean(
            report.items,
            options: CleanOptions(apply: true, permanent: true)
        )

        XCTAssertEqual(result.deleted.count, 1)
        XCTAssertTrue(result.skipped.isEmpty)
        XCTAssertFalse(fileManager.fileExists(atPath: cache.path))
    }

    func testCleanerRefusesChangedIdentity() throws {
        let directory = home.appendingPathComponent("Library/Caches/com.example.app")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 100).write(to: directory.appendingPathComponent("old.bin"))

        let report = JunkScanner(home: home, includeSystemPaths: false).scan(categories: [.system])
        let item = try XCTUnwrap(report.items.first { $0.path.hasSuffix("com.example.app") })

        let backup = directory.deletingLastPathComponent().appendingPathComponent("com.example.backup")
        try fileManager.moveItem(at: directory, to: backup)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 100).write(to: directory.appendingPathComponent("new.bin"))

        let result = Cleaner(home: home, includeSystemPaths: false).clean(
            [item],
            options: CleanOptions(apply: true, permanent: true)
        )

        XCTAssertEqual(result.skipped.count, 1)
        XCTAssertTrue(result.deleted.isEmpty)
        XCTAssertTrue(result.skipped[0].reason.contains("changed"))
        XCTAssertTrue(fileManager.fileExists(atPath: directory.appendingPathComponent("new.bin").path))
    }

    func testUnicodeAndNewlinePathCleanup() throws {
        let directory = home.appendingPathComponent("Library/Caches/应用 数据/line\nbreak")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 4096).write(to: directory.appendingPathComponent("café 文件.bin"))

        let report = JunkScanner(home: home, includeSystemPaths: false).scan(categories: [.system])
        let item = try XCTUnwrap(report.items.first { $0.path.contains("应用 数据") })
        let result = Cleaner(home: home, includeSystemPaths: false).clean(
            [item],
            options: CleanOptions(apply: true, permanent: true)
        )

        XCTAssertEqual(result.deleted.count, 1)
        XCTAssertFalse(fileManager.fileExists(atPath: directory.path))
    }

    func testPermissionDeniedCleanupFailsSafely() throws {
        let directory = home.appendingPathComponent("Library/Caches/locked.app")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 4096).write(to: directory.appendingPathComponent("blob.bin"))

        let report = JunkScanner(home: home, includeSystemPaths: false).scan(categories: [.system])
        let item = try XCTUnwrap(report.items.first { $0.path.hasSuffix("locked.app") })

        try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.path)
        defer {
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        }

        let result = Cleaner(home: home, includeSystemPaths: false).clean(
            [item],
            options: CleanOptions(apply: true, permanent: true)
        )

        XCTAssertEqual(result.failed.count + result.skipped.count, 1)
        XCTAssertTrue(fileManager.fileExists(atPath: directory.path))
    }

    func testTrashContentsAreDeletedPermanentlyInTrashMode() throws {
        let file = try write(".Trash/old.bin", bytes: 10)
        let report = JunkScanner(home: home, includeSystemPaths: false).scan(categories: [.trash])

        let result = Cleaner(home: home, includeSystemPaths: false).clean(
            report.items,
            options: CleanOptions(apply: true, permanent: false)
        )

        XCTAssertEqual(result.deleted.count, 1)
        XCTAssertTrue(result.movedToTrash.isEmpty)
        XCTAssertFalse(fileManager.fileExists(atPath: file.path))
    }

    func testSelectionHonorsAutoselectCautionAndScanOnly() {
        let report = ScanReport(items: [
            item(ruleID: "user-caches"),
            item(ruleID: "xcode-archives"),
            item(ruleID: "large-downloads"),
        ])

        let conservative = CleanOptions().select(from: report)
        XCTAssertEqual(conservative.map(\.ruleID), ["user-caches"])

        let caution = CleanOptions(includeCaution: true).select(from: report)
        XCTAssertEqual(caution.map(\.ruleID), ["user-caches", "xcode-archives"])

        let large = CleanOptions(includeCaution: true, categories: [.large]).select(from: report)
        XCTAssertEqual(large.map(\.ruleID), ["large-downloads"])
    }
}

final class FileSizerTests: XCTestCase {
    private let fileManager = FileManager.default
    private var home: URL!

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("maclean-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        home = base.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: home)
    }

    func testCountsNestedFiles() throws {
        let root = home.appendingPathComponent("dir")
        try fileManager.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try Data(repeating: 0, count: 64).write(to: root.appendingPathComponent("a.bin"))
        try Data(repeating: 0, count: 32).write(to: root.appendingPathComponent("nested/b.bin"))

        let size = FileSizer.measure(root, fileManager: fileManager)

        XCTAssertTrue(size.isDirectory)
        XCTAssertEqual(size.files, 2)
        XCTAssertGreaterThanOrEqual(size.bytes, 96)
    }

    func testDetectsSymbolicLinks() throws {
        let target = home.appendingPathComponent("target")
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        let link = home.appendingPathComponent("link")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: target)

        let size = FileSizer.measure(link, fileManager: fileManager)

        XCTAssertTrue(size.isSymbolicLink)
        XCTAssertEqual(size.bytes, 0)
    }

    func testHardLinksAreCountedOnce() throws {
        let directory = home.appendingPathComponent("hardlinks")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = directory.appendingPathComponent("original.bin")
        let link = directory.appendingPathComponent("link.bin")
        try Data(repeating: 0x41, count: 1024 * 1024).write(to: original)
        try fileManager.linkItem(at: original, to: link)

        let size = FileSizer.measure(directory, fileManager: fileManager)

        XCTAssertEqual(size.files, 2)
        XCTAssertLessThan(size.bytes, 1_500_000, "hard-linked data must not be counted twice")
    }

    func testUnicodeAndNewlinePaths() throws {
        let directory = home.appendingPathComponent("Unicode 数据/line\nbreak")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("café 文件.bin")
        try Data(repeating: 0x41, count: 128).write(to: file)

        let size = FileSizer.measure(directory, fileManager: fileManager)
        XCTAssertEqual(size.files, 1)
        XCTAssertGreaterThan(size.bytes, 0)
    }
}

final class AppCatalogTests: XCTestCase {
    private let fileManager = FileManager.default
    private var home: URL!

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("maclean-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        home = base.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: home)
    }

    func testReadsBundleMetadata() throws {
        let apps = home.appendingPathComponent("Applications")
        let bundle = apps.appendingPathComponent("Sample.app")
        let contents = bundle.appendingPathComponent("Contents")
        try fileManager.createDirectory(at: contents, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.example.sample",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleName": "Sample",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        try Data(repeating: 7, count: 128).write(to: bundle.appendingPathComponent("binary"))

        let listed = AppCatalog.list(directories: [apps], fileManager: fileManager)

        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].bundleID, "com.example.sample")
        XCTAssertEqual(listed[0].version, "1.2.3")
        XCTAssertEqual(listed[0].name, "Sample")
        XCTAssertGreaterThan(listed[0].bytes, 0)
    }
}

final class RulesTests: XCTestCase {
    func testRuleIdentifiersAreUnique() {
        let ids = Rules.bundled.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testEveryJunkCategoryHasRules() {
        for category in JunkCategory.allCases {
            XCTAssertTrue(Rules.bundled.contains { $0.category == category }, "missing rules for \(category)")
        }
    }
}

final class ArtifactTests: XCTestCase {
    private let fileManager = FileManager.default
    private var home: URL!

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("maclean-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        home = base.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: home)
    }

    @discardableResult
    private func write(_ relative: String, bytes: Int) throws -> URL {
        let url = home.appendingPathComponent(relative)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: bytes).write(to: url)
        return url
    }

    func testArtifactCleanerDeletesInsideAllowedRoot() throws {
        let file = try write("Library/Caches/com.example.app/blob.bin", bytes: 100)
        let artifact = try XCTUnwrap(ArtifactBuilder.make(
            path: file.path,
            allowedRoot: file.deletingLastPathComponent().path,
            group: "Cache",
            risk: .caution,
            autoselect: true,
            fileManager: fileManager
        ))

        let result = ArtifactCleaner(home: home, fileManager: fileManager).clean(
            [artifact],
            apply: true,
            permanent: true,
            includeCaution: true
        )

        XCTAssertEqual(result.deleted.count, 1)
        XCTAssertFalse(fileManager.fileExists(atPath: file.path))
    }

    func testCautionItemsRequireOptIn() throws {
        let file = try write("Library/Safari/History.db", bytes: 100)
        let artifact = try XCTUnwrap(ArtifactBuilder.make(
            path: file.path,
            allowedRoot: file.deletingLastPathComponent().path,
            group: "Browsing history",
            risk: .caution,
            autoselect: false,
            fileManager: fileManager
        ))

        let conservative = ArtifactCleaner(home: home, fileManager: fileManager).clean(
            [artifact], apply: true, permanent: true, includeCaution: false
        )
        XCTAssertTrue(conservative.planned.isEmpty)
        XCTAssertTrue(fileManager.fileExists(atPath: file.path))

        let optedIn = ArtifactCleaner(home: home, fileManager: fileManager).clean(
            [artifact], apply: true, permanent: true, includeCaution: true
        )
        XCTAssertEqual(optedIn.deleted.count, 1)
    }

    func testArtifactCleanerRejectsForbiddenRoot() {
        let artifact = Artifact(
            path: "/etc/hosts",
            bytes: 1,
            files: 1,
            group: "test",
            detail: "",
            risk: .caution,
            autoselect: true,
            allowedRoot: "/etc",
            isDirectory: false,
            modified: nil
        )

        let result = ArtifactCleaner(home: home, fileManager: fileManager).clean(
            [artifact], apply: true, permanent: true, includeCaution: true
        )

        XCTAssertEqual(result.skipped.count, 1)
        XCTAssertTrue(result.deleted.isEmpty)
        XCTAssertTrue(fileManager.fileExists(atPath: "/etc/hosts"))
    }
}

final class UninstallerTests: XCTestCase {
    private let fileManager = FileManager.default
    private var home: URL!

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("maclean-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        home = base.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: home)
    }

    @discardableResult
    private func write(_ relative: String, bytes: Int) throws -> URL {
        let url = home.appendingPathComponent(relative)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x43, count: bytes).write(to: url)
        return url
    }

    func testPlanIncludesAppBundleAndLeftovers() throws {
        let bundle = home.appendingPathComponent("Applications/Sample.app")
        let contents = bundle.appendingPathComponent("Contents")
        try fileManager.createDirectory(at: contents, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.example.sample",
            "CFBundleExecutable": "Sample",
            "CFBundleName": "Sample",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))

        try write("Library/Caches/com.example.sample/blob.bin", bytes: 100)
        try write("Library/Preferences/com.example.sample.plist", bytes: 20)
        try write("Library/Containers/com.example.sample/Data/file.bin", bytes: 30)
        try write("Library/Application Support/com.example.sample/data.bin", bytes: 40)

        let launchAgent = home.appendingPathComponent("Library/LaunchAgents/com.example.sample.agent.plist")
        try fileManager.createDirectory(at: launchAgent.deletingLastPathComponent(), withIntermediateDirectories: true)
        let agent: [String: Any] = [
            "Label": "com.example.sample.agent",
            "Program": "/Applications/Sample.app/Contents/MacOS/Sample",
        ]
        let agentData = try PropertyListSerialization.data(fromPropertyList: agent, format: .xml, options: 0)
        try agentData.write(to: launchAgent)

        let app = AppInfo(
            name: "Sample",
            path: bundle.path,
            bundleID: "com.example.sample",
            version: "1.0",
            bytes: 0
        )
        let plan = Uninstaller.plan(for: app, home: home, fileManager: fileManager)
        let paths = Set(plan.map(\.path))

        XCTAssertTrue(paths.contains { $0.hasSuffix("Applications/Sample.app") })
        XCTAssertTrue(paths.contains { $0.hasSuffix("Library/Caches/com.example.sample") })
        XCTAssertTrue(paths.contains { $0.hasSuffix("Library/Preferences/com.example.sample.plist") })
        XCTAssertTrue(paths.contains { $0.hasSuffix("Library/Containers/com.example.sample") })
        XCTAssertTrue(paths.contains { $0.hasSuffix("Library/LaunchAgents/com.example.sample.agent.plist") })
        XCTAssertTrue(plan.allSatisfy { !$0.allowedRoot.isEmpty })
    }
}

final class PrivacyScannerTests: XCTestCase {
    private let fileManager = FileManager.default
    private var home: URL!

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("maclean-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        home = base.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: home)
    }

    @discardableResult
    private func write(_ relative: String, bytes: Int) throws -> URL {
        let url = home.appendingPathComponent(relative)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x44, count: bytes).write(to: url)
        return url
    }

    func testFindsChromeAndSafariArtifacts() throws {
        try write("Library/Application Support/Google/Chrome/Default/History", bytes: 100)
        try write("Library/Application Support/Google/Chrome/Default/Cookies", bytes: 100)
        try write("Library/Safari/History.db", bytes: 100)

        let artifacts = PrivacyScanner.scan(home: home, fileManager: fileManager)
        let groups = Set(artifacts.map(\.group))
        XCTAssertTrue(groups.contains("Browsing history"))
        XCTAssertTrue(groups.contains("Cookies"))
        XCTAssertTrue(artifacts.allSatisfy { !$0.autoselect })
        XCTAssertTrue(artifacts.allSatisfy { $0.risk == .caution })
    }

    func testFindsFirefoxProfileArtifacts() throws {
        let profile = home.appendingPathComponent("Library/Application Support/Firefox/Profiles/abc.default")
        try fileManager.createDirectory(at: profile, withIntermediateDirectories: true)
        try Data(repeating: 0x45, count: 10).write(to: profile.appendingPathComponent("places.sqlite"))
        try Data(repeating: 0x45, count: 10).write(to: profile.appendingPathComponent("logins.json"))

        let artifacts = PrivacyScanner.scan(home: home, fileManager: fileManager)
        XCTAssertTrue(artifacts.contains { $0.group == "Saved passwords" })
        XCTAssertTrue(artifacts.contains { $0.group == "Browsing history" })
    }
}

final class PerformanceScannerTests: XCTestCase {
    private let fileManager = FileManager.default
    private var home: URL!

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("maclean-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        home = base.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: home)
    }

    func testDetectsBrokenLaunchAgent() throws {
        let url = home.appendingPathComponent("Library/LaunchAgents/com.example.missing.plist")
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "Label": "com.example.missing",
            "Program": "/Applications/DefinitelyMissing.app/Contents/MacOS/DefinitelyMissing",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url)

        let items = PerformanceScanner.startupItems(home: home, fileManager: fileManager, includeSystemPaths: false)
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items[0].broken)
        XCTAssertEqual(items[0].kind, "Login item")
        XCTAssertEqual(items[0].scope, "user")
    }

    func testHealthyLaunchAgentIsNotBroken() throws {
        let executable = home.appendingPathComponent("bin/agent")
        try fileManager.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: executable)

        let url = home.appendingPathComponent("Library/LaunchAgents/com.example.agent.plist")
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let plist: [String: Any] = ["Label": "com.example.agent", "Program": executable.path]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url)

        let items = PerformanceScanner.startupItems(home: home, fileManager: fileManager, includeSystemPaths: false)
        XCTAssertEqual(items.count, 1)
        XCTAssertFalse(items[0].broken)
    }
}

final class DuplicateScannerTests: XCTestCase {
    private let fileManager = FileManager.default
    private var home: URL!

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("maclean-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        home = base.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: home)
    }

    @discardableResult
    private func write(_ relative: String, data: Data) throws -> URL {
        let url = home.appendingPathComponent(relative)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    func testFindsExactDuplicatesAndIgnoresUniqueFiles() throws {
        let payload = Data(repeating: 0x46, count: 2048)
        try write("Downloads/a.bin", data: payload)
        try write("Desktop/b.bin", data: payload)
        try write("Documents/unique.bin", data: Data(repeating: 0x47, count: 2048))

        let groups = DuplicateScanner.scan(
            directories: [home.appendingPathComponent("Downloads"), home.appendingPathComponent("Desktop")],
            minBytes: 1,
            fileManager: fileManager
        )

        XCTAssertEqual(groups.count, 1)
        let names = Set(groups[0].paths.map { URL(fileURLWithPath: $0).lastPathComponent })
        XCTAssertEqual(names, ["a.bin", "b.bin"])
        XCTAssertEqual(groups[0].wastedBytes, 2048)
    }

    func testSha256IsStable() throws {
        let data = Data(repeating: 0x48, count: 4096)
        let url = try write("file.bin", data: data)
        XCTAssertEqual(DuplicateScanner.sha256(of: url), DuplicateScanner.sha256(of: url))
    }
}

final class LensTests: XCTestCase {
    private let fileManager = FileManager.default
    private var home: URL!

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("maclean-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        home = base.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: home)
    }

    func testBuildsSizedTree() throws {
        let downloads = home.appendingPathComponent("Downloads")
        let documents = home.appendingPathComponent("Documents")
        try fileManager.createDirectory(at: downloads, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: documents, withIntermediateDirectories: true)
        try Data(repeating: 0x49, count: 300).write(to: downloads.appendingPathComponent("a.bin"))
        try Data(repeating: 0x49, count: 500).write(to: documents.appendingPathComponent("b.bin"))

        let node = Lens.scan(root: home, depth: 1, fileManager: fileManager)

        XCTAssertEqual(node.files, 2)
        XCTAssertGreaterThanOrEqual(node.bytes, 800)
        XCTAssertEqual(Set(node.children.map(\.name)), ["Downloads", "Documents"])
        XCTAssertEqual(node.children.first?.name, "Documents")
    }
}

final class DiskImageScannerTests: XCTestCase {
    private let fileManager = FileManager.default
    private var home: URL!

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("maclean-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        home = base.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: home)
    }

    func testFindsOldLargeDiskImage() throws {
        let url = home.appendingPathComponent("Downloads/old.dmg")
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x4A, count: 2 * 1024 * 1024).write(to: url)
        try fileManager.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-90 * 86_400)],
            ofItemAtPath: url.path
        )

        let artifacts = DiskImageScanner.scan(
            home: home,
            olderThanDays: 30,
            minBytes: 1024 * 1024,
            fileManager: fileManager
        )

        XCTAssertEqual(artifacts.count, 1)
        XCTAssertEqual(artifacts[0].group, "Unused disk image")
        XCTAssertTrue(artifacts[0].path.hasSuffix("old.dmg"))
    }

    func testIgnoresRecentDiskImage() throws {
        let url = home.appendingPathComponent("Downloads/new.dmg")
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x4A, count: 2 * 1024 * 1024).write(to: url)

        let artifacts = DiskImageScanner.scan(
            home: home,
            olderThanDays: 30,
            minBytes: 1024 * 1024,
            fileManager: fileManager
        )
        XCTAssertTrue(artifacts.isEmpty)
    }
}

final class MailScannerTests: XCTestCase {
    private let fileManager = FileManager.default
    private var home: URL!

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("maclean-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        home = base.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: home)
    }

    func testFindsMailDataAttachments() throws {
        let attachments = home.appendingPathComponent("Library/Mail/V10/ACCOUNT/MailData/Attachments")
        try fileManager.createDirectory(at: attachments, withIntermediateDirectories: true)
        let file = attachments.appendingPathComponent("attachment.bin")
        try Data(repeating: 0x4B, count: 256).write(to: file)

        let artifacts = MailScanner.scan(home: home, fileManager: fileManager)

        XCTAssertEqual(artifacts.count, 1)
        XCTAssertTrue(artifacts[0].path.hasSuffix("MailData/Attachments/attachment.bin"))
        XCTAssertTrue(artifacts[0].allowedRoot.hasSuffix("MailData/Attachments"))
        XCTAssertEqual(artifacts[0].group, "Mail attachments")
        XCTAssertFalse(artifacts[0].autoselect)
    }
}

final class CloudScannerTests: XCTestCase {
    private let fileManager = FileManager.default
    private var home: URL!

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("maclean-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        home = base.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: home)
    }

    func testReportsLocalCloudFolder() throws {
        let dropbox = home.appendingPathComponent("Dropbox")
        try fileManager.createDirectory(at: dropbox, withIntermediateDirectories: true)
        let big = dropbox.appendingPathComponent("big.bin")
        try Data(repeating: 0x4C, count: 4096).write(to: big)

        let scan = CloudScanner.scan(home: home, minLargeBytes: 1024, fileManager: fileManager)

        XCTAssertTrue(scan.locations.contains { $0.name == "Dropbox" })
        XCTAssertTrue(scan.largeFiles.contains { $0.path.hasSuffix("Dropbox/big.bin") })
    }
}

final class SimilarImageScannerTests: XCTestCase {
    private let fileManager = FileManager.default

    func testDHashIsStableAndGroupsIdenticalImages() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("maclean-images-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let first = directory.appendingPathComponent("one.png")
        let second = directory.appendingPathComponent("two.png")

        let width = 64
        let height = 64
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())

        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            first as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        try fileManager.copyItem(at: first, to: second)

        let hash = try XCTUnwrap(SimilarImageScanner.dHash(first))
        XCTAssertEqual(hash, SimilarImageScanner.dHash(second))

        let groups = SimilarImageScanner.scan(
            directories: [directory],
            maxDistance: 0,
            minBytes: 0,
            fileManager: fileManager
        )
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(Set(groups[0].paths.map { URL(fileURLWithPath: $0).lastPathComponent }), ["one.png", "two.png"])
    }
}
