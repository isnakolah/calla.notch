import AppKit
import CallaContracts
import Defaults
import KeyboardShortcuts
import SwiftUI

/// Registers the live-session shortcuts and dispatches them to whichever
/// surface is running.
///
/// Everything about *which* action a key means lives in `NotchSessionRouter`,
/// which is pure and tested. This type is only the wiring: one Carbon handler
/// per action, and the side effect each routed effect performs.
@MainActor
enum NotchSessionShortcuts {
    /// One shortcut name per action.
    static let bindings: [(KeyboardShortcuts.Name, NotchSessionAction)] = [
        (.sessionPrevious, .previous),
        (.sessionNext, .next),
        (.sessionScrollUp, .scrollUp),
        (.sessionScrollDown, .scrollDown),
        (.sessionHold, .hold),
        (.sessionAsk, .ask),
        (.sessionCopy, .copy),
        (.sessionSurface, .surface)
    ]

    static func install() {
        NotchShortcutMigration.run()

        for (name, action) in bindings {
            KeyboardShortcuts.onKeyDown(for: name) {
                Task { @MainActor in perform(action) }
            }
        }
    }

    /// Which live surface a key press belongs to right now.
    static var surface: NotchSessionSurface {
        let engine = CallaEngineClient.shared
        return NotchSessionRouter.surface(for: NotchSessionState(
            quizActive: engine.status.quiz.active,
            callLive: CopilotLiveSession.shared.isLive))
    }

    /// The shortcut bound to an action, for the hint row and for `help`.
    static func name(for action: NotchSessionAction) -> KeyboardShortcuts.Name? {
        bindings.first { $0.1 == action }?.0
    }

    /// The printable chord for an action, e.g. `⌥⌘←`.
    static func chord(for action: NotchSessionAction) -> String? {
        guard let name = name(for: action) else { return nil }
        return KeyboardShortcuts.getShortcut(for: name)?.description
    }

    /// The word shown beside the chord. Deliberately the same word on every
    /// surface — that is the point of routing one key to all three.
    static func label(for action: NotchSessionAction) -> String {
        switch action {
        case .previous: return "Previous"
        case .next: return "Next"
        case .scrollUp: return "Scroll"
        case .scrollDown: return "Scroll down"
        case .hold: return "Hold"
        case .ask: return "Ask"
        case .copy: return "Copy"
        case .surface: return "History"
        }
    }

    static func perform(_ action: NotchSessionAction) {
        guard let effect = NotchSessionRouter.effect(for: action, on: surface) else { return }
        apply(effect)
    }

    private static func apply(_ effect: NotchSessionEffect) {
        let engine = CallaEngineClient.shared

        switch effect {
        case .callAsk:
            NotificationCenter.default.post(name: .callaCallAskQuestion, object: nil)
        case .callToggleSurface:
            NotificationCenter.default.post(name: .callaCallToggleSurface, object: nil)
        case .callPreviousAnswer:
            NotificationCenter.default.post(name: .callaCallPreviousAnswer, object: nil)
        case .callNextAnswer:
            NotificationCenter.default.post(name: .callaCallNextAnswer, object: nil)

        case .quizPreviousAnswer:
            let history = engine.status.quiz.answerHistory
            guard history.count > 1 else { return }
            CopilotLiveSession.shared.quizAnswerBack(history: history)
        case .quizNextAnswer:
            let history = engine.status.quiz.answerHistory
            guard history.count > 1 else { return }
            CopilotLiveSession.shared.quizAnswerForward(history: history)

        case .quizScroll(let lines):
            // One key, two meanings, decided by what Quiz is waiting for. When a
            // scroll prompt is showing, the question runs past the window edge
            // and scrolling the target is the whole point. Otherwise the reader
            // is reading an answer, and the key moves that — scrolling the
            // target then would send Quiz off to collect mid-read.
            guard let sessionID = engine.status.quiz.sessionID, engine.status.quiz.active else { return }
            if engine.status.quiz.scrollPrompt != nil {
                engine.sendQuiz(.init(sessionID: sessionID,
                                      command: lines < 0 ? .scrollUp : .scrollDown))
            } else {
                CopilotLiveSession.shared.scrollQuizAnswer(by: lines)
            }

        case .quizCopyAnswer:
            // The answer on screen, not the newest one: the reader may have
            // stepped back through the session.
            let history = engine.status.quiz.answerHistory
            guard let shown = CopilotLiveSession.shared
                .quizDisplayedAnswer(history: history), shown.verified else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(CallaQuizPresentation.copyableText(for: shown), forType: .string)

        case .quizTogglePause:
            guard let sessionID = engine.status.quiz.sessionID, engine.status.quiz.active else { return }
            let command: QuizCommandKind = engine.status.quiz.state == .paused ? .resume : .pause
            engine.sendQuiz(.init(sessionID: sessionID, command: command))
        }
    }
}
