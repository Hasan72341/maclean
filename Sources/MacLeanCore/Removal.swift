import Foundation

public enum RemovalOutcome {
    case trashed
    case deleted
}

public enum Removal {
    public static func remove(
        path: String,
        permanent: Bool,
        home: URL,
        fileManager: FileManager = .default
    ) throws -> RemovalOutcome {
        if permanent || isInsideTrash(path, home: home) {
            try fileManager.removeItem(atPath: path)
            return .deleted
        }
        try fileManager.trashItem(
            at: URL(fileURLWithPath: path),
            resultingItemURL: nil
        )
        return .trashed
    }

    public static func isInsideTrash(_ path: String, home: URL) -> Bool {
        if path.hasPrefix(home.appendingPathComponent(".Trash").path + "/") {
            return true
        }
        return path.hasPrefix("/Volumes/") && path.contains("/.Trashes/")
    }
}
