//
//  SettingsSearchIndex.swift
//  callaNotch
//

import SwiftUI

/// What the ⌘K palette looks through.
///
/// Individual settings, not just pages: nobody searching "sneak peek" wants to
/// be dropped at the top of Music and left to find it. A setting carries the
/// anchor of the group it sits in, so choosing it opens the page scrolled to
/// that group and lit up.
enum SettingsSearchIndex {
    enum Kind { case setting, page }

    struct Match: Identifiable {
        let id: String
        let title: String
        /// Where it lives: "Music › Closed notch", or "Page".
        let context: String
        let section: SettingsSection
        let route: SettingsRoute
        let kind: Kind
    }

    private struct Entry {
        let match: Match
        let haystack: [String]
    }

    /// One setting: its name, the page and group it is in, and the words people
    /// would type for it.
    private static func setting(_ title: String, _ section: SettingsSection, _ group: String,
                                anchor: String, _ keywords: [String] = []) -> Entry {
        let page = String(localized: section.title)
        let match = Match(id: "\(anchor):\(title)", title: title, context: "\(page) › \(group)",
                          section: section, route: .init(section, focus: anchor), kind: .setting)
        return Entry(match: match, haystack: ([title, page, group] + keywords).map { $0.lowercased() })
    }

    private static let entries: [Entry] = {
        var out: [Entry] = []
        for section in SettingsSection.allCases {
            let title = String(localized: section.title)
            var words = [title] + section.keywords
            if let detail = section.detail { words.append(String(localized: detail)) }
            out.append(Entry(
                match: Match(id: section.rawValue, title: title, context: "Page", section: section,
                             route: .init(section), kind: .page),
                haystack: words.map { $0.lowercased() }))
        }
        for page in SettingsPage.indexable {
            let title = String(localized: page.title)
            let owner = String(localized: page.section.title)
            out.append(Entry(
                match: Match(id: page.identifier, title: title, context: owner, section: page.section,
                             route: .init(page: page), kind: .setting),
                haystack: ([title, owner] + page.keywords).map { $0.lowercased() }))
        }
        out += [
            setting("Live activity", .music, "Closed notch", anchor: "music.closed", ["artwork", "meter"]),
            setting("Sneak peek on new track", .music, "Closed notch", anchor: "music.closed", ["peek", "track change"]),
            setting("Hide when paused", .music, "Closed notch", anchor: "music.closed", ["timeout", "inactivity"]),
            setting("Read playback from", .music, "Source", anchor: "music.source", ["spotify", "apple music", "youtube", "controller"]),
            setting("Colour from the artwork", .music, "Player", anchor: "music.player", ["tint", "color"]),
            setting("Blur behind artwork", .music, "Player", anchor: "music.player", ["lighting"]),
            setting("Progress bar colour", .music, "Player", anchor: "music.player", ["slider"]),
            setting("Hide in full screen", .music, "Full screen", anchor: "music.fullscreen", ["fullscreen"]),

            setting("Open notch size", .appearance, "Size", anchor: "appearance.notch-size", ["resize", "width", "height"]),
            setting("Closed height", .appearance, "Size", anchor: "appearance.notch-size", ["notch height", "menu bar"]),
            setting("Shadow", .appearance, "Shape", anchor: "appearance.shape"),
            setting("Rounder corners", .appearance, "Shape", anchor: "appearance.shape", ["corner radius"]),

            setting("Hide all-day events", .calendar, "Display", anchor: "calendar.display"),
            setting("Hide completed reminders", .calendar, "Display", anchor: "calendar.display"),
            setting("Open meetings in their own app", .calendar, "Display", anchor: "calendar.display", ["zoom", "meet"]),

            setting("Copy instead of move", .shelf, "Dragging", anchor: "shelf.dragging"),
            setting("Remove after dragging out", .shelf, "Dragging", anchor: "shelf.dragging"),

            setting("Show new suggestions", .copilot, "During a call", anchor: "copilot.during", ["reveal", "peek", "answers"]),
            setting("Running summary", .copilot, "During a call", anchor: "copilot.during", ["ambient"]),
            setting("Panel transparency", .copilot, "During a call", anchor: "copilot.during", ["glass", "opacity"]),
            setting("Save calls to a folder", .copilot, "After a call", anchor: "copilot.after", ["documents", "export"]),
            setting("Keep the audio", .copilot, "After a call", anchor: "copilot.after", ["recording"]),
            setting("Recognise voices", .copilot, "After a call", anchor: "copilot.after", ["speakers", "forget", "voiceprint"]),

            setting("Speech model", .models, "Hears the call", anchor: "models.hears", ["whisper", "transcription"]),
            setting("Clean up the transcript afterwards", .models, "Hears the call", anchor: "models.hears", ["re-transcribe"]),
            setting("Google account", .models, "Answers", anchor: "models.answers", ["sign in", "agy"]),
            setting("Live tier", .models, "Answers", anchor: "models.answers", ["fast", "balanced"]),
            setting("Recap model", .models, "Answers", anchor: "models.answers", ["summary"]),
            setting("Gateway fallback", .models, "Answers", anchor: "models.fallback", ["offline"]),

            setting("Launch at login", .general, "Startup", anchor: "general.startup", ["startup"]),
            setting("Menu bar icon", .general, "Startup", anchor: "general.startup"),
            setting("Open on hover", .general, "Opening", anchor: "general.opening", ["click", "hover delay"]),
            setting("Haptic feedback", .general, "Opening", anchor: "general.opening"),
            setting("Hide from screen recording", .general, "Privacy", anchor: "general.privacy", ["capture", "share"]),
            setting("Show on the lock screen", .general, "Window", anchor: "general.window"),

            setting("Screen Recording", .permissions, "Permissions", anchor: "permissions.screenRecording", ["system audio", "capture"]),
            setting("Accessibility", .permissions, "Permissions", anchor: "permissions.accessibility", ["hud", "keys"]),
            setting("Microphone", .permissions, "Permissions", anchor: "permissions.microphone", ["mic"]),
        ]
        return out
    }()

    static func search(_ query: String) -> [Match] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }

        // Ranked, not just filtered: a title that starts with what was typed
        // beats one that merely contains it, which beats a keyword hit.
        func rank(_ entry: Entry) -> Int? {
            let title = entry.haystack[0]
            if title.hasPrefix(needle) { return 0 }
            if title.contains(needle) { return 1 }
            if entry.haystack.dropFirst().contains(where: { $0.hasPrefix(needle) }) { return 2 }
            if entry.haystack.dropFirst().contains(where: { $0.contains(needle) }) { return 3 }
            return nil
        }

        return entries
            .compactMap { entry in rank(entry).map { (entry, $0) } }
            .sorted { ($0.1, $0.0.match.title) < ($1.1, $1.0.match.title) }
            .map(\.0.match)
    }
}
