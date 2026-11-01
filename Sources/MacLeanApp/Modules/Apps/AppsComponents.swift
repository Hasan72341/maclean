import AppKit
import MacLeanCore
import SwiftUI

struct AppsIcon: View {
    let path: String
    var size: CGFloat = 28
    @ObservedObject private var store = AppsStore.shared

    var body: some View {
        Image(nsImage: store.icon(path))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

/// App row with icon; optional checkbox for multi-select lists.
struct AppsAppRow: View {
    let app: AppsApp
    var trailing: String? = nil
    var isOn: Binding<Bool>? = nil
    var badge: String? = nil
    var badgeTint: Color = Theme.info
    @EnvironmentObject private var nav: Navigator
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            if let isOn {
                Button { isOn.wrappedValue.toggle() } label: {
                    Image(systemName: isOn.wrappedValue ? "checkmark.square.fill" : "square")
                        .font(.system(size: 15))
                        .foregroundStyle(isOn.wrappedValue ? Theme.accent : Theme.faint)
                }
                .buttonStyle(.plain)
            }
            AppsIcon(path: app.path, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(app.name).font(Type.text(13, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                    if let version = app.version {
                        Text(version).font(Type.mono(10)).foregroundStyle(Theme.faint).lineLimit(1)
                    }
                    if let badge { RiskBadge(text: badge, tint: badgeTint) }
                }
                Text(app.bundleID ?? Format.abbreviated(app.path))
                    .font(Type.mono(10)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Format.bytes(app.bytes)).font(Type.mono(12, weight: .semibold)).foregroundStyle(Theme.ink).monospacedDigit()
                Text(trailing ?? "Used \(Format.relative(app.lastUsed))")
                    .font(Type.text(10)).foregroundStyle(Theme.faint).lineLimit(1)
            }
            if hovering {
                Button { EngineActions.reveal(app.path) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.plain).foregroundStyle(Theme.muted).help("Reveal in Finder")
            }
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Theme.line.opacity(0.4) : Theme.canvas))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { nav.push(.apps(.appDetail(app.path))) }
    }
}

/// Shows the right panel for a LoadState when no data has arrived yet.
struct AppsStateGate<Content: View>: View {
    let state: LoadState
    let isEmpty: Bool
    var emptyIcon: String = "checkmark.circle"
    var emptyTitle: String = "Nothing found"
    var emptyMessage: String? = nil
    let retry: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        switch state {
        case .idle:
            LoadingPanel(text: "Preparing…")
        case .loading(let text) where isEmpty:
            LoadingPanel(text: text)
        case .failed(let message) where isEmpty:
            ErrorPanel(message: message, retry: retry)
        default:
            if isEmpty {
                EmptyPanel(icon: emptyIcon, title: emptyTitle, message: emptyMessage)
            } else {
                content()
            }
        }
    }
}

struct AppsCopyBox: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title.uppercased()).font(Type.label).tracking(1).foregroundStyle(Theme.muted)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    ToastCenter.shared.show("Copied to clipboard")
                }
                .buttonStyle(EditorialButtonStyle(kind: .inline))
            }
            ScrollView(.horizontal) {
                Text(text)
                    .font(Type.mono(11))
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.paper))
        }
    }
}

/// Failed root-owned paths: run with the admin prompt, or copy the sudo commands.
struct AppsAdminPanel: View {
    let paths: [String]
    var outcomeKey: String? = nil
    @ObservedObject private var store = AppsStore.shared
    @State private var busy = false

    var body: some View {
        let eligible = paths.filter(AppsAdmin.isEligible)
        if !eligible.isEmpty {
            Card("Needs administrator rights", trailing: "\(eligible.count) item\(eligible.count == 1 ? "" : "s")") {
                Text("These items are owned by root. MacLean can move them to your Trash after the macOS password prompt, or you can run the commands yourself in Terminal.")
                    .font(Type.text(12)).foregroundStyle(Theme.muted)
                ForEach(eligible, id: \.self) { path in
                    HStack {
                        Image(systemName: "lock").foregroundStyle(Theme.warning)
                        Text(path).font(Type.mono(10)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { EngineActions.reveal(path) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.plain)
                    }
                }
                HStack {
                    ConfirmButton(
                        title: "Move to Trash as Administrator",
                        message: "macOS will ask for your password. \(eligible.count) root-owned item(s) will be moved to your Trash.",
                        kind: .destructive,
                        disabled: busy
                    ) {
                        busy = true
                        Task {
                            await store.adminRemove(eligible, outcomeKey: outcomeKey)
                            busy = false
                        }
                    }
                    if busy { ProgressView().controlSize(.small) }
                }
                AppsCopyBox(title: "Terminal commands", text: AppsAdmin.sudoText(for: eligible))
                if let output = store.lastAdminOutput {
                    AppsCopyBox(title: "Last administrator output", text: output)
                }
            }
        }
    }
}

struct AppsArtifactRow: View {
    let artifact: Artifact
    @Binding var isOn: Bool

    var body: some View {
        CheckRow(
            isOn: $isOn,
            title: Format.abbreviated(artifact.path),
            subtitle: "\(artifact.group) · \(Format.count(artifact.files)) file\(artifact.files == 1 ? "" : "s") · modified \(Format.relative(artifact.modified))",
            value: Format.bytes(artifact.bytes),
            badge: AppsAdmin.isEligible(artifact.path) ? "root" : (artifact.autoselect ? nil : "review"),
            badgeTint: AppsAdmin.isEligible(artifact.path) ? Theme.danger : Theme.warning,
            onReveal: { EngineActions.reveal(artifact.path) }
        )
    }
}

enum AppsPalette {
    static let colors: [Color] = [Theme.accent, Theme.info, Theme.success, Theme.warning, Theme.danger, Theme.muted]
    static func color(_ index: Int) -> Color { colors[index % colors.count] }
}
