import AppKit
import SwiftUI

/// One resize editor for whole app. It owns target display and restoration so
/// Settings navigation cannot strand an open preview or resize every display.
@MainActor
final class NotchResizeSession: ObservableObject {
    static let shared = NotchResizeSession()

    @Published private(set) var isEditing = false
    @Published private(set) var activeProfile: NotchSizeProfile = .normal
    @Published private(set) var liveSize = NotchSizeProfile.normal.defaultSize
    @Published private(set) var isDragging = false
    @Published private(set) var targetScreenUUID: String?
    @Published private(set) var failureReason: String?
    /// Which resize control the pointer is over, published by the panel.
    ///
    /// SwiftUI's own `onHover` is unreliable here: the panel turns mouse events
    /// off whenever the pointer leaves a painted island, so the matching exit
    /// event is the one that never arrives and a control stays lit — or never
    /// lights at all. The window already tracks the pointer every frame for
    /// click-through; the highlight reads that instead of guessing.
    @Published var hoveredControl: String?
    /// Whether the corner has been dragged in this session. Only used to retire
    /// the hint line once it has done its job.
    @Published private(set) var hasDragged = false

    private weak var targetViewModel: CallaViewModel?
    private var priorState: NotchState = .closed
    private var priorView: NotchViews = .home
    private var dragStart: CGSize?
    /// The layout a live call was in when editing began.
    ///
    /// Picking a profile puts the call into the matching layout so the panel
    /// shows what is being sized; the call gets its own layout back on Done. The
    /// editor is for sizing, and which layout a call is in is the call's
    /// business, not the editor's.
    private var priorCallLayout: CopilotLiveSession.Layout?

    private init() {}

    func isEditing(_ viewModel: CallaViewModel) -> Bool {
        isEditing && targetViewModel === viewModel
    }

    func previewSize(for viewModel: CallaViewModel) -> CGSize? {
        isEditing(viewModel) ? effectivePreviewSize : nil
    }

    /// Two surfaces never open at the normal profile's size: they carry a floor
    /// of their own, applied over whatever the profile says. A preview that
    /// ignored it would draw the panel at a size the app never opens them to.
    private var previewFloor: CGSize {
        guard activeProfile == .normal else { return .zero }
        switch CallaViewCoordinator.shared.currentView {
        case .knowledgeDrop: return CGSize(width: 600, height: 300)
        case .dropChooser: return CGSize(width: 512, height: 200)
        default: return .zero
        }
    }

    /// What the notch is actually drawn at: the size being edited, raised to the
    /// current tab's own floor where it has one.
    private var effectivePreviewSize: CGSize {
        NotchResizeGeometry.applyingMinimum(previewFloor, to: liveSize)
    }

    /// The floor in force, when it is above the size being edited — so the tray
    /// can say why the panel stopped shrinking with the corner.
    var activeFloor: CGSize? {
        let floor = previewFloor
        guard floor.width > liveSize.width || floor.height > liveSize.height else { return nil }
        return floor
    }

    /// Re-applies the preview after the reader switches tab mid-session. The
    /// size does not change; which floor applies to it can.
    func refreshPreview() {
        guard isEditing else { return }
        targetViewModel?.setResizePreview(size: effectivePreviewSize)
    }

    func begin(on screen: NSScreen?) {
        failureReason = nil
        let requestedScreen = screen ?? SettingsWindowController.shared.window?.screen ?? NSScreen.main
        guard let requestedScreen, let uuid = requestedScreen.displayUUID else {
            failureReason = "Could not resolve the display containing Settings."
            return
        }
        if isEditing, targetScreenUUID == uuid { return }
        if isEditing { finish() }

        guard let delegate = AppDelegate.shared ?? (NSApp.delegate as? AppDelegate) else {
            failureReason = "The notch window is not ready yet."
            return
        }
        guard let viewModel = delegate.prepareNotchResizeTarget(on: requestedScreen) else {
            failureReason = "No notch is available on this display."
            return
        }

        targetViewModel = viewModel
        targetScreenUUID = uuid
        priorState = viewModel.notchState
        priorView = CallaViewCoordinator.shared.currentView
        activeProfile = initialProfile
        priorCallLayout = CopilotLiveSession.shared.isLive
            ? CopilotLiveSession.shared.layout
            : nil
        hasDragged = false
        liveSize = clampedStoredSize(activeProfile)
        isEditing = true
        viewModel.setResizePreview(size: effectivePreviewSize)
    }

    func retarget(to screen: NSScreen?) {
        guard isEditing, screen?.displayUUID != targetScreenUUID else { return }
        let profile = activeProfile
        finish()
        begin(on: screen)
        select(profile)
    }

    func select(_ profile: NotchSizeProfile) {
        activeProfile = profile
        // A running call follows the profile being sized, so what is on screen
        // is the layout the numbers belong to.
        switch profile {
        case .callExpanded: CopilotLiveSession.shared.setLayout(.full)
        case .callCollapsed: CopilotLiveSession.shared.setLayout(.compact)
        case .normal: break
        }
        if isEditing {
            apply(NotchSizePreferences.size(profile), persist: false)
        } else {
            liveSize = NotchSizePreferences.size(profile)
        }
    }

    func setSize(_ size: CGSize) {
        if isEditing {
            apply(size, persist: true)
        } else {
            NotchSizePreferences.set(size, for: activeProfile)
            liveSize = NotchSizePreferences.size(activeProfile)
        }
    }

    func refreshFromPreferences() {
        guard isEditing else { return }
        apply(NotchSizePreferences.size(activeProfile), persist: false)
    }

    func resetActiveProfile() {
        NotchSizePreferences.reset(activeProfile)
        if isEditing {
            refreshFromPreferences()
        } else {
            liveSize = NotchSizePreferences.size(activeProfile)
        }
    }

    func beginDrag() {
        guard isEditing else { return }
        dragStart = liveSize
        isDragging = true
        hasDragged = true
    }

    /// Keyboard resizing, in points. The corner is not always somewhere the
    /// pointer can comfortably reach — a notch pushed against the screen edge,
    /// or a size a few points off what was wanted.
    func nudge(width: CGFloat, height: CGFloat) {
        guard isEditing else { return }
        apply(CGSize(width: liveSize.width + width, height: liveSize.height + height),
              persist: true)
    }

    /// True when the live size is pinned against its own profile's bound, so
    /// the readout can say why the corner stopped following the pointer.
    var isAtLimit: Bool {
        let bounds = NotchResizeGeometry.clamped(
            CGSize(width: CGFloat.greatestFiniteMagnitude,
                   height: CGFloat.greatestFiniteMagnitude),
            for: activeProfile,
            screenSize: targetScreenSize
        )
        let floor = CGSize(width: activeProfile.widthBounds.lowerBound,
                           height: activeProfile.heightBounds.lowerBound)
        return abs(liveSize.width - bounds.width) < 0.5
            || abs(liveSize.height - bounds.height) < 0.5
            || abs(liveSize.width - floor.width) < 0.5
            || abs(liveSize.height - floor.height) < 0.5
    }

    func drag(translation: CGSize) {
        guard isEditing else { return }
        let start = dragStart ?? liveSize
        if dragStart == nil { beginDrag() }
        let proposed = NotchResizeGeometry.dragged(
            from: start,
            translation: translation,
            profile: activeProfile,
            screenSize: targetScreenSize
        )
        apply(proposed, persist: true)
    }

    func endDrag() {
        guard isEditing else { return }
        dragStart = nil
        isDragging = false
        guard let targetViewModel else { return }
        withAnimation(.easeOut(duration: 0.14)) {
            targetViewModel.setResizePreview(size: effectivePreviewSize)
        }
    }

    func finish() {
        guard isEditing else { return }
        let viewModel = targetViewModel
        let state = priorState
        let view = priorView

        isEditing = false
        isDragging = false
        hoveredControl = nil
        dragStart = nil
        if let priorCallLayout {
            CopilotLiveSession.shared.setLayout(priorCallLayout)
        }
        priorCallLayout = nil
        targetViewModel = nil
        targetScreenUUID = nil

        guard let viewModel else { return }
        let call = CopilotLiveSession.shared
        let forceCallOpen = call.hasActiveSurface
        if forceCallOpen {
            CallaViewCoordinator.shared.currentView = .copilot
        } else {
            CallaViewCoordinator.shared.currentView = view
        }
        let snapshot = NotchResizeSnapshot(wasOpen: state == .open)
        if let restored = snapshot.restoredSize(
            preferredOpenSize: call.preferredOpenSize,
            forceOpen: forceCallOpen
        ) {
            viewModel.open(size: restored)
        } else {
            viewModel.close()
        }
        (AppDelegate.shared ?? (NSApp.delegate as? AppDelegate))?.finishNotchResizeTarget()
    }

    private var initialProfile: NotchSizeProfile {
        let call = CopilotLiveSession.shared
        if call.starting || call.ending || call.startupFailed { return .callCollapsed }
        if call.isLive { return call.layout == .full ? .callExpanded : .callCollapsed }
        return .normal
    }

    private var targetScreenSize: CGSize? {
        guard let targetScreenUUID,
              let screen = NSScreen.screen(withUUID: targetScreenUUID) else { return nil }
        return screen.frame.size
    }

    private func clampedStoredSize(_ profile: NotchSizeProfile) -> CGSize {
        NotchResizeGeometry.clamped(
            NotchSizePreferences.size(profile),
            for: profile,
            screenSize: targetScreenSize
        )
    }

    private func apply(_ proposed: CGSize, persist: Bool) {
        let size = NotchResizeGeometry.clamped(
            proposed,
            for: activeProfile,
            screenSize: targetScreenSize
        )
        if persist { NotchSizePreferences.set(size, for: activeProfile) }
        liveSize = size
        targetViewModel?.setResizePreview(size: effectivePreviewSize)
    }
}

extension CopilotLiveSession {
    var hasActiveSurface: Bool {
        isLive || starting || ending || startupFailed || signInActive
    }
}
