import XCTest
@testable import NotchShortcuts

final class NotchSessionRouterTests: XCTestCase {
    /// Quiz runs over a call's capture, so it has to be asked about first.
    func testQuizOutranksACall() {
        XCTAssertEqual(NotchSessionRouter.surface(for: .init(quizActive: true, callLive: true)), .quiz)
        XCTAssertEqual(NotchSessionRouter.surface(for: .init(callLive: true)), .call)
        XCTAssertEqual(NotchSessionRouter.surface(for: .init()), .none)
    }

    /// One key, one meaning per surface, no second name to learn.
    func testPreviousAndNextMeanSomethingOnEverySurface() {
        for surface in [NotchSessionSurface.call, .quiz] {
            XCTAssertNotNil(NotchSessionRouter.effect(for: .previous, on: surface), "\(surface)")
            XCTAssertNotNil(NotchSessionRouter.effect(for: .next, on: surface), "\(surface)")
        }
    }

    func testPreviousRoutesToTheRightSurface() {
        XCTAssertEqual(NotchSessionRouter.effect(for: .previous, on: .call), .callPreviousAnswer)
        XCTAssertEqual(NotchSessionRouter.effect(for: .previous, on: .quiz), .quizPreviousAnswer)
    }

    /// Nothing live means nothing happens, rather than a notification posted
    /// into a panel that is not on screen.
    func testNoSessionAnswersNothing() {
        for action in NotchSessionAction.allCases {
            XCTAssertNil(NotchSessionRouter.effect(for: action, on: .none), "\(action)")
        }
    }

    func testQuizScrollDirectionsAreOppositeAndEqual() {
        let up = NotchSessionRouter.effect(for: .scrollUp, on: .quiz)
        let down = NotchSessionRouter.effect(for: .scrollDown, on: .quiz)
        guard case let .quizScroll(a) = up, case let .quizScroll(b) = down else {
            return XCTFail("Quiz should scroll both ways")
        }
        XCTAssertEqual(a, -b)
        XCTAssertEqual(abs(a), NotchSessionRouter.scrollLines)
    }

    func testACallHasNoScrollOrHold() {
        for action in [NotchSessionAction.scrollUp, .scrollDown, .hold] {
            XCTAssertNil(NotchSessionRouter.effect(for: action, on: .call), "\(action)")
        }
    }

    /// Every action reaches at least one surface. One that reached none would
    /// be a shortcut the reader can bind and press to no effect at all.
    func testEveryActionIsReachable() {
        for action in NotchSessionAction.allCases {
            let reached = [NotchSessionSurface.call, .quiz]
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
    /// decision: navigation before reading.
    func testHintsLeadWithNavigation() {
        XCTAssertEqual(Array(NotchSessionRouter.hintedActions(for: .quiz).prefix(3)),
                       [.previous, .next, .copy])
    }
}
