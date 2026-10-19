//
//  TabButton.swift
//  callaNotch
//
//  Created by Hugo Persson on 2024-08-24.
//

import SwiftUI

/// One tab in the open notch's header.
///
/// `label` and `selected` were accepted and then dropped on the floor: the glyph
/// was the entire button, so VoiceOver read out an SF Symbol name — "tray dot
/// fill" — and nothing said which tab was the current one. Both are now used for
/// what they were always for.
struct TabButton: View {
    let label: String
    let icon: String
    let selected: Bool
    /// The tab's accent. Selected, the capsule is drawn in it over a wash of it.
    var accent: Color = NotchInk.primary
    /// Unselected ink. Tertiary, except the Call tab mid-call, which stays mint.
    var restingInk: Color = NotchInk.tertiary
    /// The small dot that says a call is running behind another tab.
    var showsLiveDot = false
    let onClick: () -> Void

    var body: some View {
        Button(action: onClick) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                if selected {
                    Text(label)
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.1)
                        .lineLimit(1)
                        .fixedSize()
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
                }
            }
            .foregroundStyle(selected ? accent : restingInk)
            .padding(.horizontal, selected ? 10 : 0)
            .frame(minWidth: 26, minHeight: 26)
            .overlay(alignment: .topTrailing) {
                if showsLiveDot {
                    Circle()
                        .fill(NotchAccent.call)
                        .frame(width: 6, height: 6)
                        .overlay(Circle().strokeBorder(.black, lineWidth: 2).padding(-2))
                        .offset(x: -3, y: 3)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(PlainButtonStyle())
        .help(label)
        .accessibilityLabel(showsLiveDot ? "\(label), call running" : label)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

#Preview {
    TabButton(label: "Home", icon: "tray.fill", selected: true) {
        print("Tapped")
    }
}
