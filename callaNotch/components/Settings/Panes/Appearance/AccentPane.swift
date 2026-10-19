//
//  AccentPane.swift
//  callaNotch
//

import Defaults
import SwiftUI

/// The one colour the app spends, as a row of swatches.
///
/// The first swatch follows macOS; the rest are the system's own accent
/// presets; the last opens a picker for anything else. The name of the choice
/// sits at the end of the row, so the swatches never need labels of their own.
struct AccentSwatches: View {
    @Default(.useCustomAccentColor) private var useCustomAccentColor
    @Default(.customAccentColorData) private var customAccentColorData

    @State private var customColor: Color = .accentColor

    enum Preset: String, CaseIterable, Identifiable {
        case blue = "Blue", purple = "Purple", pink = "Pink", red = "Red"
        case orange = "Orange", yellow = "Yellow", green = "Green", graphite = "Graphite"

        var id: String { rawValue }

        var color: Color {
            switch self {
            case .blue: return Color(red: 0.0, green: 0.478, blue: 1.0)
            case .purple: return Color(red: 0.686, green: 0.322, blue: 0.871)
            case .pink: return Color(red: 1.0, green: 0.176, blue: 0.333)
            case .red: return Color(red: 1.0, green: 0.271, blue: 0.227)
            case .orange: return Color(red: 1.0, green: 0.584, blue: 0.0)
            case .yellow: return Color(red: 1.0, green: 0.8, blue: 0.0)
            case .green: return Color(red: 0.4, green: 0.824, blue: 0.176)
            case .graphite: return Color(red: 0.557, green: 0.557, blue: 0.576)
            }
        }
    }

    /// The preset the stored colour matches, if any.
    private var selectedPreset: Preset? {
        guard useCustomAccentColor, let stored = storedColor else { return nil }
        return Preset.allCases.first { Self.same(Color(nsColor: stored), $0.color) }
    }

    private var storedColor: NSColor? {
        guard let data = customAccentColorData else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data)
    }

    private var name: String {
        if !useCustomAccentColor { return "Following macOS" }
        return selectedPreset?.rawValue ?? "Custom"
    }

    var body: some View {
        HStack(spacing: 10) {
            swatch(fill: AnyShapeStyle(AngularGradient(
                        colors: [.red, .orange, .yellow, .green, .blue, .purple, .red], center: .center)),
                   selected: !useCustomAccentColor, label: "Follow macOS") {
                useCustomAccentColor = false
                announce()
            }
            ForEach(Preset.allCases) { preset in
                swatch(fill: AnyShapeStyle(preset.color), selected: selectedPreset == preset,
                       label: preset.rawValue) {
                    save(preset.color)
                }
            }
            ColorPicker(selection: Binding(get: { customColor }, set: { save($0) }),
                        supportsOpacity: false) { EmptyView() }
                .labelsHidden()
                .help("Any colour")
                .accessibilityLabel(Text("Pick any colour"))
            Spacer(minLength: 8)
            Text(name)
                .font(NotchType.rowDetail)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
        .onAppear { if let storedColor { customColor = Color(nsColor: storedColor) } }
    }

    private func swatch(fill: AnyShapeStyle, selected: Bool, label: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(fill)
                .frame(width: 22, height: 22)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                .padding(3)
                .overlay(Circle().strokeBorder(selected ? Color.primary.opacity(0.85) : .clear, lineWidth: 2))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func save(_ color: Color) {
        customColor = color
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: NSColor(color),
                                                        requiringSecureCoding: false) {
            customAccentColorData = data
        }
        useCustomAccentColor = true
        announce()
    }

    /// The notch itself still listens for this to recolour.
    private func announce() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Notification.Name("AccentColorChanged"), object: nil)
        }
    }

    private static func same(_ a: Color, _ b: Color) -> Bool {
        let x = NSColor(a).usingColorSpace(.sRGB) ?? NSColor(a)
        let y = NSColor(b).usingColorSpace(.sRGB) ?? NSColor(b)
        return abs(x.redComponent - y.redComponent) < 0.01
            && abs(x.greenComponent - y.greenComponent) < 0.01
            && abs(x.blueComponent - y.blueComponent) < 0.01
    }
}
