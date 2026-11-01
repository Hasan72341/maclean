import AppKit
import MacLeanCore
import SwiftUI

// MARK: - Shared bits

enum RuleText {
    static func originBadge(_ rule: JunkRule, enabled: Bool) -> (String, Color)? {
        if !enabled { return ("Off", Theme.faint) }
        switch rule.origin {
        case .custom: return ("Custom", Theme.accent)
        case .edited: return ("Edited", Theme.info)
        case .bundled: return nil
        }
    }

    static func flags(_ rule: JunkRule) -> String {
        var parts: [String] = [rule.scanOnly ? "report only" : (rule.autoselect ? "auto-select" : "manual")]
        if rule.risk == .caution { parts.append("caution") }
        if rule.requiresRoot { parts.append("admin") }
        if !rule.excludes.isEmpty { parts.append("\(rule.excludes.count) excludes") }
        return parts.joined(separator: ", ")
    }
}

/// Catalog row: on/off switch plus a navigating row.
private struct CatalogRuleRow: View {
    let rule: JunkRule
    @ObservedObject private var lab = RuleLab.shared
    @ObservedObject private var store = CleanupStore.shared
    @ObservedObject private var trace = ScanTrace.shared
    @EnvironmentObject private var nav: Navigator
    @State private var hovering = false

    var body: some View {
        let enabled = lab.isEnabled(rule.id)
        let found = store.items(rule: rule.id)
        let stat = trace.ruleStats[rule.id]
        HStack(spacing: 10) {
            Toggle("", isOn: lab.enabledBinding(rule.id))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help(enabled ? "Disable this rule" : "Enable this rule")
            Button {
                nav.push(.cleanup(.ruleDetail(rule.id)))
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: rule.requiresRoot ? "lock" : (rule.risk == .caution ? "exclamationmark.triangle" : CleanupText.icon(rule.category)))
                        .foregroundStyle(enabled ? (rule.risk == .caution ? Theme.warning : CleanupText.tint(rule.category)) : Theme.faint)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(rule.title).font(Type.text(13, weight: .medium)).foregroundStyle(enabled ? Theme.ink : Theme.muted).lineLimit(1)
                            if let badge = RuleText.originBadge(rule, enabled: enabled) {
                                RiskBadge(text: badge.0, tint: badge.1)
                            }
                        }
                        Text("\(CleanupText.location(rule)) · \(RuleText.flags(rule))")
                            .font(Type.text(11)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    if let stat, stat.status == .done {
                        Text(String(format: "%.2fs", stat.seconds)).font(Type.mono(10)).foregroundStyle(Theme.faint)
                    }
                    Text(store.hasResults ? (found.isEmpty ? "0" : "\(Format.count(found.count)) · \(Format.bytes(store.bytes(found)))") : "—")
                        .font(Type.mono(12, weight: .semibold)).foregroundStyle(Theme.ink).monospacedDigit()
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.faint)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9).fill(hovering ? Theme.line.opacity(0.45) : Theme.canvas))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line, lineWidth: 1))
        .onHover { hovering = $0 }
    }
}

/// Editable list of name patterns (`name` or `prefix*`).
struct ExcludesEditor: View {
    @Binding var excludes: [String]
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if excludes.isEmpty {
                Text("No exclusions. Every entry in the folder is considered.").font(Type.text(11)).foregroundStyle(Theme.muted)
            }
            FlowChips(items: excludes) { item in
                excludes.removeAll { $0 == item }
            }
            HStack(spacing: 8) {
                TextField("Name or prefix* to exclude (e.g. com.apple.Safari or Google*)", text: $draft)
                    .textFieldStyle(EditorialTextFieldStyle())
                    .onSubmit(add)
                Button("Add", action: add)
                    .buttonStyle(EditorialButtonStyle(kind: .secondary))
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Matched against each entry's name. A trailing * matches any name starting with the text before it.")
                .font(Type.text(10)).foregroundStyle(Theme.faint)
        }
    }

    private func add() {
        let value = draft.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, !excludes.contains(value) else { draft = ""; return }
        excludes.append(value)
        draft = ""
    }
}

private struct FlowChips: View {
    let items: [String]
    let remove: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                HStack(spacing: 4) {
                    Text(item).font(Type.mono(10)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button { remove(item) } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.muted)
                    }
                    .buttonStyle(.plain)
                    .help("Remove \(item)")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Theme.line.opacity(0.6)))
            }
        }
    }
}

/// Dry-run result of a rule: what it would find right now.
struct RuleTestCard: View {
    let ruleID: String
    var draft: (() throws -> JunkRule)? = nil
    @ObservedObject private var lab = RuleLab.shared
    @State private var showLog = false
    @State private var error: String?

    var body: some View {
        let result = lab.tests[ruleID]
        Card("Test rule", trailing: result.map { "\(Format.relative($0.date)) · \(String(format: "%.2fs", $0.seconds))" } ?? "read-only dry run") {
            HStack(spacing: 10) {
                Text("Runs only this rule now and lists what it would find. Nothing is removed.")
                    .font(Type.text(11)).foregroundStyle(Theme.muted)
                Spacer()
                if lab.testing.contains(ruleID) { ProgressView().controlSize(.small) }
                Button(result == nil ? "Run test" : "Run again") { run() }
                    .buttonStyle(EditorialButtonStyle(kind: .secondary))
                    .disabled(lab.testing.contains(ruleID))
            }
            if let error {
                Text(error).font(Type.text(11)).foregroundStyle(Theme.danger)
            }
            if let result {
                TileGrid(minWidth: 130) {
                    StatTile(label: "Would find", value: Format.bytes(result.bytes), tint: Theme.accent)
                    StatTile(label: "Items", value: Format.count(result.items.count))
                    StatTile(label: "Files", value: Format.count(result.items.reduce(0) { $0 + $1.files }))
                    StatTile(label: "Skipped", value: Format.count(result.lines.filter { $0.level == .skip }.count))
                }
                ForEach(result.items.sorted { $0.bytes > $1.bytes }.prefix(25), id: \.path) { item in
                    HStack {
                        Text(Format.abbreviated(item.path)).font(Type.mono(10)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(Format.bytes(item.bytes)).font(Type.mono(10, weight: .semibold)).monospacedDigit()
                        Button("Reveal") { EngineActions.reveal(item.path) }.buttonStyle(EditorialButtonStyle(kind: .inline))
                    }
                }
                if result.items.count > 25 {
                    Text("\(Format.count(result.items.count - 25)) more items").font(Type.text(11)).foregroundStyle(Theme.faint)
                }
                Button(showLog ? "Hide test log" : "Show test log (\(Format.count(result.lines.count)) lines)") { showLog.toggle() }
                    .buttonStyle(EditorialButtonStyle(kind: .inline))
                if showLog {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(result.lines.prefix(400)) { ScanLineView(line: $0, showTime: false) }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.paper))
                }
            }
        }
    }

    private func run() {
        error = nil
        let rule: JunkRule?
        if let draft {
            do { rule = try draft() } catch { self.error = error.localizedDescription; return }
        } else {
            rule = lab.rule(ruleID)
        }
        guard let rule else { error = "Unknown rule"; return }
        Task { await lab.test(rule) }
    }
}

// MARK: - Catalog

struct CleanupRulesCatalogScreen: View {
    @ObservedObject private var store = CleanupStore.shared
    @ObservedObject private var lab = RuleLab.shared
    @EnvironmentObject private var nav: Navigator
    @State private var query = ""
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", matched = "With findings", custom = "Custom", edited = "Edited", off = "Off"
        var id: String { rawValue }
    }

    var body: some View {
        let all = lab.rules
        let rules = all.filter { rule in
            let text = query.isEmpty || rule.title.localizedCaseInsensitiveContains(query) || rule.id.localizedCaseInsensitiveContains(query) || CleanupText.location(rule).localizedCaseInsensitiveContains(query)
            guard text else { return false }
            switch filter {
            case .all: return true
            case .matched: return !store.items(rule: rule.id).isEmpty
            case .custom: return rule.origin == .custom
            case .edited: return rule.origin == .edited
            case .off: return !lab.isEnabled(rule.id)
            }
        }
        let active = all.filter { lab.isEnabled($0.id) }
        ScreenScaffold("Rules", subtitle: "Every location the engine scans. Switch rules off, edit them or add your own.") {
            HStack(spacing: 8) {
                Button("New Rule") { nav.push(.cleanup(.newRule)) }.buttonStyle(EditorialButtonStyle(kind: .primary))
                Menu("More") {
                    Button("Import rules…") { lab.importRules() }
                    Button("Export rules…") { lab.exportRules() }
                    Button("Reveal rules.json") { EngineActions.reveal(lab.book.url.path) }
                        .disabled(!FileManager.default.fileExists(atPath: lab.book.url.path))
                    Button("Reload from disk") { lab.reload() }
                    Divider()
                    Button("Reset edits to built-in rules") { lab.resetEdits() }
                    Button("Reset everything (removes custom rules)") { lab.resetEverything() }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        } content: {
            TileGrid(minWidth: 130) {
                StatTile(label: "Active", value: Format.count(active.count), detail: "of \(Format.count(all.count))", tint: Theme.success, icon: "books.vertical")
                StatTile(label: "Off", value: Format.count(lab.disabledCount), tint: Theme.muted)
                StatTile(label: "Custom", value: Format.count(lab.customCount), tint: Theme.accent)
                StatTile(label: "Edited", value: Format.count(lab.editedCount), tint: Theme.info)
                StatTile(label: "Matched last scan", value: Format.count(all.filter { !store.items(rule: $0.id).isEmpty }.count))
                StatTile(label: "Caution", value: Format.count(active.filter { $0.risk == .caution }.count), tint: Theme.warning)
                StatTile(label: "Admin", value: Format.count(active.filter(\.requiresRoot).count), tint: Theme.danger)
            }
            HStack(spacing: 10) {
                SearchField(text: $query, prompt: "Search rules, ids, paths")
                Picker("Filter", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .flexibleWidth(400)
                Spacer()
                Text("\(Format.count(rules.count)) shown").font(Type.text(11)).foregroundStyle(Theme.muted)
            }
            Text("Changes are saved to \(Format.abbreviated(lab.book.url.path)) and apply to the next scan, in the app and in the maclean CLI.")
                .font(Type.text(11)).foregroundStyle(Theme.faint)
            let custom = rules.filter { $0.origin == .custom }
            if !custom.isEmpty {
                SectionHeader(title: "Custom rules", detail: "\(custom.count) rules")
                ForEach(custom) { CatalogRuleRow(rule: $0) }
            }
            ForEach(JunkCategory.allCases, id: \.self) { category in
                let group = rules.filter { $0.category == category && $0.origin != .custom }
                if !group.isEmpty {
                    SectionHeader(title: category.title, detail: "\(group.filter { lab.isEnabled($0.id) }.count)/\(group.count) on · \(Format.bytes(store.bytes(group.flatMap { store.items(rule: $0.id) })))")
                    ForEach(group) { CatalogRuleRow(rule: $0) }
                }
            }
            if rules.isEmpty {
                EmptyPanel(icon: "magnifyingglass", title: "No rules match", message: filter == .custom ? "You have not created any rules yet." : nil, actionTitle: filter == .custom ? "New Rule" : nil) {
                    nav.push(.cleanup(.newRule))
                }
            }
        }
    }
}

// MARK: - Rule detail

struct CleanupRuleDetailScreen: View {
    let ruleID: String
    @ObservedObject private var store = CleanupStore.shared
    @ObservedObject private var lab = RuleLab.shared
    @ObservedObject private var trace = ScanTrace.shared
    @EnvironmentObject private var nav: Navigator
    @State private var roots: [(path: String, exists: Bool, entries: Int)] = []

    var body: some View {
        ScreenScaffold(lab.rule(ruleID)?.title ?? ruleID, subtitle: ruleID) {
            HStack(spacing: 8) {
                if lab.rule(ruleID) != nil {
                    Button("Edit") { nav.push(.cleanup(.ruleEditor(ruleID))) }.buttonStyle(EditorialButtonStyle(kind: .primary))
                }
                RefreshLine(state: store.scanState) { store.scan() }
            }
        } content: {
            if let rule = lab.rule(ruleID) {
                let found = store.items(rule: rule.id)
                let enabled = lab.isEnabled(rule.id)
                Card {
                    HStack(spacing: 12) {
                        Toggle("", isOn: lab.enabledBinding(rule.id)).toggleStyle(.switch).labelsHidden()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(enabled ? "Rule is on" : "Rule is off").font(Type.text(13, weight: .semibold)).foregroundStyle(Theme.ink)
                            Text(enabled ? "Included in every Smart Scan and CLI scan." : "Skipped by scans. Items already found stay in the current results.")
                                .font(Type.text(11)).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        if let badge = RuleText.originBadge(rule, enabled: enabled) { RiskBadge(text: badge.0, tint: badge.1) }
                        if rule.origin == .edited {
                            ConfirmButton(title: "Reset", message: "Restore the built-in definition of \(rule.title)?", kind: .ghost) { lab.resetRule(rule.id) }
                        }
                    }
                }
                TileGrid {
                    StatTile(label: "Found", value: Format.bytes(store.bytes(found)), detail: store.hasResults ? "last scan" : "not scanned", tint: CleanupText.tint(rule.category))
                    StatTile(label: "Items", value: Format.count(found.count), detail: "\(Format.count(store.files(found))) files")
                    StatTile(label: "Roots", value: Format.count(roots.count), detail: "\(Format.count(roots.filter(\.exists).count)) exist")
                    if let stat = trace.ruleStats[rule.id] {
                        StatTile(label: "Scan time", value: String(format: "%.2fs", stat.seconds), detail: stat.status.rawValue)
                        StatTile(label: "Examined", value: Format.count(stat.examined), detail: "\(Format.count(stat.skipped)) skipped")
                    }
                }
                Card("Definition") {
                    KeyValueRow(key: "Identifier", value: rule.id, mono: true)
                    KeyValueRow(key: "Origin", value: rule.origin == .custom ? "Custom rule" : (rule.origin == .edited ? "Built-in, edited" : "Built-in"))
                    KeyValueRow(key: "Category", value: rule.category.title)
                    KeyValueRow(key: "Location", value: CleanupText.location(rule), mono: true)
                    KeyValueRow(key: "Mode", value: CleanupText.mode(rule))
                    KeyValueRow(key: "Risk", value: rule.risk == .safe ? "Safe" : "Caution")
                    KeyValueRow(key: "Auto-select", value: rule.autoselect ? "Yes" : "No")
                    KeyValueRow(key: "Report only", value: rule.scanOnly ? "Yes" : "No")
                    KeyValueRow(key: "Requires administrator", value: rule.requiresRoot ? "Yes" : "No")
                    KeyValueRow(key: "Removes root folder itself", value: rule.targetsRootItself ? "Yes" : "No")
                    if rule.risk == .caution || rule.scanOnly || rule.requiresRoot {
                        Text(CleanupText.cautionReason(rule.id)).font(Type.text(11)).foregroundStyle(Theme.warning)
                    }
                }
                Card("Resolved roots", trailing: "\(roots.count)") {
                    if roots.isEmpty {
                        Text("No roots on this Mac (no matching containers or volumes).").font(Type.text(11)).foregroundStyle(Theme.muted)
                    }
                    ForEach(Array(roots.prefix(40).enumerated()), id: \.offset) { entry in
                        HStack {
                            Image(systemName: entry.element.exists ? "checkmark.circle.fill" : "circle.dashed")
                                .foregroundStyle(entry.element.exists ? Theme.success : Theme.faint)
                            Text(Format.abbreviated(entry.element.path)).font(Type.mono(10)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            if entry.element.exists {
                                Text("\(Format.count(entry.element.entries)) entries").font(Type.text(10)).foregroundStyle(Theme.muted)
                                Button("Reveal") { EngineActions.reveal(entry.element.path) }.buttonStyle(EditorialButtonStyle(kind: .inline))
                            } else {
                                Text("missing").font(Type.text(10)).foregroundStyle(Theme.faint)
                            }
                        }
                    }
                    if roots.count > 40 {
                        Text("\(Format.count(roots.count - 40)) more").font(Type.text(11)).foregroundStyle(Theme.faint)
                    }
                }
                Card("Excluded names", trailing: "\(rule.excludes.count)") {
                    if rule.excludes.isEmpty {
                        Text("None").font(Type.text(11)).foregroundStyle(Theme.muted)
                    } else {
                        Text(rule.excludes.joined(separator: ", ")).font(Type.mono(10)).foregroundStyle(Theme.muted).textSelection(.enabled)
                    }
                    Button("Edit exclusions") { nav.push(.cleanup(.ruleEditor(rule.id))) }.buttonStyle(EditorialButtonStyle(kind: .inline))
                }
                RuleTestCard(ruleID: rule.id)
                NavRow(icon: "list.bullet", title: "Items found by this rule", subtitle: found.isEmpty ? "Nothing in the last scan" : "\(Format.count(found.count)) items", value: Format.bytes(store.bytes(found)), route: .cleanup(.ruleGroup(rule.id)))
                NavRow(icon: "terminal", title: "Scan console", subtitle: "Verbose log of the last scan", value: "\(Format.count(trace.lines.filter { $0.ruleID == rule.id }.count)) lines", tint: Theme.info, route: .cleanup(.scanConsole))
                NavRow(icon: CleanupText.icon(rule.category), title: rule.category.title, subtitle: "Open category", route: .cleanup(.category(rule.category.rawValue)))
            } else {
                ErrorPanel(message: "Unknown rule \(ruleID). It may have been deleted.")
            }
        }
        .task(id: lab.revision) {
            guard let rule = lab.rule(ruleID) else { roots = []; return }
            roots = await engine { () -> [(path: String, exists: Bool, entries: Int)] in
                RuleRoots(home: FileManager.default.homeDirectoryForCurrentUser).roots(for: rule).map { url in
                    let names = try? FileManager.default.contentsOfDirectory(atPath: url.path)
                    return (path: url.path, exists: FileManager.default.fileExists(atPath: url.path), entries: names?.count ?? 0)
                }
            }
        }
    }
}

// MARK: - Editor (built-in rules)

struct CleanupRuleEditorScreen: View {
    let ruleID: String
    @ObservedObject private var lab = RuleLab.shared

    var body: some View {
        if lab.isCustom(ruleID), let custom = lab.custom(ruleID) {
            CustomRuleEditorScreen(existing: custom)
        } else if let base = lab.book.bundled(id: ruleID) {
            BundledRuleEditor(base: base)
        } else {
            ScreenScaffold("Edit rule") { ErrorPanel(message: "Unknown rule \(ruleID)") }
        }
    }
}

private struct BundledRuleEditor: View {
    let base: JunkRule
    @ObservedObject private var lab = RuleLab.shared
    @EnvironmentObject private var nav: Navigator
    @State private var loaded = false
    @State private var enabled = true
    @State private var title = ""
    @State private var risk: Risk = .safe
    @State private var autoselect = true
    @State private var excludes: [String] = []
    @State private var days = 0

    private var largeDays: Int? {
        if case .largeFiles(let d) = base.mode { return d ?? 0 }
        return nil
    }

    private var override: RuleOverride {
        RuleOverride(
            enabled: enabled ? nil : false,
            title: title == base.title || title.trimmingCharacters(in: .whitespaces).isEmpty ? nil : title,
            risk: risk == base.risk ? nil : risk,
            autoselect: autoselect == base.autoselect ? nil : autoselect,
            excludes: excludes == base.excludes ? nil : excludes,
            olderThanDays: largeDays.flatMap { $0 == days ? nil : days }
        )
    }

    private var dirty: Bool { override != (lab.book.override(for: base.id) ?? RuleOverride()) }

    var body: some View {
        ScreenScaffold("Edit \(base.title)", subtitle: "Built-in rule · \(base.id)") {
            HStack(spacing: 8) {
                Button("Revert") { load() }.buttonStyle(EditorialButtonStyle(kind: .ghost)).disabled(!dirty)
                Button("Save") { lab.saveOverride(base.id, override); nav.pop() }
                    .buttonStyle(EditorialButtonStyle(kind: .primary))
                    .disabled(!dirty)
            }
        } content: {
            Card("State") {
                Toggle("Rule is on (included in scans)", isOn: $enabled).toggleStyle(EditorialToggleStyle())
                HStack {
                    Text("Display name").font(Type.text(12)).foregroundStyle(Theme.muted).frame(width: 120, alignment: .leading)
                    TextField(base.title, text: $title).textFieldStyle(EditorialTextFieldStyle())
                }
            }
            Card("Behaviour") {
                HStack {
                    Text("Risk").font(Type.text(12)).foregroundStyle(Theme.muted).frame(width: 120, alignment: .leading)
                    Picker("Risk", selection: $risk) {
                        Text("Safe").tag(Risk.safe)
                        Text("Caution").tag(Risk.caution)
                    }
                    .pickerStyle(.segmented).labelsHidden().flexibleWidth(220)
                    Spacer()
                }
                if base.scanOnly {
                    Text("This rule is report only: its items are listed but never pre-selected. That cannot be changed.")
                        .font(Type.text(11)).foregroundStyle(Theme.muted)
                } else {
                    Toggle("Pre-select items found by this rule (auto-select)", isOn: $autoselect).toggleStyle(EditorialToggleStyle())
                    if autoselect && risk == .caution {
                        Text("Caution items are pre-selected when auto-select is on. Make sure that is what you want.")
                            .font(Type.text(11)).foregroundStyle(Theme.warning)
                    }
                }
                if let _ = largeDays {
                    Stepper(value: $days, in: 0...3_650, step: 30) {
                        KeyValueRow(key: "Only files not modified for", value: days == 0 ? "Any age" : "\(days) days")
                    }
                }
                if base.requiresRoot {
                    Text("Needs administrator rights. Scanned and cleaned only from Administrator Items or `sudo maclean`.")
                        .font(Type.text(11)).foregroundStyle(Theme.warning)
                }
            }
            Card("Excluded names", trailing: "\(excludes.count)") {
                ExcludesEditor(excludes: $excludes)
                if excludes != base.excludes {
                    Button("Restore built-in exclusions (\(base.excludes.count))") { excludes = base.excludes }
                        .buttonStyle(EditorialButtonStyle(kind: .inline))
                }
            }
            Card("Fixed by the engine") {
                KeyValueRow(key: "Category", value: base.category.title)
                KeyValueRow(key: "Location", value: CleanupText.location(base), mono: true)
                KeyValueRow(key: "Mode", value: CleanupText.mode(base))
                Text("Locations of built-in rules cannot be changed. To clean a different folder, create a custom rule.")
                    .font(Type.text(11)).foregroundStyle(Theme.muted)
            }
            RuleTestCard(ruleID: base.id, draft: { RuleBook.apply(override, to: base) })
        }
        .onAppear { if !loaded { load(); loaded = true } }
    }

    private func load() {
        let current = lab.book.override(for: base.id) ?? RuleOverride()
        enabled = current.enabled ?? true
        title = current.title ?? base.title
        risk = current.risk ?? base.risk
        autoselect = current.autoselect ?? base.autoselect
        excludes = current.excludes ?? base.excludes
        days = current.olderThanDays ?? largeDays ?? 0
    }
}

// MARK: - Editor (custom rules)

struct CustomRuleEditorScreen: View {
    let existing: CustomRule?
    @ObservedObject private var lab = RuleLab.shared
    @EnvironmentObject private var nav: Navigator
    @State private var draft = CustomRule()
    @State private var loaded = false
    @State private var preview: (exists: Bool, entries: Int, isDirectory: Bool)?

    private var validation: Result<String, Error> {
        Result { try RuleBook.validate(draft) }
    }

    var body: some View {
        let valid: Bool = { if case .success = validation { return true }; return false }()
        ScreenScaffold(existing == nil ? "New Rule" : "Edit \(existing?.title ?? "")", subtitle: existing == nil ? "Clean a folder the built-in rules do not cover" : "Custom rule · \(draft.id)") {
            HStack(spacing: 8) {
                if let existing {
                    ConfirmButton(title: "Delete", message: "Delete the custom rule \(existing.title)? Files are not affected.", kind: .destructive) {
                        lab.deleteCustom(existing.id)
                        nav.popToRoot()
                        nav.push(.cleanup(.rulesCatalog))
                    }
                }
                Button(existing == nil ? "Create Rule" : "Save") {
                    if lab.saveCustom(draft) {
                        nav.pop()
                        if existing == nil { nav.push(.cleanup(.ruleDetail(draft.id))) }
                    }
                }
                .buttonStyle(EditorialButtonStyle(kind: .primary))
                .disabled(!valid || draft == existing)
            }
        } content: {
            Card("Rule") {
                field("Name") {
                    TextField("e.g. Figma cache", text: $draft.title).textFieldStyle(EditorialTextFieldStyle())
                }
                field("Category") {
                    Picker("Category", selection: $draft.category) {
                        ForEach(JunkCategory.allCases.filter { $0 != .trash }, id: \.self) { Label($0.title, systemImage: CleanupText.icon($0)).tag($0) }
                    }
                    .labelsHidden().flexibleWidth(240)
                }
                Toggle("Rule is on", isOn: $draft.enabled).toggleStyle(EditorialToggleStyle())
            }
            Card("Location") {
                field("Folder") {
                    HStack(spacing: 8) {
                        TextField("~/Library/Caches/com.example.app", text: $draft.relativePath)
                            .textFieldStyle(EditorialTextFieldStyle())
                            .font(Type.mono(12))
                        Button("Choose…") { choose() }.buttonStyle(EditorialButtonStyle(kind: .secondary))
                    }
                }
                switch validation {
                case .success(let relative):
                    HStack(spacing: 6) {
                        Image(systemName: preview?.exists == true ? "checkmark.circle.fill" : "circle.dashed")
                            .foregroundStyle(preview?.exists == true ? Theme.success : Theme.warning)
                        Text("~/" + relative).font(Type.mono(11)).foregroundStyle(Theme.ink)
                        if let preview {
                            Text(preview.exists ? (preview.isDirectory ? "· \(Format.count(preview.entries)) entries" : "· is a file, not a folder") : "· does not exist yet (the rule will simply find nothing)")
                                .font(Type.text(11)).foregroundStyle(preview.exists && preview.isDirectory ? Theme.muted : Theme.warning)
                        }
                        Spacer()
                        if preview?.exists == true {
                            Button("Reveal") { EngineActions.reveal(EngineActions.home.appendingPathComponent(relative).path) }
                                .buttonStyle(EditorialButtonStyle(kind: .inline))
                        }
                    }
                case .failure(let error):
                    if !draft.relativePath.isEmpty || !draft.title.isEmpty {
                        Label(error.localizedDescription, systemImage: "exclamationmark.octagon")
                            .font(Type.text(11)).foregroundStyle(Theme.danger)
                    }
                }
                Text("Custom rules can only target folders inside your home folder. Keychains, Mail, Messages, Photos, iCloud Drive, SSH keys and top-level folders such as Documents are refused.")
                    .font(Type.text(10)).foregroundStyle(Theme.faint)
            }
            Card("What to clean") {
                Picker("Mode", selection: $draft.mode) {
                    ForEach(CustomRuleMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Text(modeHelp).font(Type.text(11)).foregroundStyle(Theme.muted)
                if draft.mode == .largeFiles {
                    Stepper(value: Binding(get: { draft.olderThanDays ?? 0 }, set: { draft.olderThanDays = $0 == 0 ? nil : $0 }), in: 0...3_650, step: 30) {
                        KeyValueRow(key: "Only files not modified for", value: (draft.olderThanDays ?? 0) == 0 ? "Any age" : "\(draft.olderThanDays ?? 0) days")
                    }
                    Text("Uses the large-file threshold from Scan Options (\(CleanupStore.shared.settings.largeThresholdMB) MB).").font(Type.text(10)).foregroundStyle(Theme.faint)
                }
            }
            Card("Safety") {
                field("Risk") {
                    Picker("Risk", selection: $draft.risk) {
                        Text("Safe").tag(Risk.safe)
                        Text("Caution").tag(Risk.caution)
                    }
                    .pickerStyle(.segmented).labelsHidden().flexibleWidth(220)
                }
                Toggle("Pre-select items found by this rule", isOn: $draft.autoselect)
                    .toggleStyle(EditorialToggleStyle())
                    .disabled(draft.mode == .largeFiles)
                Text(draft.mode == .largeFiles ? "Large-file rules are report only and never pre-selected." : "Leave this off until a test shows only what you expect. Items still go to the Trash unless permanent delete is on.")
                    .font(Type.text(11)).foregroundStyle(Theme.muted)
            }
            Card("Excluded names", trailing: "\(draft.excludes.count)") {
                ExcludesEditor(excludes: $draft.excludes)
            }
            RuleTestCard(ruleID: draft.id, draft: { try lab.draftRule(draft) })
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let existing {
                draft = existing
                draft.relativePath = "~/" + existing.relativePath
            }
        }
        .task(id: draft.relativePath) {
            guard case .success(let relative) = validation else { preview = nil; return }
            let url = EngineActions.home.appendingPathComponent(relative)
            preview = await engine {
                var isDir: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                let entries = (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.count ?? 0
                return (exists, entries, isDir.boolValue)
            }
        }
    }

    private var modeHelp: String {
        switch draft.mode {
        case .contents: return "Each file and folder directly inside the folder becomes one item. The folder itself is kept. Best for caches."
        case .whole: return "The folder is one item and is removed as a whole. Best for a single cache folder an app recreates."
        case .largeFiles: return "Lists files above the large-file threshold anywhere inside. Never pre-selected."
        }
    }

    private func field<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack {
            Text(label).font(Type.text(12)).foregroundStyle(Theme.muted).frame(width: 90, alignment: .leading)
            content()
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = EngineActions.home.appendingPathComponent("Library/Caches")
        panel.prompt = "Use Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.relativePath = Format.abbreviated(url.path)
        if draft.title.isEmpty { draft.title = url.lastPathComponent }
    }
}

// MARK: - Scan console

struct ScanLineView: View {
    let line: ScanLine
    var showTime = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if showTime {
                Text(String(format: "%7.2f", line.time)).font(Type.mono(9)).foregroundStyle(Theme.faint).frame(width: 46, alignment: .trailing)
            }
            Text(line.level.tag).font(Type.mono(9, weight: .bold)).foregroundStyle(line.level.tint).frame(width: 40, alignment: .leading)
            Text(line.text).font(Type.mono(10)).foregroundStyle(line.level == .skip || line.level == .missing || line.level == .measure ? Theme.muted : Theme.ink)
                .lineLimit(1)
                .layoutPriority(1)
            if let path = line.path {
                Text(Format.abbreviated(path)).font(Type.mono(10)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if let bytes = line.bytes {
                Text(Format.bytes(bytes)).font(Type.mono(10, weight: .semibold)).foregroundStyle(Theme.success).monospacedDigit()
            }
        }
        .contextMenu {
            if let path = line.path {
                Button("Reveal in Finder") { EngineActions.reveal(path) }
                Button("Copy path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                }
            }
            Button("Copy line") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(line.plain, forType: .string)
            }
        }
    }
}

/// Compact live status used on the Smart Scan hub while scanning.
struct ScanLiveDetail: View {
    @ObservedObject private var trace = ScanTrace.shared
    @EnvironmentObject private var nav: Navigator

    var body: some View {
        Card("Now scanning", trailing: "\(Format.count(trace.rulesDone + trace.rulesSkipped))/\(Format.count(trace.rulesTotal)) rules") {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(trace.currentRule ?? "Preparing…").font(Type.text(13, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                    Text(trace.currentPath.map(Format.abbreviated) ?? " ").font(Type.mono(10)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                }
                ProgressView(value: trace.rulesFraction).tint(Theme.info)
                TileGrid(minWidth: 120) {
                    StatTile(label: "Folders read", value: Format.count(trace.rootsVisited), detail: "\(Format.count(trace.rootsMissing)) missing")
                    StatTile(label: "Examined", value: Format.count(trace.examined), detail: "\(Format.count(trace.measured)) measured", history: trace.rateHistory.count > 1 ? trace.rateHistory : nil)
                    StatTile(label: "Found", value: Format.count(trace.found), detail: Format.bytes(trace.foundBytes), tint: Theme.success)
                    StatTile(label: "Skipped", value: Format.count(trace.skippedTotal), detail: trace.skipCounts.max { $0.value < $1.value }?.key ?? "—")
                    StatTile(label: "Rate", value: String(format: "%.0f/s", trace.rateHistory.last ?? 0), detail: "entries per second", tint: Theme.info)
                }
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(trace.lines.suffix(14)) { ScanLineView(line: $0) }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.paper))
                HStack {
                    Text("\(Format.count(trace.lines.count + trace.droppedLines)) log lines · \(trace.verbosity.title.lowercased()) detail")
                        .font(Type.text(10)).foregroundStyle(Theme.faint)
                    Spacer()
                    Button("Open full console") { nav.push(.cleanup(.scanConsole)) }.buttonStyle(EditorialButtonStyle(kind: .inline))
                }
            }
        }
    }
}

struct CleanupScanConsoleScreen: View {
    @ObservedObject private var trace = ScanTrace.shared
    @ObservedObject private var store = CleanupStore.shared
    @EnvironmentObject private var nav: Navigator
    @State private var levels = Set(ScanLineLevel.allCases)
    @State private var query = ""
    @State private var follow = true

    var body: some View {
        let filtered = trace.lines.filter { line in
            levels.contains(line.level) && (query.isEmpty || line.text.localizedCaseInsensitiveContains(query) || (line.path?.localizedCaseInsensitiveContains(query) ?? false) || (line.ruleID?.localizedCaseInsensitiveContains(query) ?? false))
        }
        let shown = Array(filtered.suffix(3_000))
        ScreenScaffold("Scan Console", subtitle: "Everything the scanner did, line by line", scrolls: false) {
            HStack(spacing: 8) {
                if store.scanState.isLoading {
                    Button("Stop") { store.stopScan() }.buttonStyle(EditorialButtonStyle(kind: .secondary))
                } else {
                    Button("Scan") { store.scan() }.buttonStyle(EditorialButtonStyle(kind: .primary))
                }
                Button("Copy") { trace.copyToPasteboard() }.buttonStyle(EditorialButtonStyle(kind: .ghost)).disabled(trace.lines.isEmpty)
                Button("Log file") {
                    if let url = trace.logURL { EngineActions.reveal(url.path) } else { EngineActions.open(ScanTrace.logDirectory.path) }
                }
                .buttonStyle(EditorialButtonStyle(kind: .ghost))
            }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                TileGrid(minWidth: 120) {
                    StatTile(label: "Elapsed", value: trace.started == nil ? "—" : String(format: "%.1fs", trace.elapsed), detail: trace.finished == nil && trace.started != nil ? "running" : (trace.finished.map { Format.relative($0) } ?? "no scan yet"))
                    StatTile(label: "Rules", value: "\(Format.count(trace.rulesDone))/\(Format.count(trace.rulesTotal))", detail: "\(Format.count(trace.rulesSkipped)) skipped", tint: Theme.info)
                    StatTile(label: "Folders", value: Format.count(trace.rootsVisited), detail: "\(Format.count(trace.rootsMissing)) missing")
                    StatTile(label: "Examined", value: Format.count(trace.examined), history: trace.rateHistory.count > 1 ? trace.rateHistory : nil)
                    StatTile(label: "Found", value: Format.bytes(trace.foundBytes), detail: "\(Format.count(trace.found)) items", tint: Theme.success)
                    StatTile(label: "Skipped", value: Format.count(trace.skippedTotal), tint: Theme.muted)
                }
                if let rule = trace.currentRule {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(rule).font(Type.text(12, weight: .semibold))
                        Text(trace.currentPath.map(Format.abbreviated) ?? "").font(Type.mono(10)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                    }
                }
                HStack(spacing: 10) {
                    SearchField(text: $query, prompt: "Filter lines, paths, rule ids")
                    Picker("Detail", selection: $trace.verbosity) {
                        ForEach(ScanVerbosity.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().flexibleWidth(240)
                    .help("Applies to new lines. Trace logs every measured path.")
                    Toggle("Follow", isOn: $follow).toggleStyle(EditorialToggleStyle())
                    Spacer()
                    Button("Rule timings") { nav.push(.cleanup(.ruleTimings)) }.buttonStyle(EditorialButtonStyle(kind: .inline))
                }
                HStack(spacing: 6) {
                    ForEach(ScanLineLevel.allCases) { level in
                        let count = trace.lines.filter { $0.level == level }.count
                        Button {
                            if levels.contains(level) { levels.remove(level) } else { levels.insert(level) }
                        } label: {
                            Text("\(level.rawValue) \(Format.count(count))")
                                .font(Type.mono(10, weight: .semibold))
                                .foregroundStyle(levels.contains(level) ? level.tint : Theme.faint)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(levels.contains(level) ? level.tint.opacity(0.14) : Theme.line.opacity(0.4)))
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    Text("\(Format.count(filtered.count)) lines\(filtered.count > shown.count ? " · last \(Format.count(shown.count)) shown" : "")\(trace.droppedLines > 0 ? " · \(Format.count(trace.droppedLines)) older dropped (full log on disk)" : "")")
                        .font(Type.text(10)).foregroundStyle(Theme.faint)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(shown) { ScanLineView(line: $0).id($0.id) }
                        }
                        .padding(10)
                        .textSelection(.enabled)
                    }
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.canvas))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
                    .overlay {
                        if trace.lines.isEmpty {
                            EmptyPanel(icon: "terminal", title: "No scan log yet", message: "Run Smart Scan and every rule, folder, skipped entry and finding appears here live.", actionTitle: "Scan Now") { store.scan() }
                        }
                    }
                    .onChange(of: trace.lines.last?.id) { id in
                        guard follow, let id else { return }
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                    .onAppear {
                        if let id = shown.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
            }
        }
    }
}

// MARK: - Rule timings

struct CleanupRuleTimingsScreen: View {
    @ObservedObject private var trace = ScanTrace.shared
    @EnvironmentObject private var nav: Navigator
    @State private var sort: Sort = .time

    enum Sort: String, CaseIterable, Identifiable {
        case time = "Time", size = "Size", examined = "Examined", name = "Name"
        var id: String { rawValue }
    }

    var body: some View {
        let stats: [RuleScanStat] = {
            let all = Array(trace.ruleStats.values)
            switch sort {
            case .time: return all.sorted { $0.seconds > $1.seconds }
            case .size: return all.sorted { $0.bytes > $1.bytes }
            case .examined: return all.sorted { $0.examined > $1.examined }
            case .name: return all.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            }
        }()
        let totalTime = max(stats.reduce(0) { $0 + $1.seconds }, 0.0001)
        ScreenScaffold("Rule Timings", subtitle: "How long each rule took and what it found in the last scan") {
            Picker("Sort", selection: $sort) {
                ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().flexibleWidth(280)
        } content: {
            TileGrid {
                StatTile(label: "Rules run", value: Format.count(stats.filter { $0.status == .done }.count), tint: Theme.info)
                StatTile(label: "Skipped", value: Format.count(stats.filter { $0.status == .skipped }.count))
                StatTile(label: "Rule time", value: String(format: "%.2fs", totalTime))
                StatTile(label: "Slowest", value: stats.max { $0.seconds < $1.seconds }.map { String(format: "%.2fs", $0.seconds) } ?? "—", detail: stats.max { $0.seconds < $1.seconds }?.title)
                StatTile(label: "Biggest", value: Format.bytes(stats.map(\.bytes).max() ?? 0), detail: stats.max { $0.bytes < $1.bytes }?.title, tint: Theme.accent)
            }
            if stats.isEmpty {
                EmptyPanel(icon: "stopwatch", title: "No timings yet", message: "Run Smart Scan to time every rule.")
            } else {
                Card("Share of scan time") {
                    ForEach(stats.filter { $0.status == .done }.sorted { $0.seconds > $1.seconds }.prefix(12)) { stat in
                        BarRow(label: stat.title, value: stat.seconds, total: totalTime, valueText: String(format: "%.2fs", stat.seconds), tint: stat.category.map(CleanupText.tint) ?? Theme.info) {
                            nav.push(.cleanup(.ruleDetail(stat.ruleID)))
                        }
                    }
                }
                ForEach(stats) { stat in
                    NavRow(
                        icon: stat.status == .skipped ? "forward.end" : (stat.category.map(CleanupText.icon) ?? "list.bullet"),
                        title: stat.title,
                        subtitle: stat.status == .skipped
                            ? "Skipped: \(stat.skipReason ?? "")"
                            : "\(stat.status.rawValue) · \(Format.count(stat.roots)) roots (\(Format.count(stat.rootsMissing)) missing) · \(Format.count(stat.examined)) examined · \(Format.count(stat.skipped)) skipped · \(Format.count(stat.items)) items",
                        value: stat.status == .skipped ? "—" : String(format: "%.2fs · %@", stat.seconds, Format.bytes(stat.bytes)),
                        tint: stat.status == .skipped ? Theme.faint : (stat.category.map(CleanupText.tint) ?? Theme.info),
                        route: .cleanup(.ruleDetail(stat.ruleID))
                    )
                }
            }
        }
    }
}
