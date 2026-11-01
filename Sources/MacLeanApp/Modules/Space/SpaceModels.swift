import AppKit
import Foundation
import ImageIO
import MacLeanCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - File model

struct SpaceFile: Sendable, Hashable, Identifiable {
    var path: String
    var bytes: Int64
    var modified: Date?
    var created: Date?
    var accessed: Date?
    var added: Date?
    var isDirectory: Bool = false
    var files: Int = 1
    var note: String = ""

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var ext: String { (path as NSString).pathExtension.lowercased() }
    var kind: SpaceKind { isDirectory ? .other : SpaceKind.classify(ext) }
    var ageReference: Date? { added ?? modified }

    static let keys: Set<URLResourceKey> = [
        .isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .isPackageKey,
        .fileSizeKey, .totalFileAllocatedSizeKey,
        .contentModificationDateKey, .creationDateKey, .contentAccessDateKey, .addedToDirectoryDateKey,
    ]

    static func make(_ url: URL, _ values: URLResourceValues, measureDirectories: Bool = false) -> SpaceFile {
        let isDir = values.isDirectory ?? false
        var bytes = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        var files = 1
        if isDir && measureDirectories {
            let size = FileSizer.measure(url)
            bytes = size.bytes
            files = size.files
        }
        return SpaceFile(
            path: url.path,
            bytes: bytes,
            modified: values.contentModificationDate,
            created: values.creationDate,
            accessed: values.contentAccessDate,
            added: values.addedToDirectoryDate,
            isDirectory: isDir,
            files: files
        )
    }

    static func load(_ path: String, measure: Bool = true) -> SpaceFile? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        return make(url, values, measureDirectories: measure)
    }

    static func from(_ artifact: Artifact) -> SpaceFile {
        SpaceFile(
            path: artifact.path,
            bytes: artifact.bytes,
            modified: artifact.modified,
            isDirectory: artifact.isDirectory,
            files: artifact.files,
            note: artifact.detail
        )
    }
}

// MARK: - Kinds

enum SpaceKind: String, CaseIterable, Sendable, Hashable, Identifiable {
    case video, audio, images, documents, archives, code, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .video: return "Video"
        case .audio: return "Audio"
        case .images: return "Images"
        case .documents: return "Documents"
        case .archives: return "Archives & Installers"
        case .code: return "Code"
        case .other: return "Other"
        }
    }

    var icon: String {
        switch self {
        case .video: return "film"
        case .audio: return "music.note"
        case .images: return "photo"
        case .documents: return "doc.text"
        case .archives: return "archivebox"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .other: return "doc"
        }
    }

    var color: Color {
        switch self {
        case .video: return Theme.accent
        case .audio: return Theme.info
        case .images: return Theme.success
        case .documents: return Theme.warning
        case .archives: return Theme.danger
        case .code: return Color(nsColor: .systemPurple)
        case .other: return Theme.faint
        }
    }

    static let map: [String: SpaceKind] = {
        var m: [String: SpaceKind] = [:]
        for e in ["mp4", "mov", "m4v", "mkv", "avi", "wmv", "flv", "webm", "mpg", "mpeg", "3gp", "mts", "m2ts", "prores", "braw"] { m[e] = .video }
        for e in ["mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "ogg", "opus", "alac", "caf", "mid", "midi", "logicx", "band"] { m[e] = .audio }
        for e in ["jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "bmp", "webp", "raw", "cr2", "cr3", "nef", "arw", "dng", "orf", "raf", "psd", "ai", "svg", "ico", "icns", "sketch", "fig", "xcf"] { m[e] = .images }
        for e in ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "txt", "rtf", "rtfd", "md", "csv", "tsv", "odt", "ods", "odp", "epub", "mobi", "tex", "log"] { m[e] = .documents }
        for e in SpaceKind.archiveExtensions { m[e] = .archives }
        for e in ["swift", "m", "mm", "h", "c", "cc", "cpp", "hpp", "js", "jsx", "ts", "tsx", "py", "rb", "go", "rs", "java", "kt", "php", "cs", "json", "yaml", "yml", "xml", "html", "css", "scss", "sh", "zsh", "sql", "ipynb", "lua", "dart", "vue", "toml", "gradle", "o", "a", "dylib", "so", "class", "jar", "wasm"] { m[e] = .code }
        return m
    }()

    static let archiveExtensions: Set<String> = ["zip", "tar", "gz", "tgz", "bz2", "xz", "rar", "7z", "pkg", "mpkg", "dmg", "iso", "xip", "sparseimage", "zst", "lz", "lzma", "cab"]
    static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "zip", "xip", "iso"]

    static func classify(_ ext: String) -> SpaceKind { map[ext] ?? .other }
}

// MARK: - Age buckets

enum SpaceAgeBucket: String, CaseIterable, Sendable, Identifiable {
    case week, month, quarter, year, older, unknown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .week: return "Last 7 days"
        case .month: return "7–30 days"
        case .quarter: return "1–3 months"
        case .year: return "3–12 months"
        case .older: return "Over a year"
        case .unknown: return "Unknown date"
        }
    }

    static func of(_ date: Date?, now: Date = Date()) -> SpaceAgeBucket {
        guard let date else { return .unknown }
        let days = now.timeIntervalSince(date) / 86_400
        switch days {
        case ..<7: return .week
        case ..<30: return .month
        case ..<90: return .quarter
        case ..<365: return .year
        default: return .older
        }
    }
}

// MARK: - Safety

enum SpaceSafety {
    static let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    static let protectedHomeChildren: Set<String> = [
        "Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures",
        "Public", "Applications", "Developer", "Sites", ".Trash", "iCloud Drive (Archive)",
    ]

    /// Returns a reason when a path must never be offered for removal.
    static func refusal(_ path: String) -> String? {
        let resolved = PathCanon.resolve(path)
        if resolved == "/" || resolved == home { return "the home folder itself" }
        let parent = (resolved as NSString).deletingLastPathComponent
        let name = (resolved as NSString).lastPathComponent
        if parent == home && protectedHomeChildren.contains(name) { return "a top-level home folder" }
        let library = home + "/Library"
        if parent == library { return "a top-level Library folder" }
        if parent == library + "/CloudStorage" || resolved == library + "/Mobile Documents/com~apple~CloudDocs" {
            return "a cloud provider root"
        }
        if parent == "/Volumes" { return "a volume root" }
        if !(resolved.hasPrefix(home + "/") || resolved.hasPrefix("/Volumes/") || resolved.hasPrefix("/Users/Shared/") || resolved.hasPrefix("/Applications/")) {
            return "outside the locations MacLean may remove"
        }
        return nil
    }

    static func canRemove(_ path: String) -> Bool { refusal(path) == nil }
}

// MARK: - Progress + walking

struct SpaceProgressInfo: Sendable, Equatable {
    var scanned: Int = 0
    var matched: Int = 0
    var current: String = ""
}

final class SpaceProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var info = SpaceProgressInfo()
    private var stop = false

    func tick(_ path: String, matched: Int) {
        lock.lock()
        info.scanned += 1
        info.matched = matched
        if info.scanned % 64 == 0 { info.current = path }
        lock.unlock()
    }

    var snapshot: SpaceProgressInfo {
        lock.lock(); defer { lock.unlock() }
        return info
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return stop
    }

    func cancel() {
        lock.lock(); stop = true; lock.unlock()
    }
}

enum SpaceWalker {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    /// Enumerates regular files (and optionally directories) below `roots`,
    /// skipping hidden items, package contents, ~/Library and ~/.Trash.
    static func walk(
        roots: [URL],
        skipLibrary: Bool = true,
        includeDirectories: Bool = false,
        progress: SpaceProgress,
        limit: Int = 3_000_000,
        visit: (URL, URLResourceValues) -> Void
    ) {
        let fm = FileManager.default
        let skip: Set<String> = skipLibrary
            ? [home.appendingPathComponent("Library").path, home.appendingPathComponent(".Trash").path]
            : [home.appendingPathComponent(".Trash").path]
        var seen = 0
        for root in roots {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: Array(SpaceFile.keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }
            for case let url as URL in enumerator {
                if progress.isCancelled { return }
                seen += 1
                if seen > limit { return }
                if skip.contains(url.path) {
                    enumerator.skipDescendants()
                    continue
                }
                guard let values = try? url.resourceValues(forKeys: SpaceFile.keys) else { continue }
                if values.isSymbolicLink == true { continue }
                if values.isDirectory == true {
                    if values.isPackage == true { enumerator.skipDescendants() }
                    if includeDirectories { visit(url, values) }
                    continue
                }
                visit(url, values)
            }
        }
    }
}

// MARK: - Aggregates

struct SpaceFolderUsage: Sendable, Identifiable, Hashable {
    var name: String
    var path: String
    var bytes: Int64
    var files: Int
    var icon: String
    var id: String { path }
}

struct SpaceKindStat: Sendable, Hashable {
    var bytes: Int64 = 0
    var count: Int = 0
}

struct SpaceTypeReport: Sendable {
    var root: String
    var stats: [String: SpaceKindStat] = [:]
    var files: [String: [SpaceFile]] = [:]
    var extensions: [String: SpaceKindStat] = [:]
    var totalBytes: Int64 { stats.values.reduce(0) { $0 + $1.bytes } }
    var totalCount: Int { stats.values.reduce(0) { $0 + $1.count } }
}

struct SpaceVolume: Sendable, Identifiable, Hashable {
    var name: String
    var path: String
    var total: Int64
    var available: Int64
    var important: Int64
    var format: String
    var isRemovable: Bool
    var isEjectable: Bool
    var isInternal: Bool
    var isRoot: Bool
    var id: String { path }
    var used: Int64 { max(0, total - available) }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    static func list() -> [SpaceVolume] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey, .volumeIsRemovableKey,
            .volumeIsEjectableKey, .volumeIsInternalKey, .volumeLocalizedFormatDescriptionKey,
            .volumeIsRootFileSystemKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return SpaceVolume(
                name: v.volumeName ?? url.lastPathComponent,
                path: url.path,
                total: Int64(v.volumeTotalCapacity ?? 0),
                available: Int64(v.volumeAvailableCapacity ?? 0),
                important: v.volumeAvailableCapacityForImportantUsage ?? 0,
                format: v.volumeLocalizedFormatDescription ?? "",
                isRemovable: v.volumeIsRemovable ?? false,
                isEjectable: v.volumeIsEjectable ?? false,
                isInternal: v.volumeIsInternal ?? false,
                isRoot: v.volumeIsRootFileSystem ?? false
            )
        }
    }
}

struct SpaceFileDetail: Sendable {
    var file: SpaceFile
    var typeDescription: String
    var permissions: String
    var owner: String
    var group: String
    var isPackage: Bool
    var isHidden: Bool
    var isWritable: Bool
    var uti: String

    static func load(_ path: String) -> SpaceFileDetail? {
        guard let file = SpaceFile.load(path, measure: true) else { return nil }
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey, .isPackageKey, .isHiddenKey, .typeIdentifierKey])
        let attrs = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        return SpaceFileDetail(
            file: file,
            typeDescription: values?.localizedTypeDescription ?? (file.isDirectory ? "Folder" : "File"),
            permissions: permissionString(mode, directory: file.isDirectory) + String(format: " (%o)", mode),
            owner: attrs[.ownerAccountName] as? String ?? "—",
            group: attrs[.groupOwnerAccountName] as? String ?? "—",
            isPackage: values?.isPackage ?? false,
            isHidden: values?.isHidden ?? false,
            isWritable: FileManager.default.isWritableFile(atPath: path),
            uti: values?.typeIdentifier ?? "—"
        )
    }

    static func permissionString(_ mode: Int, directory: Bool) -> String {
        let chars = ["r", "w", "x"]
        var out = directory ? "d" : "-"
        for shift in stride(from: 6, through: 0, by: -3) {
            for (i, c) in chars.enumerated() {
                out += (mode >> (shift + 2 - i)) & 1 == 1 ? c : "-"
            }
        }
        return out
    }
}

enum SpaceThumb {
    /// PNG thumbnail data for an image file, generated off-main.
    static func make(_ path: String, maxPixels: Int = 220) -> Data? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    static func dimensions(_ path: String) -> String? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return "\(w) × \(h)"
    }
}

enum SpacePaths {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path

    static func display(_ path: String) -> String {
        if path == home { return "Home" }
        return (path as NSString).lastPathComponent
    }

    static func url(_ name: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(name)
    }
}
