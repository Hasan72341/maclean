import AppKit
import MacLeanCore
import SwiftUI

// MARK: - General

struct SettingsGeneralScreen: View {
    @ObservedObject private var store = SettingsStore.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScreenScaffold("General", subtitle: "Appearance and how MacLean removes files") {
            TileGrid {
                StatTile(label: "Appearance", value: store.appearance.title, detail: "rendering \(scheme == .dark ? "dark" : "light")", icon: store.appearance.icon)
                StatTile(label: "Removal", value: store.permanentDelete ? "Permanent" : "Trash", detail: store.permanentDelete ? "files skip the Trash" : "recoverable from Trash", tint: store.permanentDelete ? Theme.danger : Theme.success, icon: "trash")
                StatTile(label: "Trash now", value: store.trashBytes.map(Format.bytes) ?? "…", detail: "~/.Trash", icon: "trash.circle")
            }

            InterfaceSizeCard()
            Card("Appearance", trailing: "saved to maclean.appearance") {
                HStack(spacing: 12) {
                    ForEach(SettingsAppearance.allCases, id: \.self) { option in
                        Button {
                            store.setAppearance(option)
                        } label: {
                            VStack(spacing: 8) {
                                Image(systemName: option.icon).font(.system(size: 22))
                                    .foregroundStyle(store.appearance == option ? Theme.accent : Theme.muted)
                                Text(option.title).font(Type.text(12, weight: .medium)).foregroundStyle(Theme.ink)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(RoundedRectangle(cornerRadius: 10).fill(store.appearance == option ? Theme.accent.opacity(0.12) : Theme.paper))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(store.appearance == option ? Theme.accent : Theme.line, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Card("Default removal", trailing: "saved to maclean.permanentDelete") {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsRadioRow(selected: !store.permanentDelete, title: "Move to Trash", detail: "Recommended. Removed items can be restored from the Trash until it is emptied.") {
                        store.setPermanentDelete(false)
                    }
                    SettingsRadioRow(selected: store.permanentDelete, title: "Delete permanently", detail: "Frees space immediately. Removed items cannot be recovered.") {
                        store.setPermanentDelete(true)
                    }
                }
            }

            Card("Related") {
                VStack(spacing: 8) {
                    NavRow(icon: "waveform.path.ecg", title: "Monitoring", subtitle: "Sampling interval and live preview", route: .settings(.monitoring))
                    NavRow(icon: "lock.shield", title: "Full Disk Access", subtitle: "Unlock protected locations", route: .settings(.fullDiskAccess))
                }
            }
        }
        .task { await store.loadTrashSize() }
    }
}

struct SettingsRadioRow: View {
    let selected: Bool
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Theme.accent : Theme.faint)
                    .font(.system(size: 14))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Type.text(13, weight: .medium)).foregroundStyle(Theme.ink)
                    Text(detail).font(Type.text(11)).foregroundStyle(Theme.muted)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Monitoring

struct SettingsMonitoringScreen: View {
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var monitor = SystemMonitor.shared

    static let intervals: [Double] = [0.5, 1, 2, 3, 5, 10]

    static func label(_ seconds: Double) -> String {
        seconds < 1 ? "\(Int(seconds * 1000)) ms" : "\(Int(seconds)) s"
    }

    var body: some View {
        ScreenScaffold("Monitoring", subtitle: "Live system sampling used by graphs across the app") {
            Button(store.monitorPaused ? "Resume" : "Pause") { store.toggleMonitor() }
                .buttonStyle(EditorialButtonStyle(kind: store.monitorPaused ? .primary : .secondary))
        } content: {
            TileGrid {
                StatTile(label: "Status", value: store.monitorPaused ? "Paused" : "Live", detail: "last sample \(Format.relative(monitor.latest.date))", tint: store.monitorPaused ? Theme.warning : Theme.success, icon: "dot.radiowaves.left.and.right")
                StatTile(label: "Interval", value: Self.label(monitor.intervalSeconds), detail: "\(String(format: "%.1f", 60 / max(0.25, monitor.intervalSeconds))) samples/min", icon: "timer")
                StatTile(label: "History window", value: Format.duration(Double(SystemMonitor.historyLength) * monitor.intervalSeconds), detail: "\(SystemMonitor.historyLength) samples kept", icon: "clock")
                StatTile(label: "CPU", value: Format.percent(monitor.latest.cpu.total, digits: 1), detail: "\(monitor.latest.cpu.cores.count) cores", tint: Theme.accent, history: monitor.cpuHistory, icon: "cpu")
                StatTile(label: "Memory", value: Format.percent(monitor.latest.memory.usedFraction), detail: Format.bytes(monitor.latest.memory.used), tint: Theme.info, history: monitor.memoryHistory, icon: "memorychip")
            }

            Card("Sampling interval") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        ForEach(Self.intervals, id: \.self) { value in
                            Button(Self.label(value)) { store.setInterval(value) }
                                .buttonStyle(EditorialButtonStyle(kind: abs(monitor.intervalSeconds - value) < 0.01 ? .primary : .secondary))
                        }
                    }
                    Text("Shorter intervals make graphs smoother but use more CPU. The choice is remembered across launches.")
                        .font(Type.text(11)).foregroundStyle(Theme.muted)
                }
            }

            Card("Live preview", trailing: "\(monitor.cpuHistory.count) samples") {
                LiveChart(series: [
                    .init(values: monitor.cpuUserHistory, color: Theme.accent, label: "User"),
                    .init(values: monitor.cpuSystemHistory, color: Theme.info, label: "System"),
                    .init(values: monitor.memoryHistory, color: Theme.success, label: "Memory", fill: false),
                ], maxValue: 1, format: { Format.percent($0) })
            }

            Card("Network and disk", trailing: "per second") {
                LiveChart(series: [
                    .init(values: monitor.netRxHistory, color: Theme.success, label: "Down"),
                    .init(values: monitor.netTxHistory, color: Theme.accent, label: "Up"),
                    .init(values: monitor.diskReadHistory, color: Theme.info, label: "Disk read", fill: false),
                    .init(values: monitor.diskWriteHistory, color: Theme.warning, label: "Disk write", fill: false),
                ], format: { Format.rate($0) }, height: 120)
            }

            Card("Elsewhere") {
                NavRow(icon: "gauge.with.dots.needle.67percent", title: "Open Dashboard", subtitle: "Full live system overview", action: { Navigator.shared.go(.dashboard) })
            }
        }
    }
}

// MARK: - Shortcuts

struct SettingsShortcutsScreen: View {
    private let keys: [(String, String, String)] = [
        ("⌘ [", "Back", "Return to the previous screen in the current section"),
        ("Esc", "Back", "Same as ⌘ [ — pops one screen"),
        ("⌘ Q", "Quit", "Quit MacLean"),
        ("⌘ W", "Close window", "Close the MacLean window"),
        ("⌘ M", "Minimize", "Minimize the window to the Dock"),
        ("⌃ ⌘ F", "Full screen", "Toggle full-screen mode"),
    ]

    var body: some View {
        ScreenScaffold("Keyboard Shortcuts", subtitle: "Keys that work everywhere in MacLean") {
            TileGrid {
                StatTile(label: "Shortcuts", value: Format.count(keys.count), icon: "keyboard")
                StatTile(label: "Sections", value: Format.count(AppSection.allCases.count), detail: "jump below", icon: "sidebar.left")
            }
            Card("Keys") {
                VStack(spacing: 0) {
                    ForEach(Array(keys.enumerated()), id: \.offset) { item in
                        HStack(spacing: 14) {
                            Text(item.element.0)
                                .font(Type.mono(12, weight: .semibold))
                                .foregroundStyle(Theme.ink)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.paper))
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.lineStrong))
                                .frame(width: 80, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.element.1).font(Type.text(13, weight: .medium)).foregroundStyle(Theme.ink)
                                Text(item.element.2).font(Type.text(11)).foregroundStyle(Theme.muted)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 8)
                        if item.offset < keys.count - 1 { Hairline() }
                    }
                }
            }
            Card("Jump to section") {
                VStack(spacing: 8) {
                    ForEach(AppSection.allCases.filter { $0 != .settings }) { section in
                        NavRow(icon: section.icon, title: section.title, subtitle: section.group, action: { Navigator.shared.go(section) })
                    }
                }
            }
        }
    }
}

// MARK: - About

struct SettingsAboutScreen: View {
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var log = ActivityLog.shared

    var body: some View {
        ScreenScaffold("About MacLean", subtitle: "An open-source Mac cleaner") {
            HStack(spacing: 18) {
                Image(systemName: "archivebox")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 72, height: 72)
                    .background(RoundedRectangle(cornerRadius: 18).fill(Theme.accent.opacity(0.12)))
                VStack(alignment: .leading, spacing: 4) {
                    Text("MacLean").font(Type.display(30, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text("Version \(SettingsStore.appVersion)").font(Type.mono(12)).foregroundStyle(Theme.muted)
                }
            }
            TileGrid {
                StatTile(label: "Freed so far", value: Format.bytes(log.totalFreed), tint: Theme.success, icon: "arrow.down.circle")
                StatTile(label: "Cleanup rules", value: Format.count(Rules.all.count), icon: "list.bullet")
                StatTile(label: "YARA rules", value: Format.count(store.engineInfo.yaraRuleFiles.count), icon: "shield")
                StatTile(label: "CLI", value: store.engineInfo.cliVersion.isEmpty ? "—" : store.engineInfo.cliVersion, icon: "terminal")
            }
            Card("About") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("MacLean finds and removes junk, leftovers, caches, large and duplicate files, privacy traces and malware on macOS. Every removal is re-validated by the engine and goes to the Trash by default.")
                        .font(Type.text(13)).foregroundStyle(Theme.ink)
                    Text("MacLean is an original clean-room implementation. It is not affiliated with, endorsed by, or derived from MacPaw or CleanMyMac.")
                        .font(Type.text(12)).foregroundStyle(Theme.muted)
                }
            }
            SoftwareUpdateCard()
            Card("Details") {
                VStack(spacing: 0) {
                    KeyValueRow(key: "App version", value: SettingsStore.appVersion, mono: true)
                    KeyValueRow(key: "Engine", value: "MacLeanCore", mono: true)
                    KeyValueRow(key: "macOS", value: ProcessInfo.processInfo.operatingSystemVersionString, mono: true)
                    KeyValueRow(key: "Bundle", value: Format.abbreviated(Bundle.main.bundlePath), mono: true)
                }
            }
            VStack(spacing: 8) {
                NavRow(icon: "doc.text", title: "Licenses", subtitle: "Third-party notices", route: .settings(.licenses))
                NavRow(icon: "stethoscope", title: "Diagnostics", subtitle: "Copy a system report", route: .settings(.diagnostics))
                NavRow(icon: "gearshape.2", title: "Engine", subtitle: "Rules, YARA and CLI", route: .settings(.engine))
            }
        }
        .onAppear { store.loadEngineIfNeeded() }
    }
}

// MARK: - Full Disk Access

struct SettingsFullDiskAccessScreen: View {
    @ObservedObject private var store = SettingsStore.shared
    static let settingsURL = SystemPane.privacy(.fullDiskAccess).urlString

    var body: some View {
        ScreenScaffold("Full Disk Access", subtitle: "Detected by reading protected files directly") {
            RefreshLine(state: store.accessState) { Task { await store.checkAccess() } }
        } content: {
            let granted = store.fullDiskAccessGranted
            TileGrid {
                StatTile(label: "Status", value: granted == true ? "Granted" : granted == false ? "Not granted" : "Unknown",
                         tint: granted == true ? Theme.success : granted == false ? Theme.danger : Theme.ink, icon: "lock.shield")
                StatTile(label: "Readable", value: "\(store.accessProbes.filter(\.readable).count)/\(store.accessProbes.filter(\.exists).count)", detail: "protected locations", icon: "eye")
                StatTile(label: "Blocked", value: Format.count(store.accessProbes.filter { $0.exists && !$0.readable }.count), tint: Theme.danger, icon: "xmark.octagon")
                StatTile(label: "Checked", value: Format.relative(store.accessState.loadedAt), icon: "clock")
            }

            if store.accessState.isLoading && store.accessProbes.isEmpty {
                LoadingPanel(text: "Probing protected locations…")
            } else if store.accessProbes.isEmpty {
                EmptyPanel(icon: "lock.shield", title: "Not checked yet", actionTitle: "Check now") { Task { await store.checkAccess() } }
            } else {
                Card("Probes") {
                    VStack(spacing: 8) {
                        ForEach(store.accessProbes) { probe in
                            HStack(spacing: 10) {
                                Image(systemName: !probe.exists ? "minus.circle" : probe.readable ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(!probe.exists ? Theme.faint : probe.readable ? Theme.success : Theme.danger)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(probe.label).font(Type.text(13, weight: .medium)).foregroundStyle(Theme.ink)
                                    Text(Format.abbreviated(probe.path)).font(Type.mono(10)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                Text(probe.detail).font(Type.text(11)).foregroundStyle(Theme.muted).lineLimit(1)
                                if probe.exists {
                                    Button("Reveal") { EngineActions.reveal(probe.path) }.buttonStyle(EditorialButtonStyle(kind: .inline))
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }

            FullDiskAccessHelper()
            NavRow(icon: "questionmark.circle", title: "Permissions Guide", subtitle: "What each permission unlocks", route: .settings(.permissionsGuide))
        }
        .onAppear { store.loadAccessIfNeeded() }
    }
}

// MARK: - Permissions guide

struct SettingsPermissionsGuideScreen: View {
    @ObservedObject private var store = SettingsStore.shared

    private struct Item: Identifiable {
        let id: String
        let icon: String
        let title: String
        let unlocks: String
        let pane: String
    }

    private let items: [Item] = [
        Item(id: "fda", icon: "lock.shield", title: "Full Disk Access", unlocks: "Mail attachments and downloads, Safari history and caches, Messages attachments, TCC privacy records, protected app containers.", pane: "Privacy_AllFiles"),
        Item(id: "automation", icon: "applescript", title: "Automation", unlocks: "Quitting running apps before uninstall and asking Finder to empty the Trash.", pane: "Privacy_Automation"),
        Item(id: "files", icon: "folder", title: "Files and Folders", unlocks: "Scanning Desktop, Documents, Downloads and removable volumes for large and duplicate files.", pane: "Privacy_FilesAndFolders"),
        Item(id: "photos", icon: "photo", title: "Photos", unlocks: "Measuring the Photos library and its caches.", pane: "Privacy_Photos"),
        Item(id: "admin", icon: "key", title: "Administrator password", unlocks: "System-wide caches and logs, installing the command-line link, flushing DNS and other maintenance tasks. Asked per operation, never stored.", pane: ""),
    ]

    var body: some View {
        ScreenScaffold("Permissions Guide", subtitle: "What MacLean needs and why") {
            TileGrid {
                StatTile(label: "Permissions", value: Format.count(items.count), icon: "checklist")
                StatTile(label: "Full Disk Access", value: store.fullDiskAccessGranted == true ? "Granted" : store.fullDiskAccessGranted == false ? "Missing" : "Unknown",
                         tint: store.fullDiskAccessGranted == true ? Theme.success : Theme.warning, icon: "lock.shield")
            }
            ForEach(items) { item in
                Card {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: item.icon).font(.system(size: 16)).foregroundStyle(Theme.accent)
                            .frame(width: 32, height: 32)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent.opacity(0.12)))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(Type.text(14, weight: .semibold)).foregroundStyle(Theme.ink)
                            Text(item.unlocks).font(Type.text(12)).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        if !item.pane.isEmpty {
                            Button("Open") {
                                SystemPane.privacy(SystemPane.Anchor(rawValue: item.pane) ?? .fullDiskAccess).open()
                            }
                        }
                    }
                }
            }
            NavRow(icon: "lock.shield", title: "Check Full Disk Access", route: .settings(.fullDiskAccess))
        }
        .onAppear { store.loadAccessIfNeeded() }
    }
}


/// Interface size: scales every font and the layout with it, for small
/// screens or large display scaling. Also ⌘+ / ⌘− / ⌘0.
struct InterfaceSizeCard: View {
    @ObservedObject private var scale = InterfaceScale.shared
    @ObservedObject private var sidebar = SidebarState.shared
    @Environment(\.windowWidth) private var windowWidth

    var body: some View {
        Card("Interface size", trailing: "⌘+  ⌘−  ⌘0") {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { buttons }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 6)], alignment: .leading, spacing: 6) { buttons }
                }
                Text("Makes text and controls larger or smaller across MacLean, for small screens, high display scaling, or easier reading. The window keeps fitting your screen.")
                    .font(Type.text(11)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("Sidebar").font(Type.text(12)).foregroundStyle(Theme.ink)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { sidebar.userCollapsed.map { $0 ? 2 : 1 } ?? 0 },
                        set: { sidebar.userCollapsed = $0 == 0 ? nil : ($0 == 2) }
                    )) {
                        Text("Automatic").tag(0)
                        Text("Full").tag(1)
                        Text("Icons only").tag(2)
                    }
                    .pickerStyle(.segmented).labelsHidden().flexibleWidth(300)
                }
                Text("Automatic shows icons only when the window is narrow (⌃⌘S toggles).")
                    .font(Type.text(11)).foregroundStyle(Theme.muted)
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        ForEach(InterfaceScale.steps, id: \.self) { step in
            Button(InterfaceScale.label(step)) { scale.value = step }
                .buttonStyle(EditorialButtonStyle(kind: abs(scale.value - step) < 0.01 ? .primary : .secondary))
                .fixedSize()
        }
    }
}
