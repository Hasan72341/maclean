import CryptoKit
import Foundation

public struct MachOSectionDigest: Codable, Sendable, Hashable {
    public let segment: String
    public let section: String
    public let size: Int64
    public let hash: String

    public init(segment: String, section: String, size: Int64, hash: String) {
        self.segment = segment
        self.section = section
        self.size = size
        self.hash = hash
    }
}

public struct MachOInfo: Sendable {
    public let isMachO: Bool
    public let teamID: String?
    public let sections: [MachOSectionDigest]
    public let sliceCount: Int

    public init(isMachO: Bool, teamID: String?, sections: [MachOSectionDigest], sliceCount: Int) {
        self.isMachO = isMachO
        self.teamID = teamID
        self.sections = sections
        self.sliceCount = sliceCount
    }
}

public enum MachOAnalyzer {
    public static func sectionKey(segment: String, section: String, size: Int64) -> String {
        "\(segment)\u{0}\(section)\u{0}\(size)"
    }

    public static func sectionKey(segment: String, section: String, size: Int64, hash: String) -> String {
        "\(segment)\u{0}\(section)\u{0}\(size)\u{0}\(hash.lowercased())"
    }

    public static func analyze(
        url: URL,
        sectionKeys: Set<String>?,
        needTeamID: Bool
    ) -> MachOInfo? {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let head = try? handle.read(upToCount: 4),
              head.count == 4
        else { return nil }
        try? handle.close()

        let magicBytes = [UInt8](head)
        guard isMachOMagic(magicBytes) else { return nil }
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }

        var teamID: String?
        var sections: [MachOSectionDigest] = []
        var sliceCount = 0
        var seenSections = Set<MachOSectionDigest>()

        if let fat = fatLayout(data) {
            for index in 0..<fat.count {
                guard let slice = fat.slice(index, in: data) else { continue }
                sliceCount += 1
                parseThin(
                    data: data,
                    base: slice.offset,
                    length: slice.size,
                    needTeamID: needTeamID,
                    sectionKeys: sectionKeys,
                    teamID: &teamID,
                    sections: &sections,
                    seenSections: &seenSections
                )
            }
        } else if thinLayout(data, base: 0) != nil {
            sliceCount = 1
            parseThin(
                data: data,
                base: 0,
                length: data.count,
                needTeamID: needTeamID,
                sectionKeys: sectionKeys,
                teamID: &teamID,
                sections: &sections,
                seenSections: &seenSections
            )
        } else {
            return nil
        }

        return MachOInfo(
            isMachO: true,
            teamID: teamID,
            sections: sections,
            sliceCount: sliceCount
        )
    }

    private static func isMachOMagic(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 4 else { return false }
        let magic = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
        switch magic {
        case 0xFEEDFACE, 0xFEEDFACF, 0xCEFAEDFE, 0xCFFAEDFE,
             0xCAFEBABE, 0xCAFEBABF:
            return true
        default:
            return false
        }
    }

    private struct ThinLayout {
        let is64: Bool
        let littleEndian: Bool
    }

    private static func thinLayout(_ data: Data, base: Int) -> ThinLayout? {
        guard let magic = le32(data, base) else { return nil }
        switch magic {
        case 0xFEEDFACF: return ThinLayout(is64: true, littleEndian: true)
        case 0xFEEDFACE: return ThinLayout(is64: false, littleEndian: true)
        case 0xCFFAEDFE: return ThinLayout(is64: true, littleEndian: false)
        case 0xCEFAEDFE: return ThinLayout(is64: false, littleEndian: false)
        default: return nil
        }
    }

    private struct FatLayout {
        let count: Int
        let is64: Bool

        func slice(_ index: Int, in data: Data) -> (offset: Int, size: Int)? {
            let entry = 8 + index * (is64 ? 32 : 20)
            let offset: UInt64
            let size: UInt64
            if is64 {
                guard let o = be64(data, entry + 8), let s = be64(data, entry + 16) else { return nil }
                offset = o
                size = s
            } else {
                guard let o = be32(data, entry + 8), let s = be32(data, entry + 12) else { return nil }
                offset = UInt64(o)
                size = UInt64(s)
            }
            guard size > 0, offset <= UInt64(Int.max), size <= UInt64(Int.max) else { return nil }
            let start = Int(offset)
            let length = Int(size)
            guard start >= 0, length > 0, start + length <= data.count else { return nil }
            return (start, length)
        }
    }

    private static func fatLayout(_ data: Data) -> FatLayout? {
        guard let magic = be32(data, 0) else { return nil }
        guard magic == 0xCAFEBABE || magic == 0xCAFEBABF,
              let count = be32(data, 4),
              count > 0, count < 64 else { return nil }
        return FatLayout(count: Int(count), is64: magic == 0xCAFEBABF)
    }

    private static func parseThin(
        data: Data,
        base: Int,
        length: Int,
        needTeamID: Bool,
        sectionKeys: Set<String>?,
        teamID: inout String?,
        sections: inout [MachOSectionDigest],
        seenSections: inout Set<MachOSectionDigest>
    ) {
        guard let layout = thinLayout(data, base: base) else { return }
        let is64 = layout.is64
        let le = layout.littleEndian
        let end = base + length

        guard let ncmds = u32(data, base + 16, le),
              let sizeofcmds = u32(data, base + 20, le),
              ncmds > 0, ncmds < 20_000,
              Int(sizeofcmds) <= length else { return }

        var cursor = base + (is64 ? 32 : 28)
        let commandsEnd = min(end, cursor + Int(sizeofcmds))
        var codeSignature: (offset: Int, size: Int)?

        for _ in 0..<ncmds {
            guard cursor + 8 <= commandsEnd,
                  let cmd = u32(data, cursor, le),
                  let cmdsize = u32(data, cursor + 4, le),
                  cmdsize >= 8,
                  cursor + Int(cmdsize) <= commandsEnd
            else { return }

            switch cmd {
            case 0x19:
                parseSegment64(
                    data: data,
                    command: cursor,
                    base: base,
                    end: end,
                    le: le,
                    sectionKeys: sectionKeys,
                    sections: &sections,
                    seenSections: &seenSections
                )
            case 0x01:
                parseSegment32(
                    data: data,
                    command: cursor,
                    base: base,
                    end: end,
                    le: le,
                    sectionKeys: sectionKeys,
                    sections: &sections,
                    seenSections: &seenSections
                )
            case 0x1d:
                if let offset = u32(data, cursor + 8, le),
                   let size = u32(data, cursor + 12, le),
                   size > 0 {
                    codeSignature = (Int(offset), Int(size))
                }
            default:
                break
            }
            cursor += Int(cmdsize)
        }

        if needTeamID, teamID == nil, let codeSignature {
            teamID = parseTeamID(
                data: data,
                base: base,
                offset: codeSignature.offset,
                size: codeSignature.size,
                sliceEnd: end
            )
        }
    }

    private static func parseSegment64(
        data: Data,
        command: Int,
        base: Int,
        end: Int,
        le: Bool,
        sectionKeys: Set<String>?,
        sections: inout [MachOSectionDigest],
        seenSections: inout Set<MachOSectionDigest>
    ) {
        guard let nsects = u32(data, command + 64, le), nsects < 10_000 else { return }
        var section = command + 72
        for _ in 0..<nsects {
            guard section + 80 <= end else { return }
            let sectName = string(data, section, 16)
            let segName = string(data, section + 16, 16)
            guard let size64 = u64(data, section + 40, le),
                  let offset = u32(data, section + 48, le) else {
                section += 80
                continue
            }
            appendSection(
                data: data,
                base: base,
                end: end,
                segment: segName,
                section: sectName,
                size: Int64(size64),
                offset: Int(offset),
                sectionKeys: sectionKeys,
                sections: &sections,
                seenSections: &seenSections
            )
            section += 80
        }
    }

    private static func parseSegment32(
        data: Data,
        command: Int,
        base: Int,
        end: Int,
        le: Bool,
        sectionKeys: Set<String>?,
        sections: inout [MachOSectionDigest],
        seenSections: inout Set<MachOSectionDigest>
    ) {
        guard let nsects = u32(data, command + 48, le), nsects < 10_000 else { return }
        var section = command + 56
        for _ in 0..<nsects {
            guard section + 68 <= end else { return }
            let sectName = string(data, section, 16)
            let segName = string(data, section + 16, 16)
            guard let size = u32(data, section + 36, le),
                  let offset = u32(data, section + 40, le) else {
                section += 68
                continue
            }
            appendSection(
                data: data,
                base: base,
                end: end,
                segment: segName,
                section: sectName,
                size: Int64(size),
                offset: Int(offset),
                sectionKeys: sectionKeys,
                sections: &sections,
                seenSections: &seenSections
            )
            section += 68
        }
    }

    private static func appendSection(
        data: Data,
        base: Int,
        end: Int,
        segment: String,
        section: String,
        size: Int64,
        offset: Int,
        sectionKeys: Set<String>?,
        sections: inout [MachOSectionDigest],
        seenSections: inout Set<MachOSectionDigest>
    ) {
        guard size > 0, size <= Int64(Int.max), offset >= 0 else { return }
        let key = sectionKey(segment: segment, section: section, size: size)
        if let sectionKeys, !sectionKeys.contains(key) { return }
        guard offset <= end - base,
              size <= Int64(end - base - offset) else { return }
        let start = base + offset
        let count = Int(size)
        guard start + count <= data.count else { return }

        let digest = SHA256.hash(data: data.subdata(in: start..<(start + count)))
            .map { String(format: "%02x", $0) }
            .joined()
        let item = MachOSectionDigest(
            segment: segment,
            section: section,
            size: size,
            hash: digest
        )
        if seenSections.insert(item).inserted {
            sections.append(item)
        }
    }

    private static func parseTeamID(
        data: Data,
        base: Int,
        offset: Int,
        size: Int,
        sliceEnd: Int
    ) -> String? {
        let start = base + offset
        let end = min(start + size, sliceEnd)
        guard start >= 0, end <= data.count, start + 12 <= end else { return nil }
        guard let magic = be32(data, start), magic == 0xFADE0CC0,
              let count = be32(data, start + 8),
              count > 0, count < 64 else { return nil }

        for index in 0..<Int(count) {
            let entry = start + 12 + index * 8
            guard entry + 8 <= end,
                  let type = be32(data, entry),
                  let blobOffset = be32(data, entry + 4) else { continue }
            guard type == 0 else { continue }
            let blob = start + Int(blobOffset)
            guard blob + 52 <= end,
                  let codeMagic = be32(data, blob), codeMagic == 0xFADE0C02,
                  let version = be32(data, blob + 8) else { continue }
            guard version >= 0x20200,
                  let teamOffset = be32(data, blob + 48),
                  teamOffset > 0 else { continue }
            let teamStart = blob + Int(teamOffset)
            guard teamStart < end else { continue }
            let maxLength = min(64, end - teamStart)
            var bytes: [UInt8] = []
            for index in 0..<maxLength {
                let byte = data[teamStart + index]
                if byte == 0 { break }
                bytes.append(byte)
            }
            guard !bytes.isEmpty else { continue }
            let team = String(decoding: bytes, as: UTF8.self)
            if team.allSatisfy({ $0.isLetter || $0.isNumber }) {
                return team
            }
        }
        return nil
    }

    private static func string(_ data: Data, _ offset: Int, _ length: Int) -> String {
        guard offset >= 0, offset + length <= data.count else { return "" }
        var bytes: [UInt8] = []
        for index in 0..<length {
            let byte = data[offset + index]
            if byte == 0 { break }
            bytes.append(byte)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func le32(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }

    private static func be32(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return UInt32(data[offset]) << 24
            | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8
            | UInt32(data[offset + 3])
    }

    private static func u32(_ data: Data, _ offset: Int, _ littleEndian: Bool) -> UInt32? {
        littleEndian ? le32(data, offset) : be32(data, offset)
    }

    private static func u64(_ data: Data, _ offset: Int, _ littleEndian: Bool) -> UInt64? {
        guard offset >= 0, offset + 8 <= data.count else { return nil }
        var value: UInt64 = 0
        if littleEndian {
            for index in (0..<8).reversed() {
                value = value << 8 | UInt64(data[offset + index])
            }
        } else {
            for index in 0..<8 {
                value = value << 8 | UInt64(data[offset + index])
            }
        }
        return value
    }

    private static func be64(_ data: Data, _ offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= data.count else { return nil }
        var value: UInt64 = 0
        for index in 0..<8 {
            value = value << 8 | UInt64(data[offset + index])
        }
        return value
    }
}
