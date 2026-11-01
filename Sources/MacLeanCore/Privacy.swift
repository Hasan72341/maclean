import Foundation

public enum PrivacyScanner {
    struct ChromiumBrowser {
        let name: String
        let root: String
    }

    static let chromiumBrowsers = [
        ChromiumBrowser(name: "Google Chrome", root: "Library/Application Support/Google/Chrome"),
        ChromiumBrowser(name: "Microsoft Edge", root: "Library/Application Support/Microsoft Edge"),
        ChromiumBrowser(name: "Brave", root: "Library/Application Support/BraveSoftware/Brave-Browser"),
        ChromiumBrowser(name: "Chromium", root: "Library/Application Support/Chromium"),
        ChromiumBrowser(name: "Arc", root: "Library/Application Support/Arc/User Data"),
    ]

    static let chromiumFiles: [(String, String)] = [
        ("History", "Browsing history"),
        ("Top Sites", "Browsing history"),
        ("Visited Links", "Browsing history"),
        ("Cookies", "Cookies"),
        ("Network/Cookies", "Cookies"),
        ("Web Data", "Autofill"),
        ("Login Data", "Saved passwords"),
        ("Current Session", "Session data"),
        ("Current Tabs", "Session data"),
        ("Last Session", "Session data"),
        ("Last Tabs", "Session data"),
    ]

    static let firefoxFiles: [(String, String)] = [
        ("places.sqlite", "Browsing history"),
        ("cookies.sqlite", "Cookies"),
        ("formhistory.sqlite", "Autofill"),
        ("logins.json", "Saved passwords"),
        ("sessionstore.jsonlz4", "Session data"),
        ("downloads.sqlite", "Downloads history"),
    ]

    static let safariFiles: [(String, String)] = [
        ("History.db", "Browsing history"),
        ("Cookies.binarycookies", "Cookies"),
        ("Downloads.plist", "Downloads history"),
        ("RecentlyClosedTabs.plist", "Session data"),
        ("LocalStorage", "Website data"),
        ("Databases", "Website data"),
    ]

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

        for browser in chromiumBrowsers {
            let root = home.appendingPathComponent(browser.root)
            guard fileManager.fileExists(atPath: root.path) else { continue }
            guard let entries = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            ) else { continue }

            var profiles: [URL] = []
            if fileManager.fileExists(atPath: root.appendingPathComponent("History").path) {
                profiles.append(root)
            }
            for entry in entries {
                let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                guard isDirectory else { continue }
                if fileManager.fileExists(atPath: entry.appendingPathComponent("History").path)
                    || fileManager.fileExists(atPath: entry.appendingPathComponent("Cookies").path) {
                    profiles.append(entry)
                }
            }

            for profile in profiles {
                let profileName = profile.lastPathComponent
                for (relative, group) in chromiumFiles {
                    let path = profile.appendingPathComponent(relative)
                    add(
                        path.path,
                        root: path.deletingLastPathComponent().path,
                        group: group,
                        detail: "\(browser.name) · \(profileName)"
                    )
                }
            }
        }

        let firefoxRoot = home.appendingPathComponent("Library/Application Support/Firefox/Profiles")
        if let profiles = try? fileManager.contentsOfDirectory(
            at: firefoxRoot,
            includingPropertiesForKeys: nil,
            options: []
        ) {
            for profile in profiles {
                for (relative, group) in firefoxFiles {
                    let path = profile.appendingPathComponent(relative)
                    add(
                        path.path,
                        root: profile.path,
                        group: group,
                        detail: "Firefox · \(profile.lastPathComponent)"
                    )
                }
            }
        }

        let safariRoot = home.appendingPathComponent("Library/Safari")
        for (relative, group) in safariFiles {
            let path = safariRoot.appendingPathComponent(relative)
            add(path.path, root: safariRoot.path, group: group, detail: "Safari")
        }

        let sharedFileLists = home.appendingPathComponent("Library/Application Support/com.apple.sharedfilelist")
        if let entries = try? fileManager.contentsOfDirectory(
            at: sharedFileLists,
            includingPropertiesForKeys: nil,
            options: []
        ) {
            for entry in entries where entry.lastPathComponent.contains("LSSharedFileList.Recent") {
                add(
                    entry.path,
                    root: sharedFileLists.path,
                    group: "Recent items",
                    detail: "macOS shared file list"
                )
            }
        }

        let recentItems = home.appendingPathComponent("Library/Preferences/com.apple.recentitems.plist")
        add(
            recentItems.path,
            root: recentItems.deletingLastPathComponent().path,
            group: "Recent items",
            detail: "macOS recent items"
        )

        return artifacts.sorted { $0.bytes > $1.bytes }
    }
}
