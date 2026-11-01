import AppKit
import MacLeanCore
import SwiftUI

// MARK: - Item detail

struct CleanupItemDetailScreen: View {
    let path: String
    @ObservedObject private var store = CleanupStore.shared
    @EnvironmentObject private var nav: Navigator
    @State private var measured: SizeInfo?
    @State private var childQuery = ""

    var body: some View {
        let item = store.item(at: path)
        ScreenScaffold(CleanupText.name(path), subtitle: Format.abbreviated(path)) {
            HStack(spacing: 8) {
                Button("Reveal") { EngineActions.reveal(path) }.buttonStyle(EditorialButtonStyle(kind: .secondary))
                if let item {
                    if store.cleaning { ProgressView().controlSize(.small) }
                    ConfirmButton(
                        title: store.settings.permanent ? "Delete" : "Clean",
                        message: "\(Format.abbreviated(path)) (\(Format.bytes(item.bytes))). " + store.confirmMessage,
                        disabled: store.cleaning
                    ) {
                        Task {
                            await store.clean([item], title: "Clean \(CleanupText.name(path))")
                            nav.pop()
                            nav.push(.cleanup(.cleanResult))
                        }
                    }
                }
            }
        } content: {
            if let item {
                content(item)
            } else {
                Card("Not in the last scan") {
                    Text("This path is not part of the current scan results, so it cannot be cleaned from here.").font(Type.text(12)).foregroundStyle(Theme.muted)
                    if let measured {
                        KeyValueRow(key: "Size", value: Format.bytes(measured.bytes))
                        KeyValueRow(key: "Files", value: Format.count(measured.files))
                        KeyValueRow(key: "Modified", value: Format.date(measured.modified))
                    }
                }
                .task {
                    let target = path
                    measured = await engine { FileSizer.measure(URL(fileURLWithPath: target)) }
                }
            }
        }
    }

    @ViewBuilder
    private func content(_ item: JunkItem) -> some View {
        let rule = Rules.rule(id: item.ruleID)
        TileGrid {
            StatTile(label: "Size", value: Format.bytes(item.bytes), tint: CleanupText.tint(item.category), icon: item.isDirectory ? "folder" : "doc")
            StatTile(label: "Files", value: Format.count(item.files))
            StatTile(label: "Modified", value: Format.relative(item.modified), detail: Format.date(item.modified))
            StatTile(label: "Risk", value: item.risk == .safe ? "Safe" : "Review", tint: item.risk == .safe ? Theme.success : Theme.warning)
            StatTile(label: "Share", value: Format.percent(Double(item.bytes) / Double(max(store.totalBytes, 1)), digits: 1), detail: "of all junk found")
        }
        if item.risk == .caution {
            Card {
                Label(CleanupText.cautionReason(item.ruleID), systemImage: "exclamationmark.triangle").font(Type.text(12)).foregroundStyle(Theme.warning)
            }
        }
        Card("Details") {
            KeyValueRow(key: "Path", value: item.path, mono: true)
            KeyValueRow(key: "Rule", value: "\(item.ruleTitle) (\(item.ruleID))")
            KeyValueRow(key: "Category", value: item.category.title)
            KeyValueRow(key: "Kind", value: item.isDirectory ? "Folder" : "File")
            KeyValueRow(key: "Auto-selected", value: store.isRecommended(item) ? "Yes" : "No")
            KeyValueRow(key: "Requires administrator", value: item.requiresRoot ? "Yes" : "No")
            KeyValueRow(key: "Device", value: item.device.map { String($0) } ?? "—", mono: true)
            KeyValueRow(key: "Inode", value: item.inode.map { String($0) } ?? "—", mono: true)
            KeyValueRow(key: "Selected", value: store.selection.contains(item.path) ? "Yes" : "No")
            HStack(spacing: 8) {
                Toggle("Include in selection", isOn: store.binding(item.path)).toggleStyle(EditorialToggleStyle())
                Spacer()
                Button("Copy path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.path, forType: .string)
                }
                .buttonStyle(EditorialButtonStyle(kind: .inline))
                if !item.isDirectory {
                    Button("Open") { EngineActions.open(item.path) }.buttonStyle(EditorialButtonStyle(kind: .inline))
                }
            }
        }
        if let rule {
            NavRow(icon: "books.vertical", title: "Rule: \(rule.title)", subtitle: CleanupText.location(rule), value: Format.bytes(store.bytes(store.items(rule: rule.id))), route: .cleanup(.ruleDetail(rule.id)))
            NavRow(icon: "list.bullet", title: "Other items of this rule", subtitle: "\(Format.count(store.items(rule: rule.id).count)) items", route: .cleanup(.ruleGroup(rule.id)))
        }
        if let parent = store.parentItem(of: item.path) {
            NavRow(icon: "arrow.up.folder", title: "Parent: \(CleanupText.name(parent.path))", subtitle: Format.abbreviated(parent.path), value: Format.bytes(parent.bytes), route: .cleanup(.itemDetail(parent.path)))
        }
        if item.isDirectory {
            childrenCard(item)
        }
    }

    @ViewBuilder
    private func childrenCard(_ item: JunkItem) -> some View {
        let state = store.childState[item.path] ?? .idle
        let kids = store.children[item.path] ?? []
        let shown = childQuery.isEmpty ? kids : kids.filter { $0.name.localizedCaseInsensitiveContains(childQuery) }
        Card("Contents", trailing: kids.isEmpty ? nil : "\(Format.count(kids.count)) entries") {
            HStack {
                SearchField(text: $childQuery, prompt: "Filter contents")
                Spacer()
                RefreshLine(state: state) { Task { await store.loadChildren(item.path, force: true) } }
            }
            if state.isLoading && kids.isEmpty {
                LoadingPanel(text: "Measuring contents", detail: Format.abbreviated(item.path))
            } else if kids.isEmpty {
                Text(state.loadedAt == nil ? "Not measured yet." : "Empty folder.").font(Type.text(12)).foregroundStyle(Theme.muted)
            } else {
                let peak = Double(kids.first?.bytes ?? 1)
                ForEach(shown.prefix(60)) { child in
                    HStack(spacing: 8) {
                        Image(systemName: child.isDirectory ? "folder" : "doc").foregroundStyle(Theme.muted).frame(width: 16)
                        BarRow(label: "\(child.name) · \(Format.count(child.files)) files", value: Double(child.bytes), total: peak, valueText: Format.bytes(child.bytes), tint: CleanupText.tint(item.category)) {
                            nav.push(.cleanup(.itemDetail(child.path)))
                        }
                        Button { EngineActions.reveal(child.path) } label: { Image(systemName: "magnifyingglass") }
                            .buttonStyle(.plain).foregroundStyle(Theme.faint)
                    }
                }
                if shown.count > 60 {
                    Text("\(Format.count(shown.count - 60)) smaller entries not shown").font(Type.text(11)).foregroundStyle(Theme.faint)
                }
            }
        }
        .task { await store.loadChildren(item.path) }
    }
}

// MARK: - Clean result

struct CleanupResultScreen: View {
    @ObservedObject private var store = CleanupStore.shared
    @EnvironmentObject private var nav: Navigator

    var body: some View {
        ScreenScaffold("Cleanup Result", subtitle: store.lastClean.map { "\($0.title) · \(Format.date($0.date))" }) {
            Button("Rescan") { store.scan(); nav.popToRoot() }.buttonStyle(EditorialButtonStyle(kind: .secondary))
        } content: {
            if store.cleaning {
                LoadingPanel(text: "Cleaning", detail: "The engine validates every path before removing it")
            } else if let run = store.lastClean {
                TileGrid {
                    StatTile(label: "Freed", value: Format.bytes(run.bytes), tint: Theme.success, icon: "checkmark.circle")
                    StatTile(label: "Removed", value: Format.count(run.removed.isEmpty ? run.tallies.reduce(0) { $0 + $1.count } : run.removed.count), detail: "of \(Format.count(run.requested)) requested")
                    StatTile(label: "Failed / skipped", value: Format.count(run.failures.count), tint: run.failures.isEmpty ? Theme.ink : Theme.danger)
                    StatTile(label: "Mode", value: run.permanent ? "Deleted" : "Trash", detail: run.permanent ? "not recoverable" : "recoverable from Trash")
                    StatTile(label: "Disk free now", value: Format.bytes(SystemMonitor.shared.latest.disk.available), tint: Theme.info)
                }
                if !run.tallies.isEmpty {
                    Card("Freed by category") {
                        let peak = Double(run.tallies.map(\.bytes).max() ?? 1)
                        ForEach(run.tallies) { tally in
                            BarRow(label: "\(tally.category.title) (\(Format.count(tally.count)))", value: Double(tally.bytes), total: peak, valueText: Format.bytes(tally.bytes), tint: CleanupText.tint(tally.category))
                        }
                    }
                }
                FailureList(failures: run.failures)
                if !run.removed.isEmpty {
                    Card("Removed items", trailing: "\(Format.count(run.removed.count))") {
                        ForEach(run.removed.sorted { $0.bytes > $1.bytes }.prefix(100), id: \.path) { item in
                            HStack {
                                Text(Format.abbreviated(item.path)).font(Type.mono(10)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(Format.bytes(item.bytes)).font(Type.mono(11, weight: .semibold)).monospacedDigit()
                            }
                        }
                    }
                }
                HStack(spacing: 8) {
                    if !run.permanent {
                        Button("Open Trash bins") { nav.push(.cleanup(.trash)) }.buttonStyle(EditorialButtonStyle(kind: .secondary))
                    }
                    Button("Cleanup history") { nav.push(.cleanup(.cleanupHistory)) }.buttonStyle(EditorialButtonStyle(kind: .ghost))
                    Button("Back to Smart Scan") { nav.popToRoot() }.buttonStyle(EditorialButtonStyle(kind: .ghost))
                }
            } else {
                EmptyPanel(icon: "archivebox", title: "No cleanup yet", message: "Results of the last clean in this session appear here.")
            }
        }
    }
}

// MARK: - Administrator items

struct CleanupRootScreen: View {
    @ObservedObject private var store = CleanupStore.shared
    @EnvironmentObject private var nav: Navigator

    var body: some View {
        let cliPath = CLI.locate()?.path ?? "maclean"
        ScreenScaffold("Administrator Items", subtitle: "Shared system locations the engine only cleans as root") {
            RefreshLine(state: store.rootState) { Task { await store.loadRootEstimates() } }
        } content: {
            let readable = store.rootEstimates.filter(\.readable)
            TileGrid {
                StatTile(label: "Rules", value: Format.count(store.rootRules.count), tint: Theme.danger, icon: "lock.shield")
                StatTile(label: "Measured", value: Format.bytes(readable.reduce(0) { $0 + $1.bytes }), detail: "readable without root")
                StatTile(label: "Files", value: Format.count(readable.reduce(0) { $0 + $1.files }))
                StatTile(label: "Unreadable", value: Format.count(store.rootEstimates.count - readable.count), detail: "locations", tint: Theme.warning)
                StatTile(label: "CLI", value: CLI.locate() == nil ? "Missing" : "Found", detail: Format.abbreviated(cliPath), tint: CLI.locate() == nil ? Theme.danger : Theme.success)
            }
            if store.rootState.isLoading && store.rootEstimates.isEmpty {
                LoadingPanel(text: "Measuring protected locations", detail: "Read-only")
            }
            ForEach(store.rootRules) { rule in
                let rows = store.rootEstimates.filter { $0.ruleID == rule.id }
                Card(rule.title, trailing: rows.isEmpty ? nil : Format.bytes(rows.reduce(0) { $0 + $1.bytes })) {
                    Text(CleanupText.cautionReason(rule.id)).font(Type.text(11)).foregroundStyle(Theme.warning)
                    ForEach(rows) { row in
                        KeyValueRow(key: row.root, value: row.readable ? "\(Format.count(row.entries)) entries · \(Format.count(row.files)) files · \(Format.bytes(row.bytes))" : "not readable without root", mono: true)
                    }
                    NavRow(icon: "info.circle", title: "Rule details", subtitle: CleanupText.location(rule), route: .cleanup(.ruleDetail(rule.id)))
                }
            }
            Card("Run as administrator") {
                Text("These rules are skipped by in-app scans. The command below runs the engine as root for the \(store.rootCategories.map(\.title).joined(separator: " and ")) categories. As root, home-relative rules apply to the root account (/var/root), and caution items in those categories are included. Run the dry run first and read the plan.")
                    .font(Type.text(11)).foregroundStyle(Theme.muted)
                commandRow("Dry run", "sudo " + store.rootCommand(cliPath: cliPath, apply: false))
                commandRow("Apply", "sudo " + store.rootCommand(cliPath: cliPath, apply: true))
                HStack(spacing: 8) {
                    Button("Dry Run with Password…") { Task { await store.runAdmin(apply: false) } }
                        .buttonStyle(EditorialButtonStyle(kind: .secondary))
                        .disabled(store.adminRunning)
                    ConfirmButton(title: "Clean as Administrator…", message: "macOS will ask for your password, then the engine cleans the protected locations as root. " + (store.settings.permanent ? "Permanent delete is ON." : "Items move to root's Trash."), kind: .destructive, disabled: store.adminRunning) {
                        Task { await store.runAdmin(apply: true) }
                    }
                    if store.adminRunning { ProgressView().controlSize(.small) }
                }
            }
            if let output = store.adminOutput {
                Card("Command output", trailing: store.adminStatus.map { "exit \($0)" }) {
                    ScrollView(.horizontal) {
                        Text(output).font(Type.mono(10)).foregroundStyle(store.adminStatus == 0 ? Theme.ink : Theme.danger).textSelection(.enabled)
                    }
                    .frame(maxHeight: 320)
                }
            }
        }
        .task { if store.rootState.loadedAt == nil { await store.loadRootEstimates() } }
    }

    private func commandRow(_ label: String, _ command: String) -> some View {
        HStack(spacing: 8) {
            Text(label.uppercased()).font(Type.label).foregroundStyle(Theme.muted).frame(width: 60, alignment: .leading)
            Text(command).font(Type.mono(10)).foregroundStyle(Theme.ink).textSelection(.enabled).lineLimit(2)
            Spacer()
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                ToastCenter.shared.show("Command copied")
            }
            .buttonStyle(EditorialButtonStyle(kind: .inline))
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.paper))
    }
}

// MARK: - Trash bins

struct CleanupTrashScreen: View {
    @ObservedObject private var store = CleanupStore.shared
    @EnvironmentObject private var nav: Navigator

    private struct Bin: Identifiable {
        let id: String
        let title: String
        let items: [JunkItem]
        var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    }

    private var bins: [Bin] {
        let groups = Dictionary(grouping: store.trashItems) { item -> String in
            if CleanupText.isUserTrash(item.path) { return "~/.Trash" }
            let parts = item.path.split(separator: "/")
            return parts.count > 2 ? "/Volumes/\(parts[1])" : item.path
        }
        return groups.map { key, list in
            Bin(id: key, title: key == "~/.Trash" ? "Your Trash" : "Trash on \(key.replacingOccurrences(of: "/Volumes/", with: ""))", items: list)
        }
        .sorted { $0.bytes > $1.bytes }
    }

    var body: some View {
        let userBytes = store.trashItems.filter { CleanupText.isUserTrash($0.path) }.reduce(0) { $0 + $1.bytes }
        ScreenScaffold("Trash Bins", subtitle: "Your Trash and Trash folders on mounted local volumes") {
            HStack(spacing: 8) {
                RefreshLine(state: store.trashState) { Task { await store.loadTrash() } }
                ConfirmButton(title: "Empty Trash", message: "Permanently delete everything in your Trash (\(Format.bytes(userBytes))). This cannot be undone.", kind: .destructive, disabled: store.cleaning || userBytes == 0) {
                    Task {
                        await store.emptyUserTrash()
                        nav.push(.cleanup(.cleanResult))
                    }
                }
            }
        } content: {
            TileGrid {
                StatTile(label: "In Trash", value: Format.bytes(store.bytes(store.trashItems)), tint: Theme.danger, icon: "trash")
                StatTile(label: "Items", value: Format.count(store.trashItems.count))
                StatTile(label: "Files", value: Format.count(store.files(store.trashItems)))
                StatTile(label: "Bins", value: Format.count(bins.count))
                StatTile(label: "Oldest", value: Format.relative(store.trashItems.compactMap(\.modified).min()))
            }
            if store.trashState.isLoading && store.trashItems.isEmpty {
                LoadingPanel(text: "Measuring Trash bins")
            } else if store.trashItems.isEmpty {
                EmptyPanel(icon: "trash", title: "Trash is empty", message: store.trashState.loadedAt == nil ? nil : "Nothing in any Trash bin.")
            } else {
                Card("Bins") {
                    let peak = Double(bins.first?.bytes ?? 1)
                    ForEach(bins) { bin in
                        BarRow(label: "\(bin.title) · \(Format.count(bin.items.count)) items", value: Double(bin.bytes), total: peak, valueText: Format.bytes(bin.bytes), tint: Theme.danger)
                    }
                }
                Text("Removing items that are already in a Trash deletes them permanently.").font(Type.text(11)).foregroundStyle(Theme.warning)
                CleanupItemList(items: store.trashItems, actionTitle: "Delete Selected", activityTitle: "Delete from Trash")
            }
        }
        .task { if store.trashState.loadedAt == nil { await store.loadTrash() } }
    }
}
