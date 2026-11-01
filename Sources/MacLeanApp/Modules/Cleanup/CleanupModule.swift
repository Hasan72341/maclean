import MacLeanCore
import SwiftUI

enum CleanupRoute: Hashable {
    case scanResults
    case category(String)
    case ruleGroup(String)
    case itemDetail(String)
    case reviewSelection
    case cleanResult
    case cautionItems
    case rootItems
    case trash
    case largeFiles
    case devJunk
    case browserCaches
    case aiData
    case updateLeftovers
    case systemJunk
    case rulesCatalog
    case ruleDetail(String)
    case scanOptions
    case cleanupHistory
    case scanLog
    case scanConsole
    case ruleTimings
    case ruleEditor(String)
    case newRule
}

enum CleanupModule {
    @MainActor @ViewBuilder
    static func root() -> some View {
        CleanupHubScreen()
    }

    @MainActor @ViewBuilder
    static func destination(_ route: CleanupRoute) -> some View {
        switch route {
        case .scanResults: CleanupResultsScreen()
        case .category(let raw):
            if let category = JunkCategory(rawValue: raw) {
                CleanupCategoryScreen(category: category)
            } else {
                ScreenScaffold("Unknown category") { ErrorPanel(message: "No category named \(raw)") }
            }
        case .ruleGroup(let id): CleanupRuleGroupScreen(ruleID: id)
        case .itemDetail(let path): CleanupItemDetailScreen(path: path)
        case .reviewSelection: CleanupReviewScreen()
        case .cleanResult: CleanupResultScreen()
        case .cautionItems: CleanupCautionScreen()
        case .rootItems: CleanupRootScreen()
        case .trash: CleanupTrashScreen()
        case .largeFiles: CleanupCategoryScreen(category: .large)
        case .devJunk: CleanupCategoryScreen(category: .dev)
        case .browserCaches: CleanupCategoryScreen(category: .browser)
        case .aiData: CleanupCategoryScreen(category: .ai)
        case .updateLeftovers: CleanupCategoryScreen(category: .updates)
        case .systemJunk: CleanupCategoryScreen(category: .system)
        case .rulesCatalog: CleanupRulesCatalogScreen()
        case .ruleDetail(let id): CleanupRuleDetailScreen(ruleID: id)
        case .scanOptions: CleanupOptionsScreen()
        case .cleanupHistory: CleanupHistoryScreen()
        case .scanLog: CleanupScanLogScreen()
        case .scanConsole: CleanupScanConsoleScreen()
        case .ruleTimings: CleanupRuleTimingsScreen()
        case .ruleEditor(let id): CleanupRuleEditorScreen(ruleID: id)
        case .newRule: CustomRuleEditorScreen(existing: nil)
        }
    }

    static func title(_ route: CleanupRoute) -> String {
        switch route {
        case .scanResults: return "Scan Results"
        case .category(let raw): return JunkCategory(rawValue: raw)?.title ?? raw
        case .ruleGroup(let id): return Rules.rule(id: id)?.title ?? id
        case .itemDetail(let path): return (path as NSString).lastPathComponent
        case .reviewSelection: return "Review Selection"
        case .cleanResult: return "Cleanup Result"
        case .cautionItems: return "Needs Review"
        case .rootItems: return "Administrator Items"
        case .trash: return "Trash Bins"
        case .largeFiles: return "Large Files"
        case .devJunk: return "Developer Junk"
        case .browserCaches: return "Browser Caches"
        case .aiData: return "AI Tool Data"
        case .updateLeftovers: return "Update Leftovers"
        case .systemJunk: return "System Junk"
        case .rulesCatalog: return "Rules Catalog"
        case .ruleDetail(let id): return Rules.rule(id: id)?.title ?? id
        case .scanOptions: return "Scan Options"
        case .cleanupHistory: return "Cleanup History"
        case .scanLog: return "Scan Log"
        case .scanConsole: return "Scan Console"
        case .ruleTimings: return "Rule Timings"
        case .ruleEditor(let id): return "Edit " + (Rules.rule(id: id)?.title ?? id)
        case .newRule: return "New Rule"
        }
    }

    static func route(for category: JunkCategory) -> CleanupRoute {
        switch category {
        case .system: return .systemJunk
        case .dev: return .devJunk
        case .browser: return .browserCaches
        case .ai: return .aiData
        case .updates: return .updateLeftovers
        case .trash: return .trash
        case .large: return .largeFiles
        }
    }
}

// MARK: - Shared item list

/// Searchable, sortable, selectable list of junk items with a confirmed clean action.
struct CleanupItemList: View {
    let items: [JunkItem]
    var actionTitle: String = "Clean Selected"
    var activityTitle: String = "Cleanup"
    var showCategory: Bool = false
    @ObservedObject private var store = CleanupStore.shared
    @EnvironmentObject private var nav: Navigator
    @State private var query = ""
    @State private var sort: CleanupSort = .size
    @State private var limit = 200

    private var filtered: [JunkItem] {
        let base = query.isEmpty ? items : items.filter {
            $0.path.localizedCaseInsensitiveContains(query) || $0.ruleTitle.localizedCaseInsensitiveContains(query)
        }
        return sort.apply(base)
    }

    var body: some View {
        let list = filtered
        let selected = list.filter { store.selection.contains($0.path) }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                SearchField(text: $query, prompt: "Filter \(Format.count(items.count)) items")
                Spacer()
                Picker("Sort", selection: $sort) {
                    ForEach(CleanupSort.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)
            }
            SelectionBar(
                selectedCount: selected.count,
                totalCount: list.count,
                selectedBytes: selected.reduce(0) { $0 + $1.bytes },
                actionTitle: actionTitle,
                confirmMessage: store.confirmMessage,
                busy: store.cleaning,
                onSelectAll: { store.select(list) },
                onSelectNone: { store.deselect(list) },
                action: {
                    Task {
                        await store.clean(selected, title: activityTitle)
                        nav.push(.cleanup(.cleanResult))
                    }
                }
            )
            if list.isEmpty {
                EmptyPanel(icon: "checkmark.seal", title: query.isEmpty ? "Nothing here" : "No matches", message: query.isEmpty ? "The last scan found nothing in this group." : "No item matches “\(query)”.")
            } else {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(list.prefix(limit), id: \.path) { item in
                        CheckRow(
                            isOn: store.binding(item.path),
                            title: CleanupText.name(item.path),
                            subtitle: subtitle(item),
                            value: Format.bytes(item.bytes),
                            badge: badge(item),
                            badgeTint: item.risk == .caution ? Theme.warning : Theme.info,
                            onOpen: { nav.push(.cleanup(.itemDetail(item.path))) },
                            onReveal: { EngineActions.reveal(item.path) }
                        )
                    }
                    if list.count > limit {
                        Button("Show \(Format.count(min(200, list.count - limit))) more of \(Format.count(list.count - limit)) remaining") { limit += 200 }
                            .buttonStyle(EditorialButtonStyle(kind: .inline))
                    }
                }
            }
        }
    }

    private func subtitle(_ item: JunkItem) -> String {
        var parts = [Format.abbreviated((item.path as NSString).deletingLastPathComponent)]
        if showCategory { parts.append(item.category.title) }
        parts.append(item.ruleTitle)
        parts.append("\(Format.count(item.files)) file\(item.files == 1 ? "" : "s")")
        if let modified = item.modified { parts.append(Format.relative(modified)) }
        return parts.joined(separator: " · ")
    }

    private func badge(_ item: JunkItem) -> String? {
        if item.requiresRoot { return "Admin" }
        if item.risk == .caution { return "Review" }
        if Rules.rule(id: item.ruleID)?.scanOnly == true { return "Report only" }
        return nil
    }
}

/// Bar chart of values over consecutive buckets (e.g. days).
struct CleanupBarChart: View {
    struct Bar: Identifiable {
        let label: String
        let value: Double
        let text: String
        var id: String { label }
    }

    let bars: [Bar]
    var tint: Color = Theme.accent
    var height: CGFloat = 120

    var body: some View {
        let peak = max(bars.map(\.value).max() ?? 1, 0.0001)
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(bars) { bar in
                VStack(spacing: 4) {
                    Spacer(minLength: 0)
                    if bar.value > 0 {
                        Text(bar.text).font(Type.mono(8)).foregroundStyle(Theme.muted).lineLimit(1).minimumScaleFactor(0.5)
                    }
                    RoundedRectangle(cornerRadius: 3)
                        .fill(bar.value > 0 ? tint : Theme.line)
                        .frame(height: max(2, CGFloat(bar.value / peak) * (height - 34)))
                    Text(bar.label).font(Type.mono(8)).foregroundStyle(Theme.faint).lineLimit(1).minimumScaleFactor(0.5)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: height)
    }
}

/// Shown on screens that need scan results when no scan has run yet.
struct CleanupNeedsScan: View {
    @ObservedObject private var store = CleanupStore.shared

    var body: some View {
        if store.scanState.isLoading {
            LoadingPanel(text: "Scan in progress", detail: { if case .loading(let t) = store.scanState { return t }; return nil }())
        } else {
            EmptyPanel(icon: "archivebox", title: "No scan yet", message: "Run Smart Scan to measure junk on this Mac.", actionTitle: "Scan Now") {
                store.scan()
            }
        }
    }
}
