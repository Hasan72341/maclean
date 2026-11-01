import XCTest
@testable import MacLeanCore

final class CorpusFetcherTests: XCTestCase {
    func testDetectsRemoteSources() {
        XCTAssertTrue(CorpusFetcher.isRemote("https://corpus.nyora.xyz/panther_corpus.sqlite"))
        XCTAssertTrue(CorpusFetcher.isRemote("http://localhost:8080/corpus.sqlite"))
        XCTAssertFalse(CorpusFetcher.isRemote("/Users/example/corpus.sqlite"))
        XCTAssertFalse(CorpusFetcher.isRemote("~/corpus.sqlite"))
    }

    func testCacheLocationIsStableAndRemoteOnly() {
        let directory = URL(fileURLWithPath: "/tmp/maclean-cache-test")
        let first = CorpusFetcher.cacheLocation(
            for: "https://corpus.nyora.xyz/panther_corpus.sqlite",
            cacheDirectory: directory
        )
        let second = CorpusFetcher.cacheLocation(
            for: "https://corpus.nyora.xyz/panther_corpus.sqlite",
            cacheDirectory: directory
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first?.pathExtension, "sqlite")
        XCTAssertNil(CorpusFetcher.cacheLocation(
            for: "/tmp/local.sqlite",
            cacheDirectory: directory
        ))
    }

    func testLocalPathPassesThrough() throws {
        let resolved = try CorpusFetcher.resolve("/tmp/example-corpus.sqlite")
        XCTAssertEqual(resolved.path, "/tmp/example-corpus.sqlite")
    }
}
