//
//  CallaMode.swift
//  callaNotch
//

import Foundation

/// What the copilot tab starts: a live call, or a screen quiz.
public enum CallaMode: String, CaseIterable, Identifiable, Sendable {
    case call, quiz

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .call: "Call"
        case .quiz: "Quiz"
        }
    }

    /// A stored identity from an older build — `interview`, `code` — reads as
    /// Call, which is what those builds fell back to once the interview flow
    /// was switched off.
    public static func stored(_ raw: String) -> CallaMode {
        CallaMode(rawValue: raw) ?? .call
    }

    /// The modes actually offered, in a fixed order so a segment never moves
    /// under the pointer when a setting changes.
    public static func available(quiz: Bool) -> [CallaMode] {
        quiz ? [.call, .quiz] : [.call]
    }

    /// Unavailable selections use Call.
    public static func resolved(_ raw: String, quiz: Bool) -> CallaMode {
        let mode = stored(raw)
        return available(quiz: quiz).contains(mode) ? mode : .call
    }
}
