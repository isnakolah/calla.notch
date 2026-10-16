//
//  Constants.swift
//  boringNotch
//
//  Created by Richard Kunkli on 16/08/2024.
//

import Defaults
import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    static let clipboardHistoryPanel = Self("clipboardHistoryPanel", default: .init(.c, modifiers: [.shift, .command]))
    static let toggleMicrophone = Self("toggleMicrophone", default: .init(.f5, modifiers: [.function]))
    static let decreaseBacklight = Self("decreaseBacklight", default: .init(.f1, modifiers: [.command]))
    static let increaseBacklight = Self("increaseBacklight", default: .init(.f2, modifiers: [.command]))
    static let toggleSneakPeek = Self("toggleSneakPeek", default: .init(.h, modifiers: [.command, .shift]))
    static let toggleNotchOpen = Self("toggleNotchOpen", default: .init(.i, modifiers: [.command, .shift]))
    static let pomodoroStartPause = Self("pomodoroStartPause", default: .init(.t, modifiers: [.command, .shift]))
    static let pomodoroSkipPhase = Self("pomodoroSkipPhase")
    static let pomodoroStopTimer = Self("pomodoroStopTimer")

    // MARK: - The session, whichever session it is

    // These are Carbon global hotkeys like every shortcut in this file; SwiftUI's
    // local `.keyboardShortcut` is not used for them.
    //
    // One name per *action*, not per surface. Call and Quiz are mutually
    // exclusive, so ⌥⌘← is "the previous thing" in both and
    // `NotchSessionRouter` decides what that means when the key is pressed.
    //
    // The three-name-per-action arrangement this replaces had a real cost
    // beyond memorising: two names cannot share a Carbon chord — whichever
    // registered last shadowed the other — so Code navigation was pushed onto
    // ⇧⌥⌘ purely to get out of Quiz's way, and the reader paid for an
    // implementation detail with an extra modifier.
    //
    // ⌥⌘ is the live loop: what you press while someone is talking.
    static let sessionPrevious = Self("sessionPrevious", default: .init(.leftArrow, modifiers: [.option, .command]))
    static let sessionNext = Self("sessionNext", default: .init(.rightArrow, modifiers: [.option, .command]))
    static let sessionScrollUp = Self("sessionScrollUp", default: .init(.upArrow, modifiers: [.option, .command]))
    static let sessionScrollDown = Self("sessionScrollDown", default: .init(.downArrow, modifiers: [.option, .command]))
    static let sessionHold = Self("sessionHold", default: .init(.space, modifiers: [.option, .command]))
    static let sessionAsk = Self("sessionAsk", default: .init(.q, modifiers: [.option, .command]))
    static let sessionCopy = Self("sessionCopy", default: .init(.a, modifiers: [.option, .command]))
    static let sessionSurface = Self("sessionSurface", default: .init(.s, modifiers: [.option, .command]))

    /// Quiz-only: no other surface wraps anything, so this keeps its own name.
    static let quizToggleWrap = Self("quizToggleWrap", default: .init(.l, modifiers: [.shift, .option, .command]))

    // MARK: - The panel itself

    static let copilotToggleCall = Self("copilotToggleCall", default: .init(.c, modifiers: [.option, .command]))
    static let copilotToggleLayout = Self("copilotToggleLayout", default: .init(.t, modifiers: [.option, .command]))
    static let copilotDismiss = Self("copilotDismiss", default: .init(.period, modifiers: [.option, .command]))
    /// Holds the notch open, or lets it go. Shared by Call and Quiz, because the
    /// pin is a decision about the notch rather than about either session.
    static let copilotTogglePin = Self("copilotTogglePin", default: .init(.p, modifiers: [.option, .command]))
}

/// Carries a reader's customised per-surface bindings onto the unified names.
///
/// The first version of this got it wrong in a way worth recording, because the
/// trap is not obvious: `KeyboardShortcuts.Name.init` *writes its default into
/// UserDefaults* the first time the name is used. So by the time this ran, every
/// retired name had a stored value whether or not anyone had ever opened
/// Settings — and a migration that inherits "whatever is stored" therefore
/// inherits the old defaults, which is precisely what the new key layout exists
/// to replace. Hold came through as ⇧⌥⌘Space, Continue as ⇧⌥⌘↩ and Copy as
/// ⌥⌘K: the old keys, on the new names, with the reader none the wiser.
///
/// A stored value is only a *choice* if it differs from what that name shipped
/// with. That is what this compares against now, and the pass also repairs the
/// bindings the first version moved across by mistake.
enum NotchShortcutMigration {
    /// One retired name: what it was called, and the chord it shipped with.
    struct Retired {
        let name: String
        let shipped: KeyboardShortcuts.Shortcut?
        init(_ name: String, _ key: KeyboardShortcuts.Key, _ modifiers: NSEvent.ModifierFlags) {
            self.name = name
            self.shipped = KeyboardShortcuts.Shortcut(key, modifiers: modifiers)
        }
    }

    private static let liveLoop: NSEvent.ModifierFlags = [.option, .command]
    private static let reference: NSEvent.ModifierFlags = [.shift, .option, .command]

    /// New name ← the names it replaces, most specific first. A coding binding
    /// wins over Quiz's, which wins over Call's.
    static let map: [(new: KeyboardShortcuts.Name, old: [Retired])] = [
        (.sessionPrevious, [Retired("codingPreviousMove", .leftArrow, reference),
                            Retired("quizPreviousAnswer", .leftArrow, liveLoop),
                            Retired("callPreviousAnswer", .leftBracket, liveLoop)]),
        (.sessionNext, [Retired("codingNextMove", .rightArrow, reference),
                        Retired("quizNextAnswer", .rightArrow, liveLoop),
                        Retired("callNextAnswer", .rightBracket, liveLoop)]),
        (.sessionScrollUp, [Retired("codingScrollUp", .upArrow, reference),
                            Retired("quizScrollUp", .upArrow, liveLoop)]),
        (.sessionScrollDown, [Retired("codingScrollDown", .downArrow, reference),
                              Retired("quizScrollDown", .downArrow, liveLoop)]),
        (.sessionHold, [Retired("codingHold", .space, reference),
                        Retired("quizTogglePause", .space, liveLoop)]),
        (.sessionAsk, [Retired("callAskQuestion", .q, liveLoop)]),
        (.sessionCopy, [Retired("codingCopy", .k, liveLoop),
                        Retired("quizCopyAnswer", .a, liveLoop)]),
        (.sessionSurface, [Retired("callToggleSurface", .s, liveLoop)])
    ]

    private static let prefix = "KeyboardShortcuts_"

    /// Must run before the unified names are registered for key events, so the
    /// chord that ends up registered is the one this settles on.
    static func run() {
        guard Defaults[.sessionShortcutMigration] < currentVersion else { return }
        let store = UserDefaults.standard

        for entry in map {
            let shipped = Set(entry.old.compactMap(\.shipped))
            let current = KeyboardShortcuts.getShortcut(for: entry.new)

            // A binding the first pass carried across by mistake: it is one of
            // the retired defaults, which means nobody chose it.
            if let current, shipped.contains(current), current != entry.new.defaultShortcut {
                KeyboardShortcuts.reset(entry.new)
            }

            let settled = KeyboardShortcuts.getShortcut(for: entry.new)
            guard settled == entry.new.defaultShortcut else { continue }

            // A retired name's stored value is only worth carrying over if the
            // reader actually changed it from what it shipped with.
            let chosen = entry.old.first { retired in
                guard let stored = shortcut(storedFor: retired.name) else { return false }
                return stored != retired.shipped
            }
            if let chosen, let stored = store.object(forKey: prefix + chosen.name) {
                store.set(stored, forKey: prefix + entry.new.rawValue)
            }
        }

        // The old names are gone from the app, so their stored values can only
        // confuse a future reader of the defaults domain.
        for retired in map.flatMap(\.old) {
            store.removeObject(forKey: prefix + retired.name)
        }

        Defaults[.sessionShortcutMigration] = currentVersion
    }

    /// Version 1 inherited retired defaults as if they were choices; version 2
    /// puts those back and keeps only real customisations.
    static let currentVersion = 2

    private static func shortcut(storedFor name: String) -> KeyboardShortcuts.Shortcut? {
        guard let raw = UserDefaults.standard.string(forKey: prefix + name),
              let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(KeyboardShortcuts.Shortcut.self, from: data)
    }
}

extension Defaults.Keys {
    /// How far the per-surface → per-action shortcut migration has got. A
    /// version rather than a flag: the first pass shipped a bug, and the fix has
    /// to reach the installs that already ran it.
    static let sessionShortcutMigration = Key<Int>("sessionShortcutMigration", default: 0)
}
