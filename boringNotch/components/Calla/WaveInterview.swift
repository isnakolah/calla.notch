//
//  WaveInterview.swift
//  boringNotch
//
//  The one meeting the live call exists for.
//
//  Every session — a scenario run this afternoon, the real thing on Monday —
//  is a session *of this meeting*. That is the whole point of pinning it here
//  rather than resolving it from the calendar: the calendar answer depends on
//  what time it is, so a rehearsal today resolved nothing and Monday would have
//  resolved something else, and the two would have retrieved different
//  knowledge and landed in different rows of History.
//
//  The project folder is deliberately *not* part of this identity. Swapping the
//  folder to try a scenario against a scratch copy must not change which
//  meeting the session belongs to.
//

import Foundation

/// The Wave part-2 spreadsheet interview, as a fixed identity.
///
/// `seriesID` and `eventID` are both synthetic. Both are carried because they
/// do different jobs downstream: `MeetingContext.scopes(persona:)` appends the
/// series *then* the event, so notes filed against the series reach every
/// session, while `CallRecords.calls(forEvent:seriesID:)` prefers the series
/// when grouping History. Neither has to exist in EventKit — nothing on this
/// path asks the calendar whether it recognises them.
enum WaveInterview {
    /// Every session of the interview. What knowledge is filed against, and
    /// what History groups on — so a rehearsal and the sitting are two sessions
    /// of one meeting, sharing everything that was prepared.
    static let seriesID = "wave-interview"
    /// The sitting itself. Keeps individual call rows joinable.
    static let eventID = "wave-interview-2026-09-07"
    /// Rehearsals. Same series, different occurrence: identical preparation and
    /// retrieval, but distinguishable afterwards — and, because an approved
    /// recap is filed at the narrowest scope its meeting has, what a rehearsal
    /// concluded cannot reach Monday by itself.
    static let rehearsalEventID = "wave-interview-rehearsal"
    static let title = "Wave interview"
    /// Part 2 of the spreadsheet interview, which is what a session is for.
    static let detail = "Spreadsheet part 2 · Angel"

    /// `live/personas/interview.md`. Pinned rather than chosen: this call is
    /// never a sales call or a support call, and offering the choice only made
    /// it possible to start the interview on the wrong guidance.
    static let persona = "interview"

    /// The `interviewProfile` value the engine switches Wave behaviour on:
    /// the wave-v1 context pack, the task ladder and the reading viewport.
    static let profileID = "wave"

    /// "This is a two-hour screenshare session" — the published spec.
    static let plannedMinutes = 120

    /// Monday, 7 September 2026, 12:00–14:00 Africa/Nairobi (09:00–11:00 UTC).
    static let startsAt: Date = date(hour: 12)
    static let endsAt: Date = date(hour: 14)

    private static func date(hour: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Africa/Nairobi") ?? .gmt
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 7
        components.hour = hour
        return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }

    /// Where the work lives, by default.
    ///
    /// A hint, not a grant: the app is sandboxed and a usable folder bookmark
    /// can only be minted from a folder the reader picks themselves. So this
    /// opens the picker in the right place and names the folder the interview
    /// expects — it cannot silently attach it.
    ///
    /// Supplied part-2 files go straight into this folder. There is no import
    /// step, which means the tree Prepare probes is the tree the session runs
    /// against, with no staged copy to diverge from it.
    static var defaultProjectFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("dev/WaveInterview/spreadsheet", isDirectory: true)
    }

    /// The scope prepared material and knowledge are filed under. Series rather
    /// than event so it applies to every session, including today's.
    static let setupScope = "series"
    static var setupScopeKey: String { seriesID }

    /// Which run this is.
    ///
    /// The interview is tomorrow, and the only way to know any of this works is
    /// to run the whole thing today. Both are sessions of the same meeting —
    /// same project, same brief, same attached material, same History group —
    /// so a rehearsal exercises exactly the path the sitting will take. What
    /// differs is that it says so, on screen and in the archive, and that its
    /// conclusions stay out of the sitting's knowledge.
    enum Session: String, CaseIterable, Identifiable, Sendable {
        case rehearsal
        case sitting

        var id: String { rawValue }

        /// Stored as a plain string; anything unrecognised is a rehearsal,
        /// because guessing wrong towards the real sitting is the costly
        /// direction.
        static func stored(_ raw: String) -> Session { Session(rawValue: raw) ?? .rehearsal }

        var eventID: String {
            switch self {
            case .rehearsal: WaveInterview.rehearsalEventID
            case .sitting: WaveInterview.eventID
            }
        }

        var title: String {
            switch self {
            case .rehearsal: "Rehearsal"
            case .sitting: "The interview"
            }
        }

        /// What the notch's context chip says, so which run this is can never be
        /// a thing you have to remember.
        var chipTitle: String {
            switch self {
            case .rehearsal: "Wave rehearsal"
            case .sitting: WaveInterview.title
            }
        }

        var detail: String {
            switch self {
            case .rehearsal: "A full run of the real thing. Marked as a rehearsal in History."
            case .sitting: WaveInterview.detail
            }
        }

        var isRehearsal: Bool { self == .rehearsal }
    }
}

/// Stored mode identities remain compatible with retained interview settings.
/// Availability controls which surfaces the current app offers.
/// Re-enable deliberately when the retained interview flow is ready for reuse.
public enum CallaFeatureAvailability {
    public static let liveCoding = false
}

public enum CallaMode: String, CaseIterable, Identifiable, Sendable {
    case interview, call, quiz

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .interview: "Interview"
        case .call: "Call"
        case .quiz: "Quiz"
        }
    }

    /// Decode legacy identities without changing saved preferences.
    /// Use `resolved` for presentation and actions.
    public static func stored(_ raw: String) -> CallaMode {
        if raw == "code" { return .interview }
        return CallaMode(rawValue: raw) ?? .interview
    }

    /// The modes actually offered, given what is switched on. Order is fixed so
    /// a segment never moves under the pointer when a setting changes.
    public static func available(plainCall: Bool, quiz: Bool) -> [CallaMode] {
        var modes: [CallaMode] = CallaFeatureAvailability.liveCoding ? [.interview] : [.call]
        if CallaFeatureAvailability.liveCoding && plainCall { modes.append(.call) }
        if quiz { modes.append(.quiz) }
        return modes
    }

    /// Unavailable selections use the default visible mode.
    public static func resolved(_ raw: String, plainCall: Bool, quiz: Bool) -> CallaMode {
        let mode = stored(raw)
        return available(plainCall: plainCall, quiz: quiz).contains(mode)
            ? mode : (CallaFeatureAvailability.liveCoding ? .interview : .call)
    }
}
