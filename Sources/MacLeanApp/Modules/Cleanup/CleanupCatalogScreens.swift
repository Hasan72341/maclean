import MacLeanCore
import SwiftUI

// MARK: - Options

struct CleanupOptionsScreen: View {
    @ObservedObject private var store = CleanupStore.shared
    @ObservedObject private var trace = ScanTrace.shared

    var body: some View {
        ScreenScaffold("Scan Options", subtitle: "Saved automatically and used by every scan and clean") {
            Button("Reset to defaults") { store.settings = CleanupSettings() }.buttonStyle(EditorialButtonStyle(kind: .ghost))
        } content: {
            TileGrid {
                StatTile(label: "Categories", value: "\(store.settings.enabledCategories.count)/\(JunkCategory.allCases.count)")
                StatTile(label: "Minimum size", value: store.settings.minSizeMB == 0 ? "Any" : Format.megabytes(store.settings.minSizeMB))
                StatTile(label: "Large file", value: "≥ " + Format.megabytes(store.settings.largeThresholdMB))
                StatTile(label: "Removal", value: store.settings.permanent ? "Delete" : "Trash", tint: store.settings.permanent ? Theme.danger : Theme.success)
            }
            Card("Categories to scan") {
                ForEach(JunkCategory.allCases, id: \.self) { category in
                    Toggle(isOn: Binding(
                        get: { CleanupStore.shared.settings.enabled.contains(category.rawValue) },
                        set: { on in
                            var enabled = CleanupStore.shared.settings.enabled.filter { $0 != category.rawValue }
                            if on { enabled.append(category.rawValue) }
                            CleanupStore.shared.settings.enabled = enabled
                        }
                    )) {
                        HStack {
                            Label(category.title, systemImage: CleanupText.icon(category))
                            Text("· \(Rules.all.filter { $0.category == category }.count) active rules").foregroundStyle(Theme.muted)
                        }
                    }
                    .toggleStyle(EditorialToggleStyle())
                }
            }
            Card("Thresholds") {
                Stepper(value: $store.settings.minSizeMB, in: 0...10_000, step: 5) {
                    KeyValueRow(key: "Ignore items smaller than", value: store.settings.minSizeMB == 0 ? "No minimum" : Format.megabytes(store.settings.minSizeMB))
                }
                Stepper(value: $store.settings.largeThresholdMB, in: 50...50_000, step: 50) {
                    KeyValueRow(key: "Large file threshold", value: Format.megabytes(store.settings.largeThresholdMB))
                }
                Text("Applies to the next scan.").font(Type.text(11)).foregroundStyle(Theme.faint)
            }
            Card("Scan log detail") {
                Picker("Verbosity", selection: $trace.verbosity) {
                    ForEach(ScanVerbosity.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(trace.verbosity.blurb).font(Type.text(11)).foregroundStyle(Theme.muted)
                Text("Every scan writes its log to ~/Library/Application Support/MacLean/scan-logs (the 20 most recent are kept).").font(Type.text(11)).foregroundStyle(Theme.faint)
            }
            Card("Rules") {
                NavRow(icon: "books.vertical", title: "Edit rules", subtitle: "Turn rules on or off, change risk, auto-select and exclusions, or add your own", value: "\(Rules.all.count) active", tint: Theme.info, route: .cleanup(.rulesCatalog))
            }
            Card("Safety") {
                Toggle("Include caution items in lists and totals", isOn: $store.settings.includeCaution).toggleStyle(EditorialToggleStyle())
                Text("Caution items are never pre-selected either way; this only controls whether they are shown and selectable.").font(Type.text(11)).foregroundStyle(Theme.muted)
                Toggle("Delete permanently instead of moving to Trash", isOn: $store.settings.permanent).toggleStyle(EditorialToggleStyle())
                Text(store.settings.permanent ? "Every clean deletes immediately. Files cannot be recovered." : "Cleaned items go to the Trash and can be put back until the Trash is emptied.")
                    .font(Type.text(11)).foregroundStyle(store.settings.permanent ? Theme.danger : Theme.muted)
            }
        }
    }
}

// MARK: - History

struct CleanupHistoryScreen: View {
    @ObservedObject private var log = ActivityLog.shared
    @EnvironmentObject private var nav: Navigator
    @State private var expanded: UUID?

    var body: some View {
        let entries = log.entries.filter { $0.module == "Cleanup" }
        ScreenScaffold("Cleanup History", subtitle: "Every cleanup run from this section") {
            Button("Scan log") { nav.push(.cleanup(.scanLog)) }.buttonStyle(EditorialButtonStyle(kind: .ghost))
        } content: {
            TileGrid {
                StatTile(label: "Total freed", value: Format.bytes(entries.reduce(0) { $0 + $1.bytes }), tint: Theme.success, icon: "checkmark.circle")
                StatTile(label: "Cleanups", value: Format.count(entries.count))
                StatTile(label: "Items removed", value: Format.count(entries.reduce(0) { $0 + $1.items }))
                StatTile(label: "Failures", value: Format.count(entries.reduce(0) { $0 + $1.failures }), tint: Theme.warning)
                StatTile(label: "Last", value: Format.relative(entries.first?.date))
            }
            Card("Freed per day", trailing: "last 14 days") {
                CleanupBarChart(bars: days(entries), tint: Theme.success)
            }
            if entries.isEmpty {
                EmptyPanel(icon: "clock.arrow.circlepath", title: "No cleanups yet", message: "Cleanups from Smart Scan, categories and Trash are recorded here.")
            } else {
                ForEach(entries) { entry in
                    Card {
                        Button {
                            expanded = expanded == entry.id ? nil : entry.id
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.title).font(Type.text(12, weight: .medium)).foregroundStyle(Theme.ink)
                                    Text("\(Format.date(entry.date)) · \(Format.count(entry.items)) items · \(Format.count(entry.failures)) failed").font(Type.text(11)).foregroundStyle(Theme.muted)
                                }
                                Spacer()
                                Text(Format.bytes(entry.bytes)).font(Type.mono(12, weight: .semibold)).monospacedDigit()
                                Image(systemName: expanded == entry.id ? "chevron.up" : "chevron.down").font(.system(size: 10)).foregroundStyle(Theme.faint)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if expanded == entry.id, !entry.detail.isEmpty {
                            Text(entry.detail).font(Type.mono(10)).foregroundStyle(Theme.muted).textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    private func days(_ entries: [ActivityEntry]) -> [CleanupBarChart.Bar] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<14).reversed().map { offset -> CleanupBarChart.Bar in
            let day = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
            let bytes = entries.filter { calendar.isDate($0.date, inSameDayAs: day) }.reduce(Int64(0)) { $0 + $1.bytes }
            return .init(label: day.formatted(.dateTime.day().month(.narrow)), value: Double(bytes), text: bytes > 0 ? Format.bytes(bytes) : "")
        }
    }
}

// MARK: - Scan log

struct CleanupScanLogScreen: View {
    @ObservedObject private var store = CleanupStore.shared

    var body: some View {
        let log = store.scanLog
        ScreenScaffold("Scan Log", subtitle: "Recent Smart Scans on this Mac") {
            ConfirmButton(title: "Clear log", message: "Remove the scan log. Files are not affected.", kind: .ghost, disabled: log.isEmpty) {
                store.clearScanLog()
            }
        } content: {
            TileGrid {
                StatTile(label: "Scans", value: Format.count(log.count))
                StatTile(label: "Average found", value: Format.bytes(log.isEmpty ? 0 : log.reduce(0) { $0 + $1.bytes } / Int64(log.count)))
                StatTile(label: "Average time", value: log.isEmpty ? "—" : Format.duration(log.reduce(0) { $0 + $1.duration } / Double(log.count)))
                StatTile(label: "Peak", value: Format.bytes(log.map(\.bytes).max() ?? 0), tint: Theme.accent)
            }
            if log.count > 1 {
                Card("Found per scan") {
                    LiveChart(series: [
                        .init(values: log.reversed().map { Double($0.bytes) / 1_048_576 }, color: Theme.accent, label: "Found (MB)"),
                        .init(values: log.reversed().map { Double($0.recommendedBytes) / 1_048_576 }, color: Theme.success, label: "Recommended (MB)", fill: false),
                    ], capacity: max(log.count, 2), format: { String(format: "%.0f", $0) })
                }
            }
            if log.isEmpty {
                EmptyPanel(icon: "waveform.path.ecg", title: "No scans recorded")
            }
            ForEach(log) { record in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Format.date(record.date)).font(Type.text(12, weight: .medium)).foregroundStyle(Theme.ink)
                        Text("\(Format.count(record.items)) items · \(Format.count(record.files)) files · \(Format.duration(record.duration))").font(Type.text(11)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Format.bytes(record.bytes)).font(Type.mono(12, weight: .semibold)).monospacedDigit()
                        Text("\(Format.bytes(record.recommendedBytes)) recommended").font(Type.text(10)).foregroundStyle(Theme.success)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.canvas))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
            }
        }
    }
}
