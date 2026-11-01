import Foundation

public enum DiskImageScanner {
    static let extensions: Set<String> = ["dmg", "iso", "sparseimage", "toast"]

    public static func scan(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        directories: [URL]? = nil,
        olderThanDays: Int = 30,
        minBytes: Int64 = 100 * 1024 * 1024,
        fileManager: FileManager = .default
    ) -> [Artifact] {
        let roots = directories ?? [
            home.appendingPathComponent("Downloads"),
            home.appendingPathComponent("Desktop"),
            home.appendingPathComponent("Documents"),
            home.appendingPathComponent("Movies"),
        ]
        let cutoff = Date().addingTimeInterval(-Double(olderThanDays) * 86_400)
        var artifacts: [Artifact] = []
        var seen = Set<String>()

        for root in roots {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: Array(FileSizer.keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }

            for case let url as URL in enumerator {
                guard extensions.contains(url.pathExtension.lowercased()) else { continue }
                guard let values = try? url.resourceValues(forKeys: FileSizer.keys) else { continue }
                if values.isSymbolicLink == true || values.isDirectory == true { continue }
                if let modified = values.contentModificationDate, modified > cutoff { continue }
                let size = Int64(values.fileSize ?? 0)
                if size < minBytes { continue }
                guard seen.insert(url.path).inserted else { continue }

                if let artifact = ArtifactBuilder.make(
                    path: url.path,
                    allowedRoot: root.path,
                    group: "Unused disk image",
                    detail: url.pathExtension.uppercased(),
                    risk: .caution,
                    autoselect: false,
                    fileManager: fileManager
                ) {
                    artifacts.append(artifact)
                }
            }
        }

        return artifacts.sorted { $0.bytes > $1.bytes }
    }
}
