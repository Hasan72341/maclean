import CryptoKit
import Foundation




/// Saves Space Lens trees to disk so maps survive relaunches.
///
/// Layout: `MLNS` magic, a version byte, a UInt32 header length, a JSON
/// header (`LensArchive.Header`), then the tree depth-first in a compact
/// binary record per item. Paths are not stored; they are rebuilt from the
/// root path and each item's name.
public enum LensArchive {
    public struct Header: Codable, Sendable {
        public let root: String
        public let scanned: Date
        public let duration: TimeInterval
        public let bytes: Int64
        public let files: Int
        public let folders: Int
        public let volumeTotal: Int64?
        public let volumeAvailable: Int64?
        public let unreadableSamples: [String]
        public let largest: [LensFile]
        public let items: Int
    }

    static let magic: [UInt8] = Array("MLNS".utf8)
    static let version: UInt8 = 1

    public static var directory: URL {
        if let custom = ProcessInfo.processInfo.environment["MACLEAN_LENS_CACHE"] { return URL(fileURLWithPath: custom) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/MacLean/Lens")
    }

    public static func file(for root: String) -> URL {
        let digest = SHA256.hash(data: Data(root.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(digest).mlens")
    }

    // MARK: Write

    @discardableResult
    public static func write(_ result: LensResult, scanned: Date = Date(), keep: Int = 8) -> URL? {
        let (data, url) = encode(result, scanned: scanned)
        guard let data else { return nil }
        return store(data, to: url, keep: keep)
    }

    /// Serialises a tree (call on the thread that owns the tree).
    public static func encode(_ result: LensResult, scanned: Date = Date()) -> (Data?, URL) {
        var body = [UInt8]()
        body.reserveCapacity(1 << 20)
        var count = 0
        encode(result.root, into: &body, count: &count)
        let header = Header(root: result.root.path, scanned: scanned, duration: result.duration, bytes: result.root.bytes,
                            files: result.root.files, folders: result.root.folders, volumeTotal: result.volumeTotal,
                            volumeAvailable: result.volumeAvailable, unreadableSamples: result.unreadableSamples,
                            largest: result.largest, items: count)
        guard let json = try? JSONEncoder().encode(header) else { return (nil, file(for: result.root.path)) }
        var out = Data(magic)
        out.append(version)
        appendInt(&out, UInt32(json.count))
        out.append(json)
        out.append(contentsOf: body)
        return (out, file(for: result.root.path))
    }

    /// Writes encoded data (safe on any thread).
    @discardableResult
    public static func store(_ out: Data, to url: URL, keep: Int = 8) -> URL? {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try out.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        prune(keep: keep)
        return url
    }

    private static func appendInt<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func put<T: FixedWidthInteger>(_ buffer: inout [UInt8], _ value: T) {
        withUnsafeBytes(of: value.littleEndian) { buffer.append(contentsOf: $0) }
    }

    private static func encode(_ item: LensItem, into buffer: inout [UInt8], count: inout Int) {
        count += 1
        var flags: UInt8 = 0
        if item.isDirectory { flags |= 1 }
        if item.isPackage { flags |= 2 }
        if item.isAggregate { flags |= 4 }
        let hasKinds = !item.kindBytes.isEmpty
        if hasKinds { flags |= 8 }
        buffer.append(flags)
        buffer.append(UInt8(item.kind.rawValue))
        let name = Array(item.name.utf8.prefix(Int(UInt16.max)))
        put(&buffer, UInt16(name.count))
        buffer.append(contentsOf: name)
        put(&buffer, item.bytes)
        put(&buffer, UInt32(clamping: item.files))
        put(&buffer, UInt32(clamping: item.folders))
        put(&buffer, (item.modified?.timeIntervalSince1970 ?? .nan).bitPattern)
        put(&buffer, UInt32(clamping: item.unreadable))
        put(&buffer, UInt32(clamping: item.aggregateCount))
        if hasKinds {
            for kind in LensKind.allCases { put(&buffer, kind.rawValue < item.kindBytes.count ? item.kindBytes[kind.rawValue] : 0) }
        }
        put(&buffer, UInt32(item.children.count))
        for child in item.children { encode(child, into: &buffer, count: &count) }
    }

    // MARK: Read

    public static func header(at url: URL) -> Header? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: 9), prefix.count == 9,
              Array(prefix.prefix(4)) == magic, prefix[4] == version else { return nil }
        let length = prefix.subdata(in: 5..<9).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        guard let json = try? handle.read(upToCount: Int(length)) else { return nil }
        return try? JSONDecoder().decode(Header.self, from: json)
    }

    /// Every saved map, newest first.
    public static func saved() -> [(url: URL, header: Header)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "mlens" }
            .compactMap { url in header(at: url).map { (url, $0) } }
            .sorted { $0.header.scanned > $1.header.scanned }
    }

    public static func read(_ url: URL) -> (header: Header, result: LensResult)? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count > 9,
              Array(data.prefix(4)) == magic, data[4] == version else { return nil }
        let length = Int(data.subdata(in: 5..<9).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian })
        guard data.count >= 9 + length, let header = try? JSONDecoder().decode(Header.self, from: data.subdata(in: 9..<(9 + length))) else { return nil }
        var reader = Reader(data: data, offset: 9 + length)
        guard let root = reader.item(path: header.root, isRoot: true) else { return nil }
        let result = LensResult(root: root, largest: header.largest, duration: header.duration,
                                unreadableSamples: header.unreadableSamples, cancelled: false,
                                volumeTotal: header.volumeTotal, volumeAvailable: header.volumeAvailable)
        return (header, result)
    }

    public static func delete(root: String) {
        try? FileManager.default.removeItem(at: file(for: root))
    }

    static func prune(keep: Int) {
        for stale in saved().dropFirst(keep) { try? FileManager.default.removeItem(at: stale.url) }
    }

    struct Reader {
        let data: Data
        var offset: Int

        mutating func take<T: FixedWidthInteger>(_: T.Type) -> T? {
            let size = MemoryLayout<T>.size
            guard offset + size <= data.count else { return nil }
            let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
            offset += size
            return T(littleEndian: value)
        }

        mutating func item(path: String?, parentPath: String = "", isRoot: Bool = false) -> LensItem? {
            guard let flags = take(UInt8.self), let kindRaw = take(UInt8.self), let nameLength = take(UInt16.self) else { return nil }
            guard offset + Int(nameLength) <= data.count else { return nil }
            let name = String(decoding: data[offset..<(offset + Int(nameLength))], as: UTF8.self)
            offset += Int(nameLength)
            guard let bytes = take(Int64.self), let files = take(UInt32.self), let folders = take(UInt32.self),
                  let modifiedBits = take(UInt64.self), let unreadable = take(UInt32.self), let aggregate = take(UInt32.self) else { return nil }
            var kindBytes: [Int64] = []
            if flags & 8 != 0 {
                for _ in LensKind.allCases { guard let value = take(Int64.self) else { return nil }; kindBytes.append(value) }
            }
            guard let childCount = take(UInt32.self) else { return nil }
            let isAggregate = flags & 4 != 0
            let ownPath: String
            if let path { ownPath = path }
            else if isAggregate { ownPath = parentPath + "/\u{2026}smaller-items" }
            else { ownPath = parentPath == "/" ? "/" + name : parentPath + "/" + name }
            var children: [LensItem] = []
            children.reserveCapacity(Int(childCount))
            for _ in 0..<childCount {
                guard let child = item(path: nil, parentPath: ownPath) else { return nil }
                children.append(child)
            }
            let modified = Double(bitPattern: modifiedBits)
            return LensItem(path: ownPath, name: name, isDirectory: flags & 1 != 0, isPackage: flags & 2 != 0,
                            isAggregate: isAggregate, aggregateCount: Int(aggregate), kind: LensKind(rawValue: Int(kindRaw)) ?? .other,
                            bytes: bytes, files: Int(files), folders: Int(folders),
                            modified: modified.isNaN ? nil : Date(timeIntervalSince1970: modified),
                            children: children, kindBytes: kindBytes, unreadable: Int(unreadable))
        }
    }
}
