import AppKit
import SwiftUI

/// Window chrome: sidebar + routed detail + live status strip.
struct RootShell: View {
    var smoke = false
    @StateObject private var nav = Navigator.shared
    @StateObject private var monitor = SystemMonitor.shared
    @StateObject private var activity = ActivityLog.shared
    @StateObject private var toasts = ToastCenter.shared
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        HStack(spacing: 0) {
            ShellSidebar()
            Rectangle().fill(Theme.line).frame(width: 1)
            VStack(spacing: 0) {
                ZStack {
                    if let top = nav.path.last {
                        RouteView(route: top)
                            .id(nav.path.count)
                            .transition(.asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .opacity
                            ))
                    } else {
                        SectionRootView(section: nav.section)
                            .id(nav.section)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottom) { SelectionDockView() }
                .animation(.easeOut(duration: 0.18), value: nav.path.count)
                .animation(.easeOut(duration: 0.15), value: nav.section)
                LiveStatusStrip()
            }
            .background(Theme.paper)
        }
        .background(Theme.paper)
        .tint(Theme.accent)
        .buttonStyle(EditorialButtonStyle())
        .environmentObject(nav)
        .environmentObject(monitor)
        .environmentObject(activity)
        .environmentObject(toasts)
        .overlay(alignment: .top) { ToastOverlay() }
        .sheet(isPresented: Binding(get: { updater.showPopup && !smoke }, set: { if !$0 { updater.showPopup = false } })) {
            UpdateSheet()
        }
        .background {
            // Keyboard back: ⌘[ and Esc.
            Button("") { nav.pop() }
                .keyboardShortcut("[", modifiers: .command)
                .opacity(0)
            Button("") { nav.pop() }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
        }
        .onAppear {
            monitor.start()
            if !smoke { SmokeTest.runIfRequested() }
        }
    }
}

private struct ShellSidebar: View {
    @EnvironmentObject private var nav: Navigator
    @EnvironmentObject private var monitor: SystemMonitor

    private var groups: [(String, [AppSection])] {
        var result: [(String, [AppSection])] = []
        for section in AppSection.allCases {
            if let index = result.firstIndex(where: { $0.0 == section.group }) {
                result[index].1.append(section)
            } else {
                result.append((section.group, [section]))
            }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("maclean").font(Type.display(26)).foregroundStyle(Theme.ink)
                Text(".").font(Type.display(26)).foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, 20)
            .padding(.top, 44)
            .padding(.bottom, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(groups, id: \.0) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.0.uppercased())
                                .font(Type.label)
                                .tracking(1.1)
                                .foregroundStyle(Theme.faint)
                                .padding(.horizontal, 20)
                                .padding(.bottom, 4)
                            ForEach(group.1) { section in
                                ShellSidebarRow(
                                    section: section,
                                    selected: nav.section == section,
                                    depth: nav.section == section ? nav.path.count : 0
                                ) {
                                    if nav.section == section {
                                        nav.popToRoot()
                                    } else {
                                        nav.section = section
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)

            VStack(alignment: .leading, spacing: 8) {
                Hairline()
                MiniMeter(label: "CPU", value: monitor.latest.cpu.total, tint: Theme.accent)
                MiniMeter(label: "RAM", value: monitor.latest.memory.usedFraction, tint: Theme.info)
                MiniMeter(label: "DISK", value: monitor.latest.disk.usedFraction, tint: Theme.warning)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
        }
        .frame(width: 232)
        .background(Theme.canvas)
    }
}

private struct ShellSidebarRow: View {
    let section: AppSection
    let selected: Bool
    let depth: Int
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(selected ? Theme.accent : Theme.muted)
                Text(section.title)
                    .font(Type.text(13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(Theme.ink)
                Spacer()
                if depth > 0 {
                    Text("\(depth)")
                        .font(Type.mono(9, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Theme.line))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? Theme.accent.opacity(0.12) : (hovering ? Theme.line.opacity(0.5) : .clear))
            )
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct MiniMeter: View {
    let label: String
    let value: Double
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(Type.mono(9, weight: .semibold))
                .foregroundStyle(Theme.faint)
                .frame(width: 32, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.line)
                    Capsule().fill(tint)
                        .frame(width: max(2, proxy.size.width * min(1, max(0, value))))
                }
            }
            .frame(height: 5)
            Text(String(format: "%3.0f%%", value * 100))
                .font(Type.mono(9))
                .foregroundStyle(Theme.muted)
                .frame(width: 34, alignment: .trailing)
        }
        .animation(.easeOut(duration: 0.4), value: value)
    }
}

/// Bottom strip with live numbers on every screen.
private struct LiveStatusStrip: View {
    @EnvironmentObject private var monitor: SystemMonitor
    @EnvironmentObject private var activity: ActivityLog

    var body: some View {
        let s = monitor.latest
        HStack(spacing: 18) {
            stat("CPU", String(format: "%.0f%%", s.cpu.total * 100))
            stat("MEM", "\(Format.bytes(s.memory.used)) / \(Format.bytes(s.memory.total))")
            stat("FREE", Format.bytes(s.disk.available))
            stat("↓", Format.rate(s.network.rxPerSec))
            stat("↑", Format.rate(s.network.txPerSec))
            if let battery = s.battery {
                stat("BAT", "\(battery.percent)%\(battery.isCharging ? " ⚡︎" : "")")
            }
            Spacer()
            if let last = activity.entries.first {
                Text("LAST: \(last.title) · \(Format.bytes(last.bytes))")
                    .font(Type.mono(9))
                    .foregroundStyle(Theme.faint)
                    .lineLimit(1)
            }
            Text("FREED TOTAL \(Format.bytes(activity.totalFreed))")
                .font(Type.mono(9, weight: .semibold))
                .foregroundStyle(Theme.success)
        }
        .padding(.horizontal, 20)
        .frame(height: 28)
        .background(Theme.canvas)
        .overlay(alignment: .top) { Hairline() }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Text(label).font(Type.mono(9, weight: .semibold)).foregroundStyle(Theme.faint)
            Text(value).font(Type.mono(10)).foregroundStyle(Theme.ink).monospacedDigit()
        }
    }
}

// MARK: - Toasts

@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let isError: Bool
    }

    @Published var current: Toast?

    func show(_ text: String, error: Bool = false) {
        let toast = Toast(text: text, isError: error)
        current = toast
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if current == toast { current = nil }
        }
    }
}

private struct ToastOverlay: View {
    @ObservedObject private var toasts = ToastCenter.shared

    var body: some View {
        if let toast = toasts.current {
            HStack(spacing: 8) {
                Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(toast.isError ? Theme.danger : Theme.success)
                Text(toast.text)
                    .font(Type.text(12, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.canvas).shadow(color: .black.opacity(0.15), radius: 10, y: 3))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line))
            .padding(.top, 14)
            .transition(.move(edge: .top).combined(with: .opacity))
            .onTapGesture { toasts.current = nil }
        }
    }
}
