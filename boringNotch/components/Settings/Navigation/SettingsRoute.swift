//
//  SettingsRoute.swift
//  boringNotch
//

import Foundation

/// Where the window is: which section, and how far into it.
struct SettingsRoute: Hashable {
    var section: SettingsSection
    var path: [SettingsPage]

    init(_ section: SettingsSection, _ path: [SettingsPage] = []) {
        self.section = section
        self.path = path.map(\.availablePage)
    }

    /// A page, with every page above it in the trail.
    init(_ page: SettingsPage) {
        self.init(page.section, page.lineage)
    }

    /// The page actually on screen, or `nil` at a section's landing pane.
    var leaf: SettingsPage? { path.last }

    /// The trail, outermost first.
    var crumbs: [LocalizedStringResource] { [section.title] + path.map(\.title) }
}

// MARK: - The string form

extension SettingsRoute {
    /// `"notch"`, `"notch.media"`, `"calls.knowledge.event:F3A1-…"`.
    var identifier: String {
        leaf.map(\.identifier) ?? section.rawValue
    }

    init?(identifier: String) {
        if let page = SettingsPage(identifier: identifier) {
            self.init(page)
            return
        }
        guard let section = SettingsSection(rawValue: identifier) else { return nil }
        self.init(section)
    }
}

// MARK: - Deep links

extension SettingsRoute {
    /// Deep links, menu items and older code still arrive as the old names.
    /// Every one lands somewhere that holds what it asked for; names of
    /// features that were removed land on the section that used to hold them.
    init(legacyIdentifier raw: String) {
        switch raw {
        case "General", "general": self = .init(.general)
        case "Advanced", "advanced": self = .init(.advanced)
        case "Shortcuts", "shortcuts": self = .init(.shortcuts)
        case "Privacy", "privacy": self = .init(.privacy)
        case "Appearance", "appearance", "Notch", "notch": self = .init(.notch)
        case "Layout", "NotchLayout", "layout": self = .init(.headerLayout)
        case "Media", "media": self = .init(.media)
        case "Calendar", "calendar": self = .init(.calendar)
        case "HUD", "huds": self = .init(.huds)
        case "Usage", "usage": self = .init(.usage)
        case "Shelf", "shelf": self = .init(.shelf)
        case "Pomodoro", "pomodoro": self = .init(.pomodoro)
        case "Calls", "calls": self = .init(.calls)
        case "Copilot", "CallCopilot", "copilotCall": self = .init(.copilotCall)
        case "Quiz", "copilotQuiz": self = .init(.copilotQuiz)
        case "CopilotIntelligence", "copilotIntelligence", "CopilotTranscription",
             "copilotTranscription", "CopilotModels", "copilotModels":
            self = .init(.copilotModels)
        case "CopilotPrompts", "copilotPrompts": self = .init(.copilotPrompts)
        case "CopilotKnowledge", "copilotKnowledge": self = .init(.copilotKnowledge)
        case "CopilotHistory", "copilotHistory": self = .init(.copilotHistory)
        case "About", "about": self = .init(.about)
        default: self = SettingsRoute(identifier: raw) ?? .init(.general)
        }
    }
}
