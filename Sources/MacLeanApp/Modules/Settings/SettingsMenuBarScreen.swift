import MacLeanCore
import SwiftUI

/// Settings › Menu Bar & Background: how MacLean runs when its window is closed.
struct SettingsMenuBarScreen: View {
    @ObservedObject private var settings = MenuBarSettings.shared
    @ObservedObject private var monitor = SystemMonitor.shared
    @EnvironmentObject private var nav: Navigator

    var body: some View {
        ScreenScaffold("Menu Bar & Background", subtitle: "Run MacLean in the background, from the menu bar, at login") {
            EmptyView()
        } content: {
            TileGrid {
                StatTile(label: "Mode", value: modeTitle, detail: modeDetail, tint: Theme.accent, icon: "macwindow")
                StatTile(label: "At login", value: settings.launchAtLogin ? "Starts" : "Off", detail: settings.openWindowAtLaunch ? "opens the window" : "starts quietly", icon: "power")
                StatTile(label: "Menu bar", value: settings.showInMenuBar ? settings.labelStyle.rawValue : "Hidden", detail: "\(settings.panelSections.count) of \(MenuBarSettings.PanelSection.allCases.count) panel sections", icon: "menubar.rectangle")
                StatTile(label: "Refresh", value: SettingsMonitoringScreen.label(monitor.intervalSeconds), detail: "live numbers in the panel", icon: "timer")
            }

            Card("Background") {
                VStack(alignment: .leading, spacing: 12) {
                    row("Keep running when the window is closed",
                        detail: "The menu bar item, live numbers and threat notifications keep working. Off: closing the window quits MacLean.",
                        isOn: $settings.runInBackground)
                    row("Show MacLean in the Dock",
                        detail: "Off makes MacLean a menu bar app: no Dock icon or app switcher entry. The window still opens from the menu bar.",
                        isOn: $settings.showInDock)
                    row("Open the window when MacLean starts",
                        detail: "Off: MacLean starts quietly in the menu bar (useful with Open at login).",
                        isOn: $settings.openWindowAtLaunch)
                    row("Open MacLean at login",
                        detail: "Registered with macOS (System Settings › General › Login Items).",
                        isOn: Binding(get: { settings.launchAtLogin }, set: { settings.setLaunchAtLogin($0) }))
                    if let error = settings.loginError {
                        HStack {
                            Text(error).font(Type.text(11)).foregroundStyle(Theme.warning)
                            Spacer()
                            Button("Open Login Items") { SystemPane.loginItems.open() }.buttonStyle(EditorialButtonStyle(kind: .inline))
                        }
                    }
                }
            }

            Card("Menu bar item") {
                VStack(alignment: .leading, spacing: 12) {
                    row("Show MacLean in the menu bar",
                        detail: settings.showInDock ? "Live system numbers and quick actions one click away." : "Required while the Dock icon is hidden, so MacLean stays reachable.",
                        isOn: $settings.showInMenuBar)
                        .disabled(!settings.showInDock)
                    HStack(spacing: 12) {
                        Text("Next to the icon").font(Type.text(12)).foregroundStyle(Theme.ink)
                        Picker("", selection: $settings.labelStyle) {
                            ForEach(MenuBarSettings.LabelStyle.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 380)
                        Spacer()
                        HStack(spacing: 4) { MenuBarLabel() }
                            .font(.system(size: 13))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.canvas))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line))
                            .help("Preview")
                    }
                }
            }

            Card("Panel sections", trailing: "shown in the menu bar panel") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(MenuBarSettings.PanelSection.allCases) { section in
                        HStack(spacing: 10) {
                            Image(systemName: section.icon).frame(width: 18).foregroundStyle(Theme.accent)
                            Text(section.rawValue).font(Type.text(13, weight: .medium)).foregroundStyle(Theme.ink)
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { settings.panelSections.contains(section) },
                                set: { on in if on { settings.panelSections.insert(section) } else { settings.panelSections.remove(section) } }
                            ))
                            .toggleStyle(.switch).labelsHidden().tint(Theme.accent)
                        }
                    }
                }
            }

            Card("Notifications") {
                row("Notify me about new threats",
                    detail: "When the realtime agent flags a file, macOS shows a notification even if the window is closed.",
                    isOn: $settings.notifyThreats)
            }

            NavRow(icon: "waveform.path.ecg", title: "Refresh interval", subtitle: "How often live numbers update (shared with the whole app)", value: SettingsMonitoringScreen.label(monitor.intervalSeconds), route: .settings(.monitoring))
            Text("The realtime protection agent is a separate background process managed by macOS; it keeps watching even when MacLean is quit.")
                .font(Type.text(11)).foregroundStyle(Theme.muted)
        }
    }

    private var modeTitle: String {
        if !settings.showInDock { return "Menu bar app" }
        return settings.runInBackground ? "Background" : "Window only"
    }

    private var modeDetail: String {
        if !settings.showInDock { return "no Dock icon" }
        return settings.runInBackground ? "keeps running after closing" : "quits with its window"
    }

    private func row(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Type.text(13, weight: .medium)).foregroundStyle(Theme.ink)
                Text(detail).font(Type.text(11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: isOn).toggleStyle(.switch).labelsHidden().tint(Theme.accent)
        }
    }
}
