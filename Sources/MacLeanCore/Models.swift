import Foundation

public enum JunkCategory: String, CaseIterable, Codable, Sendable {
    case system
    case dev
    case browser
    case ai
    case updates
    case trash
    case large

    public var title: String {
        switch self {
        case .system: return "System junk"
        case .dev: return "Developer junk"
        case .browser: return "Browser caches"
        case .ai: return "AI tool data"
        case .updates: return "Update leftovers"
        case .trash: return "Trash bins"
        case .large: return "Large files"
        }
    }

    public var order: Int {
        JunkCategory.allCases.firstIndex(of: self) ?? 0
    }
}

public enum Risk: String, Codable, Sendable {
    case safe
    case caution
}

public struct JunkItem: Codable, Sendable, Hashable {
    public let path: String
    public let bytes: Int64
    public let files: Int
    public let ruleID: String
    public let ruleTitle: String
    public let category: JunkCategory
    public let risk: Risk
    public let autoselect: Bool
    public let requiresRoot: Bool
    public let isDirectory: Bool
    public let modified: Date?
    public let device: UInt64?
    public let inode: UInt64?

    public init(
        path: String,
        bytes: Int64,
        files: Int,
        ruleID: String,
        ruleTitle: String,
        category: JunkCategory,
        risk: Risk,
        autoselect: Bool,
        requiresRoot: Bool,
        isDirectory: Bool,
        modified: Date?,
        device: UInt64? = nil,
        inode: UInt64? = nil
    ) {
        self.path = path
        self.bytes = bytes
        self.files = files
        self.ruleID = ruleID
        self.ruleTitle = ruleTitle
        self.category = category
        self.risk = risk
        self.autoselect = autoselect
        self.requiresRoot = requiresRoot
        self.isDirectory = isDirectory
        self.modified = modified
        self.device = device
        self.inode = inode
    }
}

public struct ScanReport: Sendable {
    public let items: [JunkItem]

    public init(items: [JunkItem]) {
        self.items = items
    }

    public var totalBytes: Int64 {
        items.reduce(0) { $0 + $1.bytes }
    }

    public var totalFiles: Int {
        items.reduce(0) { $0 + $1.files }
    }

    public var autoselectedItems: [JunkItem] {
        items.filter(\.autoselect)
    }

    public var autoselectedBytes: Int64 {
        autoselectedItems.reduce(0) { $0 + $1.bytes }
    }

    public func items(in category: JunkCategory) -> [JunkItem] {
        items.filter { $0.category == category }
    }
}
