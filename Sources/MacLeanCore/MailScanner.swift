import Foundation

public enum MailScanner {
    public static func scan(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [Artifact] {
        var artifacts: [Artifact] = []
        var seen = Set<String>()

        func add(_ path: String, root: String, group: String, detail: String) {
            guard seen.insert(path).inserted else { return }
            if let artifact = ArtifactBuilder.make(
                path: path,
                allowedRoot: root,
                group: group,
                detail: detail,
                risk: .caution,
                autoselect: false,
                fileManager: fileManager
            ) {
                artifacts.append(artifact)
            }
        }

        let mailRoots = [
            home.appendingPathComponent("Library/Mail"),
            home.appendingPathComponent("Library/Containers/com.apple.mail/Data/Library/Mail"),
        ]

        for mailRoot in mailRoots {
            guard let enumerator = fileManager.enumerator(
                at: mailRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles],
                errorHandler: { _, _ in true }
            ) else { continue }

            for case let url as URL in enumerator {
                guard url.lastPathComponent == "Attachments" else { continue }
                guard url.path.contains("MailData") else { continue }
                enumerator.skipDescendants()

                let account = accountName(for: url, mailRoot: mailRoot)
                guard let entries = try? fileManager.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: nil,
                    options: []
                ) else { continue }

                for entry in entries {
                    add(
                        entry.path,
                        root: url.path,
                        group: "Mail attachments",
                        detail: account
                    )
                }
            }
        }

        let downloads = home.appendingPathComponent(
            "Library/Containers/com.apple.mail/Data/Library/Mail Downloads"
        )
        if let entries = try? fileManager.contentsOfDirectory(
            at: downloads,
            includingPropertiesForKeys: nil,
            options: []
        ) {
            for entry in entries {
                add(
                    entry.path,
                    root: downloads.path,
                    group: "Mail downloads",
                    detail: "Mail"
                )
            }
        }

        return artifacts.sorted { $0.bytes > $1.bytes }
    }

    private static func accountName(for url: URL, mailRoot: URL) -> String {
        let components = url.pathComponents
        guard let index = components.firstIndex(where: { $0.hasPrefix("V") && $0.count <= 3 }) else {
            return mailRoot.lastPathComponent
        }
        guard index + 1 < components.count else { return mailRoot.lastPathComponent }
        let next = components[index + 1]
        return next.isEmpty ? mailRoot.lastPathComponent : next
    }
}
