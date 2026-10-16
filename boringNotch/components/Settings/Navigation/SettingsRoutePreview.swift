//
//  SettingsRoutePreview.swift
//  boringNotch
//

import Defaults
import SwiftUI

extension SettingsRoute {
    /// What the well above the sidebar shows while this route is open.
    ///
    /// The section sets the scene and the subpage refines it, so moving deeper
    /// sharpens the preview rather than replacing it. Panes with nothing of
    /// their own to draw fall to `.shape`, which is still the truth for them:
    /// General, Appearance and Advanced are what set that geometry.
    var previewContent: NotchPreviewContent {
        if let leaf { return Self.preview(for: leaf) ?? Self.preview(for: section) }
        return Self.preview(for: section)
    }

    private static func preview(for page: SettingsPage) -> NotchPreviewContent? {
        switch page {
        case .huds: return .hud(symbol: "speaker.wave.2.fill", fraction: 0.6)
        case .usage:
            return .meter(label: "68% left", fraction: 0.68,
                          tint: NotchTint.active, caption: "Claude allowance")
        case .headerLayout:
            return .slots(leading: Defaults[.notchHeaderLeading].compactMap { $0 },
                          trailing: Defaults[.notchHeaderTrailing].compactMap { $0 })
        case .media, .controlSlots:
            return .media(title: "Windowlicker", artist: "Aphex Twin")
        case .calendar, .calendarSources:
            return .activity(symbol: "calendar", text: "Standup in 10m",
                             tint: NotchTint.active, caption: "Next event")
        case .shelf, .localSend, .kdeConnect:
            return .activity(symbol: "tray.full.fill", text: "3 items on the shelf",
                             tint: NotchTint.active, caption: "Shelf activity")
        case .pomodoro:
            return .activity(symbol: "timer", text: "24:10 focus",
                             tint: NotchTint.healthy, caption: "Focus timer")
        case .notchSize, .accent, .displays, .gestures, .advanced:
            return .shape
        default: return nil
        }
    }

    private static func preview(for section: SettingsSection) -> NotchPreviewContent {
        switch section {
        case .notch:
            return .media(title: "Windowlicker", artist: "Aphex Twin")
        case .calls:
            return .activity(symbol: "waveform.badge.mic", text: "When could you start?",
                             tint: NotchTint.active, caption: "A pointer mid-call")
        case .general, .about:
            return .shape
        }
    }
}
