//
//  SettingsSection.swift
//  callaNotch
//

import SwiftUI

/// The sidebar's three headed groups, plus the unheaded Home row above them.
enum SettingsGroup: String, CaseIterable, Identifiable {
    case top, notch, calls, app

    var id: String { rawValue }

    var title: LocalizedStringResource? {
        switch self {
        case .top: return nil
        case .notch: return "Notch"
        case .calls: return "Calls"
        case .app: return "App"
        }
    }

    var sections: [SettingsSection] {
        SettingsSection.allCases.filter { $0.group == self }
    }
}

/// One row in the sidebar, and one page.
///
/// Four sections with tile grids and twenty-five pages behind them meant most
/// settings were two clicks and a breadcrumb away. These are flat: every page is
/// one scroll, and what used to be a subpage — Playback Controls, Notch Size,
/// LocalSend — is a group on the page that owns it. Only records drill in: a
/// knowledge file, and a past call, which History shows beside its list.
enum SettingsSection: String, CaseIterable, Identifiable, Hashable, Codable {
    case home
    case appearance, music, calendar, shelf, focus, usage
    case copilot, models, persona, knowledge, history, quiz
    case general, permissions, about

    var id: String { rawValue }

    var group: SettingsGroup {
        switch self {
        case .home: return .top
        case .appearance, .music, .calendar, .shelf, .focus, .usage: return .notch
        case .copilot, .models, .persona, .knowledge, .history, .quiz: return .calls
        case .general, .permissions, .about: return .app
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .home: return "Home"
        case .appearance: return "Appearance"
        case .music: return "Music"
        case .calendar: return "Calendar"
        case .shelf: return "Shelf"
        case .focus: return "Focus Timer"
        case .usage: return "AI Usage"
        case .copilot: return "Copilot"
        case .models: return "Models"
        case .persona: return "Persona & Prompts"
        case .knowledge: return "Notes for Calla"
        case .history: return "Past calls"
        case .quiz: return "Screen Quiz"
        case .general: return "General"
        case .permissions: return "Permissions"
        case .about: return "About & Updates"
        }
    }

    /// Outline glyphs in the sidebar, the way a source list draws them.
    var symbol: String {
        switch self {
        case .home: return "house"
        case .appearance: return "macbook"
        case .music: return "music.note"
        case .calendar: return "calendar"
        case .shelf: return "tray"
        case .focus: return "timer"
        case .usage: return "gauge.with.needle"
        case .copilot: return "waveform"
        case .models: return "cube"
        case .persona: return "person.crop.circle"
        case .knowledge: return "books.vertical"
        case .history: return "clock.arrow.circlepath"
        case .quiz: return "macwindow"
        case .general: return "gearshape"
        case .permissions: return "checkmark.shield"
        case .about: return "info.circle"
        }
    }

    /// The glyph on a filled tile, where an outline would read as a hole.
    var filledSymbol: String {
        switch self {
        case .home: return "house.fill"
        case .shelf: return "tray.fill"
        case .usage: return "gauge.with.needle.fill"
        case .models: return "cube.fill"
        case .persona: return "person.crop.circle.fill"
        case .knowledge: return "books.vertical.fill"
        case .general: return "gearshape.fill"
        case .permissions: return "checkmark.shield.fill"
        case .about: return "info.circle.fill"
        default: return symbol
        }
    }

    /// The tile colour where a section is drawn as a filled square: Home's
    /// feature tiles and the search palette.
    var tint: Color {
        switch self {
        case .music: return Color(red: 0.76, green: 0.22, blue: 0.31)
        case .calendar: return Color(red: 0.79, green: 0.23, blue: 0.19)
        case .shelf, .permissions, .history: return Color(red: 0.12, green: 0.44, blue: 0.82)
        case .focus: return Color(red: 0.72, green: 0.43, blue: 0.0)
        case .usage, .models: return Color(red: 0.48, green: 0.31, blue: 0.82)
        case .copilot: return Color(red: 0.12, green: 0.56, blue: 0.31)
        case .persona: return Color(red: 0.72, green: 0.43, blue: 0.0)
        case .knowledge: return Color(red: 0.55, green: 0.40, blue: 0.27)
        case .quiz: return Color(red: 0.10, green: 0.55, blue: 0.58)
        case .home, .appearance, .general, .about: return Color(white: 0.30)
        }
    }

    /// The sentence under the page title.
    var detail: LocalizedStringResource? {
        switch self {
        case .home: return "What is in the notch right now, and anything that needs you."
        case .appearance: return "Size, colour and layout of the notch. Every change shows above as you make it."
        case .music: return "What is playing, in the notch. Everything about music is on this page."
        case .calendar: return "What is next, beside the music."
        case .shelf: return "Drop files on the notch to keep them close, and send them on."
        case .focus: return "Focus blocks and breaks."
        case .usage: return "How much of your Claude and Codex allowance is left."
        case .copilot: return "Listens to a call and suggests what to say next."
        case .models: return "Two jobs: one model turns the call into text, another writes the answers."
        case .persona: return "Who you are, and how each kind of call is handled."
        case .knowledge: return "Files and notes Calla uses, and when it uses them."
        case .history: return nil
        case .quiz: return "Answers what is on one window."
        case .general: return "How the app starts, how the notch opens, and where it lives."
        case .permissions: return "What macOS lets the app do, and what each one is for."
        case .about: return "Version, updates, and where the source lives."
        }
    }

    var keywords: [String] {
        switch self {
        case .home: return ["overview", "status", "features"]
        case .appearance: return ["size", "accent", "colour", "color", "layout", "shape", "hud", "theme"]
        case .music: return ["media", "now playing", "spotify", "apple music", "sneak peek"]
        case .calendar: return ["events", "meetings", "reminders"]
        case .shelf: return ["files", "drop", "airdrop", "localsend", "kde"]
        case .focus: return ["pomodoro", "timer", "break"]
        case .usage: return ["claude", "codex", "quota", "allowance", "limit"]
        case .copilot: return ["call", "meeting", "live", "suggestions"]
        case .models: return ["whisper", "speech", "gemini", "agy", "transcription"]
        case .persona: return ["prompt", "about me", "guidance", "backup", "export", "import"]
        case .knowledge: return ["knowledge", "notes", "documents", "files", "context"]
        case .history: return ["history", "transcripts", "recap", "quiz history"]
        case .quiz: return ["quiz", "exam", "question", "screen"]
        case .general: return ["launch", "login", "hover", "display", "gestures", "shortcuts", "window"]
        case .permissions: return ["privacy", "accessibility", "microphone", "screen recording", "calendar access"]
        case .about: return ["version", "update", "sparkle"]
        }
    }
}
