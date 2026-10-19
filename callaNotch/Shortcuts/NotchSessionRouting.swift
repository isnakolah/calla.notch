import Foundation

/// Which live surface owns the notch right now.
///
/// The two are mutually exclusive by construction — a Quiz and a call cannot
/// run at once — which is what makes routing one key to both safe.
public enum NotchSessionSurface: String, CaseIterable, Sendable {
    case none
    case call
    case quiz
}

/// One verb the reader has during a live session.
///
/// These are *actions*, not surfaces. That is the whole change: "previous" used
/// to be three separate shortcut names — `callPreviousAnswer` ⌥⌘[,
/// `quizPreviousAnswer` ⌥⌘← and `codingPreviousMove` ⇧⌥⌘← — so the same
/// intention had three keys depending on which session happened to be running,
/// and the reader had to know which one they were in before they could press
/// anything. Shift was doing nothing but keeping two names off one Carbon
/// chord, since registering both shadowed one of them.
///
/// One name per action removes the collision and the memorising at once.
public enum NotchSessionAction: String, CaseIterable, Sendable {
    case previous
    case next
    case scrollUp
    case scrollDown
    case hold
    case ask
    case copy
    case surface
}

/// What a key press actually does, once the live surface is known.
///
/// Kept as data rather than a closure so the routing table can be read and
/// tested without touching AppKit, a notification centre or the engine.
public enum NotchSessionEffect: Equatable, Sendable {
    case callAsk
    case callToggleSurface
    case callPreviousAnswer
    case callNextAnswer

    case quizPreviousAnswer
    case quizNextAnswer
    case quizScroll(lines: Int)
    case quizCopyAnswer
    case quizTogglePause
}

/// The live session's state, as plain values.
public struct NotchSessionState: Equatable, Sendable {
    public var quizActive: Bool
    public var callLive: Bool

    public init(quizActive: Bool = false, callLive: Bool = false) {
        self.quizActive = quizActive
        self.callLive = callLive
    }
}

public enum NotchSessionRouter {
    /// How far one scroll key moves the reader. One number, both surfaces.
    public static let scrollLines = 8

    /// Quiz runs over a call's capture, so it is asked about first.
    public static func surface(for state: NotchSessionState) -> NotchSessionSurface {
        if state.quizActive { return .quiz }
        if state.callLive { return .call }
        return .none
    }

    /// The effect of an action on a surface, or `nil` when that surface has no
    /// answer for it.
    ///
    /// `nil` is deliberate and is an improvement on what it replaces: the old
    /// per-surface names fired their notification whatever was on screen, so
    /// ⌥⌘← during a Quiz still posted a call-history event into nothing.
    public static func effect(for action: NotchSessionAction,
                              on surface: NotchSessionSurface) -> NotchSessionEffect? {
        switch surface {
        case .none:
            return nil

        case .call:
            switch action {
            case .previous: return .callPreviousAnswer
            case .next: return .callNextAnswer
            case .ask: return .callAsk
            case .surface: return .callToggleSurface
            default: return nil
            }

        case .quiz:
            switch action {
            case .previous: return .quizPreviousAnswer
            case .next: return .quizNextAnswer
            case .scrollUp: return .quizScroll(lines: -scrollLines)
            case .scrollDown: return .quizScroll(lines: scrollLines)
            case .copy: return .quizCopyAnswer
            case .hold: return .quizTogglePause
            // Quiz retargets from a menu in its header, not from a key. It is
            // the one action here with no keyboard peer, and inventing one to
            // fill the table would be a shortcut nothing asked for.
            default: return nil
            }
        }
    }

    /// The actions a surface answers, in the order they are worth showing to
    /// the reader. Drives the hint row under every live panel.
    public static func hintedActions(for surface: NotchSessionSurface) -> [NotchSessionAction] {
        let order: [NotchSessionAction] = [.previous, .next, .copy, .scrollUp, .hold, .ask, .surface]
        return order.filter { effect(for: $0, on: surface) != nil }
    }
}
