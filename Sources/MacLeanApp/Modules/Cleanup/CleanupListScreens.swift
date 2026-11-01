import MacLeanCore
import SwiftUI

// MARK: - All results

struct CleanupResultsScreen: View {
    @ObservedObject private var store = CleanupStore.shared
    @EnvironmentObject private var nav: Navigator

    var body: some View {
        ScreenScaffold("Scan Results", subtitle: "Everything the last Smart Scan found") {
            RefreshLine(state: store.scanState) { store.scan() }
        } content: {
            if !store.hasResults {
                CleanupNeedsScan()
            } else {
                let all = store.visibleItems
                TileGrid {
                    StatTile(label: "Reclaimable", value: Format.bytes(store.totalBytes), tint: Theme.accent, icon: "archivebox")
                    StatTile(label: "Items", value: Format.count(all.count), detail: "\(Format.count(store.ruleTallies(all).count)) rules matched")
                    StatTile(label: "Files", value: Format.count(store.totalFiles))
                    StatTile(label: "Selected", value: Format.bytes(store.selectedBytes), detail: "\(Format.count(store.selectedItems.count)) items")
                    StatTile(label: "Needs review", value: Format.count(store.cautionItems.count), detail: Format.bytes(store.bytes(store.cautionItems)), tint: Theme.warning)
                    StatTile(label: "Scan time", value: duration, detail: Format.date(store.scanFinished))
                }
                Card("Per-category scan", trailing: "\(store.progress.count) categories") {
                    ForEach(store.progress) { row in
                        BarRow(label: "\(row.category.title) · \(Format.count(row.items)) items · \(String(format: "%.1fs", row.seconds))", value: Double(row.bytes), total: Double(max(store.totalBytes, 1)), valueText: Format.bytes(row.bytes), tint: CleanupText.tint(row.category)) {
                            nav.push(.cleanup(.category(row.category.rawValue)))
                        }
                    }
                }
                Card("Top rules", trailing: "by size") {
                    let rules = store.ruleTallies(all)
                    let peak = Double(rules.first?.bytes ?? 1)
                    ForEach(rules.prefix(15)) { rule in
                        BarRow(label: "\(rule.title) (\(Format.count(rule.count)))", value: Double(rule.bytes), total: peak, valueText: Format.bytes(rule.bytes), tint: Theme.info) {
                            nav.push(.cleanup(.ruleGroup(rule.id)))
                        }
                    }
                }
                Card("Largest items", trailing: "top 10") {
                    ForEach(all.sorted { $0.bytes > $1.bytes }.prefix(10), id: \.path) { item in
                        NavRow(icon: item.isDirectory ? "folder" : "doc", title: CleanupText.name(item.path), subtitle: "\(item.ruleTitle) · \(Format.abbreviated(item.path))", value: Format.bytes(item.bytes), tint: CleanupText.tint(item.category), route: .cleanup(.itemDetail(item.path)))
                    }
                }
                SectionHeader(title: "All items", detail: Format.bytes(store.totalBytes))
                CleanupItemList(items: all, activityTitle: "Clean scan results", showCategory: true)
            }
        }
    }

    private var duration: String {
        guard let start = store.scanStarted, let end = store.scanFinished else { return "—" }
        return Format.duration(end.timeIntervalSince(start))
    }
}

// MARK: - Category

struct CleanupCategoryScreen: View {
    let category: JunkCategory
    @ObservedObject private var store = CleanupStore.shared
    @EnvironmentObject private var nav: Navigator
    @State private var rescanning = false

    var body: some View {
        let list = store.items(in: category)
        let selected = list.filter { store.selection.contains($0.path) }
        ScreenScaffold(category.title, subtitle: CleanupText.blurb(category)) {
            HStack(spacing: 8) {
                if rescanning || store.scanState.isLoading { ProgressView().controlSize(.small) }
                Button("Rescan \(category.title.lowercased())") {
                    rescanning = true
                    Task { await store.rescan(category); rescanning = false }
                }
                .buttonStyle(EditorialButtonStyle(kind: .secondary))
                .disabled(store.scanState.isLoading)
            }
        } content: {
            if !store.hasResults && !rescanning {
                CleanupNeedsScan()
            } else {
                TileGrid {
                    StatTile(label: "Reclaimable", value: Format.bytes(store.bytes(list)), detail: share(list), tint: CleanupText.tint(category), icon: CleanupText.icon(category))
                    StatTile(label: "Items", value: Format.count(list.count), detail: "\(Format.count(store.ruleTallies(list).count)) rules")
                    StatTile(label: "Files", value: Format.count(store.files(list)))
                    StatTile(label: "Selected", value: Format.bytes(store.bytes(selected)), detail: "\(Format.count(selected.count)) items")
                    extraTiles(list)
                }
                if category == .trash {
                    NavRow(icon: "trash", title: "Open Trash bins", subtitle: "Per-bin sizes and Empty Trash", route: .cleanup(.trash))
                }
                let rules = store.ruleTallies(list)
                if !rules.isEmpty {
                    Card("By rule", trailing: "\(rules.count)") {
                        let peak = Double(rules.first?.bytes ?? 1)
                        ForEach(rules) { rule in
                            BarRow(label: "\(rule.title) (\(Format.count(rule.count)))", value: Double(rule.bytes), total: peak, valueText: Format.bytes(rule.bytes), tint: CleanupText.tint(category)) {
                                nav.push(.cleanup(.ruleGroup(rule.id)))
                            }
                        }
                    }
                }
                if category == .large || category == .ai {
                    ageCard(list)
                }
                CleanupItemList(items: list, actionTitle: category == .large ? "Move to Trash" : "Clean Selected", activityTitle: "Clean \(category.title.lowercased())")
            }
        }
    }

    private func share(_ list: [JunkItem]) -> String {
        let total = store.totalBytes
        guard total > 0 else { return "of last scan" }
        return "\(Format.percent(Double(store.bytes(list)) / Double(total))) of all junk"
    }

    @ViewBuilder
    private func extraTiles(_ list: [JunkItem]) -> some View {
        let largest = list.max { $0.bytes < $1.bytes }
        let oldest = list.compactMap(\.modified).min()
        StatTile(label: "Largest", value: largest.map { Format.bytes($0.bytes) } ?? "—", detail: largest.map { CleanupText.name($0.path) })
        StatTile(label: "Oldest", value: Format.relative(oldest), detail: oldest.map { Format.date($0) })
        let auto = list.filter { store.isRecommended($0) }
        StatTile(label: "Auto-selected", value: Format.count(auto.count), detail: Format.bytes(store.bytes(auto)), tint: Theme.success)
        let caution = list.filter { $0.risk == .caution }
        StatTile(label: "Review", value: Format.count(caution.count), detail: Format.bytes(store.bytes(caution)), tint: Theme.warning)
    }

    private func ageCard(_ list: [JunkItem]) -> some View {
        let now = Date()
        let buckets: [(String, Double, Double)] = [
            ("< 1 mo", 0, 30), ("1–6 mo", 30, 182), ("6–12 mo", 182, 365), ("1–2 yr", 365, 730), ("> 2 yr", 730, .infinity),
        ]
        let bars = buckets.map { label, low, high -> CleanupBarChart.Bar in
            let inBucket = list.filter {
                let days = now.timeIntervalSince($0.modified ?? now) / 86_400
                return days >= low && days < high
            }
            let bytes = store.bytes(inBucket)
            return .init(label: label, value: Double(bytes), text: Format.bytes(bytes))
        }
        return Card("Size by last modified", trailing: "\(Format.count(list.count)) items") {
            CleanupBarChart(bars: bars, tint: CleanupText.tint(category))
        }
    }
}

// MARK: - Rule group

struct CleanupRuleGroupScreen: View {
    let ruleID: String
    @ObservedObject private var store = CleanupStore.shared
    @EnvironmentObject private var nav: Navigator

    var body: some View {
        let rule = Rules.rule(id: ruleID)
        let list = store.items(rule: ruleID)
        let selected = list.filter { store.selection.contains($0.path) }
        ScreenScaffold(rule?.title ?? ruleID, subtitle: rule.map { "\($0.category.title) · \(CleanupText.location($0))" }) {
            RefreshLine(state: store.scanState) { store.scan() }
        } content: {
            if let rule {
                TileGrid {
                    StatTile(label: "Found", value: Format.bytes(store.bytes(list)), tint: CleanupText.tint(rule.category))
                    StatTile(label: "Items", value: Format.count(list.count))
                    StatTile(label: "Files", value: Format.count(store.files(list)))
                    StatTile(label: "Selected", value: Format.bytes(store.bytes(selected)), detail: "\(Format.count(selected.count)) items")
                    StatTile(label: "Risk", value: rule.risk == .safe ? "Safe" : "Review", tint: rule.risk == .safe ? Theme.success : Theme.warning)
                    StatTile(label: "Mode", value: rule.scanOnly ? "Report" : (rule.autoselect ? "Auto" : "Manual"), detail: CleanupText.mode(rule))
                }
                Card("Rule") {
                    KeyValueRow(key: "Identifier", value: rule.id, mono: true)
                    KeyValueRow(key: "Location", value: CleanupText.location(rule), mono: true)
                    KeyValueRow(key: "Matches", value: CleanupText.mode(rule))
                    if rule.risk == .caution {
                        Text(CleanupText.cautionReason(rule.id)).font(Type.text(11)).foregroundStyle(Theme.warning)
                    }
                    NavRow(icon: "info.circle", title: "Full rule details", subtitle: "Roots, excludes, flags", route: .cleanup(.ruleDetail(rule.id)))
                }
                if !list.isEmpty {
                    Card("Share of rule", trailing: "top 8") {
                        StackedBar(segments: list.sorted { $0.bytes > $1.bytes }.prefix(8).enumerated().map { index, item in
                            StackedBar.Segment(label: CleanupText.name(item.path), value: Double(item.bytes), color: [Theme.accent, Theme.info, Theme.success, Theme.warning, Theme.danger, Theme.muted, Theme.faint, Theme.lineStrong][index], text: Format.bytes(item.bytes))
                        }, total: Double(max(store.bytes(list), 1)))
                    }
                }
                CleanupItemList(items: list, activityTitle: "Clean \(rule.title.lowercased())")
            } else {
                ErrorPanel(message: "Unknown rule \(ruleID)")
            }
        }
    }
}

// MARK: - Review selection

struct CleanupReviewScreen: View {
    @ObservedObject private var store = CleanupStore.shared
    @EnvironmentObject private var nav: Navigator

    var body: some View {
        let selected = store.selectedItems
        ScreenScaffold("Review Selection", subtitle: "Everything that will be cleaned, across all categories") {
            HStack(spacing: 8) {
                Button("Select recommended") { store.selectRecommended() }.buttonStyle(EditorialButtonStyle(kind: .ghost))
                Button("Clear") { store.selection = [] }.buttonStyle(EditorialButtonStyle(kind: .ghost))
            }
        } content: {
            if !store.hasResults {
                CleanupNeedsScan()
            } else {
                TileGrid {
                    StatTile(label: "Selected", value: Format.bytes(store.bytes(selected)), tint: Theme.accent)
                    StatTile(label: "Items", value: Format.count(selected.count), detail: "of \(Format.count(store.visibleItems.count))")
                    StatTile(label: "Files", value: Format.count(store.files(selected)))
                    StatTile(label: "Caution", value: Format.count(selected.filter { $0.risk == .caution }.count), tint: Theme.warning)
                    StatTile(label: "Mode", value: store.settings.permanent ? "Delete" : "Trash", tint: store.settings.permanent ? Theme.danger : Theme.success)
                }
                let tallies = store.tallies(selected)
                if !tallies.isEmpty {
                    Card("Selected by category", trailing: Format.bytes(store.bytes(selected))) {
                        StackedBar(segments: tallies.map {
                            .init(label: $0.category.title, value: Double($0.bytes), color: CleanupText.tint($0.category), text: "\(Format.count($0.count)) · \(Format.bytes($0.bytes))")
                        })
                    }
                }
                if selected.isEmpty {
                    EmptyPanel(icon: "checklist", title: "Nothing selected", message: "Pick items in a category, or select everything the engine recommends.", actionTitle: "Select Recommended") {
                        store.selectRecommended()
                    }
                } else {
                    ForEach(tallies) { tally in
                        SectionHeader(title: tally.category.title, detail: "\(Format.count(tally.count)) · \(Format.bytes(tally.bytes))")
                        ForEach(selected.filter { $0.category == tally.category }.prefix(100), id: \.path) { item in
                            CheckRow(isOn: store.binding(item.path), title: CleanupText.name(item.path), subtitle: "\(item.ruleTitle) · \(Format.abbreviated(item.path))", value: Format.bytes(item.bytes), badge: item.risk == .caution ? "Review" : nil, onOpen: { nav.push(.cleanup(.itemDetail(item.path))) }, onReveal: { EngineActions.reveal(item.path) })
                        }
                    }
                    SelectionBar(
                        selectedCount: selected.count,
                        totalCount: store.visibleItems.count,
                        selectedBytes: store.bytes(selected),
                        actionTitle: "Clean Selection",
                        confirmMessage: store.confirmMessage,
                        busy: store.cleaning,
                        onSelectAll: { store.select(store.visibleItems) },
                        onSelectNone: { store.selection = [] },
                        action: {
                            Task {
                                await store.clean(selected, title: "Clean selection")
                                nav.push(.cleanup(.cleanResult))
                            }
                        }
                    )
                }
            }
        }
    }
}

// MARK: - Caution

struct CleanupCautionScreen: View {
    @ObservedObject private var store = CleanupStore.shared

    var body: some View {
        let list = store.cautionItems
        ScreenScaffold("Needs Review", subtitle: "Items the engine never auto-selects, with the reason") {
            RefreshLine(state: store.scanState) { store.scan() }
        } content: {
            if !store.hasResults {
                CleanupNeedsScan()
            } else {
                TileGrid {
                    StatTile(label: "Caution items", value: Format.count(list.count), tint: Theme.warning)
                    StatTile(label: "Size", value: Format.bytes(store.bytes(list)))
                    StatTile(label: "Rules", value: Format.count(store.ruleTallies(list).count))
                    StatTile(label: "Shown in lists", value: store.settings.includeCaution ? "Yes" : "Hidden", detail: "Scan Options › include caution", tint: store.settings.includeCaution ? Theme.success : Theme.warning)
                }
                if !store.settings.includeCaution {
                    Card {
                        HStack {
                            Text("Caution items are hidden from category lists and totals.").font(Type.text(12)).foregroundStyle(Theme.muted)
                            Spacer()
                            Button("Show them") { store.settings.includeCaution = true }.buttonStyle(EditorialButtonStyle(kind: .inline))
                        }
                    }
                }
                ForEach(store.ruleTallies(list)) { rule in
                    Card(rule.title, trailing: "\(Format.count(rule.count)) · \(Format.bytes(rule.bytes))") {
                        Text(CleanupText.cautionReason(rule.id)).font(Type.text(12)).foregroundStyle(Theme.ink)
                        NavRow(icon: "list.bullet", title: "Review items", subtitle: "Select individual items to remove", value: Format.bytes(rule.bytes), tint: Theme.warning, route: .cleanup(.ruleGroup(rule.id)))
                    }
                }
                if list.isEmpty {
                    EmptyPanel(icon: "checkmark.shield", title: "Nothing needs review", message: "The last scan found no caution items.")
                }
            }
        }
    }
}
