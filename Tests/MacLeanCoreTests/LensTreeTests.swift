import Foundation
import Testing
@testable import MacLeanCore

@Suite("Lens tree")
struct LensTreeTests {
    func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lens-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func write(_ root: URL, _ relative: String, _ bytes: Int) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
    }

    @Test func totalsKindsAndAggregation() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "a/movie.mov", 2_000_000)
        try write(root, "a/b/c/deep.pdf", 1_000_000)
        for i in 0..<50 { try write(root, "tiny/\(i).txt", 100) }
        let result = LensScanner.scan(root: root)
        let tree = result.root
        #expect(tree.files == 52)
        #expect(tree.folders == 4) // a, a/b, a/b/c, tiny
        #expect(tree.kindBytes[LensKind.video.rawValue] >= 2_000_000)
        #expect(tree.kindBytes[LensKind.documents.rawValue] >= 1_000_000)
        let tiny = try #require(tree.find(tree.path + "/tiny"))
        let aggregate = try #require(tiny.children.first { $0.isAggregate })
        #expect(aggregate.aggregateCount == 50 - LensOptions().keepTopFiles)
        #expect(tiny.children.reduce(0) { $0 + $1.files } == 50)
        #expect(tree.find(tree.path + "/a/b/c/deep.pdf")?.lineage.count == 5)
    }

    @Test func hardLinksCountOnce() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "one/data.bin", 3_000_000)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("two"), withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: root.appendingPathComponent("one/data.bin"), to: root.appendingPathComponent("two/data.bin"))
        let tree = LensScanner.scan(root: root).root
        #expect(tree.bytes < 4_000_000)
        #expect(tree.files == 2)
    }

    @Test func symlinksAreNotFollowed() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "real/big.bin", 2_000_000)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)
        let tree = LensScanner.scan(root: root).root
        #expect(tree.bytes < 3_000_000)
    }

    @Test func removeUpdatesAncestors() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "x/y/big.bin", 2_000_000)
        try write(root, "x/keep.bin", 1_000_000)
        let tree = LensScanner.scan(root: root).root
        let before = tree.bytes
        let big = try #require(tree.find(tree.path + "/x/y/big.bin"))
        big.remove()
        #expect(tree.find(tree.path + "/x/y/big.bin") == nil)
        #expect(tree.bytes == before - big.bytes)
        #expect(tree.files == 1)
        #expect(tree.find(tree.path + "/x")?.bytes == tree.bytes)
    }

    @Test func cancelStopsEarly() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<20 { try write(root, "d\(i)/f.bin", 1000) }
        let progress = LensProgress()
        progress.cancel()
        let result = LensScanner.scan(root: root, progress: progress)
        #expect(result.cancelled)
        #expect(result.root.files == 0)
    }
}

@Suite("Lens archive and folded items")
struct LensArchiveTests {
    func tree() throws -> (URL, LensResult) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lensarc-\(UUID().uuidString)")
        for (path, size) in [("a/movie.mov", 2_000_000), ("a/b/doc.pdf", 900_000), ("pkg.app/Contents/x", 50_000)] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 2, count: size).write(to: url)
        }
        for i in 0..<30 {
            let url = root.appendingPathComponent("many/f\(i).txt")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 3, count: 100 + i).write(to: url)
        }
        return (root, LensScanner.scan(root: root))
    }

    @Test func roundTripPreservesTree() throws {
        let (root, result) = try tree()
        defer { try? FileManager.default.removeItem(at: root) }
        let (data, _) = LensArchive.encode(result)
        let file = root.appendingPathComponent("map.mlens")
        try #require(data).write(to: file)
        let loaded = try #require(LensArchive.read(file))
        let back = loaded.result.root
        #expect(back.path == result.root.path)
        #expect(back.bytes == result.root.bytes && back.files == result.root.files && back.folders == result.root.folders)
        #expect(back.kindBytes == result.root.kindBytes)
        #expect(back.find(result.root.path + "/a/b/doc.pdf")?.bytes == result.root.find(result.root.path + "/a/b/doc.pdf")?.bytes)
        #expect(back.find(result.root.path + "/pkg.app")?.isPackage == true)
        let many = try #require(back.find(back.path + "/many"))
        #expect(many.children.contains { $0.isAggregate && $0.parent === many })
        #expect(LensArchive.header(at: file)?.items == loaded.header.items)
    }

    @Test func foldedItemsListAndShrink() throws {
        let (root, result) = try tree()
        defer { try? FileManager.default.removeItem(at: root) }
        let many = try #require(result.root.find(result.root.path + "/many"))
        let aggregate = try #require(many.children.first { $0.isAggregate })
        let folded = LensScanner.foldedItems(of: many)
        #expect(folded.count == aggregate.aggregateCount)
        #expect(folded.reduce(0) { $0 + $1.files } == aggregate.files)
        let before = (result.root.bytes, result.root.files, aggregate.aggregateCount)
        let victim = try #require(folded.first)
        many.removeFolded(bytes: victim.bytes, files: 1, folders: 0, kind: victim.kind)
        #expect(result.root.bytes == before.0 - victim.bytes)
        #expect(result.root.files == before.1 - 1)
        #expect(aggregate.aggregateCount == before.2 - 1)
    }
}
