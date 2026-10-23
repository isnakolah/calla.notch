import XCTest
@testable import CallaNotchPresentation
@testable import NotchSizing

/// The call's closed notch, the approach of a meeting, the hover peek and the
/// floating window. Each test pins a product decision from the redesign.
final class ClosedCallLineTests: XCTestCase {
    func testListeningSaysSoAndPeeksWhereItStands() {
        let line = CallaCopilotPresentation.closedLine(
            mode: .listening, floating: false, elapsed: "6:12",
            latestStanding: "Finance needs the security letter before signing.",
            answerHeadline: nil, catchingUp: false)
        XCTAssertEqual(line.lead, "Listening")
        XCTAssertEqual(line.trail, "6:12")
        XCTAssertEqual(line.peek, "Finance needs the security letter before signing.")
        XCTAssertEqual(line.peekHint, "Click to open")
    }

    /// Before the first summary there is still something true to say.
    func testAnEarlyCallPeeksThatNothingIsNeeded() {
        let line = CallaCopilotPresentation.closedLine(
            mode: .listening, floating: false, elapsed: nil,
            latestStanding: nil, answerHeadline: nil, catchingUp: false)
        XCTAssertEqual(line.trail, "0:00")
        XCTAssertEqual(line.peek, "Hearing you and them. Nothing to do.")
    }

    func testOnlyHearingYouIsAWarningWithAFix() {
        let line = CallaCopilotPresentation.closedLine(
            mode: .halfDeaf, floating: false, elapsed: "1:00",
            latestStanding: "Anything", answerHeadline: nil, catchingUp: false)
        XCTAssertEqual(line.lead, "Only you")
        XCTAssertEqual(line.tone, .warning)
        XCTAssertEqual(line.peekHint, "Click to fix it")
    }

    /// The peek is the answer itself, cut to one line.
    func testAnAnswerPeeksAsOneLine() {
        let long = String(repeating: "Hold at eight percent and offer the credit ", count: 4)
        let line = CallaCopilotPresentation.closedLine(
            mode: .suggesting, floating: false, elapsed: "6:41",
            latestStanding: nil, answerHeadline: long, catchingUp: false)
        XCTAssertEqual(line.lead, "Answer ready")
        XCTAssertTrue(line.peek.hasSuffix("…"))
        XCTAssertLessThanOrEqual(line.peek.count, 71)
    }

    /// When the panel floats, the notch says where it went.
    func testFloatingReplacesTheClock() {
        let line = CallaCopilotPresentation.closedLine(
            mode: .listening, floating: true, elapsed: "6:12",
            latestStanding: "x", answerHeadline: nil, catchingUp: false)
        XCTAssertEqual(line.trail, "Floating")
        XCTAssertEqual(line.peekHint, "Click to bring it back into the notch")
    }
}

final class MeetingApproachTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private var end: Date { start.addingTimeInterval(1800) }

    private func phase(minutes: Double, joined: Bool = false) -> MeetingApproach.Phase? {
        MeetingApproach.phase(start: start, end: end,
                              now: start.addingTimeInterval(minutes * 60), joined: joined)
    }

    func testSilentUntilAQuarterOfAnHourOut() {
        XCTAssertNil(phase(minutes: -16))
        XCTAssertEqual(phase(minutes: -15), .quiet)
        XCTAssertEqual(phase(minutes: -3), .quiet)
    }

    func testGetReadyForTheLastTwoMinutes() {
        XCTAssertEqual(phase(minutes: -2), .getReady)
        XCTAssertEqual(phase(minutes: -0.1), .getReady)
    }

    func testJoinAtTheStartThenAReminderThenQuiet() {
        XCTAssertEqual(phase(minutes: 0), .starting)
        XCTAssertEqual(phase(minutes: 2.9), .starting)
        XCTAssertEqual(phase(minutes: 3), .late)
        XCTAssertEqual(phase(minutes: 9.9), .late)
        XCTAssertNil(phase(minutes: 10))
    }

    func testJoiningOrTheMeetingEndingSilencesIt() {
        XCTAssertNil(phase(minutes: -1, joined: true))
        XCTAssertNil(MeetingApproach.phase(start: start, end: start.addingTimeInterval(120),
                                           now: start.addingTimeInterval(130), joined: false))
    }

    func testTheWordsForEachPhase() {
        let quiet = MeetingApproach.line(phase: .quiet, title: "Acme renewal sync", start: start,
                                         now: start.addingTimeInterval(-15 * 60), startTime: "10:00",
                                         people: 4, notes: 3)
        XCTAssertEqual(quiet.lead, "Acme renewal sy…")
        XCTAssertEqual(quiet.trail, "10:00")
        XCTAssertEqual(quiet.peekHint, "Starts in 15 min · 4 people · 3 notes ready")
        XCTAssertFalse(quiet.joins)

        let ready = MeetingApproach.line(phase: .getReady, title: "Standup", start: start,
                                         now: start.addingTimeInterval(-90), startTime: "10:00",
                                         people: 0, notes: 1)
        XCTAssertEqual(ready.lead, "Standup · 2 min")
        XCTAssertEqual(ready.trail, "Get ready")
        XCTAssertEqual(ready.peek, "Ready to listen · 1 note ready")

        let now = MeetingApproach.line(phase: .starting, title: "Standup", start: start,
                                       now: start, startTime: "10:00", people: 0, notes: 0)
        XCTAssertEqual(now.trail, "Join")
        XCTAssertTrue(now.joins)

        let late = MeetingApproach.line(phase: .late, title: "Standup", start: start,
                                        now: start.addingTimeInterval(200), startTime: "10:00",
                                        people: 0, notes: 0)
        XCTAssertEqual(late.lead, "Started 3 min ago")
        XCTAssertTrue(late.joins)
    }

    func testAnEmptyTitleStillNamesSomething() {
        XCTAssertEqual(MeetingApproach.shortTitle("   "), "Meeting")
    }
}

final class MeetingClosedActivityTests: XCTestCase {
    func testAnApproachingMeetingOutranksAPomodoroButNotACall() {
        var inputs = ClosedNotchInputs(meetingApproaching: true, pomodoroActive: true)
        XCTAssertEqual(ClosedNotchArbiter.activity(for: inputs), .meeting)
        inputs.callLive = true
        XCTAssertEqual(ClosedNotchArbiter.activity(for: inputs), .call)
    }

    func testABareNotchSilencesTheMeetingToo() {
        let inputs = ClosedNotchInputs(hideOnClosed: true, meetingApproaching: true)
        XCTAssertEqual(ClosedNotchArbiter.activity(for: inputs), .empty)
    }

    func testOnlyTheCallAndTheMeetingPeek() {
        XCTAssertEqual(ClosedNotchActivity.allCases.filter(NotchPeekPolicy.peeks), [.call, .meeting])
        XCTAssertLessThan(NotchPeekPolicy.standard.peekDelay, NotchPeekPolicy.standard.foldDelay)
    }
}

final class FloatingPanelTests: XCTestCase {
    /// A 14-inch display: the menu bar beside the notch is 38pt tall.
    private let visible = CGRect(x: 0, y: 0, width: 1512, height: 944)

    /// As high as AppKit lets a window go — flush under the menu bar.
    func testDroppingUnderTheMenuBarNearTheNotchDocks() {
        let window = CGRect(x: 566, y: 944 - 380, width: 380, height: 380)
        XCTAssertTrue(FloatingPanelGeometry.shouldDock(window: window, visible: visible))
    }

    func testTheTopCornerIsNotTheNotch() {
        let window = CGRect(x: 1100, y: 944 - 380, width: 380, height: 380)
        XCTAssertFalse(FloatingPanelGeometry.shouldDock(window: window, visible: visible))
    }

    func testBelowTheDockZoneStaysFloating() {
        let window = CGRect(x: 566, y: 400, width: 380, height: 380)
        XCTAssertFalse(FloatingPanelGeometry.shouldDock(window: window, visible: visible))
    }

    /// Even on a display narrow enough that top right is near the centre.
    func testTheFirstPlacementNeverDocks() {
        let narrow = CGRect(x: 0, y: 0, width: 1024, height: 740)
        let frame = FloatingPanelGeometry.initialFrame(size: CGSize(width: 400, height: 560), in: narrow)
        XCTAssertFalse(FloatingPanelGeometry.shouldDock(window: frame, visible: narrow))
    }

    func testAWindowOffScreenComesBackWhole() {
        let clamped = FloatingPanelGeometry.clamped(CGRect(x: 1400, y: -200, width: 380, height: 520),
                                                    to: visible)
        XCTAssertEqual(clamped.size, CGSize(width: 380, height: 520))
        XCTAssertTrue(visible.contains(clamped))
    }

    func testTheFirstPlacementIsTopRight() {
        let frame = FloatingPanelGeometry.initialFrame(size: CGSize(width: 380, height: 520), in: visible)
        XCTAssertEqual(frame.maxX, visible.maxX - FloatingPanelGeometry.margin)
        XCTAssertEqual(frame.maxY, visible.maxY - FloatingPanelGeometry.dockZone - FloatingPanelGeometry.margin)
    }

    func testWhereTheCallStarts() {
        XCTAssertFalse(CallPanelHome(stored: "notch").startsFloating(lastCallFloated: true))
        XCTAssertTrue(CallPanelHome(stored: "floating").startsFloating(lastCallFloated: false))
        XCTAssertTrue(CallPanelHome(stored: "remembered").startsFloating(lastCallFloated: true))
        XCTAssertFalse(CallPanelHome(stored: "remembered").startsFloating(lastCallFloated: false))
        XCTAssertEqual(CallPanelHome(stored: "nonsense"), .notch)
    }
}
