import AppKit
import MacLeanCore
import ServiceManagement
import SwiftUI

/// Preferences for the menu bar extra.
@MainActor
final class MenuBarSettings: ObservableObject {
    static let shared = MenuBarSettings()

    @Published var showInMenuBar: Bool {
        didSet { UserDefaults.standard.set(showInMenuBar, forKey: "menubar.show") }
    }
    @Published var labelStyle: LabelStyle {
        didSet { UserDefaults.standard.set(labelStyle.rawValue, forKey: "menubar.label") }
    }
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var loginError: String?

    enum LabelStyle: String, CaseIterable, Identifiable {
        case icon = "Icon"
        case cpu = "CPU %"
        case memory = "Memory %"
        case free = "Free space"
        var id: String { rawValue }
    }

    init() {
        showInMenuBar = UserDefaults.standard.object(forKey: "menubar.show") as? Bool ?? true
        labelStyle = LabelStyle(rawValue: UserDefaults.standard.string(forKey: "menubar.label") ?? "") ?? .cpu
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if SMAppService.mainApp.status == .requiresApproval {
            loginError = "Approve MacLean in System Settings › General › Login Items."
        }
    }
}

/// MacLean's menu bar mark: a serif "m" with the logo's dot, drawn as a
/// template image so macOS tints it for light, dark and highlighted bars.
enum MenuBarIcon {
    static let image: NSImage = {
        let size = NSSize(width: 17, height: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            let font = NSFont(name: "Georgia-Bold", size: 15) ?? .boldSystemFont(ofSize: 15)
            let m = NSAttributedString(string: "m", attributes: [.font: font, .foregroundColor: NSColor.black])
            let bounds = m.size()
            m.draw(at: NSPoint(x: 0, y: (size.height - bounds.height) / 2 + 0.5))
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.width + 0.6, y: 3, width: 3, height: 3)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "MacLean"
        return image
    }()
}

/// Text shown next to the menu bar icon.
struct MenuBarLabel: View {
    @ObservedObject var monitor = SystemMonitor.shared
    @ObservedObject var settings = MenuBarSettings.shared
    @ObservedObject var protection = ProtectionStore.shared.monitor

    var body: some View {
        let s = monitor.latest
        HStack(spacing: 3) {
            if (protection.status?.alertCount ?? 0) > 0 {
                Image(systemName: "exclamationmark.shield.fill")
            } else {
                Image(nsImage: MenuBarIcon.image)
            }
            switch settings.labelStyle {
            case .icon: EmptyView()
            case .cpu: Text("\(Int((s.cpu.total * 100).rounded()))%").monospacedDigit()
            case .memory: Text("\(Int((s.memory.usedFraction * 100).rounded()))%").monospacedDigit()
            case .free: Text(Format.bytes(s.disk.availableImportant > 0 ? s.disk.availableImportant : s.disk.available))
            }
        }
    }
}

/// The popover shown from the menu bar.
struct MenuBarPanel: View {
    @ObservedObject private var monitor = SystemMonitor.shared
    @ObservedObject private var cleanup = CleanupStore.shared
    @ObservedObject private var store = MonitorStore.shared
    @ObservedObject private var protection = ProtectionStore.shared.monitor
    @ObservedObject private var settings = MenuBarSettings.shared
    @Environment(\.openWindow) private var openWindow
    @State private var showSettings = false
    @State private var busy: String?
    @State private var note: String?

    var body: some View {
        let s = monitor.latest
        VStack(alignment: .leading, spacing: 10) {
            header(s)
            protectionCard
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                tile("CPU", value: percent(s.cpu.total), detail: "load \(String(format: "%.2f", s.loadAverage.first ?? 0))",
                     tint: tint(s.cpu.total), history: monitor.cpuHistory, max: 1) { open(.dashboard, .monitor(.topCPU)) }
                tile("Memory", value: Format.bytes(s.memory.used), detail: "\(s.memory.pressureTitle) · of \(Format.bytes(s.memory.total))",
                     tint: tint(s.memory.usedFraction), history: monitor.memoryHistory, max: 1) { open(.dashboard, .monitor(.memoryOverview)) }
                tile("Disk free", value: Format.bytes(free(s)), detail: "\(percent(s.disk.usedFraction)) used of \(Format.bytes(s.disk.total))",
                     tint: tint(s.disk.usedFraction), history: monitor.diskWriteHistory, max: nil) { open(.space, nil) }
                tile("Network", value: "↓ \(Format.rate(s.network.rxPerSec))", detail: "↑ \(Format.rate(s.network.txPerSec))",
                     tint: Theme.info, history: monitor.netRxHistory, max: nil) { open(.dashboard, .monitor(.networkOverview)) }
            }
            if let battery = s.battery { batteryRow(battery) }
            actions(s)
            topApps
            if let note {
                Text(note).font(Type.text(11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            if showSettings { settingsCard }
            footer
        }
        .padding(14)
        .frame(width: 360)
        .background(Theme.paper)
        .task {
            // Keep protection status fresh while the panel is open.
            while !Task.isCancelled {
                protection.connect()
                protection.refresh()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        .onAppear {
            monitor.start()
            Task { await store.loadTrash(force: true) }
        }
    }

    // MARK: Sections

    private func header(_ s: MetricsSnapshot) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                Text("maclean").font(.custom("Georgia", size: 20)).foregroundStyle(Theme.ink)
                Text(".").font(.custom("Georgia", size: 20)).foregroundStyle(Theme.accent)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text("\(s.healthScore)").font(Type.mono(16, weight: .semibold)).foregroundStyle(health(s.healthScore))
                Text("HEALTH").font(Type.mono(8)).tracking(0.8).foregroundStyle(Theme.faint)
            }
            .help("System health from CPU, memory pressure, disk space, thermal state and swap")
            .onTapGesture { open(.dashboard, .monitor(.healthScore)) }
        }
    }

    private var protectionCard: some View {
        let status = protection.status
        let running = status?.running == true
        let connecting = status == nil && protection.agentInstalled
        let alerts = status?.alertCount ?? protection.alerts.count
        return HStack(spacing: 10) {
            Image(systemName: alerts > 0 ? "exclamationmark.shield.fill" : (running ? "checkmark.shield.fill" : (connecting ? "shield" : "shield.slash")))
                .font(.system(size: 20))
                .foregroundStyle(alerts > 0 ? Theme.danger : (running ? Theme.success : (connecting ? Theme.muted : Theme.warning)))
            VStack(alignment: .leading, spacing: 2) {
                Text(alerts > 0 ? "\(alerts) threat alert\(alerts == 1 ? "" : "s")" : (running ? "Real-time protection on" : (connecting ? "Real-time protection" : "Real-time protection off")))
                    .font(Type.text(12, weight: .semibold)).foregroundStyle(Theme.ink)
                Text(running ? "Watching \(status?.watchedPaths.count ?? 0) folders · corpus v\(status?.corpusVersion ?? "–")\(status?.lastScan.map { " · checked " + Format.relative($0) } ?? "")"
                     : (connecting ? "Connecting to the background agent…" : (protection.agentInstalled ? "The background agent is idle" : "Background agent not installed")))
                    .font(Type.mono(10)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer()
            if alerts > 0 {
                Button("Review") { open(.protection, .protection(.alerts)) }.buttonStyle(MenuButtonStyle(kind: .danger))
            } else if !running && !connecting {
                Button("Turn On") { protection.start() }.buttonStyle(MenuButtonStyle(kind: .primary))
                    .disabled(!protection.agentInstalled)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.canvas))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(alerts > 0 ? Theme.danger.opacity(0.6) : Theme.line))
    }

    private func tile(_ title: String, value: String, detail: String, tint: Color, history: [Double], max: Double?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title.uppercased()).font(Type.mono(9)).tracking(0.8).foregroundStyle(Theme.muted)
                Text(value).font(Type.mono(15, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1).minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
                Text(detail).font(Type.text(10)).foregroundStyle(Theme.muted).lineLimit(1)
                Sparkline(values: Array(history.suffix(60)), tint: tint, maxValue: max).frame(height: 22)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.canvas))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.3), value: value)
    }

    private func batteryRow(_ b: BatterySample) -> some View {
        HStack(spacing: 8) {
            Image(systemName: b.isCharging ? "battery.100.bolt" : (b.percent > 50 ? "battery.75" : (b.percent > 20 ? "battery.25" : "battery.0")))
                .foregroundStyle(b.percent <= 20 && !b.onAC ? Theme.danger : Theme.success)
            Text("\(b.percent)%").font(Type.mono(12, weight: .semibold)).foregroundStyle(Theme.ink)
            Text(b.isCharging ? "charging" : (b.onAC ? "on power" : (b.minutesRemaining.map { "\($0 / 60)h \($0 % 60)m left" } ?? "on battery")))
                .font(Type.text(11)).foregroundStyle(Theme.muted)
            Spacer()
            if let health = b.healthFraction {
                Text("health \(Int((health * 100).rounded()))%\(b.cycleCount.map { " · \($0) cycles" } ?? "")").font(Type.mono(10)).foregroundStyle(Theme.muted)
            }
        }
        .padding(.horizontal, 4)
    }

    private func actions(_ s: MetricsSnapshot) -> some View {
        VStack(spacing: 6) {
            actionRow(icon: "archivebox", title: junkTitle, detail: junkDetail,
                      button: cleanup.scanState.isLoading ? "Stop" : (cleanup.recommendedBytes > 0 ? "Clean" : "Scan"),
                      busy: cleanup.cleaning || busy == "junk") {
                if cleanup.scanState.isLoading { cleanup.stopScan() }
                else if cleanup.recommendedBytes > 0 { cleanJunk() }
                else { cleanup.scan() }
            }
            actionRow(icon: "memorychip", title: "Free up memory",
                      detail: "\(Format.bytes(s.memory.cached)) cached · \(Format.bytes(s.memory.swapUsed)) swap",
                      button: "Free", busy: busy == "ram") {
                busy = "ram"
                Task {
                    let before = SystemMonitor.shared.latest.memory.free
                    await store.purgeMemory()
                    let gained = SystemMonitor.shared.latest.memory.free - before
                    note = gained > 0 ? "Freed \(Format.bytes(gained)) of memory." : "Memory purge finished."
                    busy = nil
                }
            }
            actionRow(icon: "trash", title: "Trash",
                      detail: store.trash.map { "\(Format.bytes($0.bytes)) · \(Format.count($0.files)) files" } ?? "Measuring…",
                      button: "Empty", busy: busy == "trash", disabled: (store.trash?.bytes ?? 0) == 0) {
                busy = "trash"
                Task {
                    let freed = store.trash?.bytes ?? 0
                    await store.emptyTrash()
                    note = store.lastFailures.isEmpty ? "Emptied the Trash · \(Format.bytes(freed)) freed." : "Some items could not be removed from the Trash."
                    busy = nil
                }
            }
        }
    }

    private var junkTitle: String {
        if cleanup.cleaning { return "Cleaning…" }
        if cleanup.scanState.isLoading { return "Scanning for junk…" }
        if cleanup.recommendedBytes > 0 { return "\(Format.bytes(cleanup.recommendedBytes)) of junk found" }
        if cleanup.hasResults { return "No junk to clean" }
        return "System junk"
    }

    private var junkDetail: String {
        if cleanup.scanState.isLoading {
            return "\(cleanup.currentCategory?.title ?? "Preparing") · \(Format.bytes(cleanup.totalBytes)) so far"
        }
        if let run = cleanup.lastClean, !cleanup.hasResults || cleanup.recommendedBytes == 0 {
            return "Last clean freed \(Format.bytes(run.bytes)) \(Format.relative(run.date))"
        }
        if cleanup.recommendedBytes > 0 {
            return "\(cleanup.recommended.count) safe items · caches, logs, temporary files"
        }
        return "Caches, logs and temporary files"
    }

    private func cleanJunk() {
        busy = "junk"
        let targets = cleanup.recommended
        let bytes = cleanup.recommendedBytes
        Task {
            await cleanup.clean(targets, title: "Menu bar: clean junk")
            note = "Cleaned \(Format.bytes(cleanup.lastClean?.bytes ?? bytes)) of junk."
            busy = nil
        }
    }

    private func actionRow(icon: String, title: String, detail: String, button: String, busy: Bool, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 18).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Type.text(12, weight: .semibold)).foregroundStyle(Theme.ink)
                Text(detail).font(Type.mono(10)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer()
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Button(button, action: action).buttonStyle(MenuButtonStyle(kind: .secondary)).disabled(disabled)
            }
        }
        .padding(.vertical, 2)
    }

    private var topApps: some View {
        let top = Array(monitor.processes.sorted { $0.cpu > $1.cpu }.prefix(3))
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("BUSIEST APPS").font(Type.mono(9)).tracking(0.8).foregroundStyle(Theme.muted)
                Spacer()
                Button("All") { open(.dashboard, .monitor(.processList)) }.buttonStyle(.plain).font(Type.mono(9)).foregroundStyle(Theme.accent)
            }
            if top.isEmpty {
                Text("Sampling processes…").font(Type.text(11)).foregroundStyle(Theme.faint)
            }
            ForEach(top) { process in
                HStack(spacing: 8) {
                    Text(process.name).font(Type.text(11)).foregroundStyle(Theme.ink).lineLimit(1)
                    Spacer()
                    Text(String(format: "%.0f%%", process.cpu)).font(Type.mono(10, weight: .semibold)).foregroundStyle(process.cpu > 80 ? Theme.danger : Theme.ink)
                    Text(Format.bytes(process.memory)).font(Type.mono(10)).foregroundStyle(Theme.muted).frame(width: 64, alignment: .trailing)
                }
                .contentShape(Rectangle())
                .onTapGesture { open(.dashboard, .monitor(.processDetail(Int(process.pid)))) }
            }
        }
    }

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Open MacLean at login", isOn: Binding(get: { settings.launchAtLogin }, set: { settings.setLaunchAtLogin($0) }))
            if let error = settings.loginError {
                Text(error).font(Type.text(10)).foregroundStyle(Theme.warning)
            }
            Picker("Menu bar shows", selection: $settings.labelStyle) {
                ForEach(MenuBarSettings.LabelStyle.allCases) { Text($0.rawValue).tag($0) }
            }
            Toggle("Show MacLean in the menu bar", isOn: $settings.showInMenuBar)
        }
        .font(Type.text(11))
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.canvas))
    }

    private var footer: some View {
        HStack {
            Button("Open MacLean") { openMain() }.buttonStyle(MenuButtonStyle(kind: .primary))
            Spacer()
            Button { showSettings.toggle() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.plain).foregroundStyle(showSettings ? Theme.accent : Theme.muted).help("Menu bar settings")
            Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.plain).font(Type.text(11)).foregroundStyle(Theme.muted)
                .keyboardShortcut("q")
        }
    }

    // MARK: Helpers

    private func free(_ s: MetricsSnapshot) -> Int64 { s.disk.availableImportant > 0 ? s.disk.availableImportant : s.disk.available }
    private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
    private func tint(_ v: Double) -> Color { v > 0.85 ? Theme.danger : (v > 0.65 ? Theme.warning : Theme.success) }
    private func health(_ score: Int) -> Color { score >= 75 ? Theme.success : (score >= 50 ? Theme.warning : Theme.danger) }

    private func open(_ section: AppSection, _ route: Route?) {
        Navigator.shared.go(section, route)
        openMain()
    }

    private func openMain() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true || $0.title == "MacLean" }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
    }
}

struct MenuButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, danger }
    var kind: Kind
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Type.text(11, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(kind == .secondary ? Theme.ink : Color.white)
            .background(RoundedRectangle(cornerRadius: 6).fill(
                kind == .primary ? Theme.accent : (kind == .danger ? Theme.danger : Theme.line.opacity(0.6))))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
    }
}
