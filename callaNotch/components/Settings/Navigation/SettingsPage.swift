//
//  SettingsPage.swift
//  callaNotch
//

import SwiftUI

/// A named place inside a section.
///
/// Most of these used to be pages of their own. They are groups on their
/// section's page now, and the case survives as an *anchor*: deep links, the
/// header items and the search palette still name them, and arriving at one
/// scrolls its section to that group and lights it up.
///
/// Two are still destinations, because they are records rather than settings:
/// a knowledge file, pushed over Knowledge, and a past call, which History
/// selects beside its list instead of pushing.
enum SettingsPage: Hashable {
    case shortcuts, privacy, displays, gestures, advanced
    case media, controlSlots, calendar, calendarSources
    case shelf, localSend, kdeConnect
    case pomodoro, usage, huds
    case headerLayout, notchSize, accent
    case copilotCall, copilotQuiz, copilotModels, copilotPrompts
    case copilotKnowledge, copilotBackup, copilotHistory
    case copilotKnowledgeDetail(KnowledgeRoute)
    case copilotCallDetail(id: String)

    /// The sidebar row this lives under.
    var section: SettingsSection {
        switch self {
        case .shortcuts, .displays, .gestures, .advanced: return .general
        case .privacy: return .permissions
        case .media, .controlSlots: return .music
        case .calendar, .calendarSources: return .calendar
        case .shelf, .localSend, .kdeConnect: return .shelf
        case .pomodoro: return .focus
        case .usage: return .usage
        case .huds, .headerLayout, .notchSize, .accent: return .appearance
        case .copilotCall: return .copilot
        case .copilotQuiz: return .quiz
        case .copilotModels: return .models
        case .copilotPrompts, .copilotBackup: return .persona
        case .copilotKnowledge, .copilotKnowledgeDetail: return .knowledge
        case .copilotHistory, .copilotCallDetail: return .history
        }
    }

    /// The group on the section's page that this names, or `nil` when the
    /// page *is* the section and there is nothing to scroll to.
    var anchor: String? {
        switch self {
        case .media, .calendar, .shelf, .pomodoro, .usage, .privacy,
             .copilotCall, .copilotQuiz, .copilotModels, .copilotPrompts,
             .copilotKnowledge, .copilotHistory,
             .copilotKnowledgeDetail, .copilotCallDetail:
            return nil
        default:
            return identifier
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .shortcuts: return "Keyboard Shortcuts"
        case .privacy: return "Permissions"
        case .displays: return "Displays"
        case .gestures: return "Gestures"
        case .advanced: return "Window"
        case .media: return "Music"
        case .controlSlots: return "Playback Buttons"
        case .calendar: return "Calendar"
        case .calendarSources: return "Calendars & Lists"
        case .shelf: return "Shelf"
        case .localSend: return "LocalSend"
        case .kdeConnect: return "KDE Connect"
        case .pomodoro: return "Focus Timer"
        case .usage: return "AI Usage"
        case .huds: return "Volume & Brightness"
        case .headerLayout: return "Either Side of the Notch"
        case .notchSize: return "Size"
        case .accent: return "Accent Colour"
        case .copilotCall: return "Calls"
        case .copilotQuiz: return "Screen Quiz"
        case .copilotModels: return "Models"
        case .copilotPrompts: return "Persona & Prompts"
        case .copilotKnowledge: return "Notes for Calla"
        case .copilotBackup: return "Backup"
        case .copilotHistory: return "Past calls"
        case .copilotKnowledgeDetail: return "Details"
        case .copilotCallDetail: return "Call"
        }
    }

    var symbol: String {
        switch self {
        case .shortcuts: return "command"
        case .privacy: return "checkmark.shield"
        case .displays: return "display.2"
        case .gestures: return "hand.draw"
        case .advanced: return "macwindow"
        case .media: return "music.note"
        case .controlSlots: return "playpause"
        case .calendar: return "calendar"
        case .calendarSources: return "calendar.badge.checkmark"
        case .shelf: return "tray"
        case .localSend: return "antenna.radiowaves.left.and.right"
        case .kdeConnect: return "iphone.gen3.radiowaves.left.and.right"
        case .pomodoro: return "timer"
        case .usage: return "gauge.with.needle"
        case .huds: return "speaker.wave.2"
        case .headerLayout: return "rectangle.3.group"
        case .notchSize: return "arrow.up.left.and.arrow.down.right"
        case .accent: return "paintpalette"
        case .copilotCall: return "waveform"
        case .copilotQuiz: return "macwindow"
        case .copilotModels: return "cube"
        case .copilotPrompts: return "person.crop.circle"
        case .copilotKnowledge: return "books.vertical"
        case .copilotBackup: return "arrow.up.arrow.down"
        case .copilotHistory: return "clock.arrow.circlepath"
        case .copilotKnowledgeDetail: return "doc.text"
        case .copilotCallDetail: return "waveform"
        }
    }

    /// Search keywords: the words someone would actually type for this group.
    var keywords: [String] {
        switch self {
        case .shortcuts: return ["keyboard", "hotkey", "key"]
        case .privacy: return ["permission", "accessibility", "microphone", "screen recording"]
        case .displays: return ["monitor", "screen", "external"]
        case .gestures: return ["swipe", "trackpad", "scroll"]
        case .advanced: return ["hover area", "lock screen", "title bar"]
        case .media: return ["music", "now playing"]
        case .controlSlots: return ["playback", "buttons", "shuffle", "repeat", "next", "previous"]
        case .calendar: return ["events", "meetings"]
        case .calendarSources: return ["reminders", "events", "ical", "google", "lists"]
        case .shelf: return ["files", "drop"]
        case .localSend: return ["airdrop", "transfer", "share", "network"]
        case .kdeConnect: return ["phone", "android", "pair"]
        case .pomodoro: return ["pomodoro", "focus", "break"]
        case .usage: return ["claude", "codex", "quota"]
        case .huds: return ["volume", "brightness", "hud", "overlay"]
        case .headerLayout: return ["header", "tabs", "slots", "left", "right", "arrange"]
        case .notchSize: return ["resize", "width", "height", "compact", "expanded", "notch height"]
        case .accent: return ["colour", "color", "tint", "theme"]
        case .copilotCall: return ["meeting", "live"]
        case .copilotQuiz: return ["quiz", "exam"]
        case .copilotModels: return ["model", "whisper", "gemini"]
        case .copilotPrompts: return ["persona", "prompt"]
        case .copilotKnowledge: return ["knowledge", "notes", "documents"]
        case .copilotBackup: return ["export", "import", "reset", "json"]
        case .copilotHistory: return ["archive", "history"]
        case .copilotKnowledgeDetail, .copilotCallDetail: return []
        }
    }

    /// Every payload-free page that names a group, for search.
    static let indexable: [SettingsPage] = [
        .shortcuts, .displays, .gestures, .advanced,
        .controlSlots, .calendarSources,
        .localSend, .kdeConnect,
        .huds, .headerLayout, .notchSize, .accent,
        .copilotBackup,
    ]

    /// Every payload-free page, for parsing identifiers.
    private static let all: [SettingsPage] = [
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
    /// `"music.control-slots"`, `"knowledge.event:F3A1-…"`.
    var identifier: String {
        if case let .copilotKnowledgeDetail(route) = self {
            return "knowledge.\(route.identifier)"
        }
        if case let .copilotCallDetail(id) = self {
            return "history.call:\(id)"
        }
        return "\(section.rawValue).\(Self.stems[self] ?? "")"
    }

    init?(identifier: String) {
        if identifier.hasPrefix("history.call:") {
            self = .copilotCallDetail(id: String(identifier.dropFirst("history.call:".count)))
            return
        }
        if identifier.hasPrefix("knowledge."),
           let route = KnowledgeRoute(identifier: String(identifier.dropFirst("knowledge.".count))) {
            self = .copilotKnowledgeDetail(route)
            return
        }
        guard let match = Self.all.first(where: { $0.identifier == identifier }) else { return nil }
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
