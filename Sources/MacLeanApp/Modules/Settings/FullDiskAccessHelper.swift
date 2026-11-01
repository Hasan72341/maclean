import AppKit
import SwiftUI

/// Guides the user through adding MacLean to Full Disk Access.
///
/// macOS lists only apps it has already registered, and an app cannot add
/// itself, so MacLean usually is not in the list. The reliable way in is to
/// drag the app into the list (or use the + button), which this card makes a
/// one-step drag, then it re-checks access automatically until it works.
struct FullDiskAccessHelper: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var watching = false
    @State private var watchTask: Task<Void, Never>?
    @Environment(\.isCompactWidth) private var compact

    static var appURL: URL { Bundle.main.bundleURL }
    static var agentURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/maclean-monitor") }

    var body: some View {
        let granted = store.fullDiskAccessGranted == true
        Card(granted ? "Full Disk Access is on" : "Add MacLean to Full Disk Access",
             trailing: granted ? "granted" : (watching ? "watching for the change…" : nil)) {
            if granted {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 22)).foregroundStyle(Theme.success)
                    Text("MacLean can read protected locations. Scans cover Mail, Safari, Messages data and other apps' containers.")
                        .font(Type.text(12)).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                }
                agentNote
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    Text("MacLean isn't in the list yet: macOS only shows apps it already knows, and apps can't add themselves. Drag MacLean in:")
                        .font(Type.text(12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    AdaptiveStack(threshold: 700, spacing: 18) {
                        steps
                        VStack(alignment: .leading, spacing: 10) {
                            DragTile(url: Self.appURL, title: "MacLean", detail: "Drag into the list", icon: NSApp.applicationIconImage)
                            if FileManager.default.fileExists(atPath: Self.agentURL.path) {
                                DragTile(url: Self.agentURL, title: "maclean-monitor", detail: "Optional · realtime protection",
                                         icon: NSWorkspace.shared.icon(forFile: Self.agentURL.path))
                            }
                        }
                        .fixedSize()
                    }
                    HStack(spacing: 10) {
                        Button("Open Full Disk Access") { openSettings() }
                            .buttonStyle(EditorialButtonStyle(kind: .primary))
                        Button("Re-check") { Task { await store.checkAccess() } }
                            .buttonStyle(EditorialButtonStyle(kind: .secondary))
                        Button("Show MacLean in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Self.appURL]) }
                            .buttonStyle(EditorialButtonStyle(kind: .inline))
                        if watching { ProgressView().controlSize(.small) }
                    }
                    Text("Already in the list but not working? MacLean is signed on this Mac, so after an update macOS may treat it as a new app: select MacLean, press −, then drag it in again.")
                        .font(Type.text(11)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onDisappear { watchTask?.cancel(); watching = false }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 8) {
            step(1, "Press **Open Full Disk Access**. System Settings opens on the right page.")
            step(2, "Drag the **MacLean** tile into the list (or press **+**, choose MacLean in Applications, then Open).")
            step(3, "Make sure its switch is **on**. macOS may ask for your password.")
            step(4, "Come back here: MacLean checks again by itself. If macOS offers **Quit & Reopen**, accept it.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(Type.mono(11, weight: .bold)).foregroundStyle(Color.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Theme.accent))
            Text(text).font(Type.text(12)).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var agentNote: some View {
        Text("For realtime protection of protected folders, also add maclean-monitor (inside MacLean.app › Contents › MacOS).")
            .font(Type.text(11)).foregroundStyle(Theme.muted).padding(.top, 6)
    }

    private func openSettings() {
        // Touch protected data first: on recent macOS this can make MacLean
        // appear in the list on its own (switched off).
        let home = NSHomeDirectory()
        for path in ["\(home)/Library/Safari/Bookmarks.plist", "\(home)/Library/Mail", "/Library/Application Support/com.apple.TCC/TCC.db"] {
            _ = FileManager.default.isReadableFile(atPath: path)
            _ = try? FileManager.default.contentsOfDirectory(atPath: path)
            _ = FileHandle(forReadingAtPath: path)
        }
        if let url = URL(string: SettingsFullDiskAccessScreen.settingsURL) { NSWorkspace.shared.open(url) }
        startWatching()
    }

    /// Re-checks every 2 s for up to 5 minutes, stopping once access works.
    private func startWatching() {
        watchTask?.cancel()
        watching = true
        watchTask = Task { @MainActor in
            for _ in 0..<150 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { return }
                await store.checkAccess()
                if store.fullDiskAccessGranted == true {
                    ToastCenter.shared.show("Full Disk Access granted")
                    break
                }
            }
            watching = false
        }
    }
}

/// A tile that drags the file at `url` (System Settings accepts dropped apps).
private struct DragTile: View {
    let url: URL
    let title: String
    let detail: String
    let icon: NSImage
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: icon).resizable().frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Type.text(13, weight: .semibold)).foregroundStyle(Theme.ink)
                Text(detail).font(Type.text(11)).foregroundStyle(Theme.muted)
            }
            Image(systemName: "hand.draw").foregroundStyle(Theme.accent).padding(.leading, 6)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10).fill(hovering ? Theme.accent.opacity(0.12) : Theme.canvas))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.accent.opacity(0.7), style: StrokeStyle(lineWidth: 1.2, dash: [5, 3])))
        .onHover { hovering = $0; if $0 { NSCursor.openHand.push() } else { NSCursor.pop() } }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .help("Drag \(title) into the Full Disk Access list in System Settings")
    }
}
