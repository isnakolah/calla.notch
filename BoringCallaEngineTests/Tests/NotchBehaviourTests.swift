import XCTest
@testable import NotchSizing

final class ClosedNotchArbiterTests: XCTestCase {
    /// Everything ambient is on at once. Each of these asserts a *product*
    /// decision, which is why they are worth pinning: the ladder this replaced
    /// encoded them by paste order and nobody could see them.
    private var everythingOn: ClosedNotchInputs {
        ClosedNotchInputs(
            expandingViewShowing: true, expandingViewIsBattery: true,
            sneakPeekShowing: true, inlineHUDEnabled: true,
            callLive: true, pomodoroActive: true, usageBadgesEnabled: true,
            musicPlaying: true, musicPlayerIdle: false, musicLiveActivityEnabled: true,
            faceEnabled: true)
    }

    func testAPowerNotificationOutranksEverything() {
        XCTAssertEqual(ClosedNotchArbiter.activity(for: everythingOn), .batteryStatus)
    }

    func testTheHUDOutranksEveryAmbientActivity() {
        var inputs = everythingOn
        inputs.expandingViewShowing = false
        inputs.expandingViewIsBattery = false
        XCTAssertEqual(ClosedNotchArbiter.activity(for: inputs), .inlineHUD)
    }

    func testAMusicOrBatterySneakPeekIsNotTheInlineHUD() {
        var inputs = ClosedNotchInputs(sneakPeekShowing: true, inlineHUDEnabled: true,
                                       pomodoroActive: true)
        inputs.sneakPeekIsMusic = true
        XCTAssertEqual(ClosedNotchArbiter.activity(for: inputs), .pomodoro)
        inputs.sneakPeekIsMusic = false
        inputs.sneakPeekIsBattery = true
        XCTAssertEqual(ClosedNotchArbiter.activity(for: inputs), .pomodoro)
    }

    /// A conversation cannot wait; a Pomodoro can.
    func testACallOutranksAPomodoro() {
        let inputs = ClosedNotchInputs(callLive: true, pomodoroActive: true, usageBadgesEnabled: true)
        XCTAssertEqual(ClosedNotchArbiter.activity(for: inputs), .call)
    }

    func testAPomodoroOutranksUsageAndMusic() {
        let inputs = ClosedNotchInputs(pomodoroActive: true, usageBadgesEnabled: true,
                                       musicPlaying: true, musicPlayerIdle: false,
                                       musicLiveActivityEnabled: true)
        XCTAssertEqual(ClosedNotchArbiter.activity(for: inputs), .pomodoro)
    }

    func testMusicNeedsItsLiveActivityTurnedOn() {
        var inputs = ClosedNotchInputs(musicPlaying: true, musicPlayerIdle: false)
        XCTAssertEqual(ClosedNotchArbiter.activity(for: inputs), .empty)
        inputs.musicLiveActivityEnabled = true
        XCTAssertEqual(ClosedNotchArbiter.activity(for: inputs), .music)
    }

    /// A paused player is not idle, so it keeps the slot rather than handing it
    /// to the face the moment playback stops.
    func testAPausedPlayerStillHoldsTheSlot() {
        let inputs = ClosedNotchInputs(musicPlaying: false, musicPlayerIdle: false,
                                       musicLiveActivityEnabled: true, faceEnabled: true)
        XCTAssertEqual(ClosedNotchArbiter.activity(for: inputs), .music)
    }

    func testTheFaceOnlyAppearsWhenTheresNothingElse() {
        let inputs = ClosedNotchInputs(musicPlaying: false, musicPlayerIdle: true,
                                       musicLiveActivityEnabled: true, faceEnabled: true)
        XCTAssertEqual(ClosedNotchArbiter.activity(for: inputs), .face)
    }

    func testAnExpandingViewSuppressesTheFace() {
        let inputs = ClosedNotchInputs(expandingViewShowing: true, faceEnabled: true)
        XCTAssertEqual(ClosedNotchArbiter.activity(for: inputs), .empty)
    }

    /// `hideOnClosed` is the reader asking for a bare notch. A power
    /// notification and the HUD are answers to something that just happened and
    /// survive it; everything ambient does not.
    func testHideOnClosedSilencesTheAmbientActivitiesOnly() {
        var inputs = everythingOn
        inputs.hideOnClosed = true
        XCTAssertEqual(ClosedNotchArbiter.activity(for: inputs), .batteryStatus)

        inputs.expandingViewShowing = false
        inputs.expandingViewIsBattery = false
        XCTAssertEqual(ClosedNotchArbiter.activity(for: inputs), .inlineHUD)

        inputs.sneakPeekShowing = false
        XCTAssertEqual(ClosedNotchArbiter.activity(for: inputs), .empty)
    }

    func testAnOpenNotchHasNoClosedActivity() {
        var inputs = everythingOn
        inputs.isClosed = false
        XCTAssertEqual(ClosedNotchArbiter.activity(for: inputs), .empty)
    }

    func testNothingOnIsEmpty() {
        XCTAssertEqual(ClosedNotchArbiter.activity(for: ClosedNotchInputs()), .empty)
    }

    /// Every case except `.empty` is reachable, and `.empty` is the only one
    /// without a rule. A case added to the enum but never given a row in
    /// `priority` would draw nothing, silently.
    func testEveryActivityHasARule() {
        let ruled = Set(ClosedNotchArbiter.priority.map(\.0))
        XCTAssertEqual(ruled, Set(ClosedNotchActivity.allCases).subtracting([.empty]))
    }
}

final class OpenNotchHeaderArbiterTests: XCTestCase {
    func testAClosedNotchHasNoHeader() {
        XCTAssertNil(OpenNotchHeaderArbiter.header(for: OpenNotchHeaderInputs(isOpen: false)))
    }

    func testTabsAreTheDefault() {
        XCTAssertEqual(OpenNotchHeaderArbiter.header(for: .init(isOpen: true)), .tabs)
    }

    /// Sizing a call layout with no call running gets the stand-in band; with a
    /// call on screen the real header wins, because otherwise resizing replaced
    /// the thing being resized.
    func testResizePreviewOnlyStandsInForAnAbsentCall() {
        XCTAssertEqual(
            OpenNotchHeaderArbiter.header(for: .init(isOpen: true, previewingCallProfile: true)),
            .resizePreview)
        XCTAssertEqual(
            OpenNotchHeaderArbiter.header(for: .init(isOpen: true, previewingCallProfile: true,
                                                     callLive: true, wearingCallGlass: true)),
            .callLive)
    }

    func testGlassPicksTheLiveHeaderAndQuizGetsItsOwn() {
        XCTAssertEqual(
            OpenNotchHeaderArbiter.header(for: .init(isOpen: true, callLive: true, wearingCallGlass: true)),
            .callLive)
        XCTAssertEqual(
            OpenNotchHeaderArbiter.header(for: .init(isOpen: true, wearingCallGlass: true, quizActive: true)),
            .quizLive)
    }
}

final class NotchHoverPolicyTests: XCTestCase {
    func testClosingIsNeverFasterThanOpening() {
        for openDelay in [0.0, 0.1, 0.3, 0.5, 1.0, 2.5] {
            let policy = NotchHoverPolicy.resolved(openDelay: openDelay)
            XCTAssertGreaterThanOrEqual(policy.closeDelay, policy.openDelay,
                                        "a \(openDelay)s open dwell must not close faster than it opens")
            XCTAssertGreaterThanOrEqual(policy.closeDelay, NotchHoverPolicy.minimumCloseDelay)
        }
    }

    /// The shipped default was 300 ms to open and 100 ms to close.
    func testTheShippedDefaultDwellNowClosesSlowerThanItOpens() {
        let policy = NotchHoverPolicy.resolved(openDelay: 0.3)
        XCTAssertEqual(policy.closeDelay, 0.35, accuracy: 0.0001)
        XCTAssertEqual(policy.fadeDelay, 0.1, accuracy: 0.0001)
    }

    func testFadeToCloseNeverGoesNegative() {
        for openDelay in [0.0, 0.05, 0.3, 3.0] {
            let policy = NotchHoverPolicy.resolved(openDelay: openDelay)
            XCTAssertGreaterThanOrEqual(policy.delayFromFadeToClose, 0)
            XCTAssertEqual(policy.fadeDelay + policy.delayFromFadeToClose, policy.closeDelay,
                           accuracy: 0.0001)
        }
    }

    func testANegativeSettingIsClamped() {
        let policy = NotchHoverPolicy.resolved(openDelay: -5)
        XCTAssertEqual(policy.openDelay, 0)
        XCTAssertEqual(policy.closeDelay, NotchHoverPolicy.minimumCloseDelay)
    }
}
