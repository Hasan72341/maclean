import Foundation

// MARK: - Kinds

/// Coarse content categories used to colour and break down a folder.
public enum LensKind: Int, CaseIterable, Sendable, Hashable, Codable {
    case apps, video, audio, images, documents, archives, developer, other

    public var title: String {
        switch self {
        case .apps: return "Apps & bundles"
        case .video: return "Video"
        case .audio: return "Audio"
        case .images: return "Images"
        case .documents: return "Documents"
        case .archives: return "Archives & disk images"
        case .developer: return "Developer"
        case .other: return "Other"
        }
    }

    static let byExtension: [String: LensKind] = {
        var map: [String: LensKind] = [:]
        func add(_ kind: LensKind, _ list: String) { for e in list.split(separator: " ") { map[String(e)] = kind } }
        add(.video, "mp4 mov m4v mkv avi wmv flv webm mpg mpeg 3gp mts m2ts braw r3d")
        add(.audio, "mp3 m4a aac wav aiff aif flac ogg opus alac caf mid midi m4p")
        add(.images, "jpg jpeg png heic heif gif tif tiff bmp webp raw cr2 cr3 nef arw dng orf raf psd psb ai svg ico icns exr hdr")
        add(.documents, "pdf doc docx xls xlsx ppt pptx pages numbers key txt rtf md csv tsv odt ods odp epub mobi tex log json xml")
        add(.archives, "zip tar gz tgz bz2 xz rar 7z pkg mpkg dmg iso xip sparseimage sparsebundle zst lz lzma cab img vmdk vdi qcow2 hdd")
        add(.developer, "swift m mm h c cc cpp hpp js jsx ts tsx py rb go rs java kt php cs yaml yml html css sh sql ipynb o a dylib so class jar wasm pyc node map dSYM xcarchive")
        return map
    }()

    public static func classify(name: String, isPackage: Bool) -> LensKind {
        let ext = (name as NSString).pathExtension.lowercased()
        if isPackage {
            switch ext {
            case "app", "appex", "framework", "bundle", "plugin", "kext", "prefpane", "qlgenerator", "saver": return .apps
            case "photoslibrary", "imovielibrary": return .images
            case "fcpbundle", "tvlibrary": return .video
            case "musiclibrary", "logicx", "band": return .audio
            case "xcarchive", "dsym", "playground", "xcodeproj", "xcworkspace": return .developer
            case "sparsebundle": return .archives
            default: return .other
            }
        }
        return byExtension[ext] ?? .other
    }
}

// MARK: - Tree

/// One entry in a Space Lens tree. Built off the main thread by
/// `LensScanner`; afterwards it is only mutated by `remove(_:)` on the
/// caller's thread (the UI uses the main actor).
public final class LensItem: @unchecked Sendable, Identifiable, Hashable {
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let isPackage: Bool
    /// A synthetic entry that stands for many small items of the parent.
    public let isAggregate: Bool
    public fileprivate(set) var aggregateCount: Int
    public let kind: LensKind
    public fileprivate(set) var bytes: Int64
    public fileprivate(set) var files: Int
    public fileprivate(set) var folders: Int
    /// Newest modification date found in the subtree.
    public fileprivate(set) var modified: Date?
    public fileprivate(set) var children: [LensItem]
    /// Bytes per `LensKind.rawValue` for the whole subtree.
    public fileprivate(set) var kindBytes: [Int64]
    /// Folders in the subtree that could not be read.
    public fileprivate(set) var unreadable: Int
    public fileprivate(set) weak var parent: LensItem?

    public var id: String { path }

    init(path: String, name: String, isDirectory: Bool, isPackage: Bool, isAggregate: Bool = false, aggregateCount: Int = 0,
         kind: LensKind, bytes: Int64, files: Int, folders: Int, modified: Date?, children: [LensItem], kindBytes: [Int64], unreadable: Int) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isAggregate = isAggregate
        self.aggregateCount = aggregateCount
        self.kind = kind
        self.bytes = bytes
        self.files = files
        self.folders = folders
        self.modified = modified
        self.children = children
        self.kindBytes = kindBytes
        self.unreadable = unreadable
        for child in children { child.parent = self }
    }

    public static func == (lhs: LensItem, rhs: LensItem) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

    /// Entries that can be opened or removed (everything except aggregates).
    public var canDrill: Bool { isDirectory && !isAggregate && !children.isEmpty }

    /// Finds the item at `path` in this subtree.
    public func find(_ target: String) -> LensItem? {
        if target == path { return self }
        let prefix = path.hasSuffix("/") ? path : path + "/"
        guard target.hasPrefix(prefix) else { return nil }
        for child in children where !child.isAggregate {
            if target == child.path || target.hasPrefix(child.path + "/") { return child.find(target) }
        }
        return nil
    }

    /// Ancestors from the tree root down to this item.
    public var lineage: [LensItem] {
        var out: [LensItem] = [self]
        var current = parent
        while let item = current { out.insert(item, at: 0); current = item.parent }
        return out
    }

    /// Detaches this item and subtracts its totals from every ancestor.
    public func remove() {
        guard let parent else { return }
        parent.children.removeAll { $0 === self }
        var current: LensItem? = parent
        while let item = current {
            item.bytes = max(0, item.bytes - bytes)
            item.files = max(0, item.files - files)
            item.folders = max(0, item.folders - folders - (isDirectory ? 1 : 0))
            for (index, value) in kindBytes.enumerated() where index < item.kindBytes.count {
                item.kindBytes[index] = max(0, item.kindBytes[index] - value)
            }
            item.children.sort { $0.bytes > $1.bytes }
            current = item.parent
        }
        self.parent = nil
    }

    /// Removes one item that is folded into this folder's "smaller items"
    /// entry (the item itself is not part of the tree).
    public func removeFolded(bytes removed: Int64, files removedFiles: Int, folders removedFolders: Int, kind: LensKind?) {
        guard let aggregate = children.first(where: \.isAggregate) else { return }
        aggregate.aggregateCount = max(0, aggregate.aggregateCount - 1)
        var current: LensItem? = aggregate
        while let item = current {
            item.bytes = max(0, item.bytes - removed)
            item.files = max(0, item.files - removedFiles)
            item.folders = max(0, item.folders - removedFolders)
            if let kind, kind.rawValue < item.kindBytes.count {
                item.kindBytes[kind.rawValue] = max(0, item.kindBytes[kind.rawValue] - removed)
            }
            current = item.parent
        }
        if aggregate.aggregateCount == 0 { children.removeAll { $0 === aggregate } }
        children.sort { $0.bytes > $1.bytes }
    }

    /// Legacy value tree for the CLI renderer.
    public func node(depth: Int) -> LensNode {
        LensNode(path: path, name: isAggregate ? "\(aggregateCount) smaller items" : name, bytes: bytes, files: files,
                 isDirectory: isDirectory,
                 children: depth > 0 ? children.map { $0.node(depth: depth - 1) } : [])
    }
}

/// A large file seen during the scan.
public struct LensFile: Sendable, Hashable, Identifiable, Codable {
    public let path: String
    public let bytes: Int64
    public let modified: Date?
    public let kind: LensKind
    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
}

// MARK: - Progress

/// Live counters a UI can poll while `LensScanner` runs, and the cancel switch.
public final class LensProgress: @unchecked Sendable {
    public struct Snapshot: Sendable {
        public let files: Int
        public let folders: Int
        public let bytes: Int64
        public let unreadable: Int
        public let current: String

        public init(files: Int, folders: Int, bytes: Int64, unreadable: Int, current: String) {
            self.files = files; self.folders = folders; self.bytes = bytes; self.unreadable = unreadable; self.current = current
        }
    }

    private let lock = NSLock()
    private var files = 0
    private var folders = 0
    private var bytes: Int64 = 0
    private var unreadable = 0
    private var current = ""
    private var cancelled = false

    public init() {}

    public var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(files: files, folders: folders, bytes: bytes, unreadable: unreadable, current: current)
    }

    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func add(files: Int, bytes: Int64, folder: String, unreadable: Int) {
        lock.lock()
        self.files += files
        self.bytes += bytes
        self.folders += 1
        self.unreadable += unreadable
        self.current = folder
        lock.unlock()
    }
}

// MARK: - Scanner

public struct LensOptions: Sendable {
    /// Files at least this large are kept as their own entries.
    public var keepFileBytes: Int64 = 1024 * 1024
    /// The N largest files of every folder are kept regardless of size.
    public var keepTopFiles = 12
    /// Folders at least this large are kept as their own entries.
    public var keepFolderBytes: Int64 = 1024 * 1024
    /// The N largest sub-folders of every folder are kept regardless of size.
    public var keepTopFolders = 16
    /// Files at least this large go into the "largest files" list.
    public var largestMinBytes: Int64 = 20 * 1024 * 1024
    public var largestCount = 400
    /// Descend into other mounted volumes below the root.
    public var crossVolumes = false
    /// Parallelise the walk for the first N levels.
    public var parallelDepth = 3

    public init() {}
}

public struct LensResult: Sendable {
    public let root: LensItem
    public let largest: [LensFile]
    public let duration: TimeInterval
    public let unreadableSamples: [String]
    public let cancelled: Bool
    /// Volume capacity of the scanned root, for "not scanned" / free space segments.
    public let volumeTotal: Int64?
    public let volumeAvailable: Int64?
}

public enum LensScanner {
    /// Lists and measures the entries folded into `folder`'s "smaller items"
    /// entry, so they can be reviewed and removed individually.
    public static func foldedItems(of folder: LensItem, fileManager: FileManager = .default) -> [LensItem] {
        let kept = Set(folder.children.filter { !$0.isAggregate }.map(\.name))
        guard let entries = try? fileManager.contentsOfDirectory(at: URL(fileURLWithPath: folder.path), includingPropertiesForKeys: keys, options: []) else { return [] }
        var out: [LensItem] = []
        for entry in entries where !kept.contains(entry.lastPathComponent) {
            guard let values = try? entry.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else { continue }
            let name = entry.lastPathComponent
            let path = folder.path == "/" ? "/" + name : folder.path + "/" + name
            if values.isDirectory == true {
                let size = FileSizer.measure(URL(fileURLWithPath: path), fileManager: fileManager)
                out.append(LensItem(path: path, name: name, isDirectory: true, isPackage: values.isPackage ?? false,
                                    kind: LensKind.classify(name: name, isPackage: values.isPackage ?? false),
                                    bytes: size.bytes, files: size.files, folders: 0, modified: size.modified ?? values.contentModificationDate,
                                    children: [], kindBytes: [], unreadable: 0))
            } else {
                let bytes = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
                out.append(LensItem(path: path, name: name, isDirectory: false, isPackage: false,
                                    kind: LensKind.classify(name: name, isPackage: false), bytes: bytes, files: 1, folders: 0,
                                    modified: values.contentModificationDate, children: [], kindBytes: [], unreadable: 0))
            }
        }
        return out.sorted { $0.bytes > $1.bytes }
    }

    /// Paths that never belong to a scan of `/`: the APFS system volume group
    /// (already visible through firmlinks), other mounts, and virtual filesystems.
    static let excludedFromRoot: Set<String> = ["/System/Volumes", "/Volumes", "/dev", "/net", "/home", "/cores",
                                                 "/.nofollow", "/.resolve", "/.vol"]

    static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .isVolumeKey, .totalFileAllocatedSizeKey,
        .fileAllocatedSizeKey, .fileSizeKey, .contentModificationDateKey, .linkCountKey, .fileResourceIdentifierKey,
    ]

    public static func scan(root: URL, options: LensOptions = LensOptions(), progress: LensProgress = LensProgress()) -> LensResult {
        let started = Date()
        let rootURL = root.standardizedFileURL.resolvingSymlinksInPath()
        let context = Context(options: options, progress: progress, rootPath: rootURL.path)
        let values = try? rootURL.resourceValues(forKeys: [.isPackageKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let item = context.directory(rootURL, name: rootURL.path == "/" ? "Macintosh HD" : rootURL.lastPathComponent,
                                     isPackage: values?.isPackage ?? false, depth: 0)
        let important: Int64? = values?.volumeAvailableCapacityForImportantUsage
        let available: Int64? = important ?? values?.volumeAvailableCapacity.map { Int64($0) }
        return LensResult(
            root: item,
            largest: context.largestFiles(),
            duration: Date().timeIntervalSince(started),
            unreadableSamples: context.unreadableSamples(),
            cancelled: progress.isCancelled,
            volumeTotal: values?.volumeTotalCapacity.map { Int64($0) },
            volumeAvailable: available
        )
    }

    final class Context: @unchecked Sendable {
        let options: LensOptions
        let progress: LensProgress
        let rootPath: String
        let fileManager = FileManager()
        private let lock = NSLock()
        private var hardLinks = Set<String>()
        private var visitedFolders = Set<String>()
        private var largest: [LensFile] = []
        private var unreadable: [String] = []

        init(options: LensOptions, progress: LensProgress, rootPath: String) {
            self.options = options
            self.progress = progress
            self.rootPath = rootPath
        }

        func largestFiles() -> [LensFile] {
            lock.lock(); defer { lock.unlock() }
            return Array(largest.sorted { $0.bytes > $1.bytes }.prefix(options.largestCount))
        }

        func unreadableSamples() -> [String] {
            lock.lock(); defer { lock.unlock() }
            return Array(unreadable.prefix(50))
        }

        /// True the first time a folder (by volume + file ID) is entered. Aliases
        /// of the same folder (virtual path prefixes, bind-style mounts, loops)
        /// are then walked only once.
        private func firstVisit(_ id: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return visitedFolders.insert(id).inserted
        }

        /// True the first time a multiply-linked file is seen.
        private func firstLink(_ id: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return hardLinks.insert(id).inserted
        }

        private func noteLarge(_ files: [LensFile]) {
            guard !files.isEmpty else { return }
            lock.lock()
            largest.append(contentsOf: files)
            if largest.count > options.largestCount * 4 {
                largest = Array(largest.sorted { $0.bytes > $1.bytes }.prefix(options.largestCount))
            }
            lock.unlock()
        }

        private func noteUnreadable(_ path: String) {
            lock.lock()
            if unreadable.count < 200 { unreadable.append(path) }
            lock.unlock()
        }

        func directory(_ url: URL, name: String, isPackage: Bool, depth: Int) -> LensItem {
            // Foundation's URL resource caches are autoreleased; drain them per
            // folder or a million-file walk keeps gigabytes alive until the end.
            autoreleasepool { walk(url, name: name, isPackage: isPackage, depth: depth) }
        }

        private func walk(_ url: URL, name: String, isPackage: Bool, depth: Int) -> LensItem {
            let path = url.path
            var kindBytes = [Int64](repeating: 0, count: LensKind.allCases.count)
            let ownKind = LensKind.classify(name: name, isPackage: isPackage)

            guard !progress.isCancelled,
                  let entries = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: LensScanner.keys, options: [])
            else {
                if !progress.isCancelled {
                    noteUnreadable(path)
                    progress.add(files: 0, bytes: 0, folder: path, unreadable: 1)
                }
                return LensItem(path: path, name: name, isDirectory: true, isPackage: isPackage, kind: ownKind, bytes: 0, files: 0,
                                folders: 0, modified: nil, children: [], kindBytes: kindBytes, unreadable: progress.isCancelled ? 0 : 1)
            }

            var fileItems: [LensItem] = []
            var subdirs: [(URL, String, Bool)] = []
            var bytes: Int64 = 0
            var newest: Date?
            var large: [LensFile] = []

            for entry in entries {
                guard let values = try? entry.resourceValues(forKeys: Set(LensScanner.keys)) else { continue }
                if values.isSymbolicLink == true { continue }
                let entryName = entry.lastPathComponent
                // Child paths are derived from the parent's string so the whole
                // tree shares the root's spelling (/var vs /private/var).
                let childPath = path == "/" ? "/" + entryName : path + "/" + entryName
                if values.isDirectory == true {
                    if path == "/" || rootPath == "/" {
                        if LensScanner.excludedFromRoot.contains(childPath) { continue }
                    }
                    if values.isVolume == true, !options.crossVolumes, childPath != rootPath { continue }
                    if let identifier = values.fileResourceIdentifier, !firstVisit(String(describing: identifier)) { continue }
                    subdirs.append((URL(fileURLWithPath: childPath, isDirectory: true), entryName, values.isPackage ?? false))
                    continue
                }
                var size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
                if (values.linkCount ?? 1) > 1, let identifier = values.fileResourceIdentifier {
                    if !firstLink(String(describing: identifier)) { size = 0 }
                }
                let kind = LensKind.classify(name: entryName, isPackage: false)
                kindBytes[kind.rawValue] += size
                bytes += size
                if let modified = values.contentModificationDate, newest.map({ modified > $0 }) ?? true { newest = modified }
                if size >= options.largestMinBytes {
                    large.append(LensFile(path: childPath, bytes: size, modified: values.contentModificationDate, kind: kind))
                }
                fileItems.append(LensItem(path: childPath, name: entryName, isDirectory: false, isPackage: false, kind: kind,
                                          bytes: size, files: 1, folders: 0, modified: values.contentModificationDate,
                                          children: [], kindBytes: [], unreadable: 0))
            }
            noteLarge(large)
            progress.add(files: fileItems.count, bytes: bytes, folder: path, unreadable: 0)

            // Sub-folders: in parallel near the top of the tree, serially below.
            var dirItems = [LensItem?](repeating: nil, count: subdirs.count)
            if depth < options.parallelDepth, subdirs.count > 1 {
                let box = ItemBox(count: subdirs.count)
                let work = subdirs
                DispatchQueue.concurrentPerform(iterations: work.count) { index in
                    let (childURL, childName, childPackage) = work[index]
                    box.set(index, self.directory(childURL, name: childName, isPackage: childPackage, depth: depth + 1))
                }
                dirItems = box.items
            } else {
                for (index, (childURL, childName, childPackage)) in subdirs.enumerated() {
                    dirItems[index] = directory(childURL, name: childName, isPackage: childPackage, depth: depth + 1)
                }
            }

            var files = fileItems.count
            var folders = 0
            var unreadable = 0
            var folderItems: [LensItem] = []
            for case let item? in dirItems {
                bytes += item.bytes
                files += item.files
                folders += item.folders + 1
                unreadable += item.unreadable
                if let modified = item.modified, newest.map({ modified > $0 }) ?? true { newest = modified }
                for (index, value) in item.kindBytes.enumerated() { kindBytes[index] += value }
                // A package (app, library bundle) counts as its own kind as a whole.
                if item.isPackage, item.kind != .other {
                    for index in kindBytes.indices where index != item.kind.rawValue {
                        let moved = min(kindBytes[index], item.kindBytes[index])
                        kindBytes[index] -= moved
                        kindBytes[item.kind.rawValue] += moved
                    }
                }
                folderItems.append(item)
            }

            let children = trim(folders: folderItems, files: fileItems, parent: path)
            return LensItem(path: path, name: name, isDirectory: true, isPackage: isPackage, kind: ownKind, bytes: bytes,
                            files: files, folders: folders, modified: newest, children: children, kindBytes: kindBytes,
                            unreadable: unreadable)
        }

        /// Keeps large entries individually and folds the long tail into one
        /// aggregate so huge trees (node_modules, caches) stay small in memory.
        private func trim(folders: [LensItem], files: [LensItem], parent: String) -> [LensItem] {
            let sortedFolders = folders.sorted { $0.bytes > $1.bytes }
            let sortedFiles = files.sorted { $0.bytes > $1.bytes }
            var kept: [LensItem] = []
            var restBytes: Int64 = 0
            var restFiles = 0
            var restFolders = 0
            var restCount = 0
            var restKinds = [Int64](repeating: 0, count: LensKind.allCases.count)
            var restModified: Date?

            func fold(_ item: LensItem) {
                restBytes += item.bytes
                restFiles += item.files
                restFolders += item.folders + (item.isDirectory ? 1 : 0)
                restCount += 1
                if item.isDirectory {
                    for (index, value) in item.kindBytes.enumerated() { restKinds[index] += value }
                } else {
                    restKinds[item.kind.rawValue] += item.bytes
                }
                if let m = item.modified, restModified.map({ m > $0 }) ?? true { restModified = m }
            }

            for (index, item) in sortedFolders.enumerated() {
                if index < options.keepTopFolders || item.bytes >= options.keepFolderBytes { kept.append(item) } else { fold(item) }
            }
            for (index, item) in sortedFiles.enumerated() {
                if index < options.keepTopFiles || item.bytes >= options.keepFileBytes { kept.append(item) } else { fold(item) }
            }
            if restCount > 0 {
                kept.append(LensItem(path: parent + "/\u{2026}smaller-items", name: "\(restCount) smaller items",
                                     isDirectory: false, isPackage: false, isAggregate: true, aggregateCount: restCount,
                                     kind: .other, bytes: restBytes, files: restFiles, folders: restFolders,
                                     modified: restModified, children: [], kindBytes: restKinds, unreadable: 0))
            }
            return kept.sorted { $0.bytes > $1.bytes }
        }
    }

    private final class ItemBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [LensItem?]
        init(count: Int) { storage = Array(repeating: nil, count: count) }
        func set(_ index: Int, _ item: LensItem) { lock.lock(); storage[index] = item; lock.unlock() }
        var items: [LensItem?] { lock.lock(); defer { lock.unlock() }; return storage }
    }
}
