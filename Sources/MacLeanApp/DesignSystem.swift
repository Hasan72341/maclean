import AppKit
import SwiftUI

enum Theme {
    static let paper = dynamic(light: 0xF4F1E9, dark: 0x12110F)
    static let canvas = dynamic(light: 0xFBF8F1, dark: 0x191715)
    static let ink = dynamic(light: 0x171510, dark: 0xF2EEE5)
    static let muted = dynamic(light: 0x6D675C, dark: 0xA39A8D)
    static let faint = dynamic(light: 0xB6AE9F, dark: 0x5A544A)
    static let line = dynamic(light: 0xD8D1C2, dark: 0x332F2A)
    static let lineStrong = dynamic(light: 0xB9B0A0, dark: 0x514A40)
    static let accent = dynamic(light: 0xC24726, dark: 0xF07B56)
    static let success = dynamic(light: 0x2E6A4E, dark: 0x83C9A4)
    static let warning = dynamic(light: 0x956015, dark: 0xE2B15A)
    static let danger = dynamic(light: 0xA32E28, dark: 0xFF8D80)
    static let info = dynamic(light: 0x315D7A, dark: 0x8CB8D5)

    private static func color(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return color(isDark ? dark : light)
        })
    }
}

enum Type {
    /// Interface size multiplier (Settings › General › Interface size).
    static var scale: CGFloat { InterfaceScale.current }

    static func display(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size * scale, weight: weight, design: .serif)
    }

    static func text(_ size: CGFloat = 14, weight: Font.Weight = .regular) -> Font {
        .system(size: size * scale, weight: weight)
    }

    static func mono(_ size: CGFloat = 11, weight: Font.Weight = .regular) -> Font {
        .system(size: size * scale, weight: weight, design: .monospaced)
    }

    static var label: Font { .system(size: 10 * scale, weight: .semibold, design: .monospaced) }
}

enum Metric {
    static let sidebarWidth: CGFloat = 252
    static let pagePadding: CGFloat = 40
    static let contentMaxWidth: CGFloat = 1_180
    static let panelPadding: CGFloat = 24
    static let sectionGap: CGFloat = 28
}

struct EditorialButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
        case ghost
        case destructive
        case inline
        case inlineDanger
    }

    var kind: Kind = .secondary

    func makeBody(configuration: Configuration) -> some View {
        EditorialButtonBody(configuration: configuration, style: self)
    }

    fileprivate var isInline: Bool {
        kind == .inline || kind == .ghost || kind == .inlineDanger
    }

    fileprivate var foreground: Color {
        switch kind {
        case .primary: return Theme.paper
        case .destructive: return Theme.danger
        case .secondary: return Theme.ink
        case .ghost: return Theme.muted
        case .inline: return Theme.accent
        case .inlineDanger: return Theme.danger
        }
    }

    fileprivate var background: Color {
        switch kind {
        case .primary: return Theme.ink
        case .secondary, .destructive, .ghost, .inline, .inlineDanger: return .clear
        }
    }

    fileprivate var border: Color {
        switch kind {
        case .secondary: return Theme.lineStrong
        case .destructive: return Theme.danger
        case .primary, .ghost, .inline, .inlineDanger: return .clear
        }
    }

    fileprivate var showsBorder: Bool {
        kind == .secondary || kind == .destructive
    }
}

/// Disabled buttons drop their fill and fall back to a faint outline, so an
/// unavailable primary action never reads as the call to action.
private struct EditorialButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let style: EditorialButtonStyle
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(Type.mono(10, weight: .semibold))
            .textCase(.uppercase)
            .tracking(1.1)
            .foregroundStyle(isEnabled ? style.foreground : Theme.faint)
            .padding(.horizontal, style.isInline ? 0 : 12)
            .padding(.vertical, style.isInline ? 2 : 8)
            .background(isEnabled ? style.background : .clear)
            .overlay {
                if !style.isInline, style.showsBorder || !isEnabled {
                    Rectangle().stroke(isEnabled ? style.border : Theme.line, lineWidth: 1)
                }
            }
            .opacity(configuration.isPressed ? 0.58 : 1)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.15), value: isEnabled)
    }
}

struct EditorialToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 9) {
                ZStack {
                    Rectangle()
                        .stroke(Theme.lineStrong, lineWidth: 1)
                        .frame(width: 14, height: 14)
                    if configuration.isOn {
                        Rectangle()
                            .fill(Theme.accent)
                            .frame(width: 8, height: 8)
                    }
                }
                configuration.label
                    .font(Type.text(12))
                    .foregroundStyle(Theme.ink)
            }
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

struct EditorialTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(Type.text(13))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Theme.paper)
            .overlay {
                Rectangle().stroke(Theme.line, lineWidth: 1)
            }
    }
}

struct EditorialPicker<T: Hashable>: View {
    let label: String
    @Binding var selection: T
    let options: [T]
    let title: (T) -> String

    var body: some View {
        HStack(spacing: 10) {
            Text(label.uppercased())
                .font(Type.label)
                .tracking(1.1)
                .foregroundStyle(Theme.faint)
            Picker("", selection: $selection) {
                ForEach(options, id: \.self) { option in
                    Text(title(option)).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(Theme.accent)
            .controlSize(.small)
            .fixedSize()
        }
    }
}

extension View {
    func screenContent() -> some View {
        self
            .frame(maxWidth: Metric.contentMaxWidth, alignment: .leading)
            .padding(.horizontal, Metric.pagePadding)
            .padding(.vertical, 36)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

enum CountFormat {
    static let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static func string(_ value: Int) -> String {
        formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func string(_ value: Int64) -> String {
        formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

struct Hairline: View {
    var inset: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(Theme.line)
            .frame(height: 1)
            .padding(.leading, inset)
    }
}
