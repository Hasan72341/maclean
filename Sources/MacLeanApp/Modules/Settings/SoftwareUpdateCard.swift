import SwiftUI

/// Settings › About: check for, download and install MacLean updates.
struct SoftwareUpdateCard: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Card("Software update", trailing: "github.com/\(Updater.repo)") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: updater.updateAvailable ? "arrow.down.circle.fill" : "checkmark.seal")
                        .font(.system(size: 22)).foregroundStyle(updater.updateAvailable ? Theme.accent : Theme.success)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(headline).font(Type.text(13, weight: .semibold)).foregroundStyle(Theme.ink)
                        Text(detail).font(Type.text(11)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    if updater.updateAvailable {
                        Button("Update Now") { updater.install() }
                            .buttonStyle(EditorialButtonStyle(kind: .primary)).disabled(updater.phase.busy)
                    }
                    Button("Check Now") { Task { await updater.check(userInitiated: true) } }
                        .buttonStyle(EditorialButtonStyle(kind: .secondary)).disabled(updater.phase.busy)
                }
                if case .downloading(let received, let total, let rate) = updater.phase {
                    UpdateProgressBar(received: received, total: total, rate: rate)
                }
                if case .failed(let message) = updater.phase {
                    Text(message).font(Type.text(11)).foregroundStyle(Theme.danger)
                }
                HStack {
                    Text("Check automatically (at launch and every 6 hours)").font(Type.text(12)).foregroundStyle(Theme.ink)
                    Spacer()
                    Toggle("", isOn: $updater.autoCheck).toggleStyle(.switch).labelsHidden().tint(Theme.accent)
                }
            }
        }
    }

    private var headline: String {
        switch updater.phase {
        case .checking: return "Checking for updates…"
        case .downloading: return "Downloading MacLean \(updater.release?.version ?? "")…"
        case .verifying: return "Verifying the download…"
        case .installing: return "Installing — MacLean will reopen"
        default:
            if updater.updateAvailable { return "MacLean \(updater.release?.version ?? "") is available" }
            return "MacLean \(Updater.currentVersion) is up to date"
        }
    }

    private var detail: String {
        if let checked = updater.lastChecked { return "You have \(Updater.currentVersion) · last checked \(Format.relative(checked))" }
        return "You have \(Updater.currentVersion)"
    }
}
