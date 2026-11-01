import Foundation
import Testing
@testable import MacLeanCore

@Suite("Leftovers")
struct LeftoversTests {
    /// A throwaway home with a fake app and Library entries.
    final class Sandbox {
        let home: URL
        let fm = FileManager.default
        init() throws {
            home = fm.temporaryDirectory.appendingPathComponent("maclean-leftovers-\(UUID().uuidString)")
            try fm.createDirectory(at: home, withIntermediateDirectories: true)
        }
        deinit { try? fm.removeItem(at: home) }

        @discardableResult
        func file(_ relative: String, bytes: Int = 64, modified: Date? = nil) throws -> URL {
            let url = home.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 7, count: bytes).write(to: url)
            if let modified {
                // Backdate the file and every folder up to the Library location.
                var current = url
                while current.path.count > home.path.count, current.deletingLastPathComponent().lastPathComponent != "Library" {
                    try fm.setAttributes([.modificationDate: modified], ofItemAtPath: current.path)
                    current = current.deletingLastPathComponent()
                }
            }
            return url
        }

        func plist(_ relative: String, _ dict: [String: Any]) throws {
            let url = home.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
            try data.write(to: url)
        }

        func app(_ name: String, id: String, helpers: [String] = []) throws -> String {
            let path = "Applications/\(name).app"
            try plist("\(path)/Contents/Info.plist", ["CFBundleIdentifier": id, "CFBundleExecutable": name, "CFBundleName": name])
            for helper in helpers {
                try plist("\(path)/Contents/Library/LoginItems/\(helper).app/Contents/Info.plist", ["CFBundleIdentifier": helper])
            }
            return home.appendingPathComponent(path).path
        }
    }

    @Test func identityReadsNestedHelpers() throws {
        let box = try Sandbox()
        let path = try box.app("Widget", id: "com.acme.widget", helpers: ["com.acme.widget.LaunchHelper", "com.acme.agent"])
        let identity = AppIdentity.read(appPath: path, name: "Widget", bundleID: nil)
        #expect(identity.mainID == "com.acme.widget")
        #expect(identity.bundleIDs.contains("com.acme.agent"))
        #expect(identity.executable == "Widget")
    }

    @Test func relationClassifiesSuffixes() {
        #expect(Leftovers.relation("com.acme.app", to: "com.acme.app") == .exact)
        #expect(Leftovers.relation("com.acme.app.ShipIt", to: "com.acme.app") == .longer)
        #expect(Leftovers.relation("com.acme.app.AC8274AA-DDC4-5981-9FAA-5E94EAAB459C", to: "com.acme.app") == .longer)
        #expect(Leftovers.relation("com.acme.application", to: "com.acme.app") == nil)
    }

    @Test func findMatchesIDsHelpersCrashesAndSkipsTeamContainers() throws {
        let box = try Sandbox()
        let path = try box.app("Widget", id: "com.acme.widget", helpers: ["com.acme.agent"])
        try box.file("Library/Preferences/com.acme.widget.plist")
        try box.file("Library/Preferences/ByHost/com.acme.widget.AC8274AA-DDC4-5981-9FAA-5E94EAAB459C.plist")
        try box.file("Library/Caches/com.acme.widget.ShipIt/update.zip")
        try box.file("Library/Containers/com.acme.agent/Data/x")
        try box.file("Library/Group Containers/ABCDE12345.com.acme.widget.shared/db")
        try box.file("Library/Group Containers/ABCDE12345.Office/db") // another product of the team
        try box.file("Library/Logs/DiagnosticReports/Widget-2026-10-01-101010.ips")
        try box.file("Library/Preferences/com.acme.widgetpro.plist") // different app, no dot boundary
        try box.file("Library/Preferences/com.acme.widget.anything.plist") // own data: no app registered under it
        try box.file("Library/Preferences/com.acme.widget.lite.plist")     // a separate installed app
        try box.file("Library/Containers/com.acme.widget.lite.share/Data/x") // that app's extension
        try box.file("Library/Application Support/Widget/state.json") // name match, not pre-selected

        let identity = AppIdentity.read(appPath: path, name: "Widget", bundleID: nil)
        let found = Leftovers.find(for: identity, appName: "Widget", home: box.home, isOtherApp: { $0 == "com.acme.widget.lite" })
        let names = Set(found.map { ($0.path as NSString).lastPathComponent })

        #expect(names.contains("com.acme.widget.plist"))
        #expect(names.contains("com.acme.widget.AC8274AA-DDC4-5981-9FAA-5E94EAAB459C.plist"))
        #expect(names.contains("com.acme.widget.ShipIt"))
        #expect(names.contains("com.acme.agent"))
        #expect(names.contains("ABCDE12345.com.acme.widget.shared"))
        #expect(names.contains("Widget-2026-10-01-101010.ips"))
        #expect(!names.contains("ABCDE12345.Office"))
        #expect(!names.contains("com.acme.widgetpro.plist"))
        #expect(!names.contains("com.acme.widget.lite.plist"))
        #expect(!names.contains("com.acme.widget.lite.share"))

        let auto = Dictionary(uniqueKeysWithValues: found.map { (($0.path as NSString).lastPathComponent, $0.autoselect) })
        #expect(auto["com.acme.widget.plist"] == true)
        #expect(auto["com.acme.widget.anything.plist"] == true)
        #expect(auto["Widget"] == false)
        #expect(auto["ABCDE12345.com.acme.widget.shared"] == false) // group containers are never pre-selected
    }

    @Test func orphansGroupByAppAndSkipInstalledApple() throws {
        let box = try Sandbox()
        let old = Date().addingTimeInterval(-90 * 86_400)
        try box.file("Library/Application Support/com.gone.editor/data.db", bytes: 4096, modified: old)
        try box.file("Library/Preferences/com.gone.editor.plist", modified: old)
        try box.file("Library/Caches/com.gone.editor.helper/c", modified: old)
        try box.file("Library/Containers/com.gone.editor/Data/x", modified: old)
        try box.file("Library/Preferences/com.kept.app.plist")           // installed
        try box.file("Library/Preferences/com.kept.app.helper.plist")    // helper of installed
        try box.file("Library/Preferences/com.apple.finder.plist")       // Apple
        try box.file("Library/Caches/com.google/x")                       // bare vendor folder
        try box.file("Library/Preferences/com.kept.other.plist", modified: old) // same vendor as installed

        try box.file("Library/Preferences/com.registered.tool.plist", modified: old)   // registered with the system
        try box.file("Library/Caches/com.registered.tool.cache/x", modified: old)     // its sub-ID
        try box.file("Library/Preferences/com.github.someone.thing.plist", modified: old) // shared namespace
        let groups = Leftovers.orphans(installedIDs: ["com.kept.app", "com.github.other.app"],
                                       isInstalled: { $0 == "com.registered.tool" }, home: box.home)
        let ids = groups.map(\.appID)
        #expect(ids.contains("com.gone.editor"))
        #expect(!ids.contains("com.gone.editor.helper")) // folded into parent
        #expect(!ids.contains { $0.hasPrefix("com.kept.app") })
        #expect(!ids.contains { $0.hasPrefix("com.apple") })
        #expect(!ids.contains("com.google"))

        let editor = try #require(groups.first { $0.appID == "com.gone.editor" })
        #expect(editor.items.count == 4)
        #expect(editor.confidence == .high)
        #expect(!editor.vendorInstalled)

        #expect(!ids.contains { $0.hasPrefix("com.registered.tool") })
        let shared = try #require(groups.first { $0.appID == "com.github.someone.thing" })
        #expect(!shared.vendorInstalled) // a code-host namespace is not a vendor

        let other = try #require(groups.first { $0.appID == "com.kept.other" })
        #expect(other.vendorInstalled)
        #expect(other.confidence < editor.confidence)
    }

    @Test func trashedAppRaisesConfidenceAndNamesGroup() throws {
        let box = try Sandbox()
        try box.plist(".Trash/Sketchy Pad.app/Contents/Info.plist", ["CFBundleIdentifier": "io.sketchy.pad"])
        try box.file("Library/Preferences/io.sketchy.pad.plist")
        let groups = Leftovers.orphans(installedIDs: [], home: box.home)
        let group = try #require(groups.first { $0.appID == "io.sketchy.pad" })
        #expect(group.trashedApp != nil)
        #expect(group.displayName == "Sketchy Pad")
        #expect(group.confidence >= .medium)
    }

    @Test func orphanItemsCleanThroughArtifactCleaner() throws {
        let box = try Sandbox()
        let old = Date().addingTimeInterval(-60 * 86_400)
        try box.file("Library/Preferences/com.gone.tool.plist", modified: old)
        try box.file("Library/Caches/com.gone.tool/blob", bytes: 2048, modified: old)
        let group = try #require(Leftovers.orphans(installedIDs: [], home: box.home).first { $0.appID == "com.gone.tool" })
        let result = ArtifactCleaner(home: box.home).clean(group.items, apply: true, permanent: true, includeCaution: true)
        #expect(result.failed.isEmpty)
        #expect(result.skipped.isEmpty, "\(result.skipped.map(\.reason))")
        #expect(result.deleted.count == group.items.count)
        for item in group.items { #expect(!FileManager.default.fileExists(atPath: item.path)) }
    }

    @Test func displayNameSkipsGenericTails() {
        #expect(Leftovers.displayName(for: "com.figma.desktop", trashedApp: nil, items: []) == "Figma")
        #expect(Leftovers.displayName(for: "jan.ai.app", trashedApp: nil, items: []) == "Jan")
    }
}
