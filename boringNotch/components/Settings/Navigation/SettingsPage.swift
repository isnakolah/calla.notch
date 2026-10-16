//
//  SettingsPage.swift
//  boringNotch
//

import SwiftUI

/// A destination inside a section.
///
/// Pages form a shallow tree: most hang off a section's landing pane, a few hang
/// off another page (Control Slots under Media, a call under History). `parent`
/// is that tree, written once, and the breadcrumb is derived from it — so a page
/// can never be listed in one place and claim another in its trail.
///
/// `Hashable` is the hard requirement — it is what `NavigationStack` stores —
/// and the string form for deep links is built explicitly in `identifier`.
enum SettingsPage: Hashable {
    // General
    case shortcuts, privacy, displays, gestures, advanced
    // Notch
    case media, controlSlots, calendar, calendarSources
    case shelf, localSend, kdeConnect
    case pomodoro, usage, huds
    case headerLayout, notchSize, accent
    // Calls
    case copilotCall, copilotQuiz, copilotModels, copilotPrompts
    case copilotKnowledge, copilotBackup, copilotHistory
    case copilotKnowledgeDetail(KnowledgeRoute)
    case copilotCallDetail(id: String)

    /// The section this belongs to.
    var section: SettingsSection {
        switch self {
        case .shortcuts, .privacy, .displays, .gestures, .advanced: return .general
        case .media, .controlSlots, .calendar, .calendarSources, .shelf, .localSend, .kdeConnect,
             .pomodoro, .usage, .huds, .headerLayout, .notchSize, .accent:
            return .notch
        case .copilotCall, .copilotQuiz, .copilotModels, .copilotPrompts,
             .copilotKnowledge, .copilotBackup, .copilotHistory,
             .copilotKnowledgeDetail, .copilotCallDetail:
            return .calls
        }
    }

    /// The page this one is reached from, or `nil` when it hangs off the
    /// section's landing pane.
    var parent: SettingsPage? {
        switch self {
        case .controlSlots: return .media
        case .calendarSources: return .calendar
        case .localSend, .kdeConnect: return .shelf
        case .copilotKnowledgeDetail: return .copilotKnowledge
        case .copilotCallDetail: return .copilotHistory
        default: return nil
        }
    }

    /// Outermost first, ending with this page.
    var lineage: [SettingsPage] {
        (parent?.lineage ?? []) + [self]
    }

    /// The pages reached from this one, in the order it lists them.
    var children: [SettingsPage] {
        switch self {
        case .media: return [.controlSlots]
        case .calendar: return [.calendarSources]
        case .shelf: return [.localSend, .kdeConnect]
        default: return []
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .shortcuts: return "Keyboard Shortcuts"
        case .privacy: return "Privacy & Permissions"
        case .displays: return "Displays"
        case .gestures: return "Gestures"
        case .advanced: return "Window"
        case .media: return "Music"
        case .controlSlots: return "Playback Controls"
        case .calendar: return "Calendar"
        case .calendarSources: return "Calendars & Lists"
        case .shelf: return "Shelf"
        case .localSend: return "LocalSend"
        case .kdeConnect: return "KDE Connect"
        case .pomodoro: return "Focus Timer"
        case .usage: return "AI Usage"
        case .huds: return "Volume & Brightness"
        case .headerLayout: return "Header Layout"
        case .notchSize: return "Notch Size"
        case .accent: return "Accent Colour"
        case .copilotCall: return "Live Call"
        case .copilotQuiz: return "Screen Quiz"
        case .copilotModels: return "Models"
        case .copilotPrompts: return "Prompts & Personas"
        case .copilotKnowledge: return "Knowledge"
        case .copilotBackup: return "Backup"
        case .copilotHistory: return "History"
        case .copilotKnowledgeDetail: return "Details"
        case .copilotCallDetail: return "Call"
        }
    }

    var symbol: String {
        switch self {
        case .shortcuts: return "command"
        case .privacy: return "hand.raised.fill"
        case .displays: return "display.2"
        case .gestures: return "hand.draw.fill"
        case .advanced: return "macwindow"
        case .media: return "music.note"
        case .controlSlots: return "playpause.fill"
        case .calendar: return "calendar"
        case .calendarSources: return "calendar.badge.checkmark"
        case .shelf: return "tray.fill"
        case .localSend: return "antenna.radiowaves.left.and.right"
        case .kdeConnect: return "iphone.gen3.radiowaves.left.and.right"
        case .pomodoro: return "timer"
        case .usage: return "gauge.with.needle.fill"
        case .huds: return "speaker.wave.2.fill"
        case .headerLayout: return "rectangle.3.group.fill"
        case .notchSize: return "arrow.up.left.and.arrow.down.right"
        case .accent: return "paintpalette.fill"
        case .copilotCall: return "waveform.badge.mic"
        case .copilotQuiz: return "macwindow.badge.plus"
        case .copilotModels: return "brain"
        case .copilotPrompts: return "text.quote"
        case .copilotKnowledge: return "books.vertical.fill"
        case .copilotBackup: return "arrow.up.arrow.down"
        case .copilotHistory: return "clock.arrow.circlepath"
        case .copilotKnowledgeDetail: return "doc.text"
        case .copilotCallDetail: return "waveform"
        }
    }

    /// The tile colour behind the page's glyph.
    var tint: Color {
        switch self {
        case .media: return .pink
        case .calendar, .calendarSources: return .red
        case .shelf, .localSend, .kdeConnect: return .blue
        case .pomodoro: return .orange
        case .usage: return .purple
        case .huds: return .indigo
        case .copilotCall, .copilotCallDetail: return .green
        case .copilotQuiz: return .teal
        case .copilotModels: return .purple
        case .copilotPrompts: return .orange
        case .copilotKnowledge, .copilotKnowledgeDetail: return .brown
        case .copilotHistory: return .blue
        default: return .gray
        }
    }

    /// The sentence on the drill row that says what is behind it.
    var detail: LocalizedStringResource? {
        switch self {
        case .shortcuts: return "Every key combination the app answers to."
        case .privacy: return "What macOS has allowed, and what each permission unlocks."
        case .displays: return "Which screen the notch appears on."
        case .gestures: return "Swiping the notch open and closed."
        case .advanced: return "Shadow, corners, lock screen and title bar."
        case .media: return "Now Playing in the notch."
        case .controlSlots: return "Which playback buttons appear, and where."
        case .calendar: return "What is next, beside the music."
        case .calendarSources: return "Which calendars and reminder lists are shown."
        case .shelf: return "Drop files on the notch to keep them close."
        case .localSend: return "Send shelf items to other devices on the network."
        case .kdeConnect: return "Pair with a phone through KDE Connect."
        case .pomodoro: return "Focus blocks and breaks."
        case .usage: return "How much of your Claude and Codex allowance is left."
        case .huds: return "The notch's own volume and brightness overlays."
        case .headerLayout: return "What sits either side of the notch."
        case .notchSize: return "Resize the open notch and both call layouts."
        case .accent: return "The colour used for anything active or selected."
        case .copilotCall: return "What is captured and what shows in the notch."
        case .copilotQuiz: return "Answers what is on one window."
        case .copilotModels: return "Which model hears the call, and which one answers."
        case .copilotPrompts: return "Who you are, and how each kind of call is handled."
        case .copilotKnowledge: return "Files and notes the copilot reads per meeting."
        case .copilotBackup: return "Export, restore, or start over."
        case .copilotHistory: return "Past calls, transcripts and recaps."
        case .copilotKnowledgeDetail, .copilotCallDetail: return nil
        }
    }

    /// Words that should find this page in search but are not in its title.
    var keywords: [String] {
        switch self {
        case .shortcuts: return ["keyboard", "hotkey", "key"]
        case .privacy: return ["permission", "accessibility", "microphone", "screen recording", "calendar access"]
        case .displays: return ["monitor", "screen", "external"]
        case .gestures: return ["swipe", "trackpad", "scroll"]
        case .advanced: return ["shadow", "corner radius", "lock screen", "title bar", "hover area"]
        case .media: return ["music", "now playing", "spotify", "apple music", "lyrics", "sneak peek"]
        case .controlSlots: return ["playback", "buttons", "shuffle", "repeat", "next"]
        case .calendar: return ["events", "meetings", "reminders"]
        case .calendarSources: return ["reminders", "events", "ical", "google"]
        case .shelf: return ["files", "drop", "drag", "airdrop", "share"]
        case .localSend: return ["airdrop", "transfer", "share", "network"]
        case .kdeConnect: return ["phone", "android", "pair"]
        case .pomodoro: return ["pomodoro", "focus", "timer", "break"]
        case .usage: return ["claude", "codex", "quota", "allowance", "tokens", "limit"]
        case .huds: return ["volume", "brightness", "hud", "overlay"]
        case .headerLayout: return ["tabs", "slots", "left", "right", "arrange"]
        case .notchSize: return ["resize", "width", "height", "compact", "expanded"]
        case .accent: return ["colour", "color", "tint", "theme"]
        case .copilotCall: return ["meeting", "live", "zoom", "meet", "teams", "zen", "compact"]
        case .copilotQuiz: return ["quiz", "exam", "question", "screen recording"]
        case .copilotModels: return ["model", "agy", "gemini", "whisper", "speech", "transcription"]
        case .copilotPrompts: return ["persona", "about me", "guidance", "system prompt"]
        case .copilotKnowledge: return ["notes", "documents", "files", "context"]
        case .copilotBackup: return ["export", "import", "reset", "json"]
        case .copilotHistory: return ["archive", "past calls", "recap", "transcript", "speakers"]
        case .copilotKnowledgeDetail, .copilotCallDetail: return []
        }
    }

    /// A hook for pages that depend on features which can be switched off.
    /// Every page is available today.
    var availablePage: SettingsPage { self }

    /// Every page without a payload: what search indexes, and what tests walk.
    static let indexable: [SettingsPage] = [
        .shortcuts, .privacy, .displays, .gestures, .advanced,
        .media, .controlSlots, .calendar, .calendarSources,
        .shelf, .localSend, .kdeConnect,
        .pomodoro, .usage, .huds,
        .headerLayout, .notchSize, .accent,
        .copilotCall, .copilotQuiz, .copilotModels, .copilotPrompts,
        .copilotKnowledge, .copilotBackup, .copilotHistory,
    ]
}

// MARK: - The string form

extension SettingsPage {
    /// A stable, writable name for this page: `"notch.media"`,
    /// `"calls.knowledge.event:F3A1-…"`.
    var identifier: String {
        if case let .copilotKnowledgeDetail(route) = self {
            return "calls.knowledge.\(route.identifier)"
        }
        if case let .copilotCallDetail(id) = self {
            return "calls.history.call:\(id)"
        }
        return "\(section.rawValue).\(Self.stems[self] ?? "")"
    }

    init?(identifier: String) {
        if identifier.hasPrefix("calls.history.call:") {
            self = .copilotCallDetail(id: String(identifier.dropFirst("calls.history.call:".count)))
            return
        }
        if identifier.hasPrefix("calls.knowledge."),
           let route = KnowledgeRoute(identifier: String(identifier.dropFirst("calls.knowledge.".count))) {
            self = .copilotKnowledgeDetail(route)
            return
        }
        guard let match = Self.indexable.first(where: { $0.identifier == identifier }) else { return nil }
        self = match
    }

    /// The part after the section name. A table rather than a `switch` so the
    /// forward and reverse directions cannot disagree.
    private static let stems: [SettingsPage: String] = [
        .shortcuts: "shortcuts", .privacy: "privacy", .displays: "displays",
        .gestures: "gestures", .advanced: "window",
        .media: "media", .controlSlots: "control-slots",
        .calendar: "calendar", .calendarSources: "calendar-sources",
        .shelf: "shelf", .localSend: "localsend", .kdeConnect: "kde-connect",
        .pomodoro: "focus", .usage: "usage", .huds: "huds",
        .headerLayout: "header-layout", .notchSize: "notch-size", .accent: "accent",
        .copilotCall: "call", .copilotQuiz: "quiz", .copilotModels: "models",
        .copilotPrompts: "prompts", .copilotKnowledge: "knowledge",
        .copilotBackup: "backup", .copilotHistory: "history",
    ]
}

extension KnowledgeRoute {
    var identifier: String {
        switch self {
        case let .event(id): return "event:\(id)"
        case .everyCall: return "every-call"
        case .byPersona: return "by-persona"
        case .orphaned: return "orphaned"
        }
    }

    init?(identifier: String) {
        switch identifier {
        case "every-call": self = .everyCall
        case "by-persona": self = .byPersona
        case "orphaned": self = .orphaned
        default:
            guard identifier.hasPrefix("event:") else { return nil }
            self = .event(id: String(identifier.dropFirst("event:".count)))
        }
    }
}
