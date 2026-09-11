import Foundation

/// Persisted open-notch layouts. Storage stays app-owned; geometry stays pure
/// so clamping and drag behavior can be tested without launching AppKit.
enum NotchSizeProfile: String, CaseIterable, Identifiable, Sendable {
    case normal
    case wave
    case codingExpanded
    case codingCompact
    case callExpanded
    case callCollapsed

    // Former Code/Wave names remain readable but use the shared Call profile.
    static let allCases: [Self] = [.normal, .callExpanded, .callCollapsed]
    var storageProfile: Self {
        switch self {
        case .wave, .codingExpanded: .callExpanded
        case .codingCompact: .callCollapsed
        default: self
        }
    }
    var id: String { rawValue }

    var title: String {
        switch self {
        case .wave: "Wave expanded"
        case .codingExpanded: "Code expanded"
        case .codingCompact: "Code compact"
        case .normal: "Normal"
        case .callExpanded: "Call expanded"
        case .callCollapsed: "Call compact"
        }
    }

    var defaultSize: CGSize {
        switch self {
        case .wave, .codingExpanded: Self.callExpanded.defaultSize
        case .codingCompact: Self.callCollapsed.defaultSize
        case .normal: CGSize(width: 512, height: 168)
        case .callExpanded: CGSize(width: 600, height: 340)
        // Same width as expanded: a call has one width, and collapsing changes
        // only the height (it drops the transcript column). Storage backs both
        // with the same key — see `NotchSizePreferences.size(_:)` — so a
        // different default here would make a freshly installed compact layout
        // report itself as already customised.
        case .callCollapsed: CGSize(width: 600, height: 200)
        }
    }

    var widthBounds: ClosedRange<CGFloat> {
        switch self {
        case .wave, .codingExpanded, .codingCompact: storageProfile.widthBounds
        case .normal: 512...900
        case .callExpanded, .callCollapsed: 460...900
        }
    }

    var heightBounds: ClosedRange<CGFloat> {
        switch self {
        case .wave, .codingExpanded, .codingCompact: storageProfile.heightBounds
        case .normal: 168...560
        case .callExpanded: 240...560
        case .callCollapsed: 150...420
        }
    }
}

enum NotchPresentationSizing: Sendable {
    case regular
    case idleCall
    case signIn
    case preroll
    case callStarting
    case callEnding
    case callFailed
    case callExpanded
    case callCollapsed

    var profile: NotchSizeProfile {
        switch self {
        case .regular, .idleCall, .signIn, .preroll: .normal
        case .callStarting, .callEnding, .callFailed, .callCollapsed: .callCollapsed
        case .callExpanded: .callExpanded
        }
    }
}

struct NotchResizeGeometry: Sendable {
    static let horizontalScreenMargin: CGFloat = 24
    static let editorVerticalAllowance: CGFloat = 76

    static func clamped(
        _ proposed: CGSize,
        for profile: NotchSizeProfile,
        screenSize: CGSize? = nil
    ) -> CGSize {
        var maxWidth = profile.widthBounds.upperBound
        var maxHeight = profile.heightBounds.upperBound

        if let screenSize {
            maxWidth = min(maxWidth, max(
                1,
                screenSize.width - horizontalScreenMargin
            ))
            maxHeight = min(maxHeight, max(
                1,
                screenSize.height - editorVerticalAllowance
            ))
        }

        return CGSize(
            width: min(max(proposed.width, profile.widthBounds.lowerBound), maxWidth),
            height: min(max(proposed.height, profile.heightBounds.lowerBound), maxHeight)
        )
    }

    /// Top-center stays fixed. Moving right corner by x grows both sides, so
    /// width changes by twice pointer movement while height follows pointer.
    static func dragged(
        from initial: CGSize,
        translation: CGSize,
        profile: NotchSizeProfile,
        screenSize: CGSize? = nil
    ) -> CGSize {
        clamped(
            CGSize(
                width: initial.width + translation.width * 2,
                height: initial.height + translation.height
            ),
            for: profile,
            screenSize: screenSize
        )
    }

    static func applyingMinimum(_ minimum: CGSize, to preferred: CGSize) -> CGSize {
        CGSize(width: max(preferred.width, minimum.width),
               height: max(preferred.height, minimum.height))
    }
}

struct NotchResizeSnapshot: Sendable {
    let wasOpen: Bool

    /// Active surfaces force the notch open. Otherwise restore only prior open
    /// state, using the now-current profile rather than stale pre-edit geometry.
    func restoredSize(preferredOpenSize: CGSize, forceOpen: Bool) -> CGSize? {
        (forceOpen || wasOpen) ? preferredOpenSize : nil
    }
}

/// An explicit pin set during an interview expires with that interview.
/// Pins deliberately set on ordinary tabs retain their normal lifetime.
struct NotchPinState: Equatable, Sendable {
    enum Scope: Equatable, Sendable { case manual, interview }
    private(set) var scope: Scope?
    var isPinned: Bool { scope != nil }
    mutating func set(_ enabled: Bool, duringInterview: Bool) {
        scope = enabled ? (duringInterview ? .interview : .manual) : nil
    }
    mutating func releaseInterview() {
        if scope == .interview { scope = nil }
    }
}
