import Foundation

public struct LensNode: Codable, Sendable {
    public let path: String
    public let name: String
    public let bytes: Int64
    public let files: Int
    public let isDirectory: Bool
    public let children: [LensNode]

    public init(
        path: String,
        name: String,
        bytes: Int64,
        files: Int,
        isDirectory: Bool,
        children: [LensNode]
    ) {
        self.path = path
        self.name = name
        self.bytes = bytes
        self.files = files
        self.isDirectory = isDirectory
        self.children = children
    }
}

public enum Lens {
    public static func scan(
        root: URL,
        depth: Int = 3,
        minBytes: Int64 = 0,
        fileManager: FileManager = .default
    ) -> LensNode {
        node(
            at: root,
            remainingDepth: max(0, depth),
            minBytes: minBytes,
            fileManager: fileManager
        )
    }

    private static func node(
        at url: URL,
        remainingDepth: Int,
        minBytes: Int64,
        fileManager: FileManager
    ) -> LensNode {
        let keys = FileSizer.keys
        guard let values = try? url.resourceValues(forKeys: keys) else {
            return LensNode(path: url.path, name: url.lastPathComponent, bytes: 0, files: 0, isDirectory: false, children: [])
        }
        if values.isSymbolicLink == true {
            return LensNode(path: url.path, name: url.lastPathComponent, bytes: 0, files: 0, isDirectory: false, children: [])
        }

        let isDirectory = values.isDirectory ?? false
        if !isDirectory {
            let size = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            return LensNode(
                path: url.path,
                name: url.lastPathComponent,
                bytes: size,
                files: 1,
                isDirectory: false,
                children: []
            )
        }

        if remainingDepth == 0 {
            let size = FileSizer.measure(url, fileManager: fileManager)
            return LensNode(
                path: url.path,
                name: url.lastPathComponent,
                bytes: size.bytes,
                files: size.files,
                isDirectory: true,
                children: []
            )
        }

        guard let entries = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else {
            return LensNode(path: url.path, name: url.lastPathComponent, bytes: 0, files: 0, isDirectory: true, children: [])
        }

        var children: [LensNode] = []
        var bytes: Int64 = 0
        var files = 0

        for entry in entries {
            let child = node(
                at: entry,
                remainingDepth: remainingDepth - 1,
                minBytes: minBytes,
                fileManager: fileManager
            )
            guard child.bytes >= minBytes || child.files > 0 else { continue }
            children.append(child)
            bytes += child.bytes
            files += child.files
        }

        children.sort { $0.bytes > $1.bytes }
        return LensNode(
            path: url.path,
            name: url.lastPathComponent,
            bytes: bytes,
            files: files,
            isDirectory: true,
            children: children
        )
    }
}
