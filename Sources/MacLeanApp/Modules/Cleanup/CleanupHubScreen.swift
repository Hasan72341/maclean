import MacLeanCore
import SwiftUI

struct CleanupHubScreen: View {
    @ObservedObject private var store = CleanupStore.shared
    @ObservedObject private var monitor = SystemMonitor.shared
    @ObservedObject private var trace = ScanTrace.shared
    @ObservedObject private var lab = RuleLab.shared
    @EnvironmentObject private var nav: Navigator

    var body: some View {
        ScreenScaffold("Smart Scan", subtitle: "Find and remove caches, logs, developer and AI junk, leftovers and large files") {
            HStack(spacing: 8) {
                if store.scanState.isLoading {
                    Button("Stop") { store.stopScan() }.buttonStyle(EditorialButtonStyle(kind: .secondary))
                } else {
                    Button(store.hasResults ? "Rescan" : "Scan") { store.scan() }.buttonStyle(EditorialButtonStyle(kind: .primary))
                }
                Button("Console") { nav.push(.cleanup(.scanConsole)) }.buttonStyle(EditorialButtonStyle(kind: .ghost))
                Button("Rules") { nav.push(.cleanup(.rulesCatalog)) }.buttonStyle(EditorialButtonStyle(kind: .ghost))
                Button("Options") { nav.push(.cleanup(.scanOptions)) }.buttonStyle(EditorialButtonStyle(kind: .ghost))
            }
        } content: {
            tiles
            if store.scanState.isLoading {
                progressCard
            } else if store.hasResults {
                summary
            } else {
                hero
            }
            if case .failed(let message) = store.scanState {
                ErrorPanel(message: message) { store.scan() }
            }
            navigation
        }
    }

    // MARK: Tiles

    private var tiles: some View {
        TileGrid {
            StatTile(label: "Reclaimable", value: Format.bytes(store.totalBytes), detail: "\(Format.count(store.visibleItems.count)) items", tint: Theme.accent, history: store.foundHistory.count > 1 ? store.foundHistory : nil, icon: "archivebox")
            StatTile(label: "Recommended", value: Format.bytes(store.recommendedBytes), detail: "\(Format.count(store.recommended.count)) safe items", tint: Theme.success, icon: "checkmark.seal")
            StatTile(label: "Selected", value: Format.bytes(store.selectedBytes), detail: "\(Format.count(store.selectedItems.count)) items", icon: "checklist")
            StatTile(label: "Files", value: Format.count(store.totalFiles), detail: "inside reclaimable items", icon: "doc.on.doc")
            StatTile(label: "Disk free", value: Format.bytes(monitor.latest.disk.available), detail: "of \(Format.bytes(monitor.latest.disk.total)) · \(Format.percent(1 - monitor.latest.disk.usedFraction)) free", tint: Theme.info, history: monitor.diskReadHistory, icon: "internaldrive")
            StatTile(label: "Last scan", value: Format.relative(store.scanFinished ?? store.scanLog.first?.date), detail: store.scanLog.first.map { "took \(Format.duration($0.duration))" } ?? "never", icon: "clock")
        }
    }

    // MARK: Idle

    private var hero: some View {
        Card {
            HStack(alignment: .center, spacing: 24) {
                RingGauge(value: monitor.latest.disk.usedFraction, label: Format.percent(monitor.latest.disk.usedFraction), caption: "disk used", tint: Theme.accent, size: 130)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Scan \(store.settings.enabledCategories.count) categories, \(Rules.all.count) active rules")
                        .font(Type.display(22, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text("Scanning never modifies anything. Results are grouped by category; only items the engine marks safe are pre-selected.")
                        .font(Type.text(12)).foregroundStyle(Theme.muted)
                    HStack(spacing: 8) {
                        ForEach(store.settings.enabledCategories, id: \.self) { category in
                            Label(category.title, systemImage: CleanupText.icon(category))
                                .font(Type.text(10)).foregroundStyle(CleanupText.tint(category))
                        }
                    }
                    Button("Start Smart Scan") { store.scan() }.buttonStyle(EditorialButtonStyle(kind: .primary))
                }
            }
        }
    }

    // MARK: Progress

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card("Scanning", trailing: progressText) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        if let started = store.scanStarted {
                            TimelineView(.periodic(from: started, by: 0.5)) { context in
                                Text("Elapsed \(Format.duration(context.date.timeIntervalSince(started)))")
                                    .font(Type.mono(12, weight: .semibold)).foregroundStyle(Theme.ink).monospacedDigit()
                            }
                        }
                        Spacer()
                        if case .loading(let text) = store.scanState {
                            Text(text).font(Type.text(11)).foregroundStyle(Theme.muted)
                        }
                    }
                    ProgressView(value: fractionDone).tint(Theme.accent)
                    ForEach(store.progress) { row in
                        progressRow(row)
                    }
                }
            }
            ScanLiveDetail()
            Card("Live", trailing: "found \(Format.bytes(store.totalBytes))") {
                LiveChart(
                    series: [
                        .init(values: store.foundHistory, color: Theme.accent, label: "Found (MB)"),
                        .init(values: store.diskReadHistory, color: Theme.info, label: "Disk read (MB/s)", fill: false),
                    ],
                    format: { String(format: "%.1f", $0) }
                )
            }
        }
    }

    private var fractionDone: Double {
        guard !store.progress.isEmpty else { return 0 }
        let done = store.progress.filter { $0.phase == .done }.count
        return Double(done) / Double(store.progress.count)
    }

    private var progressText: String {
        "\(store.progress.filter { $0.phase == .done }.count)/\(store.progress.count)"
    }

    private func progressRow(_ row: CleanupCategoryProgress) -> some View {
        HStack(spacing: 10) {
            Group {
                switch row.phase {
                case .pending: Image(systemName: "circle").foregroundStyle(Theme.faint)
                case .scanning: ProgressView().controlSize(.mini)
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
                }
            }
            .frame(width: 16)
            Image(systemName: CleanupText.icon(row.category)).foregroundStyle(CleanupText.tint(row.category)).frame(width: 16)
            Text(row.category.title).font(Type.text(12, weight: .medium)).foregroundStyle(Theme.ink)
            Spacer()
            if row.phase == .done {
                Text("\(Format.count(row.items)) items · \(Format.count(row.files)) files · \(String(format: "%.1fs", row.seconds))")
                    .font(Type.text(11)).foregroundStyle(Theme.muted)
                Text(Format.bytes(row.bytes)).font(Type.mono(12, weight: .semibold)).foregroundStyle(Theme.ink).monospacedDigit()
                    .frame(width: 86, alignment: .trailing)
            } else if row.phase == .scanning {
                Text("scanning…").font(Type.text(11)).foregroundStyle(Theme.accent)
            }
        }
    }

    // MARK: Summary

    private var summary: some View {
        let tallies = store.tallies(store.visibleItems)
        let total = Double(max(store.totalBytes, 1))
        return VStack(alignment: .leading, spacing: 16) {
            Card("Reclaimable by category", trailing: Format.bytes(store.totalBytes)) {
                VStack(alignment: .leading, spacing: 12) {
                    StackedBar(segments: tallies.map {
                        StackedBar.Segment(label: $0.category.title, value: Double($0.bytes), color: CleanupText.tint($0.category), text: Format.bytes($0.bytes))
                    })
                    ForEach(tallies) { tally in
                        BarRow(label: "\(tally.category.title) (\(Format.count(tally.count)))", value: Double(tally.bytes), total: total, valueText: Format.bytes(tally.bytes), tint: CleanupText.tint(tally.category)) {
                            nav.push(.cleanup(CleanupModule.route(for: tally.category)))
                        }
                    }
                    if tallies.isEmpty {
                        Text("No junk found with the current options.").font(Type.text(12)).foregroundStyle(Theme.muted)
                    }
                }
            }
            Card("Clean recommended") {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(Format.count(store.recommended.count)) safe items · \(Format.bytes(store.recommendedBytes))")
                            .font(Type.text(14, weight: .semibold)).foregroundStyle(Theme.ink)
                        Text(store.settings.permanent ? "Permanent delete is on — items will not go to the Trash." : "Items move to the Trash; Trash contents are deleted.")
                            .font(Type.text(11)).foregroundStyle(store.settings.permanent ? Theme.danger : Theme.muted)
                    }
                    Spacer()
                    Button("Review") { store.selectRecommended(); nav.push(.cleanup(.reviewSelection)) }
                        .buttonStyle(EditorialButtonStyle(kind: .secondary))
                    if store.cleaning { ProgressView().controlSize(.small) }
                    ConfirmButton(
                        title: "Clean Recommended",
                        message: "Clean \(Format.count(store.recommended.count)) items (\(Format.bytes(store.recommendedBytes))). " + store.confirmMessage,
                        disabled: store.recommended.isEmpty || store.cleaning
                    ) {
                        let targets = store.recommended
                        Task {
                            await store.clean(targets, title: "Clean recommended")
                            nav.push(.cleanup(.cleanResult))
                        }
                    }
                }
            }
            if trace.started != nil {
                Card("Scan report", trailing: String(format: "%.1fs", trace.elapsed)) {
                    TileGrid(minWidth: 120) {
                        StatTile(label: "Rules run", value: Format.count(trace.rulesDone), detail: "\(Format.count(trace.rulesSkipped)) skipped", tint: Theme.info)
                        StatTile(label: "Folders read", value: Format.count(trace.rootsVisited), detail: "\(Format.count(trace.rootsMissing)) missing")
                        StatTile(label: "Examined", value: Format.count(trace.examined), detail: "\(Format.count(trace.skippedTotal)) skipped")
                        StatTile(label: "Found", value: Format.count(trace.found), detail: Format.bytes(trace.foundBytes), tint: Theme.success)
                    }
                    if !trace.skipCounts.isEmpty {
                        Text("Skipped: " + trace.skipCounts.sorted { $0.value > $1.value }.map { "\(Format.count($0.value)) \($0.key)" }.joined(separator: " · "))
                            .font(Type.text(11)).foregroundStyle(Theme.muted)
                    }
                    HStack(spacing: 14) {
                        Button("Open scan console") { nav.push(.cleanup(.scanConsole)) }.buttonStyle(EditorialButtonStyle(kind: .inline))
                        Button("Rule timings") { nav.push(.cleanup(.ruleTimings)) }.buttonStyle(EditorialButtonStyle(kind: .inline))
                        if let url = trace.logURL {
                            Button("Reveal log file") { EngineActions.reveal(url.path) }.buttonStyle(EditorialButtonStyle(kind: .inline))
                        }
                    }
                }
            }
            if store.scanLog.count > 1 {
                Card("Reclaimable over recent scans", trailing: "\(store.scanLog.count) scans") {
                    CleanupBarChart(bars: store.scanLog.prefix(14).reversed().map {
                        .init(label: $0.date.formatted(.dateTime.month(.abbreviated).day()) + " " + $0.date.formatted(.dateTime.hour().minute()), value: Double($0.bytes), text: Format.bytes($0.bytes))
                    })
                }
            }
        }
    }

    // MARK: Navigation

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Results", detail: store.hasResults ? "\(Format.count(store.visibleItems.count)) items" : nil)
            NavRow(icon: "list.bullet.rectangle", title: "All scan results", subtitle: "Every category, rule and item", value: Format.bytes(store.totalBytes), route: .cleanup(.scanResults))
            NavRow(icon: "checklist", title: "Review selection", subtitle: "Everything currently selected across categories", value: "\(Format.count(store.selectedItems.count)) · \(Format.bytes(store.selectedBytes))", route: .cleanup(.reviewSelection))
            NavRow(icon: "exclamationmark.triangle", title: "Needs review", subtitle: "Caution items and why", value: Format.bytes(store.bytes(store.cautionItems)), tint: Theme.warning, route: .cleanup(.cautionItems))
            NavRow(icon: "lock.shield", title: "Administrator items", subtitle: "System logs, caches and updates that need your password", value: "\(store.rootRules.count) rules", tint: Theme.danger, route: .cleanup(.rootItems))
            NavRow(icon: "arrow.uturn.backward.circle", title: "Last cleanup result", subtitle: store.lastClean.map { "\($0.title) · \(Format.relative($0.date))" } ?? "No cleanup in this session", value: store.lastClean.map { Format.bytes($0.bytes) }, tint: Theme.success, route: .cleanup(.cleanResult))

            SectionHeader(title: "Categories")
            ForEach(JunkCategory.allCases, id: \.self) { category in
                let list = store.items(in: category)
                NavRow(icon: CleanupText.icon(category), title: category.title, subtitle: "\(Format.count(list.count)) items · \(Format.count(store.files(list))) files", value: store.hasResults ? Format.bytes(store.bytes(list)) : "—", tint: CleanupText.tint(category), route: .cleanup(CleanupModule.route(for: category)))
            }

            SectionHeader(title: "Engine & settings")
            NavRow(icon: "books.vertical", title: "Rules", subtitle: "Turn rules on or off, edit risk, auto-select and exclusions, add custom rules", value: "\(Rules.all.count) active", tint: Theme.info, route: .cleanup(.rulesCatalog))
            NavRow(icon: "plus.circle", title: "New custom rule", subtitle: "Clean a folder inside your home folder that no built-in rule covers", tint: Theme.accent, route: .cleanup(.newRule))
            NavRow(icon: "terminal", title: "Scan console", subtitle: "Verbose live log: every rule, folder, skipped entry and finding", value: "\(Format.count(trace.lines.count)) lines", tint: Theme.info, route: .cleanup(.scanConsole))
            NavRow(icon: "stopwatch", title: "Rule timings", subtitle: "Time and findings per rule in the last scan", value: "\(Format.count(trace.ruleStats.count))", tint: Theme.muted, route: .cleanup(.ruleTimings))
            NavRow(icon: "slider.horizontal.3", title: "Scan options", subtitle: "Minimum size, categories, caution items, permanent delete", value: "\(store.settings.enabledCategories.count)/\(JunkCategory.allCases.count)", tint: Theme.muted, route: .cleanup(.scanOptions))
            NavRow(icon: "chart.bar.xaxis", title: "Cleanup history", subtitle: "Space freed by day", value: Format.bytes(ActivityLog.shared.entries.filter { $0.module == "Cleanup" }.reduce(0) { $0 + $1.bytes }), tint: Theme.success, route: .cleanup(.cleanupHistory))
            NavRow(icon: "waveform.path.ecg", title: "Scan log", subtitle: "Every Smart Scan with duration and findings", value: "\(store.scanLog.count)", tint: Theme.muted, route: .cleanup(.scanLog))
        }
    }
}
