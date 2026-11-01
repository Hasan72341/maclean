import AppKit
import MacLeanCore
import SwiftUI

extension Notification.Name {
    /// Posted with `object: [String]` after paths were removed with administrator rights.
    static let macleanAdminRemoved = Notification.Name("MacLeanAdminRemoved")
}

/// When a removal leaves items behind, offers to retry them with
/// administrator rights, and if that still fails, shows each exact path with
/// ways to remove it by hand.
@MainActor
final class RemovalRescue: ObservableObject {
    static let shared = RemovalRescue()

    struct Item: Identifiable, Equatable {
        var id: String { path }
        let path: String
        var reason: String
        var verdict: AdminRemoval.Verdict
        var adminTried = false
        var hint: String? { AdminRemoval.hint(for: reason, path: path) }
    }

    enum Stage: Equatable { case offer, running, done }

    @Published var isPresented = false
    @Published private(set) var module = ""
    @Published private(set) var title = ""
    @Published private(set) var stage: Stage = .offer
    @Published private(set) var items: [Item] = []
    @Published private(set) var removedByAdmin: [String] = []
    @Published private(set) var note: String?

    var elevatable: [Item] { items.filter { $0.verdict == .elevate && !$0.adminTried } }
    var remaining: [Item] { items }
    /// Paths it is reasonable to suggest deleting by hand: never ones MacLean refused.
    var manualPaths: [String] { items.filter { $0.verdict == .elevate }.map(\.path) }

    /// Called for every removal summary; opens the sheet when file paths failed.
    func offer(module: String, title: String, failures: [(path: String, reason: String)]) {
        let home = NSHomeDirectory()
        let fresh = failures.compactMap { failure -> Item? in
            let verdict = AdminRemoval.verdict(path: failure.path, reason: failure.reason, home: home)
            switch verdict {
            case .gone, .notAPath: return nil
            default: return Item(path: failure.path, reason: failure.reason, verdict: verdict)
            }
        }
        guard !fresh.isEmpty else { return }
        if isPresented, stage != .running {
            // Merge into the open sheet instead of replacing it.
            let known = Set(items.map(\.path))
            items += fresh.filter { !known.contains($0.path) }
            stage = elevatable.isEmpty ? .done : .offer
            return
        }
        guard !isPresented else { return }
        self.module = module
        self.title = title
        items = fresh
        removedByAdmin = []
        note = nil
        stage = elevatable.isEmpty ? .done : .offer
        isPresented = true
    }

    func retryAsAdministrator() {
        let targets = elevatable.map(\.path)
        guard !targets.isEmpty, stage != .running else { return }
        stage = .running
        note = nil
        let elevated = ProcessInfo.processInfo.environment["MACLEAN_ADMIN_NO_PROMPT"] == nil && getuid() != 0
        Task {
            let outcome = await engine(priority: .userInitiated) { AdminRemoval.run(targets, elevated: elevated) }
            apply(outcome, targets: targets)
        }
    }

    private func apply(_ outcome: AdminRemoval.Outcome, targets: [String]) {
        if outcome.cancelled {
            note = "The password prompt was cancelled. Nothing was changed."
            stage = .offer
            return
        }
        if let error = outcome.error, outcome.results.isEmpty {
            note = "Administrator removal could not run: \(error)"
            for index in items.indices where targets.contains(items[index].path) { items[index].adminTried = true }
            stage = .done
            return
        }
        let removed = Set(outcome.removed)
        removedByAdmin += outcome.removed
        let messages = Dictionary(outcome.results.map { ($0.path, $0.message) }, uniquingKeysWith: { a, _ in a })
        items = items.compactMap { item in
            guard targets.contains(item.path) else { return item }
            if removed.contains(item.path) { return nil }
            var updated = item
            updated.adminTried = true
            if let message = messages[item.path], !message.isEmpty { updated.reason = "As administrator: \(message)" }
            return updated
        }
        var summary = RemovalSummary()
        summary.removed = outcome.removed.count
        summary.failures = items.filter { targets.contains($0.path) }.map { ($0.path, $0.reason) }
        ActivityLog.shared.add(ActivityEntry(module: module, title: "\(title) (administrator)", items: summary.removed, bytes: 0, failures: summary.failures.count, detail: outcome.results.map { "\($0.ok ? "OK" : "FAIL") \($0.path) — \($0.message)" }.joined(separator: "\n")))
        if !outcome.removed.isEmpty {
            NotificationCenter.default.post(name: .macleanAdminRemoved, object: outcome.removed)
            ToastCenter.shared.show("Moved \(outcome.removed.count) item\(outcome.removed.count == 1 ? "" : "s") to the Trash as administrator")
        }
        stage = items.isEmpty ? .done : (elevatable.isEmpty ? .done : .offer)
        if items.isEmpty { note = "Everything was removed." }
    }

    func dismiss() {
        isPresented = false
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        ToastCenter.shared.show("Copied")
    }
}

// MARK: - Sheet

struct RemovalRescueSheet: View {
    @ObservedObject private var rescue = RemovalRescue.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let note = rescue.note {
                Text(note).font(Type.text(12)).foregroundStyle(rescue.items.isEmpty ? Theme.success : Theme.warning)
            }
            if !rescue.items.isEmpty {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(rescue.items) { item in RescueRow(item: item) }
                    }
                }
                .frame(minHeight: 120, maxHeight: 340)
            }
            if rescue.stage == .done, !rescue.manualPaths.isEmpty {
                manualBox
            }
            footer
        }
        .padding(22)
        .frame(minWidth: 460, idealWidth: 620, maxWidth: 760)
        .background(Theme.paper)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: rescue.items.isEmpty ? "checkmark.circle.fill" : (rescue.stage == .done ? "exclamationmark.triangle.fill" : "lock.shield"))
                .font(.system(size: 26))
                .foregroundStyle(rescue.items.isEmpty ? Theme.success : Theme.warning)
            VStack(alignment: .leading, spacing: 4) {
                Text(headline).font(Type.display(20, weight: .semibold)).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subline).font(Type.text(12)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var headline: String {
        let n = rescue.items.count
        if n == 0 { return "All items removed" }
        switch rescue.stage {
        case .offer: return "\(n) item\(n == 1 ? "" : "s") couldn't be removed"
        case .running: return "Removing as administrator…"
        case .done: return "\(n) item\(n == 1 ? "" : "s") still couldn't be removed"
        }
    }

    private var subline: String {
        switch rescue.stage {
        case .offer:
            let e = rescue.elevatable.count
            return "\(rescue.title). \(e) of them can be retried with administrator rights: macOS will ask for your password, and the items go to your Trash."
        case .running:
            return "Enter your password in the macOS prompt."
        case .done:
            if rescue.items.isEmpty { return "\(rescue.removedByAdmin.count) item(s) were moved to the Trash with administrator rights." }
            return "Here are the exact paths, so you can remove them yourself in Finder or Terminal."
        }
    }

    private var manualBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Terminal").font(Type.mono(10, weight: .semibold)).foregroundStyle(Theme.muted)
                Spacer()
                Button("Copy all paths") { rescue.copy(rescue.items.map(\.path).joined(separator: "\n")) }
                    .buttonStyle(EditorialButtonStyle(kind: .inline))
                Button("Copy commands") { rescue.copy(AdminRemoval.terminalCommands(for: rescue.manualPaths)) }
                    .buttonStyle(EditorialButtonStyle(kind: .inline))
            }
            ScrollView(.horizontal) {
                Text(AdminRemoval.terminalCommands(for: rescue.manualPaths))
                    .font(Type.mono(11)).foregroundStyle(Theme.ink).textSelection(.enabled)
                    .padding(10)
            }
            .frame(maxHeight: 110)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.canvas))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
            Text("Check each path before running these commands: they delete permanently. Items MacLean refused (system files, protected folders) are not included.")
                .font(Type.text(10)).foregroundStyle(Theme.muted)
        }
    }

    private var footer: some View {
        HStack {
            if rescue.stage == .running { ProgressView().controlSize(.small) }
            Spacer()
            switch rescue.stage {
            case .offer:
                Button("Not Now") { rescue.dismiss() }.buttonStyle(EditorialButtonStyle(kind: .secondary))
                Button("Try as Administrator…") { rescue.retryAsAdministrator() }
                    .buttonStyle(EditorialButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
            case .running:
                EmptyView()
            case .done:
                Button("Done") { rescue.dismiss() }.buttonStyle(EditorialButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct RescueRow: View {
    let item: RemovalRescue.Item
    @ObservedObject private var rescue = RemovalRescue.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon).foregroundStyle(tint).frame(width: 16)
                Text(item.path)
                    .font(Type.mono(11)).foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { rescue.copy(item.path) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.plain).foregroundStyle(Theme.muted).help("Copy path")
                Button { EngineActions.reveal(item.path) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.plain).foregroundStyle(Theme.muted).help("Show in Finder")
            }
            Text(status).font(Type.text(11)).foregroundStyle(Theme.muted).padding(.leading, 24)
                .fixedSize(horizontal: false, vertical: true)
            if let hint = item.hint, item.adminTried || item.verdict != .elevate {
                Text(hint).font(Type.text(11)).foregroundStyle(Theme.warning).padding(.leading, 24)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.canvas))
    }

    private var status: String {
        switch item.verdict {
        case .elevate: return item.adminTried ? item.reason : "\(item.reason) · can retry as administrator"
        case .refused(let why): return "\(item.reason) · not retried: \(why)"
        default: return item.reason
        }
    }

    private var icon: String {
        if item.verdict != .elevate { return "hand.raised" }
        return item.adminTried ? "xmark.octagon" : "lock"
    }

    private var tint: Color {
        item.adminTried || item.verdict != .elevate ? Theme.danger : Theme.warning
    }
}
