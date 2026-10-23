//
//  CallaCopilotTabView.swift
//  callaNotch
//
//  The copilot at rest, in the notch.
//
//  A pre-flight check rather than a settings page, because that is the question
//  people bring to it thirty seconds before a call: *will this work?* A copilot
//  that starts and then silently hears only one side is worse than one that
//  refuses to start, so the panel shows what is armed before it offers to begin,
//  and the primary control names whatever is missing instead of always saying
//  "start".
//
//  One card, two columns: the verdict on the left, the four facts behind it on
//  the right. An earlier pass put those facts in a grid *under* the verdict and
//  the whole second row fell through the notch's lower curve — 168pt does not
//  hold three stacked bands, which is why the tab-naming row is gone too.
//

import AppKit
import CallaContracts
import Defaults
import KeyboardShortcuts
import SwiftUI

/// The copilot at rest: a live call, or a screen quiz.
struct CallaCopilotTabView: View {
    @ObservedObject private var engine = CallaEngineClient.shared
    @Default(.callaQuizEnabled) private var quizEnabled
    @Default(.callaCopilotMode) private var selectedMode

    var body: some View {
        Group {
            // Resolved rather than read: a mode whose setting has since been
            // switched off must not leave the notch on a surface the switcher
            // no longer offers a way back from.
            switch CallaMode.resolved(selectedMode, quiz: quizEnabled) {
            case .quiz: CallaQuizPreflightView()
            case .call: CallaCallPreflightView()
            }
        }
        .task {
            engine.start()
            engine.startMonitoring()
        }
    }
}

/// The personas a call can start with, and their display names. The list and
/// its groups live in `CallaPersonaCatalog`, which the engine also reads.
enum CallaCopilotPersona {
    static let builtIn = CallaPersonaCatalog.builtIn
    static let all = builtIn
    static let groups = CallaPersonaCatalog.groups

    /// The built-ins plus whatever the user added, in a stable order.
    static func all(including custom: [String]) -> [String] {
        builtIn + custom.filter { !builtIn.contains($0) }.sorted()
    }

    /// Groups for a menu, with user-defined personas last under their own title.
    static func grouped(including custom: [String]) -> [(title: String, ids: [String])] {
        let extra = custom.filter { !builtIn.contains($0) }.sorted()
        return extra.isEmpty ? groups : groups + [("Your personas", extra)]
    }

    static func title(_ value: String) -> String { CallaPersonaCatalog.title(value) }

    /// What the type makes Calla listen for, short enough to follow "listens
    /// for" on one line of the notch. Drawn from each type's prompt.
    static func listensFor(_ value: String) -> String {
        switch value {
        case "standup": "status, blockers and who owns them"
        case "planning": "scope, estimates and what fits"
        case "refinement": "acceptance criteria and edge cases"
        case "review": "what shipped versus what is planned"
        case "retro": "what went well, what hurt, owned actions"
        case "design-review": "the approach, the alternative, assumptions"
        case "incident": "timeline, impact and root cause"
        case "generic": "plain notes on what was said"
        case "one-on-one": "goals, feedback and follow-ups"
        case "interview": "claims and the evidence behind them"
        case "sales": "pricing, terms and commitments as said"
        case "support": "repro, reach and the next step"
        default: "the guidance you wrote for it"
        }
    }

    /// Ids the user may create. Kept allowlist-shaped even though the guidance
    /// body is free text: an id can end up naming things, a paragraph cannot.
    static func isValidCustomID(_ value: String) -> Bool {
        !builtIn.contains(value)
            && value.range(of: "^[a-z0-9-]{1,24}$", options: .regularExpression) != nil
    }
}
