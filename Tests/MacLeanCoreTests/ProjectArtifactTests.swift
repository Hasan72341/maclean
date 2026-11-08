import XCTest
@testable import MacLeanCore

final class ProjectArtifactScannerTests: XCTestCase {
    private let fileManager = FileManager.default
    private var home: URL!
    private var projects: URL!
    private let old = Date().addingTimeInterval(-60 * 86_400)

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("maclean-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        home = base.resolvingSymlinksInPath()
        projects = home.appendingPathComponent("Projects", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: home)
    }

    private func write(_ relative: String, bytes: Int = 4096, age: Date? = nil) throws {
        let url = projects.appendingPathComponent(relative)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        if let age { try touch(relative, age) }
    }

    private func touch(_ relative: String, _ date: Date) throws {
        try fileManager.setAttributes([.modificationDate: date], ofItemAtPath: projects.appendingPathComponent(relative).path)
    }

    private func scan(git: String? = nil) -> [Artifact] {
        ProjectArtifactScanner.scan(home: home, roots: [projects], recentDays: 7, git: git, fileManager: fileManager)
    }

    private func names(_ artifacts: [Artifact]) -> [String] {
        artifacts.map { String($0.path.dropFirst(PathCanon.resolve(projects.path).count + 1)) }.sorted()
    }

    func testFindsOldNodeModulesNextToPackageJSON() throws {
        try write("web/package.json", age: old)
        try write("web/node_modules/left-pad/index.js")
        try write("web/node_modules/left-pad/node_modules/x/index.js")
        try touch("web/node_modules", old)

        let artifacts = scan()
        XCTAssertEqual(names(artifacts), ["web/node_modules"])
        XCTAssertTrue(artifacts[0].autoselect)
        XCTAssertEqual(artifacts[0].group, "Node.js dependencies")
        XCTAssertEqual(artifacts[0].allowedRoot, PathCanon.resolve(projects.appendingPathComponent("web").path))
    }

    func testIgnoresFoldersWithoutTheirProjectMarker() throws {
        try write("photos/node_modules/a.txt")
        try write("notes/build/report.pdf")
        try write("notes/target/plan.txt")
        XCTAssertTrue(scan().isEmpty)
    }

    func testRecentProjectsAreNotPreselected() throws {
        try write("api/Cargo.toml")
        try write("api/target/debug/api")
        let artifacts = scan()
        XCTAssertEqual(names(artifacts), ["api/target"])
        XCTAssertFalse(artifacts[0].autoselect)
        XCTAssertTrue(artifacts[0].detail.contains("recently active"))
    }

    func testAmbiguousFoldersNeedReviewOutsideGit() throws {
        try write("site/package.json", age: old)
        try write("site/dist/app.js")
        try touch("site/dist", old)
        let artifacts = scan()
        XCTAssertEqual(names(artifacts), ["site/dist"])
        XCTAssertFalse(artifacts[0].autoselect)
    }

    func testVirtualenvNeedsPyvenvCfg() throws {
        try write("ml/venv/lib/site.py")
        XCTAssertTrue(scan().isEmpty)
        try write("ml/.venv/pyvenv.cfg")
        XCTAssertEqual(names(scan()), ["ml/.venv"])
    }

    func testSkipsNestedRepositories() throws {
        try write("tool/package.json", age: old)
        try write("tool/node_modules/.git/HEAD")
        XCTAssertTrue(scan().isEmpty)
    }

    func testGitTrackedFoldersAreSkippedAndIgnoredOnesSelected() throws {
        guard let git = GitProbe.executable else { throw XCTSkip("git is not available") }
        let repo = projects.appendingPathComponent("app")
        try write("app/package.json", age: old)
        try write("app/.gitignore", age: old)
        try "node_modules/\n".write(to: repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try write("app/dist/committed.js")
        try write("app/build/output.js")
        try write("app/node_modules/dep/index.js")

        func runGit(_ args: [String]) {
            let result = ProcessRunner.run(git, ["-C", repo.path] + args)
            XCTAssertEqual(result.status, 0, result.stderr)
        }
        runGit(["init", "-q"])
        runGit(["add", "package.json", ".gitignore", "dist/committed.js"])
        runGit(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init"])
        for path in ["app/package.json", "app/node_modules", "app/build"] { try touch(path, old) }

        let artifacts = scan(git: git)
        XCTAssertEqual(names(artifacts), ["app/build", "app/node_modules"])
        let byName = Dictionary(uniqueKeysWithValues: artifacts.map { (($0.path as NSString).lastPathComponent, $0) })
        XCTAssertEqual(byName["node_modules"]?.autoselect, true)
        XCTAssertEqual(byName["build"]?.autoselect, false, "build is not ignored by Git, so it needs review")
    }

    func testCleanerMovesSelectedArtifactsOnly() throws {
        try write("web/package.json", age: old)
        try write("web/node_modules/dep/index.js")
        try touch("web/node_modules", old)
        try write("site/package.json", age: old)
        try write("site/dist/app.js")
        try touch("site/dist", old)

        let artifacts = scan()
        let result = ArtifactCleaner(home: home, fileManager: fileManager)
            .clean(artifacts, apply: true, permanent: true, includeCaution: false)
        XCTAssertEqual(result.deleted.count, 1)
        XCTAssertFalse(fileManager.fileExists(atPath: projects.appendingPathComponent("web/node_modules").path))
        XCTAssertTrue(fileManager.fileExists(atPath: projects.appendingPathComponent("site/dist").path))
        XCTAssertTrue(fileManager.fileExists(atPath: projects.appendingPathComponent("web/package.json").path))
    }
}
