import XCTest
@testable import CallaContracts

final class CallTypeRankingTests: XCTestCase {
    private let all = CallaPersonaCatalog.builtIn + ["board-review"]

    func testEveryCandidateIsRankedOnce() {
        let ranking = CallTypeRanker.rank(.init(candidates: all))
        XCTAssertEqual(ranking.ids.sorted(), all.sorted())
    }

    func testNothingKnownPicksNothingAndPutsGeneralFirst() {
        let ranking = CallTypeRanker.rank(.init(candidates: all))
        XCTAssertNil(ranking.pick)
        XCTAssertEqual(ranking.ids.first, "generic")
        XCTAssertEqual(ranking.entries.first?.band, .maybe)
        XCTAssertEqual(ranking.entries.first?.reason, "fits any call")
        XCTAssertEqual(ranking.entries.last?.band, .unlikely)
        XCTAssertNil(ranking.entries.last?.reason)
    }

    func testAConfirmedChoiceAlwaysWins() {
        let ranking = CallTypeRanker.rank(.init(candidates: all, confirmed: "retro",
                                                model: ["sales"], title: "Weekly standup", repeats: true))
        XCTAssertEqual(ranking.pick, "retro")
        XCTAssertEqual(ranking.entries.first?.band, .mostLikely)
        XCTAssertEqual(ranking.entries.first?.reason, "your choice for every one of these")
    }

    func testTitleAndModelAgreeingIsSure() {
        let ranking = CallTypeRanker.rank(.init(candidates: all, model: ["standup", "planning"],
                                                title: "Platform standup"))
        XCTAssertEqual(ranking.pick, "standup")
        XCTAssertEqual(ranking.entries.first?.reason, "the title says \u{201C}standup\u{201D}")
        XCTAssertEqual(Array(ranking.ids.prefix(2)), ["standup", "planning"])
    }

    func testCloseCallsAreNotPicked() {
        // "Weekly sync with Priya": two people, and the model leans standup.
        let ranking = CallTypeRanker.rank(.init(candidates: all, model: ["standup"],
                                                participantCount: 2, repeats: true))
        XCTAssertNil(ranking.pick)
        XCTAssertEqual(Set(ranking.ids.prefix(2)), ["standup", "one-on-one"])
        XCTAssertEqual(ranking.entry("one-on-one")?.reason, "two people, and it repeats")
        XCTAssertEqual(ranking.entry("one-on-one")?.band, .maybe)
        XCTAssertEqual(ranking.entry("standup")?.band, .likely)
    }

    func testEveryTitleMatchCounts() {
        let ranking = CallTypeRanker.rank(.init(candidates: all, title: "Standup and planning"))
        XCTAssertEqual(Set(ranking.ids.prefix(2)), ["standup", "planning"])
        XCTAssertNil(ranking.pick, "two equal title matches are a close call")
    }

    func testSimilarMeetingsCount() {
        let ranking = CallTypeRanker.rank(.init(candidates: all, similar: ["board-review": 2]))
        XCTAssertEqual(ranking.pick, "board-review")
        XCTAssertEqual(ranking.entries.first?.reason, "your choice for similar meetings")
    }

    func testAdHocHistory() {
        let ranking = CallTypeRanker.rank(.init(candidates: all, atThisTime: ["standup", "standup", "standup"],
                                                last: "standup", usage: ["standup": 9, "one-on-one": 4]))
        XCTAssertEqual(ranking.pick, "standup")
        XCTAssertEqual(ranking.entries.first?.reason, "3 of your calls at this time")
        XCTAssertEqual(ranking.ids[1], "generic")
        XCTAssertEqual(ranking.entry("one-on-one")?.reason, "one you use often")
    }

    func testOneLastCallAloneIsNotEnough() {
        let ranking = CallTypeRanker.rank(.init(candidates: all, last: "sales"))
        XCTAssertNil(ranking.pick)
        XCTAssertEqual(ranking.ids.first, "sales")
    }

    func testUnknownIdsAreIgnored() {
        let ranking = CallTypeRanker.rank(.init(candidates: all, confirmed: "deleted-type", model: ["nope"]))
        XCTAssertNil(ranking.pick)
        XCTAssertEqual(ranking.ids.count, all.count)
    }

    func testShortRepeatingGroupCallLeansStandup() {
        let ranking = CallTypeRanker.rank(.init(candidates: all, participantCount: 6, repeats: true,
                                                durationMinutes: 15))
        XCTAssertEqual(ranking.ids.first, "standup")
        XCTAssertEqual(ranking.entries.first?.reason, "short, repeating, several people")
    }

    func testTheSettingsDefaultLeansButNeverPicksAlone() {
        let ranking = CallTypeRanker.rank(.init(candidates: all, defaultType: "sales"))
        XCTAssertNil(ranking.pick)
        XCTAssertEqual(ranking.ids.first, "sales")
        XCTAssertEqual(ranking.entries.first?.reason, "your default for calendar calls")
    }

    func testAtThisTimeKeepsNearbyRecentWeekdayStarts() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
        }
        let now = date(22, 9, 50)   // Thursday
        let starts: [CallTypeRanker.Start] = [
            .init(type: "standup", at: date(21, 9, 30)),
            .init(type: "standup", at: date(20, 10, 20)),
            .init(type: "retro", at: date(20, 11, 0)),       // too far from 09:50
            .init(type: "sales", at: date(18, 9, 45)),       // a Sunday
            .init(type: "planning", at: date(1, 9, 50)),     // three weeks back is fine
            .init(type: "review", at: date(20, 9, 50).addingTimeInterval(-40 * 86_400)),
            .init(type: "incident", at: date(22, 9, 55))     // later than now
        ]
        XCTAssertEqual(CallTypeRanker.atThisTime(starts, now: now, calendar: calendar),
                       ["standup", "standup", "planning"])
    }

    func testModelReplyParsing() {
        XCTAssertEqual(CallTypeRanker.parseModelReply("Sales, support,sales, bogus", known: all),
                       ["sales", "support"])
        XCTAssertEqual(CallTypeRanker.parseModelReply("retro", known: all), ["retro"])
        XCTAssertEqual(CallTypeRanker.parseModelReply("", known: all), [])
    }

    func testTitleMatchesKeepEveryMatch() {
        let matches = CalendarCallPolicy.titleMatches(for: "Standup and planning")
        XCTAssertEqual(matches.map(\.id), ["standup", "planning"])
        XCTAssertEqual(matches.first?.phrase, "standup")
        XCTAssertTrue(CalendarCallPolicy.titleMatches(for: "Democracy update").isEmpty)
    }
}
