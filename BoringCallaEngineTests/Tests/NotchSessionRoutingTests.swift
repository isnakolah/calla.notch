import XCTest
@testable import NotchShortcuts

final class NotchSessionRouterTests: XCTestCase {
    /// A coding interview is a call underneath, so it has to be asked about
    /// first or every coding key would route to the plain call surface.
    func testCodingOutranksQuizWhichOutranksACall() {
        XCTAssertEqual(NotchSessionRouter.surface(for: .init(codingActive: true, quizActive: true, callLive: true)), .coding)
        XCTAssertEqual(NotchSessionRouter.surface(for: .init(quizActive: true, callLive: true)), .quiz)
        XCTAssertEqual(NotchSessionRouter.surface(for: .init(callLive: true)), .call)
        XCTAssertEqual(NotchSessionRouter.surface(for: .init()), .none)
    }

    /// The point of the whole change: one key, one meaning per surface, no
    /// second name to learn.
    func testPreviousAndNextMeanSomethingOnEverySurface() {
        for surface in [NotchSessionSurface.call, .quiz, .coding] {
            XCTAssertNotNil(NotchSessionRouter.effect(for: .previous, on: surface), "\(surface)")
            XCTAssertNotNil(NotchSessionRouter.effect(for: .next, on: surface), "\(surface)")
        }
    }

    func testPreviousRoutesToTheRightSurface() {
        XCTAssertEqual(NotchSessionRouter.effect(for: .previous, on: .call), .callPreviousAnswer)
        XCTAssertEqual(NotchSessionRouter.effect(for: .previous, on: .quiz), .quizPreviousAnswer)
        XCTAssertEqual(NotchSessionRouter.effect(for: .previous, on: .coding), .codingPrevious)
    }

    /// Nothing live means nothing happens, rather than a notification posted
    /// into a panel that is not on screen.
    func testNoSessionAnswersNothing() {
        for action in NotchSessionAction.allCases {
            XCTAssertNil(NotchSessionRouter.effect(for: action, on: .none), "\(action)")
        }
    }

    /// The coding viewport listens on the call's own notifications for these
    /// two, so they must route to the call effects.
    func testAskAndHistoryUseTheCallNotificationsUnderCoding() {
        XCTAssertEqual(NotchSessionRouter.effect(for: .ask, on: .coding), .callAsk)
        XCTAssertEqual(NotchSessionRouter.effect(for: .surface, on: .coding), .callToggleSurface)
    }

    func testScrollDirectionsAreOppositeAndEqual() {
        for surface in [NotchSessionSurface.quiz, .coding] {
            let up = NotchSessionRouter.effect(for: .scrollUp, on: surface)
            let down = NotchSessionRouter.effect(for: .scrollDown, on: surface)
            switch (up, down) {
            case (.quizScroll(let a), .quizScroll(let b)), (.codingScroll(let a), .codingScroll(let b)):
                XCTAssertEqual(a, -b)
                XCTAssertEqual(abs(a), NotchSessionRouter.scrollLines)
            default:
                XCTFail("\(surface) should scroll both ways")
            }
        }
    }

    func testACallHasNoScrollRunOrHold() {
        for action in [NotchSessionAction.scrollUp, .scrollDown, .run, .hold, .advance] {
            XCTAssertNil(NotchSessionRouter.effect(for: action, on: .call), "\(action)")
        }
    }

    /// Quiz retargets from a menu, and no key was invented to fill the table.
    func testQuizHasNoTargetKey() {
        XCTAssertNil(NotchSessionRouter.effect(for: .target, on: .quiz))
        XCTAssertEqual(NotchSessionRouter.effect(for: .target, on: .coding), .codingAction("window"))
    }

    /// Every action reaches at least one surface. One that reached none would
    /// be a shortcut the reader can bind and press to no effect at all.
    func testEveryActionIsReachable() {
        for action in NotchSessionAction.allCases {
            let reached = [NotchSessionSurface.call, .quiz, .coding]
                .contains { NotchSessionRouter.effect(for: action, on: $0) != nil }
            XCTAssertTrue(reached, "\(action) reaches no surface")
        }
    }

    func testHintsOnlyListWhatTheSurfaceAnswers() {
        for surface in NotchSessionSurface.allCases {
            for action in NotchSessionRouter.hintedActions(for: surface) {
                XCTAssertNotNil(NotchSessionRouter.effect(for: action, on: surface),
                                "\(surface) hints \(action) but does not answer it")
            }
        }
        XCTAssertTrue(NotchSessionRouter.hintedActions(for: .none).isEmpty)
        XCTAssertEqual(NotchSessionRouter.hintedActions(for: .call), [.previous, .next, .ask, .surface])
    }

    /// The hint row shows a handful, so the order it draws them in is a
    /// decision: navigation before reading, reading before reference.
    func testHintsLeadWithNavigation() {
        XCTAssertEqual(Array(NotchSessionRouter.hintedActions(for: .coding).prefix(3)),
                       [.previous, .next, .copy])
    }
}
