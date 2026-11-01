import Foundation

public struct InstalledApp: Codable, Sendable {
    public let name: String
    public let path: String
    public let bundleID: String?
    public let version: String?
    public let bytes: Int64
    public let lastUsed: Date?

    public init(
        name: String,
        path: String,
        bundleID: String?,
        version: String?,
        bytes: Int64,
        lastUsed: Date? = nil
    ) {
        self.name = name
        self.path = path
        self.bundleID = bundleID
        self.version = version
        self.bytes = bytes
        self.lastUsed = lastUsed
    }
}

public enum AppCatalog {
    public static func installed(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [InstalledApp] {
        list(
            directories: [
                URL(fileURLWithPath: "/Applications"),
                home.appendingPathComponent("Applications"),
            ],
            fileManager: fileManager
        )
    }

    public static func list(directories: [URL], fileManager: FileManager = .default) -> [InstalledApp] {
        var apps: [InstalledApp] = []

        for directory in directories {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            ) else { continue }

            for entry in entries where entry.pathExtension == "app" {
                guard let values = try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]),
                      values.isSymbolicLink != true else { continue }

                let info = infoPlist(at: entry, fileManager: fileManager)
                let size = FileSizer.measure(entry, fileManager: fileManager)
                apps.append(
                    InstalledApp(
                        name: info?["CFBundleDisplayName"] as? String
                            ?? info?["CFBundleName"] as? String
                            ?? entry.deletingPathExtension().lastPathComponent,
                        path: entry.path,
                        bundleID: info?["CFBundleIdentifier"] as? String,
                        version: info?["CFBundleShortVersionString"] as? String,
                        bytes: size.bytes
                    )
                )
            }
        }

        return apps.sorted { $0.bytes > $1.bytes }
    }

    public static func unused(
        days: Int,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [InstalledApp] {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        return installed(home: home, fileManager: fileManager).compactMap { app in
            guard let lastUsed = lastUsed(at: URL(fileURLWithPath: app.path)) else {
                return nil
            }
            guard lastUsed < cutoff else { return nil }
            return InstalledApp(
                name: app.name,
                path: app.path,
                bundleID: app.bundleID,
                version: app.version,
                bytes: app.bytes,
                lastUsed: lastUsed
            )
        }.sorted { $0.bytes > $1.bytes }
    }

    public static func lastUsed(at app: URL) -> Date? {
        let result = ProcessRunner.run(
            "/usr/bin/mdls",
            ["-name", "kMDItemLastUsedDate", "-raw", app.path],
            timeout: 5
        )
        guard result.status == 0 else { return nil }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != "(null)" else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter.date(from: value)
    }

    private static func infoPlist(at app: URL, fileManager: FileManager) -> [String: Any]? {
        let url = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
    }
}
