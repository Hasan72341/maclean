import Darwin
import Foundation

public enum PathCanon {
    public static func resolve(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        guard let resolved = realpath(path, nil) else {
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

public enum SafetyError: LocalizedError, Equatable {
    case forbiddenPath(String)
    case outsideAllowedRoot(String)
    case symbolicLink(String)
    case missing(String)
    case changed(String)

    public var errorDescription: String? {
        switch self {
        case .forbiddenPath(let path):
            return "refusing to touch protected path \(path)"
        case .outsideAllowedRoot(let path):
            return "\(path) is outside the rule's allowed roots"
        case .symbolicLink(let path):
            return "\(path) is a symbolic link"
        case .missing(let path):
            return "\(path) no longer exists"
        case .changed(let path):
            return "\(path) changed since it was scanned"
        }
    }
}

public enum Safety {
    public static func validate(
        path: String,
        roots: [URL],
        home: URL,
        allowRootItself: Bool = false,
        fileManager: FileManager = .default
    ) throws {
        guard !path.isEmpty, path != "/", !path.contains("/../") else {
            throw SafetyError.forbiddenPath(path)
        }

        let canonicalPath = PathCanon.resolve(path)
        let canonicalHome = PathCanon.resolve(home.standardizedFileURL.path)
        let forbidden: Set<String> = [
            "/", "/System", "/Library", "/Applications", "/Users", "/usr",
            "/bin", "/sbin", "/etc", "/private", "/var", "/opt", "/Volumes",
            "/cores", "/dev",
        ].map(PathCanon.resolve).reduce(into: [canonicalHome]) { $0.insert($1) }
        guard !forbidden.contains(canonicalPath) else {
            throw SafetyError.forbiddenPath(path)
        }

        let insideAllowedRoot = roots.contains { root in
            let rootPath = PathCanon.resolve(root.standardizedFileURL.path)
            if allowRootItself, canonicalPath == rootPath { return true }
            return canonicalPath.hasPrefix(rootPath + "/")
        }
        guard insideAllowedRoot else {
            throw SafetyError.outsideAllowedRoot(path)
        }

        guard fileManager.fileExists(atPath: path) else {
            throw SafetyError.missing(path)
        }

        let attributes = try? fileManager.attributesOfItem(atPath: path)
        if attributes?[.type] as? FileAttributeType == .typeSymbolicLink {
            throw SafetyError.symbolicLink(path)
        }
    }

    public static func validateIdentity(
        path: String,
        device: UInt64?,
        inode: UInt64?,
        fileManager: FileManager = .default
    ) throws {
        guard device != nil || inode != nil else { return }
        guard let attributes = try? fileManager.attributesOfItem(atPath: path) else {
            throw SafetyError.missing(path)
        }
        if let device,
           (attributes[.systemNumber] as? NSNumber)?.uint64Value != device {
            throw SafetyError.changed(path)
        }
        if let inode,
           (attributes[.systemFileNumber] as? NSNumber)?.uint64Value != inode {
            throw SafetyError.changed(path)
        }
    }
}
