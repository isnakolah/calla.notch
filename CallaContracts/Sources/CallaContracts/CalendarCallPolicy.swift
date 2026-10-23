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
        let matches = patterns.filter { entry in
            entry.1.contains { phrase in
                let pattern = "\\b\(NSRegularExpression.escapedPattern(for: phrase))\\b"
                return text.range(of: pattern, options: .regularExpression) != nil
            }
        }
        return matches.count == 1 ? matches[0].0 : nil
    }
}
