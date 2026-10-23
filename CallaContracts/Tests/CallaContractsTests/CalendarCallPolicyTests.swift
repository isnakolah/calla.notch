import Foundation
import XCTest
@testable import CallaContracts

final class CalendarCallPolicyTests: XCTestCase {
    func testEligibleMeetingsRequireAnEnabledSelectedAccountAndLink() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func eligible(start: Date, account: String = "work", link: Bool = true,
                      declined: Bool = false) -> Bool {
            CalendarCallPolicy.eligible(
                start: start, end: now.addingTimeInterval(3600), now: now,
                accountID: account, calendarID: "team",
                enabledAccounts: ["work"], selectedCalendars: ["team"],
                hasMeetingLink: link, declined: declined, allDay: false)
        }
        XCTAssertTrue(eligible(start: now.addingTimeInterval(120)))
        XCTAssertTrue(eligible(start: now.addingTimeInterval(-30)))
        XCTAssertFalse(eligible(start: now.addingTimeInterval(121)))
        XCTAssertFalse(eligible(start: now, account: "personal"))
        XCTAssertFalse(eligible(start: now, link: false))
        XCTAssertFalse(eligible(start: now, declined: true))
        XCTAssertFalse(CalendarCallPolicy.eligible(
            start: now, end: now, now: now, accountID: "work", calendarID: "team",
            enabledAccounts: ["work"], selectedCalendars: ["team"],
            hasMeetingLink: true, declined: false, allDay: false))
        XCTAssertFalse(CalendarCallPolicy.eligible(
            start: now, end: now.addingTimeInterval(3600), now: now,
            accountID: "work", calendarID: "other",
            enabledAccounts: ["work"], selectedCalendars: ["team"],
            hasMeetingLink: true, declined: false, allDay: false))
    }

    func testTitleSuggestionIsConservative() {
        XCTAssertEqual(CalendarCallPolicy.suggestedPersona(for: "Weekly standup"), "standup")
        XCTAssertEqual(CalendarCallPolicy.suggestedPersona(for: "Sprint review"), "review")
        XCTAssertNil(CalendarCallPolicy.suggestedPersona(for: "Project check-in"))
        XCTAssertNil(CalendarCallPolicy.suggestedPersona(for: "Standup and planning"))
        XCTAssertNil(CalendarCallPolicy.suggestedPersona(for: "Democracy update"))
    }
}
