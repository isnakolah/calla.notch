#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

// MARK: - The closed notch's one content slot

/// What the closed notch draws in its single content slot.
///
/// The notch is closed for nearly all of its life, so this one slot is the
/// product. Which activity wins was previously a ten-deep `else if` ladder in
/// `ContentView.NotchLayout()` that mixed feature flags, session state and
/// notch state in every branch: the priority existed, but only as an accident
/// of the order somebody happened to paste a new branch in, and it could not be
/// read or tested without launching AppKit.
///
/// The order of `priority` below *is* the product decision, written once.
public enum ClosedNotchActivity: String, CaseIterable, Sendable {
    /// Volume, brightness, backlight — the inline HUD style.
    case inlineHUD
    /// A live Copilot call or coding interview.
    case call
    /// A linked meeting is close: its time, then "Get ready", then "Join".
    case meeting
    /// A running Pomodoro block.
    case pomodoro
    /// The usage badges beside the notch.
    case usage
    /// Now playing.
    case music
    /// Nothing to say. Draws a spacer so the shape keeps its height.
    case empty
}

extension ClosedNotchActivity {
    /// Whether this activity puts something either side of the housing, so the
    /// black slab has to reach that far too.
    public var drawsWings: Bool {
        self != .empty
    }
}

/// Everything the arbiter is allowed to look at, as plain values.
///
/// Deliberately flat and `Sendable`: the whole point is that the decision can
/// be exercised in a test without a view, a manager, or a `Defaults` store.
public struct ClosedNotchInputs: Equatable, Sendable {
    public var isClosed: Bool
    /// The reader asked for a bare notch while it is closed.
    public var hideOnClosed: Bool

    public var expandingViewShowing: Bool
    public var expandingViewIsMusic: Bool

    public var sneakPeekShowing: Bool
    public var sneakPeekIsMusic: Bool
    public var inlineHUDEnabled: Bool

    public var callLive: Bool
    /// A calendar meeting with a call link is inside its approach window.
    public var meetingApproaching: Bool
    public var pomodoroActive: Bool
    public var usageBadgesEnabled: Bool

    public var musicPlaying: Bool
    public var musicPlayerIdle: Bool
    public var musicLiveActivityEnabled: Bool
    /// A song just changed and the inline style is announcing it.
    public var inlineSongChange: Bool

    public init(
        isClosed: Bool = true,
        hideOnClosed: Bool = false,
        expandingViewShowing: Bool = false,
        expandingViewIsMusic: Bool = false,
        sneakPeekShowing: Bool = false,
        sneakPeekIsMusic: Bool = false,
        inlineHUDEnabled: Bool = false,
        callLive: Bool = false,
        meetingApproaching: Bool = false,
        pomodoroActive: Bool = false,
        usageBadgesEnabled: Bool = false,
        musicPlaying: Bool = false,
        musicPlayerIdle: Bool = true,
        musicLiveActivityEnabled: Bool = false,
        inlineSongChange: Bool = false
    ) {
        self.isClosed = isClosed
        self.hideOnClosed = hideOnClosed
        self.expandingViewShowing = expandingViewShowing
        self.expandingViewIsMusic = expandingViewIsMusic
        self.sneakPeekShowing = sneakPeekShowing
        self.sneakPeekIsMusic = sneakPeekIsMusic
        self.inlineHUDEnabled = inlineHUDEnabled
        self.callLive = callLive
        self.meetingApproaching = meetingApproaching
        self.pomodoroActive = pomodoroActive
        self.usageBadgesEnabled = usageBadgesEnabled
        self.musicPlaying = musicPlaying
        self.musicPlayerIdle = musicPlayerIdle
        self.musicLiveActivityEnabled = musicLiveActivityEnabled
        self.inlineSongChange = inlineSongChange
    }
}

/// Picks the one activity the closed notch shows.
public enum ClosedNotchArbiter {
    /// Highest priority first. Adding an activity means adding a row here and
    /// nothing else — which is the difference between this and the ladder it
    /// replaces, where a new activity meant reading nine conditions to work out
    /// where to paste the tenth.
    ///
    /// Why this order:
    /// 1. The HUD is a direct response to a key the reader just pressed. It
    ///    outranks anything ambient because the reader is waiting for it.
    /// 2. A conversation cannot wait. A Pomodoro can. A meeting about to start
    ///    is the conversation arriving, so it sits right behind a live one.
    /// 3. A song change announced inline takes the notch for its few seconds,
    ///    over whatever was there — it is news, and it hands the slot back.
    /// 4. Usage and music are ambient. They lose to everything.
    public static let priority: [(ClosedNotchActivity, @Sendable (ClosedNotchInputs) -> Bool)] = [
        (.inlineHUD, { $0.sneakPeekShowing && $0.inlineHUDEnabled && !$0.sneakPeekIsMusic }),
        (.music, { $0.inlineSongChange && $0.musicLiveActivityEnabled && !$0.hideOnClosed }),
        (.call, { $0.callLive && !$0.hideOnClosed }),
        (.meeting, { $0.meetingApproaching && !$0.callLive && !$0.hideOnClosed }),
        (.pomodoro, { $0.pomodoroActive && !$0.hideOnClosed }),
        (.usage, { $0.usageBadgesEnabled && !$0.hideOnClosed }),
        (.music, {
            (!$0.expandingViewShowing || $0.expandingViewIsMusic)
                && ($0.musicPlaying || !$0.musicPlayerIdle)
                && $0.musicLiveActivityEnabled && !$0.hideOnClosed
        })
    ]

    /// The activity for these inputs, or `.empty`.
    ///
    /// An open notch has no closed activity at all: its slot belongs to the
    /// header. Returning `.empty` rather than reaching for a header keeps the
    /// two decisions apart — see `OpenNotchHeaderArbiter`.
    public static func activity(for inputs: ClosedNotchInputs) -> ClosedNotchActivity {
        guard inputs.isClosed else { return .empty }
        for (activity, matches) in priority where matches(inputs) { return activity }
        return .empty
    }
}

// MARK: - The open notch's header slot

/// What the open notch draws in the band either side of the camera housing.
public enum OpenNotchHeader: String, CaseIterable, Sendable {
    /// Sizing a call layout with no call running: a stand-in for the real band.
    case resizePreview
    /// The tab row, and the reader's own controls.
    case tabs
    /// A live Quiz. `CallaCopilotLiveHeader` reads `copilot.*` exclusively, so
    /// under Quiz it showed a dead pulse, no clock and a warning about a
    /// microphone Quiz never opens.
    case quizLive
    /// A live call or coding interview.
    case callLive
}

public struct OpenNotchHeaderInputs: Equatable, Sendable {
    public var isOpen: Bool
    public var previewingCallProfile: Bool
    public var callLive: Bool
    /// The panel is dressed as glass — a live call owns the whole slab, tab row
    /// included, because mid-call there is nothing to switch to.
    public var wearingCallGlass: Bool
    public var quizActive: Bool

    public init(isOpen: Bool = false, previewingCallProfile: Bool = false,
                callLive: Bool = false, wearingCallGlass: Bool = false,
                quizActive: Bool = false) {
        self.isOpen = isOpen
        self.previewingCallProfile = previewingCallProfile
        self.callLive = callLive
        self.wearingCallGlass = wearingCallGlass
        self.quizActive = quizActive
    }
}

public enum OpenNotchHeaderArbiter {
    /// `nil` when the notch is closed — the slot belongs to `ClosedNotchArbiter`.
    public static func header(for inputs: OpenNotchHeaderInputs) -> OpenNotchHeader? {
        guard inputs.isOpen else { return nil }
        if inputs.previewingCallProfile && !inputs.callLive { return .resizePreview }
        if !inputs.wearingCallGlass { return .tabs }
        return inputs.quizActive ? .quizLive : .callLive
    }
}

// MARK: - Hover

/// How long the notch waits before opening and before closing.
///
/// These were 300 ms and 100 ms, which is the asymmetry backwards. Entering the
/// notch is a decision and deserves a deliberate dwell; *leaving* it is mostly
/// noise — a hand moving to the keyboard, tremor at the edge, a pointer
/// crossing on its way somewhere else — and 100 ms of it shut a panel the
/// reader was still reading.
///
/// So closing is never faster than opening, and never faster than
/// `minimumCloseDelay`, whatever the reader sets the open dwell to.
public struct NotchHoverPolicy: Equatable, Sendable {
    /// The dwell before an unopened notch opens. The reader's own setting.
    public var openDelay: TimeInterval
    /// When the hover *styling* lets go. Fast, because it is only a highlight.
    public var fadeDelay: TimeInterval
    /// When an open notch actually closes.
    public var closeDelay: TimeInterval

    public static let minimumCloseDelay: TimeInterval = 0.35
    public static let fadeDelayDefault: TimeInterval = 0.1

    public init(openDelay: TimeInterval, fadeDelay: TimeInterval, closeDelay: TimeInterval) {
        self.openDelay = openDelay
        self.fadeDelay = fadeDelay
        self.closeDelay = closeDelay
    }

    /// The policy for a reader's configured open dwell.
    public static func resolved(openDelay: TimeInterval) -> NotchHoverPolicy {
        let open = max(0, openDelay)
        return NotchHoverPolicy(
            openDelay: open,
            fadeDelay: fadeDelayDefault,
            closeDelay: max(minimumCloseDelay, open)
        )
    }

    /// How long to wait after the fade before closing, for a caller that has
    /// already slept `fadeDelay` in the same task.
    public var delayFromFadeToClose: TimeInterval { max(0, closeDelay - fadeDelay) }
}

// MARK: - Peeking

/// How a closed notch that is carrying a call or a meeting answers the pointer.
///
/// Hovering those two never opens the panel. It grows the closed notch by one
/// line — the answer, or where the call stands — which is often all the reader
/// wanted, and it never takes focus from the call app. A click opens the panel.
public struct NotchPeekPolicy: Equatable, Sendable {
    /// The dwell before the peek line appears. Short: it is only one line and
    /// it covers nothing.
    public var peekDelay: TimeInterval
    /// How long the peek stays after the pointer leaves.
    public var foldDelay: TimeInterval

    public static let standard = NotchPeekPolicy(peekDelay: 0.15, foldDelay: 0.4)

    public init(peekDelay: TimeInterval, foldDelay: TimeInterval) {
        self.peekDelay = peekDelay
        self.foldDelay = foldDelay
    }

    /// Whether hovering this activity peeks instead of opening the notch.
    public static func peeks(_ activity: ClosedNotchActivity) -> Bool {
        activity == .call || activity == .meeting
    }
}

// MARK: - The floating call window

/// Where the live call panel lives when a call starts.
public enum CallPanelHome: String, CaseIterable, Sendable {
    /// In the notch, as it always was.
    case notch
    /// In its own window, floating above every app.
    case floating
    /// Wherever the reader left it at the end of the last call.
    case remembered

    public init(stored: String) {
        self = CallPanelHome(rawValue: stored) ?? .notch
    }

    /// Whether a new call should open in the floating window.
    public func startsFloating(lastCallFloated: Bool) -> Bool {
        switch self {
        case .notch: return false
        case .floating: return true
        case .remembered: return lastCallFloated
        }
    }
}

/// Placement rules for the floating call window, in AppKit screen coordinates
/// (origin bottom-left, so the top of a screen is its `maxY`).
///
/// Every rect named `visible` is the screen's visible frame. That matters for
/// docking: AppKit will not let a window rise into the menu bar, so a dock zone
/// measured from the top of the whole screen could never be reached on a
/// display with a notch, whose menu bar is taller than the zone.
public enum FloatingPanelGeometry {
    /// The band under the top of the visible area that docks a window
    /// dropped into it.
    public static let dockZone: CGFloat = 28
    /// How far either side of the screen's centre still counts as "the notch".
    /// Wider than the notch itself: it is a drop target, aimed at with a whole
    /// window, not a pointer.
    public static let dockHalfWidth: CGFloat = 320
    /// The gap kept between the window and a screen edge.
    public static let margin: CGFloat = 16

    /// A window released here goes back into the notch.
    public static func shouldDock(window: CGRect, visible: CGRect) -> Bool {
        window.maxY >= visible.maxY - dockZone
            && abs(window.midX - visible.midX) <= dockHalfWidth
    }

    /// The window moved fully onto the visible part of the screen, without
    /// changing its size unless it is bigger than the screen.
    public static func clamped(_ window: CGRect, to visible: CGRect) -> CGRect {
        let width = min(window.width, max(0, visible.width - 2 * margin))
        let height = min(window.height, max(0, visible.height - 2 * margin))
        let x = min(max(window.minX, visible.minX + margin), visible.maxX - margin - width)
        let y = min(max(window.minY, visible.minY + margin), visible.maxY - margin - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Where the window first appears: top right of the visible area, clear of
    /// the notch and the video grid's usual centre — and below the dock zone,
    /// so on a narrow display it does not dock the moment it appears.
    public static func initialFrame(size: CGSize, in visible: CGRect) -> CGRect {
        clamped(CGRect(x: visible.maxX - margin - size.width,
                       y: visible.maxY - dockZone - margin - size.height,
                       width: size.width, height: size.height),
                to: visible)
    }
}
