import AppKit
import MacLeanCore
import SwiftUI

/// Opt-in UI smoke run: `MACLEAN_SMOKE_DIR=/some/dir` hosts the shell in its
/// own window (works even while the screen is locked), visits every section
/// root and every argument-free route, renders each into a PNG, then quits.
/// Never active in normal launches.
@MainActor
enum SmokeTest {
    private static var started = false

    static var directory: URL? {
        ProcessInfo.processInfo.environment["MACLEAN_SMOKE_DIR"].map { URL(fileURLWithPath: $0) }
    }

    static let routes: [(AppSection, Route)] = [
        (.dashboard, .monitor(.healthScore)),
        (.dashboard, .monitor(.cpuOverview)),
        (.dashboard, .monitor(.cores)),
        (.dashboard, .monitor(.loadAverage)),
        (.dashboard, .monitor(.topCPU)),
        (.dashboard, .monitor(.memoryOverview)),
        (.dashboard, .monitor(.memoryPressure)),
        (.dashboard, .monitor(.topMemory)),
        (.dashboard, .monitor(.processList)),
        (.dashboard, .monitor(.processUsers)),
        (.dashboard, .monitor(.diskOverview)),
        (.dashboard, .monitor(.diskIO)),
        (.dashboard, .monitor(.volumes)),
        (.dashboard, .monitor(.networkOverview)),
        (.dashboard, .monitor(.battery)),
        (.dashboard, .monitor(.thermal)),
        (.dashboard, .monitor(.powerAssertions)),
        (.dashboard, .monitor(.systemInfo)),
        (.dashboard, .monitor(.activityLog)),
        (.dashboard, .monitor(.samplingSettings)),
        (.cleanup, .cleanup(.scanResults)),
        (.cleanup, .cleanup(.reviewSelection)),
        (.cleanup, .cleanup(.cleanResult)),
        (.cleanup, .cleanup(.cautionItems)),
        (.cleanup, .cleanup(.rootItems)),
        (.cleanup, .cleanup(.trash)),
        (.cleanup, .cleanup(.largeFiles)),
        (.cleanup, .cleanup(.devJunk)),
        (.cleanup, .cleanup(.browserCaches)),
        (.cleanup, .cleanup(.aiData)),
        (.cleanup, .cleanup(.updateLeftovers)),
        (.cleanup, .cleanup(.systemJunk)),
        (.cleanup, .cleanup(.rulesCatalog)),
        (.cleanup, .cleanup(.scanOptions)),
        (.cleanup, .cleanup(.cleanupHistory)),
        (.cleanup, .cleanup(.scanLog)),
        (.cleanup, .cleanup(.scanConsole)),
        (.cleanup, .cleanup(.ruleTimings)),
        (.cleanup, .cleanup(.newRule)),
        (.cleanup, .cleanup(.ruleDetail("user-caches"))),
        (.cleanup, .cleanup(.ruleEditor("user-caches"))),
        (.apps, .apps(.allApps)),
        (.apps, .apps(.unusedApps)),
        (.apps, .apps(.largeApps)),
        (.apps, .apps(.recentApps)),
        (.apps, .apps(.vendors)),
        (.apps, .apps(.appStoreApps)),
        (.apps, .apps(.otherApps)),
        (.apps, .apps(.architectures)),
        (.apps, .apps(.orphans)),
        (.space, .space(.lensHome)),
        (.apps, .apps(.extensions)),
        (.apps, .apps(.runningApps)),
        (.apps, .apps(.loginItems)),
        (.apps, .apps(.systemUpdates)),
        (.privacy, .privacy(.allItems)),
        (.privacy, .privacy(.browsers)),
        (.privacy, .privacy(.recentItems)),
        (.privacy, .privacy(.permissions)),
        (.privacy, .privacy(.savedState)),
        (.privacy, .privacy(.quarantineEvents)),
        (.privacy, .privacy(.shellHistory)),
        (.privacy, .privacy(.clipboard)),
        (.privacy, .privacy(.wifiNetworks)),
        (.privacy, .privacy(.quickLookCache)),
        (.privacy, .privacy(.result)),
        (.privacy, .privacy(.commandOutput)),
        (.performance, .performance(.startupItems)),
        (.performance, .performance(.userAgents)),
        (.performance, .performance(.globalAgents)),
        (.performance, .performance(.launchDaemons)),
        (.performance, .performance(.brokenItems)),
        (.performance, .performance(.runningItems)),
        (.performance, .performance(.loginItems)),
        (.performance, .performance(.snapshots)),
        (.performance, .performance(.memory)),
        (.performance, .performance(.cpu)),
        (.performance, .performance(.heavyConsumers)),
        (.performance, .performance(.topCPU)),
        (.performance, .performance(.topMemory)),
        (.performance, .performance(.energy)),
        (.performance, .performance(.sleepAssertions)),
        (.performance, .performance(.maintenance)),
        (.performance, .performance(.maintenanceHistory)),
        (.performance, .performance(.flushDNS)),
        (.performance, .performance(.reindexLaunchServices)),
        (.performance, .performance(.rebuildSpotlight)),
        (.performance, .performance(.clearFontCaches)),
        (.performance, .performance(.runPeriodicScripts)),
        (.performance, .performance(.verifyDisk)),
        (.performance, .performance(.repairHomePermissions)),
        (.performance, .performance(.thinSnapshots)),
        (.performance, .performance(.freeRAM)),
        (.space, .space(.largeOldFiles)),
        (.space, .space(.duplicates)),
        (.space, .space(.similarImages)),
        (.space, .space(.diskImages)),
        (.space, .space(.projectArtifacts)),
        (.space, .space(.downloads)),
        (.space, .space(.fileTypes)),
        (.space, .space(.extensions)),
        (.space, .space(.cloud)),
        (.space, .space(.cloudLargeFiles)),
        (.space, .space(.mailAttachments)),
        (.space, .space(.emptyFolders)),
        (.space, .space(.archives)),
        (.space, .space(.trash)),
        (.space, .space(.volumes)),
        (.space, .space(.diskActivity)),
        (.protection, .protection(.profiles)),
        (.protection, .protection(.scanRun)),
        (.protection, .protection(.findings)),
        (.protection, .protection(.history)),
        (.protection, .protection(.quarantine)),
        (.protection, .protection(.realtime)),
        (.protection, .protection(.watchedPaths)),
        (.protection, .protection(.alerts)),
        (.protection, .protection(.yaraRules)),
        (.protection, .protection(.corpus)),
        (.settings, .settings(.menuBar)),
        (.protection, .protection(.deepScan)),
        (.protection, .protection(.mailTrash)),
        (.protection, .protection(.photosDuplicates)),
        (.protection, .protection(.photoLibraries)),
        (.protection, .protection(.documentVersions)),
        (.protection, .protection(.deletedUsers)),
        (.protection, .protection(.systemCaches)),
        (.protection, .protection(.universalBinaries)),
        (.settings, .settings(.general)),
        (.settings, .settings(.monitoring)),
        (.settings, .settings(.history)),
        (.settings, .settings(.statistics)),
        (.settings, .settings(.fullDiskAccess)),
        (.settings, .settings(.permissionsGuide)),
        (.settings, .settings(.engine)),
        (.settings, .settings(.rules)),
        (.settings, .settings(.yaraRules)),
        (.settings, .settings(.cliInstall)),
        (.settings, .settings(.appData)),
        (.settings, .settings(.shortcuts)),
        (.settings, .settings(.diagnostics)),
        (.settings, .settings(.licenses)),
        (.settings, .settings(.about)),
    ]

    static func runIfRequested() {
        guard let directory, !started else { return }
        started = true
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let env = ProcessInfo.processInfo.environment
        let dwell = Double(env["MACLEAN_SMOKE_DWELL"] ?? "") ?? 2
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: smokeSize.width, height: smokeSize.height),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: RootShell(smoke: true).frame(width: smokeSize.width, height: smokeSize.height))
        window.orderFrontRegardless()
        var log = ""
        Task { @MainActor in
            SystemMonitor.shared.start()
            // MACLEAN_SMOKE_WARMUP=seconds lets live graphs fill before the first capture.
            let warmup = Double(env["MACLEAN_SMOKE_WARMUP"] ?? "") ?? 2
            try? await Task.sleep(nanoseconds: UInt64(warmup * 1_000_000_000))
            let nav = Navigator.shared
            var index = 0
            for section in AppSection.allCases {
                nav.go(section)
                nav.popToRoot()
                try? await Task.sleep(nanoseconds: UInt64(dwell * 1_000_000_000))
                index += 1
                snapshot(window, to: directory.appendingPathComponent(String(format: "%03d-%@.png", index, section.rawValue)))
                log += "ok root \(section.rawValue)\n"
            }
            if env["MACLEAN_SMOKE_SCAN"] != nil {
                // Read-only Smart Scan to capture the live verbose views.
                nav.go(.cleanup)
                nav.popToRoot()
                CleanupStore.shared.scan()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                index += 1
                snapshot(window, to: directory.appendingPathComponent(String(format: "%03d-scan-live.png", index)))
                nav.go(.cleanup, .cleanup(.scanConsole))
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                index += 1
                snapshot(window, to: directory.appendingPathComponent(String(format: "%03d-scan-console-live.png", index)))
                while CleanupStore.shared.scanState.isLoading {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                try? await Task.sleep(nanoseconds: 800_000_000)
                index += 1
                snapshot(window, to: directory.appendingPathComponent(String(format: "%03d-scan-console-done.png", index)))
                nav.popToRoot()
                try? await Task.sleep(nanoseconds: 800_000_000)
                index += 1
                snapshot(window, to: directory.appendingPathComponent(String(format: "%03d-scan-hub-done.png", index)))
                log += "ok scan \(ScanTrace.shared.lines.count) lines, \(ScanTrace.shared.rulesDone) rules\n"
            }
            if env["MACLEAN_SMOKE_PANES"] != nil {
                let panes: [SystemPane] = SystemPane.Anchor.allCases.map { .privacy($0) } + [
                    .privacySecurity, .fileVault, .loginItems, .extensions, .softwareUpdate, .battery, .network, .wifi,
                    .bluetooth, .storage, .spotlight, .timeMachine, .startupDisk, .usersGroups, .sharing,
                    .notifications(bundleID: "com.apple.Safari"), .general, .about, .profiles, .systemExtensions,
                ]
                log += "panes: \(SettingsCatalog.shared.summary)\n"
                for pane in panes { log += "pane \(pane.path) -> \(pane.urlString)\n" }
            }
            if env["MACLEAN_SMOKE_LENS"] != nil {
                log += await lensTest(window: window, directory: directory, index: &index)
                try? log.write(to: directory.appendingPathComponent("progress.log"), atomically: true, encoding: .utf8)
            }
            if env["MACLEAN_SMOKE_MENU"] != nil {
                // Render the menu bar popover in both appearances.
                for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                    let host = NSHostingView(rootView: MenuBarPanel())
                    let panel = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 360, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
                    panel.appearance = NSAppearance(named: appearance)
                    panel.contentView = host
                    host.setFrameSize(host.fittingSize)
                    panel.setContentSize(host.fittingSize)
                    panel.orderFront(nil)
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    host.setFrameSize(host.fittingSize)
                    panel.setContentSize(host.fittingSize)
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    index += 1
                    snapshot(panel, to: directory.appendingPathComponent(String(format: "%03d-menubar-\(name).png", index)))
                    log += "menu bar panel (\(name)): \(Int(host.fittingSize.width))×\(Int(host.fittingSize.height)) · CPU \(Int(SystemMonitor.shared.latest.cpu.total * 100))% · processes \(SystemMonitor.shared.processes.count)\n"
                    panel.orderOut(nil)
                }
                try? log.write(to: directory.appendingPathComponent("progress.log"), atomically: true, encoding: .utf8)
            }
            if env["MACLEAN_SMOKE_RESCUE"] != nil {
                // A file the user cannot delete: it sits in a read-only folder.
                let base = FileManager.default.temporaryDirectory.appendingPathComponent("maclean-rescue-\(UUID().uuidString)")
                let locked = base.appendingPathComponent("Locked Leftovers")
                try? FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
                let victim = locked.appendingPathComponent("com.example.helper.plist")
                try? Data("x".utf8).write(to: victim)
                try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
                var summary = RemovalSummary()
                do { try FileManager.default.removeItem(at: victim) } catch { summary.failures = [(victim.path, error.localizedDescription)] }
                summary.failures.append(("/System/Library/CoreServices/Finder.app", "Operation not permitted"))
                _ = ActivityLog.shared.record("Apps", "Remove leftovers", summary)
                let rescue = RemovalRescue.shared
                var rlog = "rescue: offered=\(rescue.isPresented) items=\(rescue.items.count) elevatable=\(rescue.elevatable.count)\n"
                @MainActor func render(_ name: String) {
                    for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                        let host = NSHostingView(rootView: RemovalRescueSheet())
                        let panel = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 640, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
                        panel.appearance = NSAppearance(named: appearance)
                        panel.contentView = host
                        host.setFrameSize(NSSize(width: 640, height: host.fittingSize.height))
                        panel.setContentSize(NSSize(width: 640, height: host.fittingSize.height))
                        panel.orderFront(nil)
                        index += 1
                        snapshot(panel, to: directory.appendingPathComponent(String(format: "%03d-rescue-\(name)-\(suffix).png", index)))
                        panel.orderOut(nil)
                    }
                }
                try? await Task.sleep(nanoseconds: 600_000_000)
                render("offer")
                // Unlock so the (non-elevated, test-mode) retry can succeed for one item…
                rescue.retryAsAdministrator()
                for _ in 0..<40 where rescue.stage == .running { try? await Task.sleep(nanoseconds: 250_000_000) }
                rlog += "rescue after retry (locked): stage=\(rescue.stage) left=\(rescue.items.map(\.path))\n"
                render("failed")
                rescue.dismiss()
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
                try? FileManager.default.removeItem(at: base)
                try? (log + rlog).write(to: directory.appendingPathComponent("progress.log"), atomically: true, encoding: .utf8)
                log += rlog
            }
            if env["MACLEAN_SMOKE_SELECTBAR"] != nil {
                let bars = VStack(alignment: .leading, spacing: 14) {
                    ForEach([(0, 0), (12, 2_400_000_000), (48, 9_100_000_000)], id: \.0) { state in
                        SelectionBar(selectedCount: state.0, totalCount: 48, selectedBytes: Int64(state.1), actionTitle: "Remove Leftovers",
                                     onSelectAll: {}, onSelectNone: {}, action: {})
                    }
                    Text("narrow").font(Type.mono(10)).foregroundStyle(Theme.muted)
                    SelectionBar(selectedCount: 12, totalCount: 48, selectedBytes: 2_400_000_000, actionTitle: "Remove Leftovers",
                                 onSelectAll: {}, onSelectNone: {}, action: {})
                        .frame(width: 380)
                }
                .padding(20).frame(width: 760).background(Theme.paper)
                let host = NSHostingView(rootView: bars)
                let panel = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 760, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
                panel.contentView = host
                panel.setContentSize(host.fittingSize)
                panel.orderFront(nil)
                try? await Task.sleep(nanoseconds: 500_000_000)
                index += 1
                snapshot(panel, to: directory.appendingPathComponent(String(format: "%03d-selectbar.png", index)))
                panel.orderOut(nil)
            }
            if env["MACLEAN_SMOKE_LENS_DISK"] != nil {
                let store = LensStore.shared
                let nav = Navigator.shared
                nav.go(.space, .space(.lens("/")))
                store.scan("/", force: true)
                let started = Date()
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                index += 1
                snapshot(window, to: directory.appendingPathComponent(String(format: "%03d-disk-progress.png", index)))
                while store.sessions["/"]?.state.isLoading == true, Date().timeIntervalSince(started) < 1200 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if let root = store.item("/"), let disk = SpaceLensHomeScreen.volume("/") {
                    let used = disk.physicalUsed
                    log += "admin pipeline: \(store.sessions["/"]?.elevated == true ? "used" : "not used")\(store.sessions["/"]?.note.map { " · " + $0 } ?? "")\n"
                    log += "disk scan: \(Format.bytes(root.bytes)) found of \(Format.bytes(used)) used · \(Format.count(root.files)) files · \(Format.count(root.folders)) folders · \(root.unreadable) unreadable · \(String(format: "%.0f", Date().timeIntervalSince(started))) s\n"
                    // APFS clones are counted per file (like du), so allow 10 %.
                    log += (root.bytes <= used + used / 10 ? "PASS" : "FAIL") + " no double counting: found within 10 % of used space\n"
                    for child in root.children.prefix(8) { log += "  \(child.name): \(Format.bytes(child.bytes))\n" }
                } else {
                    log += "FAIL disk scan did not finish\n"
                }
                index += 1
                snapshot(window, to: directory.appendingPathComponent(String(format: "%03d-disk-map.png", index)))
                store.unload("/")
                try? log.write(to: directory.appendingPathComponent("progress.log"), atomically: true, encoding: .utf8)
            }
            if env["MACLEAN_SMOKE_LEFTOVERS"] != nil {
                log += await leftoverTest(window: window, directory: directory, index: &index)
                try? log.write(to: directory.appendingPathComponent("progress.log"), atomically: true, encoding: .utf8)
            }
            if env["MACLEAN_SMOKE_ACTION"] != nil {
                log += await actionTest(window: window, directory: directory, index: &index)
                try? log.write(to: directory.appendingPathComponent("progress.log"), atomically: true, encoding: .utf8)
            }
            for (section, route) in routes {
                nav.go(section, route)
                try? await Task.sleep(nanoseconds: UInt64(dwell * 1_000_000_000))
                index += 1
                let name = String(describing: route).replacingOccurrences(of: "/", with: "_")
                snapshot(window, to: directory.appendingPathComponent(String(format: "%03d-%@.png", index, name)))
                log += "ok \(name)\n"
                try? log.write(to: directory.appendingPathComponent("progress.log"), atomically: true, encoding: .utf8)
            }
            log += "DONE \(index) screens\n"
            try? log.write(to: directory.appendingPathComponent("progress.log"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    /// End-to-end check of the selection dock on dummy files the test creates
    /// itself in ~/.maclean-smoketest (moved to the Trash by the engine).
    static func actionTest(window: NSWindow, directory: URL, index: inout Int) async -> String {
        var out = ""
        func check(_ ok: Bool, _ text: String) { out += (ok ? "PASS " : "FAIL ") + text + "\n" }
        func shot(_ name: String) {
            index += 1
            snapshot(window, to: directory.appendingPathComponent(String(format: "%03d-%@.png", index, name)))
        }
        let fm = FileManager.default
        let folder = EngineActions.home.appendingPathComponent(".maclean-smoketest")
        try? fm.removeItem(at: folder)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let names = ["one.bin", "two.bin", "three.bin"]
        for name in names {
            try? Data(repeating: 0x5A, count: 300_000).write(to: folder.appendingPathComponent(name))
        }
        let ruleID = "custom-smoketest"
        let created = RuleLab.shared.saveCustom(CustomRule(id: ruleID, title: "Smoke test files", category: .system, relativePath: "~/.maclean-smoketest", mode: .contents, risk: .safe, autoselect: false))
        check(created, "custom rule created")
        let store = CleanupStore.shared
        await store.rescan(.system)
        let paths = Set(store.items(rule: ruleID).map(\.path))
        check(paths.count == 3, "scan found \(paths.count)/3 test files through the custom rule")
        store.selection = paths
        let nav = Navigator.shared
        nav.go(.cleanup, .cleanup(.ruleGroup(ruleID)))
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let dock = SelectionDock.shared
        check(dock.active?.selected == 3, "dock shows \(dock.active?.selected ?? 0) selected, action \(dock.active?.title ?? "none")")
        shot("dock-selected")

        dock.send(.selectNone)
        try? await Task.sleep(nanoseconds: 800_000_000)
        check(store.selection.isDisjoint(with: paths) && dock.active == nil, "dock Clear deselects and hides the dock")
        shot("dock-cleared")

        store.selection.insert(paths.first ?? "")
        try? await Task.sleep(nanoseconds: 800_000_000)
        check(dock.active?.selected == 1, "dock reappears for a single checkbox (\(dock.active?.selected ?? 0))")
        dock.send(.selectAll)
        try? await Task.sleep(nanoseconds: 800_000_000)
        check(paths.isSubset(of: store.selection) && dock.active?.selected == 3, "dock Select all selects the whole list")
        shot("dock-select-all")

        dock.send(.run)
        try? await Task.sleep(nanoseconds: 500_000_000)
        while store.cleaning { try? await Task.sleep(nanoseconds: 300_000_000) }
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        let left = names.filter { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }
        check(left.isEmpty, "dock action cleaned the files (\(left.count) left in place)")
        check(store.lastClean?.removed.count == 3, "engine reports \(store.lastClean?.removed.count ?? 0) removed, \(store.lastClean?.failures.count ?? 0) failures")
        check(nav.path.last == .cleanup(.cleanResult), "navigated to the cleanup result")
        shot("dock-clean-result")

        RuleLab.shared.deleteCustom(ruleID)
        try? fm.removeItem(at: folder)
        check(!RuleBook.shared.isCustom(ruleID), "custom rule removed")
        return out
    }

    /// End-to-end check of leftover detection and removal: creates files of a
    /// made-up app that was never installed, removes them from the app group
    /// screen through the dock, and verifies they are gone.
    static func leftoverTest(window: NSWindow, directory: URL, index: inout Int) async -> String {
        var out = ""
        func check(_ ok: Bool, _ text: String) { out += (ok ? "PASS " : "FAIL ") + text + "\n" }
        func shot(_ name: String) {
            index += 1
            snapshot(window, to: directory.appendingPathComponent(String(format: "%03d-%@.png", index, name)))
        }
        let fm = FileManager.default
        let id = "com.smokeprobe.ghostwriter"
        let lib = EngineActions.home.appendingPathComponent("Library")
        let old = Date().addingTimeInterval(-120 * 86_400)
        let files = [
            "Application Support/\(id)/library.db",
            "Caches/\(id)/blob.cache",
            "Caches/\(id).ShipIt/update.zip",
            "HTTPStorages/\(id)/httpstorages.sqlite",
        ]
        var tops: [URL] = []
        for relative in files {
            let url = lib.appendingPathComponent(relative)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(repeating: 0x42, count: 200_000).write(to: url)
            let top = lib.appendingPathComponent(relative.split(separator: "/").prefix(2).joined(separator: "/"))
            tops.append(top)
            try? fm.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
            try? fm.setAttributes([.modificationDate: old], ofItemAtPath: top.path)
        }
        let prefs = lib.appendingPathComponent("Preferences/\(id).plist")
        try? (["CFBundleName": "Ghostwriter"] as NSDictionary).write(to: prefs)
        try? fm.setAttributes([.modificationDate: old], ofItemAtPath: prefs.path)
        tops.append(prefs)

        let store = AppsStore.shared
        let nav = Navigator.shared
        nav.go(.apps, .apps(.orphans))
        store.loadOrphans(force: true)
        try? await Task.sleep(nanoseconds: 500_000_000)
        while store.orphansState.isLoading { try? await Task.sleep(nanoseconds: 300_000_000) }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        shot("leftovers-list")
        let group = store.orphanGroup(id)
        check(group != nil, "engine found the probe app (\(store.visibleOrphans.count) apps with leftovers)")
        for item in group?.items ?? [] { out += "  item \(item.group): \(item.path)\n" }
        check(group?.items.count == 5, "probe group has \(group?.items.count ?? 0)/5 items in \(group?.locations.count ?? 0) locations")
        check(group?.displayName == "Ghostwriter", "display name read from preferences: \(group?.displayName ?? "-")")
        check(group?.confidence == .high, "confidence \(group?.confidence.title ?? "-")")

        nav.push(.apps(.orphanGroup(id)))
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        shot("leftovers-group")
        let dock = SelectionDock.shared
        let paths = group?.items.map(\.path) ?? []
        // Like a user: tick one box (the dock appears), then use the dock's Select all.
        store.leftoverSelection.insert(paths.first ?? "")
        try? await Task.sleep(nanoseconds: 800_000_000)
        check(dock.active?.selected == 1, "dock appears after ticking one item (\(dock.active?.title ?? "none"))")
        dock.send(.selectAll)
        try? await Task.sleep(nanoseconds: 800_000_000)
        check(Set(paths).isSubset(of: store.leftoverSelection) && dock.active?.selected == paths.count, "dock Select all picks \(dock.active?.selected ?? 0) items (\(dock.active?.title ?? "none"))")
        shot("leftovers-group-selected")
        dock.send(.run)
        try? await Task.sleep(nanoseconds: 600_000_000)
        var waited = 0
        while store.orphanGroup(id) != nil, waited < 40 { try? await Task.sleep(nanoseconds: 250_000_000); waited += 1 }
        try? await Task.sleep(nanoseconds: 800_000_000)
        shot("leftovers-group-removed")
        let left = tops.filter { fm.fileExists(atPath: $0.path) }
        check(left.isEmpty, "ArtifactCleaner moved the leftovers to the Trash (\(left.count) left)")
        check(store.lastLeftoverClean?.summary.failures.isEmpty == true && store.lastLeftoverClean?.removed.count == 5, "result: \(store.lastLeftoverClean?.removed.count ?? 0) removed, \(store.lastLeftoverClean?.summary.failures.count ?? -1) failures")
        check(store.orphanGroup(id) == nil, "group disappears from the list")
        nav.pop()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        shot("leftovers-after")
        for url in tops { try? fm.removeItem(at: url) }
        return out
    }

    /// Space Lens end to end on a folder the test builds itself.
    static func lensTest(window: NSWindow, directory: URL, index: inout Int) async -> String {
        var out = ""
        func check(_ ok: Bool, _ text: String) { out += (ok ? "PASS " : "FAIL ") + text + "\n" }
        func shot(_ name: String) {
            index += 1
            snapshot(window, to: directory.appendingPathComponent(String(format: "%03d-%@.png", index, name)))
        }
        func wait(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        let fm = FileManager.default
        let root = EngineActions.home.appendingPathComponent(".maclean-smoketest-lens")
        try? fm.removeItem(at: root)
        func make(_ relative: String, _ bytes: Int) {
            let url = root.appendingPathComponent(relative)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(repeating: 0x33, count: bytes).write(to: url)
        }
        make("big/a.bin", 4_000_000); make("big/b.bin", 2_000_000); make("big/c.bin", 1_000_000)
        make("media/clip.mov", 3_000_000); make("media/photo.jpg", 1_000_000)
        make("docs/report.pdf", 25_000_000)
        for i in 0..<60 { make("small/note\(i).txt", 1_000) }
        make("small/deep/inner/archive.zip", 600_000)

        let store = LensStore.shared
        let nav = Navigator.shared
        nav.go(.space, .space(.lensHome))
        await wait(1)
        shot("lens-home")

        // Live progress on a real scan of the home folder, then cancel.
        nav.push(.space(.lens(SpacePaths.home)))
        await wait(2.5)
        shot("lens-progress")
        let live = store.sessions[LensStore.normalize(SpacePaths.home)]?.live.files ?? 0
        check(live > 0, "live counters move during a home scan (\(live) files after 2.5 s)")
        store.cancel(SpacePaths.home)
        await wait(1.5)
        check(store.sessions[LensStore.normalize(SpacePaths.home)] == nil, "cancel stops the scan and drops the session")

        let path = LensStore.normalize(root.path)
        nav.push(.space(.lens(path)))
        var waited = 0
        while store.item(path) == nil, waited < 60 { await wait(0.25); waited += 1 }
        await wait(0.8)
        guard let item = store.item(path) else { check(false, "scan of the test folder finished"); return out }
        check(item.files == 67, "counted \(item.files)/67 files")
        let expected: Int64 = 4_000_000 + 2_000_000 + 1_000_000 + 3_000_000 + 1_000_000 + 25_000_000 + 60_000 + 600_000
        check(abs(item.bytes - expected) < 2_000_000, "size \(item.bytes) ≈ \(expected) bytes on disk")
        let small = item.find(path + "/small")
        check(small?.children.contains { $0.isAggregate } == true, "60 tiny files are grouped into one entry (\(small?.children.count ?? 0) children kept)")
        check(item.kindBytes[LensKind.video.rawValue] >= 3_000_000 && item.kindBytes[LensKind.documents.rawValue] >= 25_000_000, "per-kind totals (video \(item.kindBytes[LensKind.video.rawValue]), documents \(item.kindBytes[LensKind.documents.rawValue]))")
        check(store.largest(under: path).first?.name == "report.pdf", "largest-files list starts with report.pdf")

        for style in LensChartStyle.allCases {
            store.style = style
            await wait(0.8)
            shot("lens-\(style.rawValue.lowercased())")
        }
        store.style = .sunburst

        let sessions = store.sessions.count
        if let media = item.find(path + "/media") { LensStore.open(media, nav: nav) }
        await wait(0.8)
        check(store.sessions.count == sessions && nav.path.last == .space(.lens(path + "/media")), "drilling into a sub-folder reuses the tree (no new scan)")
        shot("lens-drill-media")
        nav.pop()
        await wait(0.6)

        let before = item.bytes
        if let big = item.find(path + "/big") {
            let summary = await store.remove([big], title: "Smoke test: Lens removal")
            check(summary.failures.isEmpty && !fm.fileExists(atPath: root.appendingPathComponent("big").path), "removed big/ through the engine (\(summary.failures.count) failures)")
        }
        await wait(0.6)
        check(item.find(path + "/big") == nil && item.bytes <= before - 7_000_000, "tree updated in place: \(Format.bytes(before)) → \(Format.bytes(item.bytes))")
        shot("lens-after-remove")

        // Smaller items: list what is folded and remove a few of them.
        if let small = item.find(path + "/small"), let aggregate = small.children.first(where: { $0.isAggregate }) {
            let countBefore = aggregate.aggregateCount
            let bytesBefore = item.bytes
            nav.push(.space(.lensSmall(small.path)))
            await wait(1.2)
            shot("lens-small-items")
            let folded = LensScanner.foldedItems(of: small)
            check(folded.count == countBefore, "smaller-items screen lists \(folded.count)/\(countBefore) grouped items")
            let victims = Array(folded.filter { !$0.isDirectory }.prefix(5))
            let summary = await store.remove(victims, title: "Smoke test: smaller items")
            await wait(0.6)
            let gone = victims.filter { !fm.fileExists(atPath: $0.path) }.count
            check(summary.failures.isEmpty && gone == 5, "removed 5 grouped files (\(gone) gone, \(summary.failures.count) failures)")
            check(aggregate.aggregateCount == countBefore - 5 && item.bytes < bytesBefore, "grouped entry shrank to \(aggregate.aggregateCount) and totals dropped")
            nav.pop()
            await wait(0.5)
        } else {
            check(false, "test folder has a smaller-items entry")
        }

        // Saved maps: drop from memory, reopen from disk.
        await wait(2.5)
        check(fm.fileExists(atPath: LensArchive.file(for: path).path), "map saved to disk after the scan")
        let bytesInMemory = item.bytes
        store.unload(path)
        nav.popToRoot()
        nav.push(.space(.lens(path)))
        waited = 0
        while store.item(path) == nil, waited < 40 { await wait(0.25); waited += 1 }
        await wait(0.8)
        let reopened = store.session(covering: path)
        check(reopened?.fromDisk == true && store.item(path)?.bytes == bytesInMemory, "reopened from the saved map (\(Format.bytes(store.item(path)?.bytes ?? 0)), from disk: \(reopened?.fromDisk == true))")
        shot("lens-saved-map")

        nav.push(.space(.lensLargest(path)))
        await wait(0.8)
        shot("lens-largest")
        nav.pop()
        nav.push(.space(.lensTypes(path)))
        await wait(0.8)
        shot("lens-types")
        store.forget(path)
        try? fm.removeItem(at: root)
        return out
    }

    /// MACLEAN_SMOKE_SIZE=WxH (default 1240x800); MACLEAN_SMOKE_SCALE=1.2 sets the interface size.
    static var smokeSize: CGSize {
        if let raw = ProcessInfo.processInfo.environment["MACLEAN_SMOKE_SCALE"], let value = Double(raw) {
            InterfaceScale.current = CGFloat(value)
        }
        let parts = (ProcessInfo.processInfo.environment["MACLEAN_SMOKE_SIZE"] ?? "").split(separator: "x").compactMap { Double($0) }
        return parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : CGSize(width: 1240, height: 800)
    }

    static func snapshot(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
