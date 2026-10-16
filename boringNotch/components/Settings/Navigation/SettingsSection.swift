//
//  SettingsSection.swift
//  boringNotch
//

import SwiftUI

/// One of four. The sidebar selects exactly this and nothing else.
///
/// Thirteen sections became four because the app became smaller: General is
/// how the app behaves, Notch is everything drawn in it, Calls is the copilot,
/// and About is the version. Each landing pane is one scroll of the settings
/// people actually change, with the rest behind an Advanced fold or a drill-in.
enum SettingsSection: String, CaseIterable, Identifiable, Hashable, Codable {
    case general, notch, calls, about

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .general: return "General"
        case .notch: return "Notch"
        case .calls: return "Calls"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .notch: return "rectangle.topthird.inset.filled"
        case .calls: return "waveform"
        case .about: return "info"
        }
    }

    /// The tile colour behind the sidebar glyph, the way System Settings tells
    /// its rows apart before a word is read.
    var tile: Color {
        switch self {
        case .general: return Color(white: 0.45)
        case .notch: return Color(red: 0.16, green: 0.16, blue: 0.18)
        case .calls: return Color(red: 0.20, green: 0.68, blue: 0.40)
        case .about: return Color(red: 0.22, green: 0.48, blue: 0.96)
        }
    }

    /// The sentence under the landing pane's title.
    var detail: LocalizedStringResource {
        switch self {
        case .general: return "How the app starts and how the notch opens."
        case .notch: return "What lives in the notch, and what it looks like."
        case .calls: return "The copilot that listens to a call and suggests what to say."
        case .about: return "Version, updates, and where the source lives."
        }
    }
}
