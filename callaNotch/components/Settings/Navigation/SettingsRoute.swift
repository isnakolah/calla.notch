//
//  SettingsRoute.swift
//  callaNotch
//

import Foundation

/// Where the window is: which page, which record over it, and which group on
/// it was asked for.
struct SettingsRoute: Hashable {
    var section: SettingsSection
    /// Records pushed over the page. Only knowledge files push now.
    var path: [SettingsPage]
    /// A group to scroll to and light up, or a selection the page understands
    /// (`"call:<id>"` on History). Set by search and deep links; cleared once
    /// the page has shown it.
    var focus: String?

    init(_ section: SettingsSection, _ path: [SettingsPage] = [], focus: String? = nil) {
        self.section = section
        self.path = path
        self.focus = focus
    }

    /// A named place: the section that owns it, scrolled to it.
    init(page: SettingsPage) {
        switch page {
        case .copilotKnowledgeDetail:
            self.init(.knowledge, [page])
        case let .copilotCallDetail(id):
            self.init(.history, focus: "call:\(id)")
        default:
            self.init(page.section, focus: page.anchor)
        }
    }

    /// The record on screen, or `nil` on the page itself.
    var leaf: SettingsPage? { path.last }
}

// MARK: - The string form

extension SettingsRoute {
    /// `"music"`, `"music.control-slots"`, `"knowledge.event:F3A1-…"`.
    var identifier: String {
        leaf.map(\.identifier) ?? focus.map { "\(section.rawValue).\($0)" } ?? section.rawValue
    }

    init?(identifier: String) {
        if let page = SettingsPage(identifier: identifier) {
            self.init(page: page)
            return
        }
        guard let section = SettingsSection(rawValue: identifier) else { return nil }
        self.init(section)
    }
}

// MARK: - Deep links

extension SettingsRoute {
    /// Deep links, menu items and older code still arrive as the old names.
    /// Every one lands on the page that now holds what it asked for.
    init(legacyIdentifier raw: String) {
        switch raw {
        case "Home", "home", "Notch", "notch": self = .init(.home)
        case "General", "general": self = .init(.general)
        case "Advanced", "advanced": self = .init(page: .advanced)
        case "Shortcuts", "shortcuts": self = .init(page: .shortcuts)
        case "Privacy", "privacy", "Permissions", "permissions": self = .init(.permissions)
        case "Appearance", "appearance": self = .init(.appearance)
        case "Layout", "NotchLayout", "layout": self = .init(page: .headerLayout)
        case "Media", "media", "Music", "music": self = .init(.music)
        case "Calendar", "calendar": self = .init(.calendar)
        case "HUD", "huds": self = .init(page: .huds)
        case "Usage", "usage": self = .init(.usage)
        case "Shelf", "shelf": self = .init(.shelf)
        case "Pomodoro", "pomodoro", "Focus", "focus": self = .init(.focus)
        case "Calls", "calls", "Copilot", "CallCopilot", "copilotCall", "copilot": self = .init(.copilot)
        case "Quiz", "copilotQuiz", "quiz": self = .init(.quiz)
        case "CopilotIntelligence", "copilotIntelligence", "CopilotTranscription",
             "copilotTranscription", "CopilotModels", "copilotModels", "models":
            self = .init(.models)
        case "CopilotPrompts", "copilotPrompts", "persona": self = .init(.persona)
        case "CopilotKnowledge", "copilotKnowledge", "knowledge": self = .init(.knowledge)
        case "CopilotHistory", "copilotHistory", "history": self = .init(.history)
        case "About", "about": self = .init(.about)
        default: self = SettingsRoute(identifier: raw) ?? .init(.home)
        }
    }
}
