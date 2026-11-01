import MacLeanCore
import SwiftUI

enum SettingsRoute: Hashable {
    case general
    case monitoring
    case menuBar
    case history
    case historyEntry(String)
    case statistics
    case statisticsModule(String)
    case fullDiskAccess
    case permissionsGuide
    case engine
    case rules
    case ruleDetail(String)
    case yaraRules
    case cliInstall
    case appData
    case shortcuts
    case diagnostics
    case licenses
    case licenseDetail(String)
    case about
}

enum SettingsModule {
    @MainActor @ViewBuilder
    static func root() -> some View {
        SettingsHomeScreen()
    }

    @MainActor @ViewBuilder
    static func destination(_ route: SettingsRoute) -> some View {
        switch route {
        case .general: SettingsGeneralScreen()
        case .monitoring: SettingsMonitoringScreen()
        case .menuBar: SettingsMenuBarScreen()
        case .history: SettingsHistoryScreen()
        case .historyEntry(let id): SettingsHistoryEntryScreen(entryID: id)
        case .statistics: SettingsStatisticsScreen()
        case .statisticsModule(let module): SettingsStatisticsModuleScreen(module: module)
        case .fullDiskAccess: SettingsFullDiskAccessScreen()
        case .permissionsGuide: SettingsPermissionsGuideScreen()
        case .engine: SettingsEngineScreen()
        case .rules: SettingsRulesScreen()
        case .ruleDetail(let id): SettingsRuleDetailScreen(ruleID: id)
        case .yaraRules: SettingsYaraRulesScreen()
        case .cliInstall: SettingsCLIInstallScreen()
        case .appData: SettingsAppDataScreen()
        case .shortcuts: SettingsShortcutsScreen()
        case .diagnostics: SettingsDiagnosticsScreen()
        case .licenses: SettingsLicensesScreen()
        case .licenseDetail(let name): SettingsLicenseDetailScreen(name: name)
        case .about: SettingsAboutScreen()
        }
    }

    static func title(_ route: SettingsRoute) -> String {
        switch route {
        case .general: return "General"
        case .monitoring: return "Monitoring"
        case .menuBar: return "Menu Bar & Background"
        case .history: return "History"
        case .historyEntry: return "History Entry"
        case .statistics: return "Statistics"
        case .statisticsModule(let module): return module
        case .fullDiskAccess: return "Full Disk Access"
        case .permissionsGuide: return "Permissions Guide"
        case .engine: return "Engine"
        case .rules: return "Cleanup Rules"
        case .ruleDetail(let id): return id
        case .yaraRules: return "YARA Rules"
        case .cliInstall: return "Command-Line Tool"
        case .appData: return "App Data"
        case .shortcuts: return "Keyboard Shortcuts"
        case .diagnostics: return "Diagnostics"
        case .licenses: return "Licenses"
        case .licenseDetail(let name): return name
        case .about: return "About MacLean"
        }
    }
}

// MARK: - Root

struct SettingsHomeScreen: View {
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var log = ActivityLog.shared
    @ObservedObject private var monitor = SystemMonitor.shared

    var body: some View {
        ScreenScaffold("Settings", subtitle: "Preferences, history, statistics and engine details") {
            RefreshLine(state: store.engineState) { Task { await store.loadEngine() } }
        } content: {
            TileGrid {
                StatTile(label: "Total freed", value: Format.bytes(log.totalFreed), detail: "across all modules", tint: Theme.success, icon: "arrow.down.circle")
                StatTile(label: "History entries", value: Format.count(log.entries.count), detail: "\(Format.count(log.entries.reduce(0) { $0 + $1.items })) items cleaned", icon: "clock.arrow.circlepath")
                StatTile(label: "Cleanup rules", value: Format.count(Rules.all.count), detail: "\(Format.count(store.engineInfo.yaraRuleFiles.count)) YARA rule files", icon: "list.bullet.rectangle")
                StatTile(label: "CLI", value: store.engineInfo.cliPath == nil ? (store.engineState.loadedAt == nil ? "…" : "Missing") : "Found",
                         detail: store.engineInfo.cliVersion.isEmpty ? "maclean" : store.engineInfo.cliVersion,
                         tint: store.engineInfo.cliPath == nil ? Theme.warning : Theme.success, icon: "terminal")
                StatTile(label: "CPU now", value: Format.percent(monitor.latest.cpu.total), detail: store.monitorPaused ? "monitor paused" : "every \(SettingsMonitoringScreen.label(monitor.intervalSeconds))", history: monitor.cpuHistory, icon: "cpu")
            }

            SectionHeader(title: "General")
            VStack(spacing: 8) {
                NavRow(icon: "paintbrush", title: "General", subtitle: "Appearance and default removal mode", value: "\(store.appearance.title) · \(store.permanentDelete ? "Permanent" : "Trash")", route: .settings(.general))
                NavRow(icon: "waveform.path.ecg", title: "Monitoring", subtitle: "Sampling interval, pause and resume", value: store.monitorPaused ? "Paused" : SettingsMonitoringScreen.label(monitor.intervalSeconds), route: .settings(.monitoring))
                NavRow(icon: "menubar.rectangle", title: "Menu Bar & Background", subtitle: "Run in background, Dock icon, open at login, panel", value: MenuBarSettings.shared.showInDock ? (MenuBarSettings.shared.runInBackground ? "Background" : "Window only") : "Menu bar app", route: .settings(.menuBar))
                NavRow(icon: "keyboard", title: "Keyboard Shortcuts", subtitle: "Navigation keys and section jumps", route: .settings(.shortcuts))
            }

            SectionHeader(title: "Permissions")
            VStack(spacing: 8) {
                NavRow(icon: "lock.shield", title: "Full Disk Access", subtitle: "Required for Mail, Safari, Messages and TCC data", value: fdaText, tint: fdaTint, route: .settings(.fullDiskAccess))
                NavRow(icon: "questionmark.circle", title: "Permissions Guide", subtitle: "What each permission unlocks", route: .settings(.permissionsGuide))
            }

            SectionHeader(title: "Engine")
            VStack(spacing: 8) {
                NavRow(icon: "gearshape.2", title: "Engine", subtitle: "CLI, rules, YARA, threat corpus", value: store.engineInfo.cliVersion.isEmpty ? nil : store.engineInfo.cliVersion, route: .settings(.engine))
                NavRow(icon: "list.bullet.rectangle", title: "Cleanup Rules", subtitle: "Every rule the cleaner applies", value: Format.count(Rules.all.count), route: .settings(.rules))
                NavRow(icon: "shield.checkered", title: "YARA Rules", subtitle: "Bundled signature-base rule files", value: Format.count(store.engineInfo.yaraRuleFiles.count), route: .settings(.yaraRules))
                NavRow(icon: "terminal", title: "Command-Line Tool", subtitle: "Link maclean into /usr/local/bin", value: store.cliLink.exists ? "Installed" : "Not linked", route: .settings(.cliInstall))
            }

            SectionHeader(title: "Data")
            VStack(spacing: 8) {
                NavRow(icon: "clock.arrow.circlepath", title: "History", subtitle: "Every clean, removal and failure", value: Format.count(log.entries.count), route: .settings(.history))
                NavRow(icon: "chart.bar.xaxis", title: "Statistics", subtitle: "Freed space per module and per day", value: Format.bytes(log.totalFreed), route: .settings(.statistics))
                NavRow(icon: "folder", title: "App Data", subtitle: "~/Library/Application Support/MacLean", value: Format.bytes(store.appDataEntries.reduce(0) { $0 + $1.bytes }), route: .settings(.appData))
                NavRow(icon: "stethoscope", title: "Diagnostics", subtitle: "System and app report to copy or save", route: .settings(.diagnostics))
            }

            SectionHeader(title: "About")
            VStack(spacing: 8) {
                NavRow(icon: "doc.text", title: "Licenses", subtitle: "YARA, OpenSSL and signature-base notices", value: store.licenses.isEmpty ? nil : Format.count(store.licenses.count), route: .settings(.licenses))
                NavRow(icon: "info.circle", title: "About & Updates", subtitle: "Version, software update, project information", value: Updater.shared.updateAvailable ? "Update to \(Updater.shared.release?.version ?? "")" : SettingsStore.appVersion, route: .settings(.about))
            }
        }
        .onAppear {
            store.applyAppearance()
            store.loadEngineIfNeeded()
            store.loadAccessIfNeeded()
            store.loadAppDataIfNeeded()
            store.loadLicensesIfNeeded()
        }
    }

    private var fdaText: String {
        switch store.fullDiskAccessGranted {
        case .some(true): return "Granted"
        case .some(false): return "Not granted"
        case .none: return store.accessState.isLoading ? "Checking…" : "Unknown"
        }
    }

    private var fdaTint: Color {
        switch store.fullDiskAccessGranted {
        case .some(true): return Theme.success
        case .some(false): return Theme.danger
        case .none: return Theme.accent
        }
    }
}
