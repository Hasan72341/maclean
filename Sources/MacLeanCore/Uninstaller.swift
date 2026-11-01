import Foundation

public struct AppInfo: Codable, Sendable, Hashable {
    public let name: String
    public let path: String
    public let bundleID: String?
    public let version: String?
    public let bytes: Int64

    public init(name: String, path: String, bundleID: String?, version: String?, bytes: Int64) {
        self.name = name
        self.path = path
        self.bundleID = bundleID
        self.version = version
        self.bytes = bytes
    }
}

public enum Uninstaller {
    public static func apps(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [AppInfo] {
        AppCatalog.installed(home: home, fileManager: fileManager).map {
            AppInfo(
                name: $0.name,
                path: $0.path,
                bundleID: $0.bundleID,
                version: $0.version,
                bytes: $0.bytes
            )
        }
    }

    public static func find(_ query: String, in apps: [AppInfo]) -> [AppInfo] {
        let needle = query.lowercased()
        let exact = apps.filter {
            $0.name.lowercased() == needle
                || ($0.bundleID?.lowercased() == needle)
                || $0.path.lowercased() == needle
        }
        if !exact.isEmpty { return exact }

        return apps.filter {
            $0.name.lowercased().contains(needle)
                || ($0.bundleID?.lowercased().contains(needle) ?? false)
        }
    }

    public static func plan(
        for app: AppInfo,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [Artifact] {
        let appURL = URL(fileURLWithPath: app.path)
        let info = PlistReader.dictionary(at: appURL.appendingPathComponent("Contents/Info.plist"))
        let bundleID = app.bundleID
            ?? PlistReader.string("CFBundleIdentifier", in: info ?? [:])
            ?? ""
        _ = info
        let name = app.name

        var artifacts: [Artifact] = []
        var seen = Set<String>()

        func add(
            _ path: String,
            root: String,
            group: String,
            risk: Risk = .caution,
            autoselect: Bool = true
        ) {
            guard seen.insert(path).inserted else { return }
            if let artifact = ArtifactBuilder.make(
                path: path,
                allowedRoot: root,
                group: group,
                detail: name,
                risk: risk,
                autoselect: autoselect,
                fileManager: fileManager
            ) {
                artifacts.append(artifact)
            }
        }

        func addHome(_ relative: String, group: String, risk: Risk = .caution, autoselect: Bool = true) {
            let path = home.appendingPathComponent(relative).path
            add(
                path,
                root: URL(fileURLWithPath: path).deletingLastPathComponent().path,
                group: group,
                risk: risk,
                autoselect: autoselect
            )
        }

        add(app.path, root: appURL.deletingLastPathComponent().path, group: "Application")

        let identity = AppIdentity.read(appPath: app.path, name: name, bundleID: bundleID.isEmpty ? nil : bundleID, fileManager: fileManager)
        for artifact in Leftovers.find(for: identity, appName: name, home: home, fileManager: fileManager)
        where seen.insert(artifact.path).inserted {
            artifacts.append(artifact)
        }

        // System-wide locations (need administrator rights to remove).
        let systemDirs = ["/Library/Application Support", "/Library/Caches", "/Library/Preferences", "/Library/Logs"]
        for dir in systemDirs {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries {
                let stem = Leftovers.stem(entry)
                guard identity.bundleIDs.contains(where: { Leftovers.belongs(stem, to: $0) })
                        || identity.names.contains(where: { $0.caseInsensitiveCompare(entry) == .orderedSame && dir.hasSuffix("Application Support") })
                else { continue }
                add("\(dir)/\(entry)", root: dir, group: "System " + (dir as NSString).lastPathComponent, risk: .caution, autoselect: false)
            }
        }

        // Launch items: the plist is named after one of the app's IDs, or its
        // program lives inside the app bundle. Substring matches are not used.
        let bundlePrefix = PathCanon.resolve(app.path) + "/"
        for directory in [
            home.appendingPathComponent("Library/LaunchAgents"),
            URL(fileURLWithPath: "/Library/LaunchAgents"),
            URL(fileURLWithPath: "/Library/LaunchDaemons"),
        ] {
            guard let entries = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: []) else { continue }
            let isSystem = directory.path.hasPrefix("/Library/")
            for entry in entries where entry.pathExtension == "plist" {
                let plist = PlistReader.dictionary(at: entry) ?? [:]
                let label = PlistReader.string("Label", in: plist) ?? ""
                let stem = entry.deletingPathExtension().lastPathComponent
                let byID = identity.bundleIDs.contains { Leftovers.belongs(stem, to: $0) || Leftovers.belongs(label, to: $0) }
                var programs: [String] = []
                if let program = plist["Program"] as? String { programs.append(program) }
                if let args = plist["ProgramArguments"] as? [String], let first = args.first { programs.append(first) }
                if let bundle = plist["BundleProgram"] as? String { programs.append(app.path + "/" + bundle) }
                let byProgram = programs.contains { PathCanon.resolve($0).hasPrefix(bundlePrefix) || $0.hasPrefix(app.path + "/") }
                guard byID || byProgram else { continue }
                add(entry.path, root: directory.path, group: "Launch item", risk: .caution, autoselect: !isSystem)
            }
        }

        if !bundleID.isEmpty {
            for receiptDirectory in ["/var/db/receipts", "/private/var/db/receipts"] {
                guard let entries = try? fileManager.contentsOfDirectory(atPath: receiptDirectory) else { continue }
                for entry in entries where identity.bundleIDs.contains(where: { entry.hasPrefix($0 + ".") }) {
                    add(
                        "\(receiptDirectory)/\(entry)",
                        root: receiptDirectory,
                        group: "Package receipt",
                        risk: .caution,
                        autoselect: false
                    )
                }
            }

            if let helpers = try? fileManager.contentsOfDirectory(atPath: "/Library/PrivilegedHelperTools") {
                for helper in helpers where identity.bundleIDs.contains(where: { helper.lowercased().hasPrefix($0.lowercased()) }) {
                    add(
                        "/Library/PrivilegedHelperTools/\(helper)",
                        root: "/Library/PrivilegedHelperTools",
                        group: "Privileged helper",
                        risk: .caution,
                        autoselect: false
                    )
                }
            }
        }

        return artifacts.sorted { $0.bytes > $1.bytes }
    }
}
