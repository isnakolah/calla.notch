//
//  SettingsLanding.swift
//  callaNotch
//

import SwiftUI

/// A capture level, drawn rather than named.
///
/// "Capturing" and "Silent" are the same word until the microphone is actually
/// dead, and by then the call is half over. Bars move.
struct SettingsLevelMeter: View {
    let label: String
    /// 0…1. Seven bars is enough to read as movement and few enough to sit in a
    /// band without becoming a chart.
    let level: Double
    var tint: Color = NotchTint.active

    private static let weights: [Double] = [0.35, 0.72, 1.0, 0.55, 0.86, 0.62, 0.30]

    var body: some View {
        VStack(spacing: 3) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(Self.weights.enumerated()), id: \.offset) { _, weight in
                    Capsule()
                        .fill(level > 0.02 ? tint : Color.secondary.opacity(0.45))
                        .frame(width: 2, height: max(2, 14 * weight * max(level, 0.14)))
                }
            }
            .frame(height: 14, alignment: .bottom)
            SettingsMicroLabel(text: label)
        }
        .animation(NotchMotion.settle, value: level)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(level > 0.02 ? "Capturing" : "Silent")
    }
}
