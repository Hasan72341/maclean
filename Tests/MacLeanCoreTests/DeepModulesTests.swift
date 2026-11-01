import XCTest
@testable import MacLeanCore

final class DeepModulesTests: XCTestCase {
    private let fileManager = FileManager.default
    private var base: URL!

    override func setUpWithError() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("maclean-deep-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: base)
    }

    func testPermissionReportParsesTCCDatabase() throws {
        let database = base.appendingPathComponent("TCC.db")
        let sql = """
        CREATE TABLE access (service TEXT, client TEXT, auth_value INTEGER, last_modified INTEGER);
        INSERT INTO access VALUES ('kTCCServiceCamera', 'com.example.app', 2, 1700000000);
        INSERT INTO access VALUES ('kTCCServiceMicrophone', 'com.example.app', 0, 0);
        """
        let result = ProcessRunner.run("/usr/bin/sqlite3", [database.path, sql])
        XCTAssertEqual(result.status, 0, result.stderr)

        let report = PermissionsScanner.scan(database: database)
        XCTAssertNil(report.error)
        XCTAssertEqual(report.grants.count, 2)
        XCTAssertEqual(report.grants.first { $0.service == "kTCCServiceCamera" }?.allowed, true)
        XCTAssertEqual(report.grants.first { $0.service == "kTCCServiceMicrophone" }?.allowed, false)
        XCTAssertNotNil(report.grants.first { $0.service == "kTCCServiceCamera" }?.lastModified)
    }

    func testMailTrashFindsDeletedMessages() throws {
        let message = base.appendingPathComponent(
            "Library/Mail/V10/ACCOUNT/Deleted Messages.mbox/ID/Data/Messages/1.emlx"
        )
        try fileManager.createDirectory(
            at: message.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x41, count: 128).write(to: message)

        let report = MailTrashScanner.scan(home: base)
        XCTAssertEqual(report.mailboxes.count, 1)
        XCTAssertEqual(report.mailboxes[0].messageCount, 1)
        XCTAssertEqual(report.mailboxes[0].bytes, 128)
        XCTAssertEqual(report.mailboxes[0].mailbox, "Deleted Messages")
    }

    func testPhotosDuplicateFindsExactOriginals() throws {
        let originals = base.appendingPathComponent(
            "Pictures/Test.photoslibrary/originals"
        )
        let first = originals.appendingPathComponent("a/one.jpg")
        let second = originals.appendingPathComponent("b/two.jpg")
        try fileManager.createDirectory(
            at: first.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: second.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let payload = Data(repeating: 0x42, count: 4096)
        try payload.write(to: first)
        try payload.write(to: second)

        let report = PhotosDuplicateScanner.scan(home: base)
        XCTAssertEqual(report.libraries.count, 1)
        XCTAssertEqual(report.exactGroups.count, 1)
        XCTAssertEqual(report.exactGroups[0].paths.count, 2)
        XCTAssertEqual(report.wastedBytes, 4096)
    }

    func testProtectedStoreScansInjectedRoots() throws {
        let deleted = base.appendingPathComponent("DeletedUsers/alice.dmg")
        let versions = base.appendingPathComponent("DocumentRevisions/a")
        let caches = base.appendingPathComponent("Caches/app")
        try fileManager.createDirectory(
            at: deleted.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x43, count: 256).write(to: deleted)
        for directory in [versions, caches] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(repeating: 0x43, count: 256).write(
                to: directory.appendingPathComponent("data")
            )
        }

        let report = ProtectedStoreScanner.scan(
            deletedUsersRoot: base.appendingPathComponent("DeletedUsers"),
            documentVersionsRoot: base.appendingPathComponent("DocumentRevisions"),
            systemCacheRoots: [base.appendingPathComponent("Caches")],
            applicationRoots: []
        )
        XCTAssertEqual(report.deletedUsers.count, 1)
        XCTAssertEqual(report.documentVersions.count, 1)
        XCTAssertEqual(report.systemCaches.count, 1)
        XCTAssertGreaterThan(report.deletedUsers[0].bytes, 0)
        XCTAssertTrue(report.deletedUsers[0].requiresRoot)
    }

    func testDocumentVersionSelectionWindow() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let dates = [
            start,
            start.addingTimeInterval(60),
            start.addingTimeInterval(20_000),
            start.addingTimeInterval(20_100),
        ]
        XCTAssertEqual(
            DocumentVersionsScanner.selectedIndexes(dates: dates, window: 14_400),
            [1]
        )
        XCTAssertEqual(
            DocumentVersionsScanner.selectedIndexes(
                dates: dates,
                window: 14_400
            ),
            DocumentVersionsScanner.selectedIndexes(dates: dates)
        )
    }

    func testTCCServiceNameMapping() {
        XCTAssertEqual(
            PermissionsScanner.tccutilServiceName("kTCCServiceCamera"),
            "Camera"
        )
        XCTAssertEqual(
            PermissionsScanner.tccutilServiceName("All"),
            "All"
        )
    }

    func testUniversalBinaryDetection() throws {
        let apps = base.appendingPathComponent("Applications")
        let macos = apps.appendingPathComponent("Test.app/Contents/MacOS")
        try fileManager.createDirectory(at: macos, withIntermediateDirectories: true)
        let binary = macos.appendingPathComponent("Test")
        try fileManager.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: binary)

        let report = ProtectedStoreScanner.scan(
            deletedUsersRoot: base.appendingPathComponent("NoDeletedUsers"),
            documentVersionsRoot: base.appendingPathComponent("NoVersions"),
            systemCacheRoots: [],
            applicationRoots: [apps]
        )
        XCTAssertEqual(report.universalBinaries.count, 1)
        XCTAssertGreaterThan(report.universalBinaries[0].archs.count, 1)
        XCTAssertGreaterThan(report.universalBinaries[0].estimatedSavings, 0)
    }

    func testUniversalThinnerBacksUpAndThins() throws {
        let apps = base.appendingPathComponent("Applications")
        let macos = apps.appendingPathComponent("Test.app/Contents/MacOS")
        try fileManager.createDirectory(at: macos, withIntermediateDirectories: true)
        let binary = macos.appendingPathComponent("Test")
        try fileManager.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: binary)

        let report = ProtectedStoreScanner.scan(
            deletedUsersRoot: base.appendingPathComponent("NoDeletedUsers"),
            documentVersionsRoot: base.appendingPathComponent("NoVersions"),
            systemCacheRoots: [],
            applicationRoots: [apps]
        )
        let backups = base.appendingPathComponent("Backups")
        let result = UniversalThinner.thin(
            report: report,
            architecture: "x86_64",
            apply: true,
            resign: false,
            backupRoot: backups
        )
        XCTAssertEqual(result.thinned.count, 1, result.failed.map(\.reason).joined(separator: ", "))
        XCTAssertEqual(result.backups.count, 1)
        XCTAssertTrue(fileManager.fileExists(atPath: result.backups[0]))
        let archs = ProcessRunner.run("/usr/bin/lipo", ["-archs", binary.path])
        XCTAssertTrue(archs.stdout.contains("x86_64"))
    }

    func testMailTrashCleanupDeletesMessages() throws {
        let message = base.appendingPathComponent(
            "Library/Mail/V10/ACCOUNT/Deleted Messages.mbox/ID/Data/Messages/1.emlx"
        )
        try fileManager.createDirectory(
            at: message.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x41, count: 128).write(to: message)

        let report = MailTrashScanner.scan(home: base)
        let result = DeepCleaner.cleanMailTrash(
            report: report,
            apply: true,
            permanent: true,
            home: base
        )
        XCTAssertEqual(result.deleted.count, 1)
        XCTAssertFalse(fileManager.fileExists(atPath: message.path))
    }

    func testPhotosCleanupKeepsOneOriginal() throws {
        let originals = base.appendingPathComponent(
            "Pictures/Test.photoslibrary/originals"
        )
        let first = originals.appendingPathComponent("a/one.jpg")
        let second = originals.appendingPathComponent("b/two.jpg")
        for file in [first, second] {
            try fileManager.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(repeating: 0x42, count: 4096).write(to: file)
        }

        let report = PhotosDuplicateScanner.scan(home: base)
        let result = DeepCleaner.cleanPhotosDuplicates(
            report: report,
            apply: true,
            permanent: true,
            home: base
        )
        XCTAssertEqual(result.deleted.count, 1)
        XCTAssertEqual(
            [first, second].filter { fileManager.fileExists(atPath: $0.path) }.count,
            1
        )
    }

    func testProtectedStoreCleanupRemovesInjectedChildren() throws {
        let deletedRoot = base.appendingPathComponent("DeletedUsers")
        let documentsRoot = base.appendingPathComponent("DocumentRevisions")
        let cachesRoot = base.appendingPathComponent("Caches")
        try fileManager.createDirectory(at: deletedRoot, withIntermediateDirectories: true)
        let deletedDMG = deletedRoot.appendingPathComponent("alice.dmg")
        try Data(repeating: 0x43, count: 256).write(to: deletedDMG)
        for directory in [
            documentsRoot.appendingPathComponent("a"),
            cachesRoot.appendingPathComponent("app"),
        ] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(repeating: 0x43, count: 256).write(
                to: directory.appendingPathComponent("data")
            )
        }

        let report = ProtectedStoreScanner.scan(
            deletedUsersRoot: deletedRoot,
            documentVersionsRoot: documentsRoot,
            systemCacheRoots: [cachesRoot],
            applicationRoots: []
        )
        let result = DeepCleaner.cleanProtectedStores(
            report: report,
            kinds: ["deleted-user", "document-version", "system-cache"],
            apply: true,
            permanent: true,
            requireRoot: false,
            deletedUsersRoot: deletedRoot,
            documentVersionsRoot: documentsRoot
        )
        XCTAssertEqual(result.failed.count, 0, result.failed.map(\.reason).joined(separator: ", "))
        XCTAssertEqual(result.deleted.count, 3)
        XCTAssertFalse(fileManager.fileExists(atPath: deletedDMG.path))
    }

    func testProtectedStoreCleanupRefusesOutsideRoot() throws {
        let outside = base.appendingPathComponent("outside")
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(repeating: 0x44, count: 64).write(to: outside.appendingPathComponent("data"))
        let item = ProtectedStoreItem(
            path: outside.path,
            name: "outside",
            kind: "deleted-user",
            bytes: 64,
            detail: "test",
            requiresRoot: true
        )
        let report = ProtectedStoreReport(
            isRoot: false,
            deletedUsers: [item],
            documentVersions: [],
            systemCaches: [],
            universalBinaries: [],
            errors: []
        )
        let result = DeepCleaner.cleanProtectedStores(
            report: report,
            kinds: ["deleted-user"],
            apply: true,
            permanent: true,
            requireRoot: false
        )
        XCTAssertEqual(result.deleted.count, 0)
        XCTAssertEqual(result.failed.count, 1)
    }
}
