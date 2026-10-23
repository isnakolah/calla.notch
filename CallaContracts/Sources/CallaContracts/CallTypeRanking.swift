import Foundation

/// Orders every call type by how likely it is for one call, with a reason.
///
/// The notch shows the top three and the picker the whole list, both in this
/// order, so a call type is something the reader confirms rather than looks up.
/// The rule that decides whether Start may go ahead without asking lives here
/// too: a pick is only made when one type is clearly ahead of the rest.
public enum CallTypeRanker {
    /// What is known about the call. Everything is optional: an ad-hoc call
    /// has no title, guests or model guess, only the reader's own history.
    public struct Signals: Equatable, Sendable {
        /// Every type that can be chosen, built-in and the reader's own, in menu order.
        public var candidates: [String]
        /// Chosen by the reader for this occurrence or its series.
        public var confirmed: String?
        /// The reader's choices for other meetings sharing a guest or a title word.
        public var similar: [String: Int]
        /// The model's reading of the invite, best first.
        public var model: [String]
        public var title: String?
        /// Everyone invited, the reader included.
        public var participantCount: Int?
        public var repeats: Bool
        public var durationMinutes: Int?
        /// Types the reader started at about this time of day, most recent first.
        public var atThisTime: [String]
        /// The type of the reader's last call.
        public var last: String?
        /// How many calls the reader has started with each type.
        public var usage: [String: Int]
        /// The reader's default for calendar calls, from Settings.
        public var defaultType: String?

        public init(candidates: [String], confirmed: String? = nil, similar: [String: Int] = [:],
                    model: [String] = [], title: String? = nil, participantCount: Int? = nil,
                    repeats: Bool = false, durationMinutes: Int? = nil, atThisTime: [String] = [],
                    last: String? = nil, usage: [String: Int] = [:], defaultType: String? = nil) {
            self.candidates = candidates
            self.confirmed = confirmed
            self.similar = similar
            self.model = model
            self.title = title
            self.participantCount = participantCount
            self.repeats = repeats
            self.durationMinutes = durationMinutes
            self.atThisTime = atThisTime
            self.last = last
            self.usage = usage
            self.defaultType = defaultType
        }
    }

    public enum Band: String, Equatable, Sendable {
        case mostLikely, likely, maybe, unlikely

        public var label: String? {
            switch self {
            case .mostLikely: "Most likely"
            case .likely: "Likely"
            case .maybe: "Maybe"
            case .unlikely: nil
            }
        }
    }

    public struct Entry: Equatable, Sendable {
        public let id: String
        public let band: Band
        /// Why it is where it is, lower case so it can follow the type's name.
        /// Nil when nothing points at it.
        public let reason: String?
        let score: Int
    }

    public struct Ranking: Equatable, Sendable {
        /// Every candidate, most likely first.
        public let entries: [Entry]
        /// The type Start may use without asking. Nil when nothing is clearly ahead.
        public let pick: String?

        public var ids: [String] { entries.map(\.id) }
        public func entry(_ id: String) -> Entry? { entries.first { $0.id == id } }
    }

    /// A pick needs this much evidence and this much of a lead.
    static let pickScore = 30
    static let pickLead = 15

    public static func rank(_ signals: Signals) -> Ranking {
        var scores: [String: Int] = [:]
        var reasons: [String: (weight: Int, text: String)] = [:]
        func add(_ id: String, _ weight: Int, _ reason: String) {
            guard signals.candidates.contains(id), weight > 0 else { return }
            scores[id, default: 0] += weight
            if weight > (reasons[id]?.weight ?? 0) { reasons[id] = (weight, reason) }
        }

        if let confirmed = signals.confirmed {
            add(confirmed, 100, signals.repeats ? "your choice for every one of these" : "your choice for this meeting")
        }
        for (id, count) in signals.similar where count > 0 {
            add(id, 20 + 6 * min(count, 5), count == 1 ? "your choice for a similar meeting" : "your choice for similar meetings")
        }
        for (index, id) in signals.model.prefix(3).enumerated() {
            add(id, [30, 14, 7][index], "from the invite")
        }
        if let title = signals.title {
            for match in CalendarCallPolicy.titleMatches(for: title) {
                add(match.id, 35, "the title says \u{201C}\(match.phrase)\u{201D}")
            }
        }
        if let people = signals.participantCount {
            if people == 2 {
                add("one-on-one", 20, signals.repeats ? "two people, and it repeats" : "two people")
            } else if people > 2, signals.repeats, let minutes = signals.durationMinutes, minutes <= 20 {
                add("standup", 20, "short, repeating, several people")
            }
        }
        let timed = Dictionary(signals.atThisTime.map { ($0, 1) }, uniquingKeysWith: +)
        for (id, count) in timed {
            add(id, 12 * min(count, 3), count == 1 ? "you started one at this time" : "\(count) of your calls at this time")
        }
        if let last = signals.last { add(last, 12, "your last call") }
        for (id, count) in signals.usage where count >= 3 {
            add(id, min(count, 10), "one you use often")
        }
        if let defaultType = signals.defaultType { add(defaultType, 10, "your default for calendar calls") }
        add("generic", 5, "fits any call")

        let order = Dictionary(signals.candidates.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let sorted = signals.candidates.sorted { lhs, rhs in
            let (l, r) = (scores[lhs] ?? 0, scores[rhs] ?? 0)
            return l != r ? l > r : (order[lhs] ?? 0) < (order[rhs] ?? 0)
        }
        let top = sorted.first.map { scores[$0] ?? 0 } ?? 0
        let second = sorted.dropFirst().first.map { scores[$0] ?? 0 } ?? 0
        let confirmedTop = signals.confirmed != nil && sorted.first == signals.confirmed
        let sure = confirmedTop || (top >= pickScore && top - second >= pickLead)

        let entries = sorted.enumerated().map { index, id -> Entry in
            let score = scores[id] ?? 0
            let band: Band
            if index == 0, sure { band = .mostLikely }
            else if score >= 25 { band = .likely }
            else if score >= 5 { band = .maybe }
            else { band = .unlikely }
            return Entry(id: id, band: band, reason: reasons[id]?.text, score: score)
        }
        return Ranking(entries: entries, pick: sure ? sorted.first : nil)
    }

    /// One call the reader started, for the history signals.
    public struct Start: Codable, Equatable, Sendable {
        public let type: String
        public let at: Date
        public init(type: String, at: Date) {
            self.type = type
            self.at = at
        }
    }

    /// Types started within `window` of this time of day over the last four
    /// weeks, most recent first. Weekends and weekdays are kept apart: a
    /// Saturday call says little about a Tuesday one.
    public static func atThisTime(_ starts: [Start], now: Date, window: TimeInterval = 45 * 60,
                                  calendar: Calendar = .current) -> [String] {
        let minute = { (date: Date) -> Int in
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        }
        let nowMinute = minute(now)
        let weekend = calendar.isDateInWeekend(now)
        let reach = Int(window / 60)
        return starts
            .filter { start in
                guard start.at <= now, now.timeIntervalSince(start.at) < 28 * 86_400,
                      calendar.isDateInWeekend(start.at) == weekend else { return false }
                let gap = abs(minute(start.at) - nowMinute)
                return min(gap, 1_440 - gap) <= reach
            }
            .sorted { $0.at > $1.at }
            .map(\.type)
    }

    /// A model reply, either a comma-separated list or a single id, kept to known ids.
    public static func parseModelReply(_ text: String, known: [String]) -> [String] {
        var seen = Set<String>()
        return text.lowercased()
            .split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { known.contains($0) && seen.insert($0).inserted }
    }
}
