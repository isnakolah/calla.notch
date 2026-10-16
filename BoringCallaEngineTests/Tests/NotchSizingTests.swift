import XCTest
@testable import NotchSizing

final class NotchSizingTests: XCTestCase {
    private func assertSize(
        _ actual: CGSize?,
        _ expected: CGSize?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual?.width, expected?.width, file: file, line: line)
        XCTAssertEqual(actual?.height, expected?.height, file: file, line: line)
    }

    func testCodeAndWaveUseNormalCallProfilesAndBounds() {
        for (alias, shared) in [(NotchSizeProfile.wave, NotchSizeProfile.callExpanded),
                                (.codingExpanded, .callExpanded), (.codingCompact, .callCollapsed)] {
            XCTAssertEqual(alias.storageProfile, shared)
            assertSize(alias.defaultSize, shared.defaultSize)
            XCTAssertEqual(alias.widthBounds, shared.widthBounds)
            XCTAssertEqual(alias.heightBounds, shared.heightBounds)
            assertSize(NotchResizeGeometry.clamped(CGSize(width: 2000, height: 2000), for: alias,
                screenSize: CGSize(width: 500, height: 320)), CGSize(width: 476, height: 244))
        }
        XCTAssertEqual(NotchSizeProfile.allCases, [.normal, .callExpanded, .callCollapsed])
    }

    func testInterviewPinExpiresButOrdinaryPinSurvives() {
        var pin = NotchPinState()
        pin.set(true, duringInterview: true)
        XCTAssertTrue(pin.isPinned)
        pin.releaseInterview()
        XCTAssertFalse(pin.isPinned)
        pin.releaseInterview()
        XCTAssertFalse(pin.isPinned)
        pin.set(true, duringInterview: false)
        pin.releaseInterview()
        XCTAssertTrue(pin.isPinned)
        pin.set(false, duringInterview: false)
        pin.set(true, duringInterview: true)
        pin.releaseInterview()
        XCTAssertFalse(pin.isPinned)
    }

    func testProfileDefaultsAndBounds() {
        assertSize(NotchSizeProfile.normal.defaultSize, CGSize(width: 512, height: 168))
        assertSize(NotchSizeProfile.callExpanded.defaultSize, CGSize(width: 720, height: 400))
        // A call has one width; collapsing changes only the height. Both call
        // profiles are backed by the same stored width, so their defaults have
        // to agree or a fresh install reports compact as already customised.
        assertSize(NotchSizeProfile.callCollapsed.defaultSize, CGSize(width: 720, height: 270))
        XCTAssertEqual(NotchSizeProfile.callCollapsed.defaultSize.width,
                       NotchSizeProfile.callExpanded.defaultSize.width)
        XCTAssertEqual(NotchSizeProfile.normal.widthBounds, 512...900)
        XCTAssertEqual(NotchSizeProfile.callExpanded.heightBounds, 240...560)
        XCTAssertEqual(NotchSizeProfile.callCollapsed.heightBounds, 150...420)
    }

    func testProfileClamp() {
        assertSize(
            NotchResizeGeometry.clamped(CGSize(width: 200, height: 900), for: .normal),
            CGSize(width: 512, height: 560)
        )
        assertSize(
            NotchResizeGeometry.clamped(CGSize(width: 920, height: 100), for: .callCollapsed),
            CGSize(width: 900, height: 150)
        )
    }

    func testScreenClampReservesEditorBar() {
        assertSize(
            NotchResizeGeometry.clamped(
                CGSize(width: 900, height: 560),
                for: .normal,
                screenSize: CGSize(width: 800, height: 600)
            ),
            CGSize(width: 776, height: 524)
        )
    }

    func testCenteredDragDoublesHorizontalDelta() {
        assertSize(
            NotchResizeGeometry.dragged(
                from: CGSize(width: 600, height: 300),
                translation: CGSize(width: 40, height: 25),
                profile: .callExpanded
            ),
            CGSize(width: 680, height: 325)
        )
    }

    func testPresentationMapping() {
        XCTAssertEqual(NotchPresentationSizing.regular.profile, .normal)
        XCTAssertEqual(NotchPresentationSizing.idleCall.profile, .normal)
        XCTAssertEqual(NotchPresentationSizing.signIn.profile, .normal)
        XCTAssertEqual(NotchPresentationSizing.preroll.profile, .normal)
        XCTAssertEqual(NotchPresentationSizing.callStarting.profile, .callCollapsed)
        XCTAssertEqual(NotchPresentationSizing.callEnding.profile, .callCollapsed)
        XCTAssertEqual(NotchPresentationSizing.callFailed.profile, .callCollapsed)
        XCTAssertEqual(NotchPresentationSizing.callExpanded.profile, .callExpanded)
        XCTAssertEqual(NotchPresentationSizing.callCollapsed.profile, .callCollapsed)
    }

    func testTransientMinimumDoesNotShrinkPreferredSize() {
        assertSize(
            NotchResizeGeometry.applyingMinimum(
                CGSize(width: 600, height: 300),
                to: CGSize(width: 512, height: 168)
            ),
            CGSize(width: 600, height: 300)
        )
        assertSize(
            NotchResizeGeometry.applyingMinimum(
                CGSize(width: 512, height: 200),
                to: CGSize(width: 760, height: 420)
            ),
            CGSize(width: 760, height: 420)
        )
    }

    func testRestorationPrefersActiveCall() {
        let open = NotchResizeSnapshot(wasOpen: true)
        assertSize(
            open.restoredSize(
                preferredOpenSize: CGSize(width: 760, height: 420),
                forceOpen: false
            ),
            CGSize(width: 760, height: 420)
        )

        let closed = NotchResizeSnapshot(wasOpen: false)
        XCTAssertNil(closed.restoredSize(
            preferredOpenSize: CGSize(width: 512, height: 168),
            forceOpen: false
        ))
        assertSize(
            closed.restoredSize(
                preferredOpenSize: CGSize(width: 600, height: 340),
                forceOpen: true
            ),
            CGSize(width: 600, height: 340)
        )
    }
}
