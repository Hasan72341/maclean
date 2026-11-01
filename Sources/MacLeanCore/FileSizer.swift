import Foundation

public struct SizeInfo: Sendable {
    public let bytes: Int64
    public let files: Int
    public let isDirectory: Bool
    public let modified: Date?
    public let isSymbolicLink: Bool
    public let device: UInt64?
    public let inode: UInt64?

    public init(
        bytes: Int64,
        files: Int,
        isDirectory: Bool,
        modified: Date?,
        isSymbolicLink: Bool,
        device: UInt64? = nil,
        inode: UInt64? = nil
    ) {
        self.bytes = bytes
        self.files = files
        self.isDirectory = isDirectory
        self.modified = modified
        self.isSymbolicLink = isSymbolicLink
        self.device = device
        self.inode = inode
    }

    public static let empty = SizeInfo(bytes: 0, files: 0, isDirectory: false, modified: nil, isSymbolicLink: false)
}

public enum FileSizer {
    static let keys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .isRegularFileKey,
        .totalFileAllocatedSizeKey,
        .fileSizeKey,
        .contentModificationDateKey,
        .fileResourceIdentifierKey,
    ]

    public static func measure(_ url: URL, fileManager: FileManager = .default) -> SizeInfo {
        guard let values = try? url.resourceValues(forKeys: keys) else {
            return .empty
        }
        if values.isSymbolicLink == true {
            return SizeInfo(bytes: 0, files: 0, isDirectory: false, modified: nil, isSymbolicLink: true)
        }

        let isDirectory = values.isDirectory ?? false
        var bytes = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        var files = isDirectory ? 0 : 1
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let device = (attributes?[.systemNumber] as? NSNumber)?.uint64Value
        let inode = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value

        if isDirectory, let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) {
            var seenIdentifiers = Set<String>()
            for case let child as URL in enumerator {
                guard let childValues = try? child.resourceValues(forKeys: keys) else { continue }
                if childValues.isSymbolicLink == true { continue }
                if childValues.isDirectory == true { continue }
                files += 1
                if let identifier = childValues.fileResourceIdentifier {
                    let key = String(describing: identifier)
                    if !seenIdentifiers.insert(key).inserted {
                        continue
                    }
                }
                bytes += Int64(childValues.totalFileAllocatedSize ?? childValues.fileSize ?? 0)
            }
        }

        return SizeInfo(
            bytes: bytes,
            files: files,
            isDirectory: isDirectory,
            modified: values.contentModificationDate,
            isSymbolicLink: false,
            device: device,
            inode: inode
        )
    }
}
