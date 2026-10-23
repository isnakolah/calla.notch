import Foundation

/// Rules shared by the calendar watch and the Call preflight.
public enum CalendarCallPolicy {
    public static let leadTime: TimeInterval = 120

    public static func eligible(start: Date, end: Date, now: Date,
                                accountID: String, calendarID: String,
                                enabledAccounts: Set<String>, selectedCalendars: Set<String>,
                                hasMeetingLink: Bool, declined: Bool, allDay: Bool) -> Bool {
        !declined && !allDay && hasMeetingLink && end > now
            && start <= now.addingTimeInterval(leadTime)
            && enabledAccounts.contains(accountID)
            && selectedCalendars.contains(calendarID)
    }

    /// An ambiguous title leaves the choice to the calendar default.
    public static func suggestedPersona(for title: String) -> String? {
        let matches = titleMatches(for: title)
        return matches.count == 1 ? matches[0].id : nil
    }

    /// Every call type the title names, with the phrase that named it. The
    /// ranker counts each one; `suggestedPersona` only trusts a lone match.
    public static func titleMatches(for title: String) -> [(id: String, phrase: String)] {
        let text = title.lowercased()
        let patterns: [(String, [String])] = [
            ("standup", ["standup", "stand-up", "daily scrum"]),
            ("planning", ["planning"]),
            ("refinement", ["refinement", "grooming"]),
            ("retro", ["retrospective", "retro"]),
            ("design-review", ["design review"]),
            ("incident", ["incident", "postmortem"]),
            ("one-on-one", ["1:1", "one-on-one"]),
            ("interview", ["interview"]),
            ("sales", ["sales", "demo"]),
            ("support", ["support"]),
            ("review", ["sprint review"])
        ]
        return patterns.compactMap { id, phrases in
            phrases.first { phrase in
                let pattern = "\\b\(NSRegularExpression.escapedPattern(for: phrase))\\b"
                return text.range(of: pattern, options: .regularExpression) != nil
            }.map { (id: id, phrase: $0) }
        }
    }
}
