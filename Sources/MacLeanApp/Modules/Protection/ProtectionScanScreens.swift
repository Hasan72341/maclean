import AppKit
import MacLeanCore
import SwiftUI

// MARK: - Overview

struct ProtectionOverviewScreen: View {
    @ObservedObject private var store = ProtectionStore.shared
    @ObservedObject private var monitor = ProtectionStore.shared.monitor
    @EnvironmentObject private var nav: Navigator

    var body: some View {
        ScreenScaffold("Protection", subtitle: "Malware scanning, quarantine, realtime monitoring and protected-store deep scan") {
            HStack(spacing: 8) {
                if store.scanState.isLoading {
                    Button("View Running Scan") { nav.push(.protection(.scanRun)) }
                        .buttonStyle(EditorialButtonStyle(kind: .secondary))
                } else {
                    Button("Smart Scan") {
                        store.runScan(profileID: "smart")
                        nav.push(.protection(.scanRun))
                    }
                    .buttonStyle(EditorialButtonStyle(kind: .primary))
                }
            }
        } content: {
            ProtectionOverviewTiles()
            if let error = scanError {
                ErrorPanel(message: error) { store.runScan(profileID: store.selectedProfile) }
            }

            if store.report != nil {
                Card("Open findings by severity", trailing: Format.count(store.openFindings.count)) {
                    ProtectionSeverityBar()
                }
            }

            if store.history.count > 1 {
                Card("Threat trend", trailing: "\(store.history.count) scans") {
                    LiveChart(series: [
                        .init(values: store.history.reversed().map { Double($0.high) }, color: Theme.danger, label: "High"),
                        .init(values: store.history.reversed().map { Double($0.medium) }, color: Theme.warning, label: "Medium"),
                        .init(values: store.history.reversed().map { Double($0.low) }, color: Theme.info, label: "Low", fill: false),
                    ], capacity: max(2, store.history.count), height: 110)
                }
            }

            ProtectionOverviewLinks()
        }
        .task {
            if store.quarantineState == .idle { await store.loadQuarantine() }
            if store.rulesState == .idle { await store.loadRules() }
            if store.corpusState == .idle { await store.loadCorpus() }
            await store.refreshRealtime()
        }
    }

    private var scanError: String? {
        if case .failed(let message) = store.scanState { return message }
        return nil
    }
}

struct ProtectionSeverityBar: View {
    @ObservedObject private var store = ProtectionStore.shared

    var body: some View {
        StackedBar(segments: ProtectionUI.severities.map { severity in
            StackedBar.Segment(label: severity.rawValue.capitalized, value: Double(store.count(severity)),
                               color: ProtectionUI.tint(severity), text: Format.count(store.count(severity)))
        })
    }
}

enum ProtectionDeepTotals {
    @MainActor static func reclaimable(_ store: ProtectionStore) -> Int64 {
        let mail: Int64 = store.mail?.totalBytes ?? 0
        let photos: Int64 = store.photos?.wastedBytes ?? 0
        let docs: Int64 = store.documents?.selectedBytes ?? 0
        let system: Int64 = store.stores?.totalBytes ?? 0
        let thin: Int64 = store.stores?.universalSavings ?? 0
        return mail + photos + docs + system + thin
    }
}

// MARK: - Profiles

struct ProtectionProfilesScreen: View {
    @ObservedObject private var store = ProtectionStore.shared

    var body: some View {
        ScreenScaffold("Scan Profiles", subtitle: "Six engine configurations, from seconds to exhaustive") {
            TileGrid {
                StatTile(label: "Profiles", value: "\(ProtectionProfile.all.count)", icon: "slider.horizontal.3")
                StatTile(label: "Detectors", value: "\(ScanOption.all.names.count)", detail: "available in the engine", icon: "sensor")
                StatTile(label: "Selected", value: ProtectionProfile.find(store.selectedProfile)?.title ?? "—", icon: "checkmark.circle")
                StatTile(label: "Last profile", value: store.reportProfile.flatMap { ProtectionProfile.find($0)?.title } ?? "—", icon: "clock")
            }
            Card("Detector coverage") {
                ForEach(ProtectionProfile.all) { profile in
                    let config = profile.configuration(paths: store.folderPaths)
                    BarRow(label: profile.title, value: Double(config.scanOption.names.count), total: Double(ScanOption.all.names.count),
                           valueText: "\(config.scanOption.names.count) detectors · depth \(config.maxEnumerationDepth < 0 ? "∞" : String(config.maxEnumerationDepth))")
                }
            }
            VStack(spacing: 8) {
                ForEach(ProtectionProfile.all) { profile in
                    NavRow(icon: profile.icon, title: profile.title, subtitle: profile.summary,
                           value: store.selectedProfile == profile.id ? "Selected" : nil,
                           route: .protection(.profileDetail(profile.id)))
                }
            }
        }
    }
}

struct ProtectionProfileDetailScreen: View {
    let profileID: String
    @ObservedObject private var store = ProtectionStore.shared
    @EnvironmentObject private var nav: Navigator

    var body: some View {
        if let profile = ProtectionProfile.find(profileID) {
            let config = profile.configuration(paths: store.folderPaths)
            let enabled = Set(config.scanOption.names)
            ScreenScaffold(profile.title, subtitle: profile.summary) {
                Button(store.scanState.isLoading ? "Scan running…" : "Run \(profile.title) Scan") {
                    store.selectedProfile = profile.id
                    store.runScan(profileID: profile.id)
                    nav.push(.protection(.scanRun))
                }
                .buttonStyle(EditorialButtonStyle(kind: .primary))
                .disabled(store.scanState.isLoading || (profile.needsPaths && store.folderPaths.isEmpty))
            } content: {
                TileGrid {
                    StatTile(label: "Mode", value: config.scanMode.title, detail: "engine mode \(config.scanMode.rawValue)", icon: profile.icon)
                    StatTile(label: "Detectors", value: "\(enabled.count)", unit: "/ \(ScanOption.all.names.count)", icon: "sensor")
                    StatTile(label: "Depth", value: config.maxEnumerationDepth < 0 ? "Unlimited" : "\(config.maxEnumerationDepth)", detail: "folder enumeration", icon: "arrow.down.to.line")
                    StatTile(label: "Archives", value: config.isArchiveScanEnabled ? "On" : "Off",
                             detail: "nesting \(config.maxArchiveNestingDepth)", icon: "doc.zipper")
                    StatTile(label: "Previous runs", value: "\(store.history.filter { $0.profile == profile.id }.count)", icon: "clock.arrow.circlepath")
                }
                Card("About") {
                    Text(profile.detail).font(Type.text(12)).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                }
                Card("Detectors", trailing: "\(enabled.count) enabled") {
                    ForEach(ScanOption.all.names, id: \.self) { name in
                        HStack {
                            Image(systemName: enabled.contains(name) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(enabled.contains(name) ? Theme.success : Theme.faint)
                            Text(name.prefix(1).uppercased() + name.dropFirst()).font(Type.text(12)).foregroundStyle(enabled.contains(name) ? Theme.ink : Theme.muted)
                            Spacer()
                        }
                    }
                }
                Card("Limits") {
                    KeyValueRow(key: "DMG inspection", value: config.isDMGScanEnabled ? "On" : "Off")
                    KeyValueRow(key: "PKG inspection", value: config.isPKGScanEnabled ? "On" : "Off")
                    KeyValueRow(key: "PUA detection", value: config.isPUAScanEnabled ? "On" : "Off")
                    KeyValueRow(key: "Extended corpus rules", value: config.extendedRulesUsageEnabled ? "On" : "Off")
                    KeyValueRow(key: "Package depth", value: config.maxPackageEnumerationDepth < 0 ? "Unlimited" : "\(config.maxPackageEnumerationDepth)")
                    KeyValueRow(key: "Max archive file", value: Format.bytes(config.maxArchiveFileSize))
                    KeyValueRow(key: "Max archive uncompressed", value: Format.bytes(config.maxArchiveTotalUncompressedSize))
                    KeyValueRow(key: "Max extracted files", value: Format.count(config.maxArchiveExtractedFilesCount))
                    KeyValueRow(key: "Max compression ratio", value: String(format: "%.0f×", config.maxArchiveCompressionRatio))
                    KeyValueRow(key: "Max PKG size", value: Format.bytes(config.maxPKGFileSize))
                    KeyValueRow(key: "Concurrency", value: "\(config.maxConcurrentOperationCount)")
                    KeyValueRow(key: "Privileged prompt allowed", value: config.scanMode.canAskPrivilegedAgentAuthorizationOnScan ? "Yes (never requested)" : "No")
                }
                ProtectionScanOptionsCard()
                if profile.needsPaths || !store.folderPaths.isEmpty {
                    ProtectionFolderPickerCard(required: profile.needsPaths)
                }
            }
        } else {
            ScreenScaffold("Profile") { EmptyPanel(icon: "questionmark", title: "Unknown profile") }
        }
    }
}

struct ProtectionScanOptionsCard: View {
    @ObservedObject private var store = ProtectionStore.shared

    var body: some View {
        Card("Signature sources") {
            Toggle("Use Panther malware corpus (hash, path, TeamID, section rules)", isOn: $store.useCorpus)
                .font(Type.text(12))
            if store.useCorpus {
                TextField("Corpus URL or local .sqlite path", text: $store.corpusSource)
                    .textFieldStyle(.roundedBorder).font(Type.mono(11))
                Toggle("Run corpus YARA rules", isOn: $store.corpusYara).font(Type.text(12))
            }
            Toggle("Run bundled YARA rules (\(store.ruleFiles.count) files, \(Format.count(store.totalRuleCount)) rules)", isOn: $store.bundledRules)
                .font(Type.text(12))
            Text(store.useCorpus
                 ? "The corpus is downloaded once and cached for 24 hours."
                 : "Without a corpus the scan is a heuristic persistence and security audit.")
                .font(Type.text(11)).foregroundStyle(Theme.muted)
        }
        .task { if store.rulesState == .idle { await store.loadRules() } }
    }
}

struct ProtectionFolderPickerCard: View {
    let required: Bool
    @ObservedObject private var store = ProtectionStore.shared

    var body: some View {
        Card("Folders to scan", trailing: "\(store.folderPaths.count)") {
            if store.folderPaths.isEmpty {
                Text(required ? "Add at least one folder to run this profile." : "Optional extra folders for any profile.")
                    .font(Type.text(12)).foregroundStyle(required ? Theme.warning : Theme.muted)
            }
            ForEach(store.folderPaths, id: \.self) { path in
                HStack {
                    Image(systemName: "folder").foregroundStyle(Theme.accent)
                    Text(Format.abbreviated(path)).font(Type.mono(11)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Remove") { store.folderPaths.removeAll { $0 == path } }
                        .buttonStyle(EditorialButtonStyle(kind: .inlineDanger))
                }
            }
            Button("Add Folder…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = true
                if panel.runModal() == .OK {
                    for url in panel.urls where !store.folderPaths.contains(url.path) {
                        store.folderPaths.append(url.path)
                    }
                }
            }
            .buttonStyle(EditorialButtonStyle(kind: .secondary))
        }
    }
}

// MARK: - Scan run

struct ProtectionScanRunScreen: View {
    @ObservedObject private var store = ProtectionStore.shared
    @ObservedObject private var metrics = SystemMonitor.shared
    @EnvironmentObject private var nav: Navigator

    var body: some View {
        let profile = ProtectionProfile.find(store.scanProfile ?? store.reportProfile ?? store.selectedProfile)
        ScreenScaffold("Scan", subtitle: profile.map { "\($0.title) profile" }) {
            if !store.scanState.isLoading {
                Button("Scan Again") { store.runScan(profileID: profile?.id ?? "smart") }
                    .buttonStyle(EditorialButtonStyle(kind: .secondary))
            }
        } content: {
            if store.scanState.isLoading, let started = store.scanStarted {
                TimelineView(.periodic(from: started, by: 0.5)) { context in
                    let elapsed = context.date.timeIntervalSince(started)
                    TileGrid {
                        StatTile(label: "Elapsed", value: String(format: "%.1f", elapsed), unit: "s", detail: profile?.title, icon: "timer")
                        StatTile(label: "CPU", value: Format.percent(metrics.latest.cpu.total), tint: Theme.accent,
                                 history: metrics.cpuHistory, icon: "cpu")
                        StatTile(label: "Disk read", value: Format.rate(metrics.latest.disk.readPerSec), tint: Theme.info,
                                 history: metrics.diskReadHistory, icon: "internaldrive")
                        StatTile(label: "Typical duration", value: typical(profile?.id).map { Format.duration($0) } ?? "—",
                                 detail: "average of previous runs", icon: "clock")
                    }
                }
                Card("Live engine activity", trailing: "CPU % · disk read") {
                    LiveChart(series: [
                        .init(values: metrics.cpuHistory.map { $0 * 100 }, color: Theme.accent, label: "CPU %"),
                    ], maxValue: 100, format: { String(format: "%.0f%%", $0) }, height: 110)
                    LiveChart(series: [
                        .init(values: metrics.diskReadHistory, color: Theme.info, label: "Read"),
                        .init(values: metrics.diskWriteHistory, color: Theme.warning, label: "Write", fill: false),
                    ], format: { Format.rate($0) }, height: 90)
                }
                LoadingPanel(text: store.scanState.isLoading ? "Scanning persistence, disk locations and signatures…" : "",
                             detail: "Detectors: \(profile?.configuration(paths: store.folderPaths).optionsDescription ?? "")")
            } else if case .failed(let message) = store.scanState {
                ErrorPanel(message: message) { store.runScan(profileID: profile?.id ?? "smart") }
            } else if let report = store.report {
                TileGrid {
                    StatTile(label: "Findings", value: Format.count(report.findings.count),
                             tint: report.findings.contains { $0.severity >= .medium } ? Theme.danger : Theme.success, icon: "exclamationmark.shield")
                    StatTile(label: "Files scanned", value: Format.count(report.scannedFiles), icon: "doc.text.magnifyingglass")
                    StatTile(label: "Duration", value: store.lastDuration.map { Format.duration($0) } ?? "—", icon: "timer")
                    StatTile(label: "Corpus", value: report.corpus?.version.map { "v\($0)" } ?? "Off", detail: report.corpus?.updateDate, icon: "server.rack")
                    StatTile(label: "YARA matches", value: Format.count((report.yara?.matches ?? 0) + (report.corpusYara?.matches ?? 0)),
                             detail: report.yara?.note ?? report.corpusYara?.note, icon: "list.bullet.rectangle")
                }
                Card("Severity") { ProtectionSeverityBar() }
                Card("Configuration") {
                    KeyValueRow(key: "Mode", value: "\(report.configuration.scanMode.title) (\(report.configuration.scanMode.rawValue))")
                    KeyValueRow(key: "Detectors", value: report.configuration.optionsDescription)
                    KeyValueRow(key: "Options mask", value: "0x" + String(report.configuration.scanOption.rawValue, radix: 16, uppercase: true), mono: true)
                    if let path = report.yara?.rulesPath { KeyValueRow(key: "Bundled rules", value: Format.abbreviated(path), mono: true) }
                    if let engine = report.yara?.enginePath ?? report.corpusYara?.enginePath { KeyValueRow(key: "YARA engine", value: engine, mono: true) }
                }
                NavRow(icon: "exclamationmark.triangle", title: "Review all findings", value: Format.count(report.findings.count), route: .protection(.findings))
                if !report.findings.isEmpty {
                    Card("Top findings") {
                        ForEach(store.findings.prefix(8), id: \.protectionID) { finding in
                            ProtectionFindingLine(finding: finding)
                        }
                    }
                } else {
                    EmptyPanel(icon: "checkmark.shield", title: "No findings", message: "The \(profile?.title ?? "") profile did not flag anything.")
                }
            } else {
                EmptyPanel(icon: "shield", title: "No scan yet", message: "Pick a profile to run the first scan.", actionTitle: "Choose Profile") {
                    nav.push(.protection(.profiles))
                }
            }
        }
    }

    private func typical(_ profile: String?) -> TimeInterval? {
        let runs = store.history.filter { $0.profile == profile }.map(\.duration)
        return runs.isEmpty ? nil : runs.reduce(0, +) / Double(runs.count)
    }
}

struct ProtectionFindingLine: View {
    let finding: ProtectionFinding
    @EnvironmentObject private var nav: Navigator

    var body: some View {
        Button { nav.push(.protection(.findingDetail(finding.protectionID))) } label: {
            HStack(spacing: 10) {
                RiskBadge(text: finding.severity.label, tint: ProtectionUI.tint(finding.severity))
                VStack(alignment: .leading, spacing: 2) {
                    Text(finding.title).font(Type.text(12, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                    Text(Format.abbreviated(finding.path)).font(Type.mono(10)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Text(finding.kind).font(Type.text(10)).foregroundStyle(Theme.faint)
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Theme.faint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Findings

struct ProtectionFindingsScreen: View {
    @ObservedObject private var store = ProtectionStore.shared

    var body: some View {
        let kinds = Dictionary(grouping: store.openFindings, by: \.kind).map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }
        ScreenScaffold("Findings", subtitle: store.reportDate.map { "Scan \(Format.date($0))" }) {
            RefreshLine(state: store.scanState) { store.runScan(profileID: store.reportProfile ?? store.selectedProfile) }
        } content: {
            TileGrid {
                ForEach(ProtectionUI.severities, id: \.self) { severity in
                    StatTile(label: severity.rawValue.capitalized, value: Format.count(store.count(severity)),
                             tint: ProtectionUI.tint(severity), icon: "circle.fill")
                }
                StatTile(label: "Reviewed", value: Format.count(store.handledFindings.count), detail: "quarantined or dismissed", icon: "checkmark.circle")
            }
            if store.report == nil {
                EmptyPanel(icon: "shield", title: "No scan results", message: "Run a scan to see findings.")
            } else {
                Card("Severity") { ProtectionSeverityBar() }
                SectionHeader(title: "By severity")
                VStack(spacing: 8) {
                    ForEach(ProtectionUI.severities, id: \.self) { severity in
                        NavRow(icon: "circle.fill", title: severity.rawValue.capitalized, value: Format.count(store.count(severity)),
                               tint: ProtectionUI.tint(severity), route: .protection(.findingsSeverity(severity.rawValue)))
                    }
                }
                if !kinds.isEmpty {
                    Card("By detector", trailing: "\(kinds.count) kinds") {
                        ForEach(kinds, id: \.0) { kind, count in
                            BarRow(label: kind, value: Double(count), total: Double(kinds.first?.1 ?? 1), valueText: Format.count(count)) {
                                Navigator.shared.push(.protection(.findingsKind(kind)))
                            }
                        }
                    }
                }
                ProtectionFindingSelectList(findings: store.openFindings)
            }
        }
    }
}

enum ProtectionFindingFilter {
    case severity(String)
    case kind(String)
}

struct ProtectionFindingListScreen: View {
    let filter: ProtectionFindingFilter
    @ObservedObject private var store = ProtectionStore.shared

    var body: some View {
        let list = store.openFindings.filter {
            switch filter {
            case .severity(let s): return $0.severity.rawValue == s
            case .kind(let k): return $0.kind == k
            }
        }
        ScreenScaffold(title, subtitle: "\(list.count) open findings") {
            TileGrid {
                StatTile(label: "Findings", value: Format.count(list.count), icon: "exclamationmark.triangle")
                StatTile(label: "Need admin", value: Format.count(list.filter(\.requiresRoot).count), icon: "lock")
                StatTile(label: "Files present", value: Format.count(list.filter { FileManager.default.fileExists(atPath: $0.path) }.count), icon: "doc")
                StatTile(label: "Locations", value: Format.count(Set(list.map { ($0.path as NSString).deletingLastPathComponent }).count), icon: "folder")
            }
            if list.isEmpty {
                EmptyPanel(icon: "checkmark.shield", title: "Nothing here")
            } else {
                ProtectionFindingSelectList(findings: list)
            }
        }
    }

    private var title: String {
        switch filter {
        case .severity(let s): return "\(s.capitalized) Findings"
        case .kind(let k): return k
        }
    }
}

/// Searchable, selectable finding list with bulk quarantine.
struct ProtectionFindingSelectList: View {
    let findings: [ProtectionFinding]
    @ObservedObject private var store = ProtectionStore.shared
    @EnvironmentObject private var nav: Navigator
    @State private var query = ""
    @State private var selected: Set<String> = []
    @State private var sizes: [String: Int64] = [:]
    @State private var failures: [(path: String, reason: String)] = []
    @State private var working = false

    private var visible: [ProtectionFinding] {
        query.isEmpty ? findings : findings.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.path.localizedCaseInsensitiveContains(query) || $0.detail.localizedCaseInsensitiveContains(query)
        }
    }

    private func quarantinable(_ f: ProtectionFinding) -> Bool {
        !f.requiresRoot && sizes[f.protectionID] != nil
    }

    var body: some View {
        let list = visible
        let candidates = list.filter(quarantinable)
        VStack(alignment: .leading, spacing: 10) {
            SearchField(text: $query, prompt: "Filter findings")
            ForEach(ProtectionUI.severities, id: \.self) { severity in
                let group = list.filter { $0.severity == severity }
                if !group.isEmpty {
                    Card(severity.rawValue.capitalized, trailing: "\(group.count)") {
                        ForEach(group, id: \.protectionID) { finding in
                            CheckRow(
                                isOn: Binding(
                                    get: { selected.contains(finding.protectionID) },
                                    set: { on in
                                        guard quarantinable(finding) else { return }
                                        if on { selected.insert(finding.protectionID) } else { selected.remove(finding.protectionID) }
                                    }
                                ),
                                title: finding.title,
                                subtitle: Format.abbreviated(finding.path),
                                value: sizes[finding.protectionID].map { Format.bytes($0) },
                                badge: finding.requiresRoot ? "ADMIN" : (sizes[finding.protectionID] == nil ? "NO FILE" : finding.kind),
                                badgeTint: ProtectionUI.tint(finding.severity),
                                onOpen: { nav.push(.protection(.findingDetail(finding.protectionID))) },
                                onReveal: sizes[finding.protectionID] == nil ? nil : { EngineActions.reveal(finding.path) }
                            )
                        }
                    }
                }
            }
            FailureList(failures: failures)
            if !candidates.isEmpty {
                SelectionBar(
                    selectedCount: selected.count,
                    totalCount: candidates.count,
                    selectedBytes: selected.reduce(Int64(0)) { $0 + (sizes[$1] ?? 0) },
                    actionTitle: "Quarantine Selected",
                    confirmMessage: "Selected files are moved into MacLean's quarantine folder. You can restore them later.",
                    busy: working,
                    onSelectAll: { selected = Set(candidates.map(\.protectionID)) },
                    onSelectNone: { selected = [] },
                    action: quarantineSelected
                )
            }
        }
        .task(id: findings.map(\.protectionID)) { await measure() }
    }

    private func measure() async {
        let items = findings.map { ($0.protectionID, $0.path) }
        sizes = await engine { () -> [String: Int64] in
            var result: [String: Int64] = [:]
            for (id, path) in items where FileManager.default.fileExists(atPath: path) {
                result[id] = FileSizer.measure(URL(fileURLWithPath: path)).bytes
            }
            return result
        }
    }

    private func quarantineSelected() {
        let chosen = findings.filter { selected.contains($0.protectionID) }
        working = true
        Task {
            var errors: [(path: String, reason: String)] = []
            for finding in chosen {
                if let error = await store.quarantinePath(finding.path, reason: "\(finding.severity.label): \(finding.title)", findingID: finding.protectionID) {
                    errors.append((finding.path, error))
                }
            }
            failures = errors
            selected = []
            working = false
            await measure()
        }
    }
}

struct ProtectionFindingDetailScreen: View {
    let findingID: String
    @ObservedObject private var store = ProtectionStore.shared
    @State private var info: (exists: Bool, bytes: Int64, modified: Date?, isDir: Bool)?
    @State private var error: String?
    @State private var working = false

    var body: some View {
        if let finding = store.finding(findingID) {
            let handled = store.handledFindings.contains(findingID)
            ScreenScaffold(finding.title, subtitle: finding.kind) {
                HStack(spacing: 8) {
                    if info?.exists == true {
                        Button("Reveal") { EngineActions.reveal(finding.path) }.buttonStyle(EditorialButtonStyle(kind: .secondary))
                    }
                    Button("Copy Path") { ProtectionUI.copy(finding.path) }.buttonStyle(EditorialButtonStyle(kind: .ghost))
                }
            } content: {
                TileGrid {
                    StatTile(label: "Severity", value: finding.severity.rawValue.capitalized, tint: ProtectionUI.tint(finding.severity), icon: "exclamationmark.shield")
                    StatTile(label: "Size", value: info.map { $0.exists ? Format.bytes($0.bytes) : "Missing" } ?? "…", icon: "doc")
                    StatTile(label: "Modified", value: info?.modified.map { Format.relative($0) } ?? "—", detail: Format.date(info?.modified), icon: "calendar")
                    StatTile(label: "Status", value: handled ? "Reviewed" : "Open", tint: handled ? Theme.success : Theme.warning, icon: "checkmark.circle")
                }
                Card("Details") {
                    KeyValueRow(key: "Title", value: finding.title)
                    KeyValueRow(key: "Detector", value: finding.kind)
                    KeyValueRow(key: "Severity", value: finding.severity.label)
                    KeyValueRow(key: "Path", value: finding.path, mono: true)
                    KeyValueRow(key: "Type", value: info.map { $0.isDir ? "Folder" : "File" } ?? "—")
                    KeyValueRow(key: "Requires admin", value: finding.requiresRoot ? "Yes" : "No")
                    if !finding.detail.isEmpty {
                        Text(finding.detail).font(Type.mono(11)).foregroundStyle(Theme.ink).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let error { ErrorPanel(message: error) }
                Card("Actions") {
                    if finding.requiresRoot {
                        Text("This item is in a system location. Remove it manually with admin rights:")
                            .font(Type.text(12)).foregroundStyle(Theme.muted)
                        HStack {
                            Text("sudo mv \(ProtectionUI.shellQuote(finding.path)) ~/.Trash/").font(Type.mono(11)).textSelection(.enabled)
                            Spacer()
                            Button("Copy") { ProtectionUI.copy("sudo mv \(ProtectionUI.shellQuote(finding.path)) ~/.Trash/") }
                        }
                    }
                    HStack(spacing: 10) {
                        ConfirmButton(
                            title: "Quarantine",
                            message: "Move \(URL(fileURLWithPath: finding.path).lastPathComponent) into MacLean's quarantine? It can be restored later.",
                            kind: .destructive,
                            disabled: working || info?.exists != true || finding.requiresRoot || handled
                        ) {
                            working = true
                            Task {
                                error = await store.quarantinePath(finding.path, reason: "\(finding.severity.label): \(finding.title)", findingID: findingID)
                                working = false
                                await load(finding.path)
                            }
                        }
                        Button(handled ? "Reviewed" : "Mark as Reviewed") { store.markHandled(findingID) }
                            .buttonStyle(EditorialButtonStyle(kind: .secondary)).disabled(handled)
                        if working { ProgressView().controlSize(.small) }
                    }
                }
            }
            .task { await load(finding.path) }
        } else {
            ScreenScaffold("Finding") { EmptyPanel(icon: "questionmark", title: "Finding no longer in the report") }
        }
    }

    private func load(_ path: String) async {
        let result = await engine { () -> (Bool, Int64, Date?, Bool) in
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            guard exists else { return (false, 0, nil, false) }
            let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            return (true, FileSizer.measure(URL(fileURLWithPath: path)).bytes, modified, isDir.boolValue)
        }
        info = (result.0, result.1, result.2, result.3)
    }
}

// MARK: - History

struct ProtectionHistoryScreen: View {
    @ObservedObject private var store = ProtectionStore.shared
    @EnvironmentObject private var nav: Navigator

    var body: some View {
        let entries = store.history
        let chrono = Array(entries.reversed())
        ScreenScaffold("Scan History", subtitle: "\(entries.count) scans recorded") {
            ConfirmButton(title: "Clear History", message: "Remove all \(entries.count) history entries? Scan results are not affected.", kind: .ghost, disabled: entries.isEmpty) {
                store.clearHistory()
            }
        } content: {
            TileGrid {
                StatTile(label: "Scans", value: Format.count(entries.count), icon: "clock.arrow.circlepath")
                StatTile(label: "Avg duration", value: entries.isEmpty ? "—" : Format.duration(entries.map(\.duration).reduce(0, +) / Double(entries.count)),
                         history: chrono.map(\.duration), icon: "timer")
                StatTile(label: "Files scanned", value: Format.count(entries.reduce(0) { $0 + $1.scannedFiles }), detail: "all scans",
                         history: chrono.map { Double($0.scannedFiles) }, icon: "doc.text.magnifyingglass")
                StatTile(label: "High findings", value: Format.count(entries.reduce(0) { $0 + $1.high }), tint: Theme.danger,
                         history: chrono.map { Double($0.high) }, icon: "exclamationmark.shield")
            }
            if entries.isEmpty {
                EmptyPanel(icon: "clock", title: "No scans yet", actionTitle: "Choose Profile") { nav.push(.protection(.profiles)) }
            } else {
                if chrono.count > 1 {
                    Card("Findings per scan") {
                        LiveChart(series: [
                            .init(values: chrono.map { Double($0.total) }, color: Theme.accent, label: "Total"),
                            .init(values: chrono.map { Double($0.high + $0.medium) }, color: Theme.danger, label: "High + Medium"),
                        ], capacity: chrono.count, height: 120)
                    }
                }
                let byProfile = Dictionary(grouping: entries, by: \.profile)
                Card("Runs by profile") {
                    ForEach(ProtectionProfile.all) { profile in
                        BarRow(label: profile.title, value: Double(byProfile[profile.id]?.count ?? 0), total: Double(entries.count),
                               valueText: "\(byProfile[profile.id]?.count ?? 0) runs")
                    }
                }
                Card("Runs") {
                    ForEach(entries) { entry in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(ProtectionProfile.find(entry.profile)?.title ?? entry.profile) · \(Format.date(entry.date))")
                                    .font(Type.text(12, weight: .medium)).foregroundStyle(Theme.ink)
                                Text("\(Format.count(entry.scannedFiles)) files · \(Format.duration(entry.duration))\(entry.corpusVersion.map { " · corpus v\($0)" } ?? "")")
                                    .font(Type.text(11)).foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            if entry.high > 0 { RiskBadge(text: "\(entry.high) HIGH", tint: Theme.danger) }
                            if entry.medium > 0 { RiskBadge(text: "\(entry.medium) MED", tint: Theme.warning) }
                            Text("\(entry.total)").font(Type.mono(12, weight: .semibold)).monospacedDigit()
                        }
                    }
                }
            }
        }
    }
}

struct ProtectionOverviewTiles: View {
    @ObservedObject private var store = ProtectionStore.shared
    @ObservedObject private var monitor = ProtectionStore.shared.monitor

    var body: some View {
        let history = store.history.reversed().map { Double($0.high + $0.medium) }
            TileGrid {
                StatTile(label: "Last scan", value: store.reportDate.map { Format.relative($0) } ?? "Never",
                         detail: store.reportProfile.flatMap { ProtectionProfile.find($0)?.title }.map { "\($0) profile" } ?? "run a scan to begin",
                         icon: "clock")
                StatTile(label: "Threats", value: Format.count(store.threatCount),
                         detail: "\(store.count(.high)) high · \(store.count(.medium)) medium",
                         tint: store.threatCount > 0 ? Theme.danger : Theme.success,
                         history: history.count > 1 ? history : nil, icon: "exclamationmark.shield")
                StatTile(label: "Files scanned", value: Format.count(store.report?.scannedFiles ?? 0),
                         detail: store.lastDuration.map { "in \(Format.duration($0))" } ?? "last report", icon: "doc.text.magnifyingglass")
                StatTile(label: "Realtime", value: monitor.status?.running == true ? "On" : "Off",
                         detail: monitor.agentInstalled ? "\(monitor.status?.watchedPaths.count ?? 0) folders watched" : "agent not installed",
                         tint: monitor.status?.running == true ? Theme.success : Theme.warning, icon: "dot.radiowaves.left.and.right")
                StatTile(label: "Quarantine", value: Format.count(store.quarantine.count),
                         detail: Format.bytes(store.quarantineBytes), icon: "archivebox")
                StatTile(label: "YARA rules", value: Format.count(store.totalRuleCount),
                         detail: "\(store.ruleFiles.count) bundled files", icon: "list.bullet.rectangle")
            }

    }
}

struct ProtectionOverviewLinks: View {
    @ObservedObject private var store = ProtectionStore.shared
    @ObservedObject private var monitor = ProtectionStore.shared.monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Malware scan")
            VStack(spacing: 8) {
                NavRow(icon: "slider.horizontal.3", title: "Scan profiles", subtitle: "Fast, Default, Smart, Protected, Folders, Paranoid",
                       value: "\(ProtectionProfile.all.count)", route: .protection(.profiles))
                NavRow(icon: "exclamationmark.triangle", title: "Findings", subtitle: "Grouped by severity with quarantine actions",
                       value: Format.count(store.openFindings.count), tint: store.threatCount > 0 ? Theme.danger : Theme.accent,
                       route: .protection(.findings))
                NavRow(icon: "clock.arrow.circlepath", title: "Scan history", subtitle: "Every scan with counts and durations",
                       value: Format.count(store.history.count), route: .protection(.history))
                if store.scanState.isLoading || store.report != nil {
                    NavRow(icon: "waveform.path.ecg", title: "Current scan", subtitle: store.scanState.isLoading ? "Running now" : "Last result",
                           route: .protection(.scanRun))
                }
            }

            SectionHeader(title: "Defense")
            VStack(spacing: 8) {
                NavRow(icon: "archivebox", title: "Quarantine", subtitle: "Restore or delete isolated files",
                       value: "\(store.quarantine.count) · \(Format.bytes(store.quarantineBytes))", route: .protection(.quarantine))
                NavRow(icon: "dot.radiowaves.left.and.right", title: "Realtime monitor", subtitle: monitor.status?.running == true ? "Watching for changes" : "Not running",
                       value: monitor.status?.running == true ? "On" : "Off", route: .protection(.realtime))
                NavRow(icon: "bell.badge", title: "Alerts", subtitle: "Files flagged by the realtime monitor",
                       value: Format.count(store.alerts.count), route: .protection(.alerts))
                NavRow(icon: "list.bullet.rectangle", title: "YARA rules", subtitle: "Bundled macOS signature base",
                       value: "\(store.ruleFiles.count) files", route: .protection(.yaraRules))
                NavRow(icon: "server.rack", title: "Malware corpus", subtitle: "Hash, path, TeamID and YARA rule database",
                       value: store.corpus?.info?.version.map { "v\($0)" }, route: .protection(.corpus))
            }

            SectionHeader(title: "Deep scan")
            VStack(spacing: 8) {
                NavRow(icon: "scope", title: "Deep scan overview", subtitle: "Mail, Photos, document versions, protected stores",
                       value: store.deepState.loadedAt == nil ? nil : Format.bytes(ProtectionDeepTotals.reclaimable(store)),
                       route: .protection(.deepScan))
                NavRow(icon: "envelope", title: "Mail Trash", value: store.mail.map { Format.bytes($0.totalBytes) }, route: .protection(.mailTrash))
                NavRow(icon: "photo.on.rectangle", title: "Photos duplicates", value: store.photos.map { Format.bytes($0.wastedBytes) }, route: .protection(.photosDuplicates))
                NavRow(icon: "doc.on.doc", title: "Document versions", value: store.documents.map { Format.bytes($0.selectedBytes) }, route: .protection(.documentVersions))
                NavRow(icon: "person.crop.circle.badge.xmark", title: "Deleted users", value: store.stores.map { Format.bytes($0.deletedUsers.reduce(0) { $0 + $1.bytes }) }, route: .protection(.deletedUsers))
                NavRow(icon: "internaldrive", title: "System caches & logs", value: store.stores.map { Format.bytes($0.systemCaches.reduce(0) { $0 + $1.bytes }) }, route: .protection(.systemCaches))
                NavRow(icon: "cpu", title: "Universal binaries", value: store.stores.map { Format.bytes($0.universalSavings) }, route: .protection(.universalBinaries))
            }
        }
    }
}
