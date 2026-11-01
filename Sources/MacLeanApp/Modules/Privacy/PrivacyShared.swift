import AppKit
import MacLeanCore
import SwiftUI

/// Running-browser guard and clean options shown above every artifact action.
struct PrivacyCleanOptions: View {
    @ObservedObject private var store = PrivacyStore.shared
    var browsers: [String]? = nil

    var body: some View {
        let relevant = browsers.map { Set($0) } ?? Set(store.browserNames)
        let running = store.running.intersection(relevant).sorted()
        VStack(alignment: .leading, spacing: 10) {
            if let message = store.blockedMessage {
                ErrorPanel(message: message) { store.blockedMessage = nil }
            }
            if !running.isEmpty {
                Card("Browsers running", trailing: "\(running.count)") {
                    ForEach(running, id: \.self) { name in
                        HStack(spacing: 10) {
                            Circle().fill(Theme.success).frame(width: 7, height: 7)
                            Text(name).font(Type.text(12, weight: .medium)).foregroundStyle(Theme.ink)
                            Text("is open — its files are locked and rewritten while running").font(Type.text(11)).foregroundStyle(Theme.muted)
                            Spacer()
                            Button("Quit \(name)") { store.quit(browser: name) }
                                .buttonStyle(EditorialButtonStyle(kind: .secondary))
                        }
                    }
                }
            }
            HStack(spacing: 18) {
                Toggle("Clean while browsers are running", isOn: $store.forceWhileRunning)
                Toggle("Delete permanently (skip Trash)", isOn: $store.permanent)
            }
            .toggleStyle(.checkbox)
            .font(Type.text(11))
            .foregroundStyle(Theme.muted)
        }
    }
}

struct PrivacyCommandCard: View {
    let output: PrivacyCommandOutput

    var body: some View {
        Card(output.title, trailing: output.status == 0 ? "exit 0 · \(Format.relative(output.date))" : "exit \(output.status)") {
            PrivacyCopyBlock(text: output.command)
            if !output.output.isEmpty {
                Text(output.output)
                    .font(Type.mono(10))
                    .foregroundStyle(output.status == 0 ? Theme.muted : Theme.danger)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(output.status == 0 ? "Completed with no output." : "Failed with no output.")
                    .font(Type.text(11)).foregroundStyle(output.status == 0 ? Theme.success : Theme.danger)
            }
        }
    }
}

struct PrivacyCopyBlock: View {
    let text: String

    var body: some View {
        HStack(alignment: .top) {
            Text(text)
                .font(Type.mono(10))
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                ToastCenter.shared.show("Copied command")
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .help("Copy")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.paper))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
    }
}

enum PrivacySort: String, CaseIterable, Identifiable {
    case size = "Size"
    case name = "Name"
    case date = "Modified"
    var id: String { rawValue }
}

struct PrivacySortPicker: View {
    @Binding var sort: PrivacySort

    var body: some View {
        Picker("Sort", selection: $sort) {
            ForEach(PrivacySort.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .flexibleWidth(220)
        .labelsHidden()
    }
}

/// Selection binding for an artifact path backed by the shared store.
@MainActor
func privacySelection(_ path: String) -> Binding<Bool> {
    Binding(
        get: { PrivacyStore.shared.selected.contains(path) },
        set: { on in
            if on { PrivacyStore.shared.selected.insert(path) } else { PrivacyStore.shared.selected.remove(path) }
        }
    )
}
