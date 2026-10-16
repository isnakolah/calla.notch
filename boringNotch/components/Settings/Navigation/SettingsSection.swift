//
//  SettingsSection.swift
//  boringNotch
//

import SwiftUI

/// One of thirteen. The sidebar selects exactly this and nothing else.
///
/// The model this replaces was one flat `SettingsTab` of twenty-seven cases,
/// carrying a doc comment arguing that nesting was the mistake — because a
/// `DisclosureGroup` inside a selectable `List` rendered collapsed regardless of
/// its binding. That was true of `DisclosureGroup`. It was never true of depth.
/// Twenty-seven siblings is not one navigation model, it is an inventory, and it
/// forced related settings apart as peers: shortcuts in three panes, permissions
/// written five different ways, media split across three places, and panes
/// pointing at each other in prose because the structure could not.
///
/// The fix is not a second navigation model in the sidebar. It is a
/// `NavigationStack` in the detail column, which has one path, one back gesture,
/// and a breadcrumb that says where the path is.
enum SettingsSection: String, CaseIterable, Identifiable, Hashable, Codable {
    case general, appearance, media, calendar, system, shelf
    case pomodoro, copilot, ice, sweep
    case shortcuts, privacy, about

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .media: return "Media"
        case .calendar: return "Calendar"
        case .system: return "System"
        case .shelf: return "Shelf"
        case .pomodoro: return "Pomodoro"
        case .copilot: return "Call Copilot"
        case .ice: return "Ice"
        case .sweep: return "Sweep"
        case .shortcuts: return "Shortcuts"
        case .privacy: return "Privacy & Permissions"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gear"
        case .appearance: return "paintbrush"
        case .media: return "play.laptopcomputer"
        case .calendar: return "calendar"
        case .system: return "gauge.with.dots.needle.33percent"
        case .shelf: return "books.vertical"
        case .pomodoro: return "timer"
        case .copilot: return "waveform.badge.mic"
        case .ice: return "snowflake"
        case .sweep: return "externaldrive.badge.checkmark"
        case .shortcuts: return "keyboard"
        case .privacy: return "hand.raised"
        case .about: return "info.circle"
        }
    }

    /// The sentence under the landing pane's title.
    var detail: LocalizedStringResource {
        switch self {
        case .general: return "How the app starts, which display it lives on, and how the notch opens."
        case .appearance: return "What the notch looks like and what sits in its header."
        case .media: return "What plays, how it is shown, and which controls you get."
        case .calendar: return "What is next, and which calendars it comes from."
        case .system: return "Readouts the notch keeps for you: charge, the volume and brightness HUDs, and what is left of your AI allowance."
        case .shelf: return "A place to drop things, and the devices to send them to."
        case .pomodoro: return "Focus intervals, breaks, and what happens when one ends."
        case .copilot: return "Help during a live call: what it hears, what it knows, what it says."
        case .ice: return "Organize menu bar extras: sections, reveal gestures, search, spacing, and appearance."
        case .sweep: return "What is taking up the disk, and what is safe to reclaim."
        case .shortcuts: return "Every key combination this app answers to, in one place."
        case .privacy: return "What macOS has allowed this app to do, and what each thing unlocks."
        case .about: return "Version, updates, and where the source lives."
        }
    }

    /// The drill-ins this section offers, in the order its landing pane lists
    /// them. Also the definition of the tree: a page not listed by exactly one
    /// section is a page nobody can reach.
    var subpages: [SettingsPage] {
        switch self {
        case .general: return [.displays, .gestures, .advanced]
        case .appearance: return [.notchSize, .accent, .headerLayout, .camera]
        case .media: return [.controlSlots]
        case .calendar: return [.calendarSources]
        case .system: return [.battery, .huds, .usage]
        case .shelf: return [.localSend, .kdeConnect]
        case .pomodoro: return []
        // Grouped on the landing pane rather than listed flat — see
        // `SettingsSection.groups`. Screen Quiz had been missing from this list
        // entirely, which made a thirty-one-kilobyte pane reachable only by a
        // deep link from the notch.
        case .copilot:
            return [.copilotCall, .copilotQuiz, .copilotCoding,
                    .copilotModels, .copilotPrompts, .copilotKnowledge,
                    .copilotHistory, .copilotBackup].filter { $0.availablePage == $0 }
        case .ice: return [.iceGeneral, .iceLayout, .iceAppearance, .iceHotkeys, .iceAdvanced]
        // Clean Up is the landing pane, so it is not listed here. History and
        // Options are reached from the header rather than from a card, since the
        // landing has real work on it to get in the way of.
        case .sweep: return [.sweepHistory, .sweepOptions]
        case .shortcuts, .privacy, .about: return []
        }
    }

    /// The subpages, in named groups.
    ///
    /// A section earns this once its list stops being scannable. Call Copilot
    /// has three things it can *do* — a call, a screen quiz, a coding interview
    /// — and five settings that apply across all three, and listing those eight
    /// as peers made the modes indistinguishable from the shared plumbing. The
    /// groups are the answer to "where is that?": the thing you are setting up,
    /// or the thing every mode shares.
    ///
    /// Sections without groups fall back to one unnamed group of `subpages`, so
    /// the landing pane has one code path.
    var groups: [(title: String, pages: [SettingsPage])] {
        switch self {
        case .copilot:
            return [
                ("What it can do", [SettingsPage.copilotCall, .copilotQuiz, .copilotCoding].filter { $0.availablePage == $0 }),
                ("What it knows", [.copilotModels, .copilotPrompts, .copilotKnowledge]),
                ("What it keeps", [.copilotHistory, .copilotBackup]),
            ]
        default:
            return subpages.isEmpty ? [] : [("", subpages)]
        }
    }
}
