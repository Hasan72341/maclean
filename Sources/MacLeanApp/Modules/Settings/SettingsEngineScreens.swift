import AppKit
import MacLeanCore
import SwiftUI

// MARK: - Engine

struct SettingsEngineScreen: View {
    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        let info = store.engineInfo
        ScreenScaffold("Engine", subtitle: "MacLeanCore, the maclean CLI and bundled rule sets") {
            RefreshLine(state: store.engineState) { Task { await store.loadEngine() } }
        } content: {
            TileGrid {
                StatTile(label: "CLI", value: info.cliPath == nil ? "Missing" : "Found", detail: info.cliVersion.isEmpty ? nil : info.cliVersion, tint: info.cliPath == nil ? Theme.warning : Theme.success, icon: "terminal")
                StatTile(label: "Cleanup rules", value: Format.count(info.rulesCount), detail: "\(info.safeRules) safe · \(info.cautionRules) caution", icon: "list.bullet.rectangle")
                StatTile(label: "YARA rule files", value: Format.count(info.yaraRuleFiles.count), detail: Format.bytes(info.yaraRuleBytes), icon: "shield.checkered")
                StatTile(label: "Need root", value: Format.count(info.rootRules), detail: "\(info.scanOnlyRules) scan-only", tint: Theme.warning, icon: "key")
            }

            if store.engineState.isLoading && info.rulesCount == 0 {
                LoadingPanel(text: "Inspecting engine…")
            } else if case .failed(let message) = store.engineState {
                ErrorPanel(message: message) { Task { await store.loadEngine() } }
            }

            Card("Command-line tool") {
                VStack(spacing: 0) {
                    KeyValueRow(key: "Path", value: info.cliPath.map(Format.abbreviated) ?? "not found", mono: true)
                    KeyValueRow(key: "maclean version", value: info.cliVersion.isEmpty ? "—" : info.cliVersion, mono: true)
                    KeyValueRow(key: "Exit status", value: info.cliStatus.map { "\($0)" } ?? "—", mono: true)
                    if !info.cliStderr.isEmpty {
                        KeyValueRow(key: "stderr", value: info.cliStderr, mono: true)
                    }
                    KeyValueRow(key: "/usr/local/bin link", value: store.cliLink.exists ? (store.cliLink.destination.map(Format.abbreviated) ?? "present (not a link)") : "not installed", mono: true)
                }
                HStack {
                    if let path = info.cliPath {
                        Button("Reveal") { EngineActions.reveal(path) }
                    }
                    Spacer()
                }
                .padding(.top, 8)
            }

            Card("Rules by category") {
                VStack(spacing: 6) {
                    ForEach(info.rulesByCategory, id: \.0) { item in
                        BarRow(label: item.0, value: Double(item.1), total: Double(max(1, info.rulesByCategory.first?.1 ?? 1)), valueText: Format.count(item.1)) {
                            Navigator.shared.push(.settings(.rules))
                        }
                    }
                }
            }

            Card("Threat intelligence") {
                VStack(spacing: 0) {
                    KeyValueRow(key: "Corpus URL", value: info.corpusURL, mono: true)
                    KeyValueRow(key: "YARA directory", value: info.yaraDirectory.map(Format.abbreviated) ?? "not found", mono: true)
                    KeyValueRow(key: "Resources", value: info.resourcesDirectory.map(Format.abbreviated) ?? "—", mono: true)
                    ForEach(info.bundledBinaries, id: \.0) { item in
                        KeyValueRow(key: "bin/\(item.0)", value: Format.bytes(item.1), mono: true)
                    }
                }
                HStack(spacing: 10) {
                    Button("Copy corpus URL") { SettingsStore.copy(info.corpusURL) }
                    if let dir = info.yaraDirectory {
                        Button("Reveal rules") { EngineActions.reveal(dir) }
                    }
                    Spacer()
                }
                .padding(.top, 8)
            }

            VStack(spacing: 8) {
                NavRow(icon: "list.bullet.rectangle", title: "Cleanup Rules", value: Format.count(info.rulesCount), route: .settings(.rules))
                NavRow(icon: "shield.checkered", title: "YARA Rules", value: Format.count(info.yaraRuleFiles.count), route: .settings(.yaraRules))
                NavRow(icon: "terminal", title: "Install Command-Line Tool", value: store.cliLink.exists ? "Installed" : "Not linked", route: .settings(.cliInstall))
                NavRow(icon: "stethoscope", title: "Diagnostics", route: .settings(.diagnostics))
            }
        }
        .onAppear { store.loadEngineIfNeeded() }
    }
}

// MARK: - Rules

enum SettingsRuleText {
    static func location(_ location: Location) -> String {
        switch location {
        case .home(let sub): return "~/" + sub
        case .absolute(let path): return path
        case .volumeTrashes: return "/Volumes/*/.Trashes"
        case .containerCaches: return "~/Library/Containers/*/Data/Library/Caches"
        case .containerSubpath(let sub): return "~/Library/Containers/*/Data/" + sub
        }
    }

    static func mode(_ mode: RuleMode) -> String {
        switch mode {
        case .contents: return "Contents of folder"
        case .whole: return "Whole item"
        case .largeFiles(let days): return days.map { "Large files older than \($0) days" } ?? "Large files"
        }
    }

    static func resolvedPath(_ location: Location) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        switch location {
        case .home(let sub): return home + "/" + sub
        case .absolute(let path): return path
        case .containerCaches, .containerSubpath: return home + "/Library/Containers"
        case .volumeTrashes: return "/Volumes"
        }
    }
}

struct SettingsRulesScreen: View {
    @State private var query = ""
    @State private var category = "All"
    @State private var risk = "All"

    var body: some View {
        let all = Rules.all
        let categories = ["All"] + Array(Set(all.map { $0.category.title })).sorted()
        let list = all.filter { rule in
            (category == "All" || rule.category.title == category)
                && (risk == "All" || rule.risk.rawValue == risk.lowercased() || (risk == "Root" && rule.requiresRoot))
                && (query.isEmpty || rule.title.localizedCaseInsensitiveContains(query) || rule.id.localizedCaseInsensitiveContains(query) || SettingsRuleText.location(rule.location).localizedCaseInsensitiveContains(query))
        }
        ScreenScaffold("Cleanup Rules", subtitle: "Locations the cleaner is allowed to scan and clean") {
            TileGrid {
                StatTile(label: "Shown", value: Format.count(list.count), detail: "of \(Format.count(all.count))", icon: "list.bullet")
                StatTile(label: "Safe", value: Format.count(list.filter { $0.risk == .safe }.count), tint: Theme.success, icon: "checkmark.shield")
                StatTile(label: "Caution", value: Format.count(list.filter { $0.risk == .caution }.count), tint: Theme.warning, icon: "exclamationmark.triangle")
                StatTile(label: "Auto-selected", value: Format.count(list.filter(\.autoselect).count), icon: "checkmark.square")
                StatTile(label: "Need root", value: Format.count(list.filter(\.requiresRoot).count), icon: "key")
            }
            HStack(spacing: 12) {
                SearchField(text: $query, prompt: "Search rules or paths")
                EditorialPicker(label: "Category", selection: $category, options: categories) { $0 }
                EditorialPicker(label: "Risk", selection: $risk, options: ["All", "Safe", "Caution", "Root"]) { $0 }
            }
            if list.isEmpty {
                EmptyPanel(icon: "magnifyingglass", title: "No rules match", actionTitle: "Reset") { query = ""; category = "All"; risk = "All" }
            } else {
                VStack(spacing: 8) {
                    ForEach(list) { rule in
                        NavRow(icon: rule.risk == .caution ? "exclamationmark.triangle" : "checkmark.shield",
                               title: rule.title,
                               subtitle: "\(rule.category.title) · \(SettingsRuleText.location(rule.location))",
                               value: rule.requiresRoot ? "root" : (rule.scanOnly ? "scan only" : nil),
                               tint: rule.risk == .caution ? Theme.warning : Theme.success,
                               route: .settings(.ruleDetail(rule.id)))
                    }
                }
            }
        }
    }
}

struct SettingsRuleDetailScreen: View {
    let ruleID: String
    @State private var size: SizeInfo?
    @State private var measuring = false

    var body: some View {
        let rule = Rules.all.first { $0.id == ruleID }
        ScreenScaffold(rule?.title ?? ruleID, subtitle: rule.map { $0.category.title }) {
            if let rule {
                let path = SettingsRuleText.resolvedPath(rule.location)
                TileGrid {
                    StatTile(label: "Risk", value: rule.risk.rawValue.capitalized, tint: rule.risk == .caution ? Theme.warning : Theme.success, icon: "shield")
                    StatTile(label: "Current size", value: measuring ? "…" : (size.map { Format.bytes($0.bytes) } ?? "—"), detail: size.map { "\(Format.count($0.files)) files" }, icon: "internaldrive")
                    StatTile(label: "Auto-select", value: rule.autoselect ? "Yes" : "No", icon: "checkmark.square")
                    StatTile(label: "Root", value: rule.requiresRoot ? "Required" : "No", tint: rule.requiresRoot ? Theme.warning : Theme.ink, icon: "key")
                }
                Card("Definition") {
                    VStack(spacing: 0) {
                        KeyValueRow(key: "Identifier", value: rule.id, mono: true)
                        KeyValueRow(key: "Category", value: rule.category.title)
                        KeyValueRow(key: "Location", value: SettingsRuleText.location(rule.location), mono: true)
                        KeyValueRow(key: "Mode", value: SettingsRuleText.mode(rule.mode))
                        KeyValueRow(key: "Scan only", value: rule.scanOnly ? "Yes — reported, never removed" : "No")
                        KeyValueRow(key: "Excludes", value: rule.excludes.isEmpty ? "—" : rule.excludes.joined(separator: ", "), mono: true)
                        KeyValueRow(key: "Measured", value: size?.modified.map { "modified \(Format.relative($0))" } ?? "—")
                    }
                }
                HStack(spacing: 10) {
                    if let path, FileManager.default.fileExists(atPath: path) {
                        Button("Reveal in Finder") { EngineActions.reveal(path) }
                        Button("Measure") { Task { await measure(path) } }.disabled(measuring)
                    } else {
                        Text("Location not present on this Mac").font(Type.text(12)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Button("Clean in Cleanup") { Navigator.shared.go(.cleanup) }.buttonStyle(EditorialButtonStyle(kind: .primary))
                }
            } else {
                EmptyPanel(icon: "questionmark", title: "Rule not found")
            }
        }
        .task {
            if let rule, let path = SettingsRuleText.resolvedPath(rule.location), FileManager.default.fileExists(atPath: path) {
                await measure(path)
            }
        }
    }

    private func measure(_ path: String) async {
        measuring = true
        size = await engine { FileSizer.measure(URL(fileURLWithPath: path)) }
        measuring = false
    }
}

// MARK: - YARA rules

struct SettingsYaraRulesScreen: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var query = ""

    var body: some View {
        let files = store.engineInfo.yaraRuleFiles
        let list = query.isEmpty ? files : files.filter { ($0 as NSString).lastPathComponent.localizedCaseInsensitiveContains(query) }
        ScreenScaffold("YARA Rules", subtitle: store.engineInfo.yaraDirectory.map(Format.abbreviated) ?? "Bundled signature-base rules") {
            RefreshLine(state: store.engineState) { Task { await store.loadEngine() } }
        } content: {
            TileGrid {
                StatTile(label: "Rule files", value: Format.count(files.count), icon: "doc.text")
                StatTile(label: "Total size", value: Format.bytes(store.engineInfo.yaraRuleBytes), icon: "internaldrive")
                StatTile(label: "Shown", value: Format.count(list.count), icon: "line.3.horizontal.decrease")
            }
            HStack(spacing: 10) {
                SearchField(text: $query, prompt: "Filter rule files")
                if let dir = store.engineInfo.yaraDirectory {
                    Button("Reveal folder") { EngineActions.reveal(dir) }
                }
                Button("Scan with these") { Navigator.shared.go(.protection) }.buttonStyle(EditorialButtonStyle(kind: .primary))
            }
            if store.engineState.isLoading && files.isEmpty {
                LoadingPanel(text: "Locating rule files…")
            } else if files.isEmpty {
                EmptyPanel(icon: "shield.slash", title: "No bundled YARA rules found", message: "The rules directory was not located in the app resources.")
            } else {
                VStack(spacing: 6) {
                    ForEach(list, id: \.self) { path in
                        HStack(spacing: 10) {
                            Image(systemName: "doc.text").foregroundStyle(Theme.accent)
                            Text((path as NSString).lastPathComponent).font(Type.mono(12)).foregroundStyle(Theme.ink)
                            Spacer()
                            Button("Open") { EngineActions.open(path) }.buttonStyle(EditorialButtonStyle(kind: .inline))
                            Button("Reveal") { EngineActions.reveal(path) }.buttonStyle(EditorialButtonStyle(kind: .inline))
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.canvas))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
                    }
                }
            }
        }
        .onAppear { store.loadEngineIfNeeded() }
    }
}

// MARK: - CLI install

struct SettingsCLIInstallScreen: View {
    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        let link = store.cliLink
        let command = store.installCommand()
        ScreenScaffold("Command-Line Tool", subtitle: "Use maclean from any terminal") {
            RefreshLine(state: store.engineState) { Task { await store.loadEngine() } }
        } content: {
            TileGrid {
                StatTile(label: "Link", value: link.exists ? (link.isSymlink ? "Installed" : "File present") : "Not linked", tint: link.exists ? Theme.success : Theme.warning, icon: "link")
                StatTile(label: "Target", value: link.pointsToBundled ? "This app" : (link.exists ? "Other" : "—"), detail: link.destination.map(Format.abbreviated), icon: "arrow.right.circle")
                StatTile(label: "CLI", value: store.engineInfo.cliPath == nil ? "Missing" : "Found", detail: store.engineInfo.cliVersion.isEmpty ? nil : store.engineInfo.cliVersion, icon: "terminal")
            }

            if let command {
                Card("Manual install", trailing: "needs administrator") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(command).font(Type.mono(12)).foregroundStyle(Theme.ink).textSelection(.enabled)
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.paper))
                        HStack(spacing: 10) {
                            Button("Copy command") { SettingsStore.copy(command) }
                            ConfirmButton(title: link.exists ? "Reinstall Link" : "Install Link", message: "MacLean will ask macOS for your administrator password and create a symbolic link at \(SettingsStore.linkPath) pointing to \(store.engineInfo.cliPath ?? "the bundled CLI").", kind: .primary, disabled: store.cliInstallBusy) {
                                Task { await store.installCLI() }
                            }
                            if link.isSymlink {
                                ConfirmButton(title: "Remove Link", message: "Removes the symbolic link \(SettingsStore.linkPath) (administrator password required). The app itself is not affected.", kind: .destructive, disabled: store.cliInstallBusy) {
                                    Task { await store.uninstallCLI() }
                                }
                            }
                            if store.cliInstallBusy { ProgressView().controlSize(.small) }
                        }
                    }
                }
            } else if store.engineState.isLoading {
                LoadingPanel(text: "Locating the maclean CLI…")
            } else {
                ErrorPanel(message: "The maclean CLI was not found next to the app. Build it with `swift build -c release` or reinstall MacLean.") {
                    Task { await store.loadEngine() }
                }
            }

            if !store.cliInstallOutput.isEmpty {
                Card("Output") {
                    Text(store.cliInstallOutput).font(Type.mono(11)).foregroundStyle(Theme.ink).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Card("After installing") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(["maclean version", "maclean scan", "maclean clean", "maclean deep --json", "maclean rules", "maclean help"], id: \.self) { line in
                        HStack {
                            Text("$ " + line).font(Type.mono(12)).foregroundStyle(Theme.ink)
                            Spacer()
                            Button("Copy") { SettingsStore.copy(line) }.buttonStyle(EditorialButtonStyle(kind: .inline))
                        }
                    }
                }
            }
        }
        .onAppear {
            store.loadEngineIfNeeded()
            store.refreshCLILink()
        }
    }
}

// MARK: - Diagnostics

struct SettingsDiagnosticsScreen: View {
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var monitor = SystemMonitor.shared
    @State private var text = ""

    var body: some View {
        ScreenScaffold("Diagnostics", subtitle: "System and app report") {
            Button("Regenerate") { text = store.diagnosticsText() }
            Button("Copy") { SettingsStore.copy(text) }
            Button("Save…") { SettingsStore.save(text: text, suggestedName: "maclean-diagnostics.txt") }
                .buttonStyle(EditorialButtonStyle(kind: .primary))
        } content: {
            TileGrid {
                StatTile(label: "Health", value: "\(monitor.latest.healthScore)", unit: "/100", history: monitor.healthHistory, icon: "heart")
                StatTile(label: "CPU", value: Format.percent(monitor.latest.cpu.total), history: monitor.cpuHistory, icon: "cpu")
                StatTile(label: "Memory", value: Format.percent(monitor.latest.memory.usedFraction), detail: monitor.latest.memory.pressureTitle, history: monitor.memoryHistory, icon: "memorychip")
                StatTile(label: "Disk free", value: Format.bytes(monitor.latest.disk.available), detail: "of \(Format.bytes(monitor.latest.disk.total))", icon: "internaldrive")
                StatTile(label: "Report", value: Format.count(text.split(separator: "\n").count), unit: "lines", icon: "doc.plaintext")
            }
            Card("Report") {
                if text.isEmpty {
                    LoadingPanel(text: "Collecting…")
                } else {
                    Text(text).font(Type.mono(11)).foregroundStyle(Theme.ink).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .task {
            if store.engineState == .idle { await store.loadEngine() }
            if store.accessState == .idle { await store.checkAccess() }
            text = store.diagnosticsText()
        }
    }
}

// MARK: - Licenses

struct SettingsLicensesScreen: View {
    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        ScreenScaffold("Licenses", subtitle: "Third-party components bundled with MacLean") {
            RefreshLine(state: store.licenseState) { Task { await store.loadLicenses() } }
        } content: {
            TileGrid {
                StatTile(label: "Notices", value: Format.count(store.licenses.count), icon: "doc.text")
                StatTile(label: "Total text", value: Format.bytes(store.licenses.reduce(0) { $0 + $1.bytes }), icon: "textformat")
            }
            if store.licenseState.isLoading && store.licenses.isEmpty {
                LoadingPanel(text: "Locating license files…")
            } else if store.licenses.isEmpty {
                EmptyPanel(icon: "doc.questionmark", title: "No license files found", message: "Bundled resources were not located.")
            } else {
                VStack(spacing: 8) {
                    ForEach(store.licenses) { license in
                        NavRow(icon: "doc.text", title: license.name, subtitle: license.summary, value: Format.bytes(license.bytes), route: .settings(.licenseDetail(license.name)))
                    }
                }
            }
            Card {
                Text("MacLean bundles YARA (BSD-3-Clause) and OpenSSL for malware rule matching, plus a macOS subset of the signature-base YARA rules. Full notices are reproduced above.")
                    .font(Type.text(12)).foregroundStyle(Theme.muted)
            }
        }
        .onAppear { store.loadLicensesIfNeeded() }
    }
}

struct SettingsLicenseDetailScreen: View {
    let name: String
    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        let license = store.licenses.first { $0.name == name }
        ScreenScaffold(name, subtitle: license.map { Format.abbreviated($0.path) }) {
            if let license {
                Button("Copy") { SettingsStore.copy(license.text) }
                Button("Reveal") { EngineActions.reveal(license.path) }
            }
        } content: {
            if let license {
                TileGrid {
                    StatTile(label: "Size", value: Format.bytes(license.bytes), icon: "doc")
                    StatTile(label: "Lines", value: Format.count(license.text.split(separator: "\n", omittingEmptySubsequences: false).count), icon: "text.alignleft")
                    StatTile(label: "Words", value: Format.count(license.text.split(whereSeparator: { $0.isWhitespace }).count), icon: "textformat")
                }
                Card {
                    Text(license.text).font(Type.mono(11)).foregroundStyle(Theme.ink).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if store.licenseState.isLoading {
                LoadingPanel(text: "Loading…")
            } else {
                EmptyPanel(icon: "doc.questionmark", title: "License not found")
            }
        }
        .onAppear { store.loadLicensesIfNeeded() }
    }
}
