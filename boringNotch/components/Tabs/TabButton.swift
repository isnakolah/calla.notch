//
//  TabButton.swift
//  boringNotch
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
    let onClick: () -> Void

    var body: some View {
        Button(action: onClick) {
            Image(systemName: icon)
                .font(NotchGlassType.glyph)
                .padding(.horizontal, 9)
                .contentShape(Capsule())
        }
        .buttonStyle(PlainButtonStyle())
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

#Preview {
    TabButton(label: "Home", icon: "tray.fill", selected: true) {
        print("Tapped")
    }
}
