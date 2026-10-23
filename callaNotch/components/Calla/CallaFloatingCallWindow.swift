//
//  CallaFloatingCallWindow.swift
//  callaNotch
//
//  The live call, spun out of the notch into a window of its own.
//
//  The notch is the right home for a call most of the time: it costs no screen
//  and the reader never has to find it. It is the wrong one when the call is
//  full screen, on another display, or when the reader wants the answer beside
//  the faces rather than above them. So the panel can float: an always-on-top
//  window, left out of screen shares exactly as the notch is, that goes back
//  into the notch when it is dragged to the top edge.
//

import AppKit
import CallaContracts
import Combine
import Defaults
import SwiftUI

/// Owns the floating window and keeps it in step with `CopilotLiveSession`.
@MainActor
final class CallaFloatingCallWindow: NSObject, NSWindowDelegate {
    static let shared = CallaFloatingCallWindow()

    /// Narrow enough to sit beside a video grid, tall enough for the account
    /// and a few turns of transcript.
    static let defaultSize = CGSize(width: 400, height: 560)

    private var panel: CallaFloatingCallPanel?
    /// The live view reads a notch view model for sizes it never uses here;
    /// this one belongs to no screen and opens nothing.
    private let viewModel = CallaViewModel()
    private var cancellables: Set<AnyCancellable> = []
    private var settleTask: Task<Void, Never>?

    /// Called once at launch.
    func start() {
        guard cancellables.isEmpty else { return }
        let session = CopilotLiveSession.shared
        session.$floating
            .combineLatest(session.$isLive)
            .map { $0 && $1 }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] show in
                if show { self?.show() } else { self?.hide() }
            }
            .store(in: &cancellables)

        Defaults.publisher(.hideFromScreenRecording)
            .sink { [weak self] _ in self?.applySharingType() }
            .store(in: &cancellables)
    }

    // MARK: - Showing

    private func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        applySharingType()
        panel.setFrame(restoredFrame(), display: true)
        panel.orderFrontRegardless()
    }

    private func hide() {
        settleTask?.cancel()
        CallaFloatingCallState.shared.nearDock = false
        guard let panel, panel.isVisible else { return }
        remember(panel.frame, on: panel.screen)
        panel.orderOut(nil)
    }

    private func makePanel() -> CallaFloatingCallPanel {
        let panel = CallaFloatingCallPanel(contentRect: CGRect(origin: .zero, size: Self.defaultSize))
        panel.delegate = self
        let host = NSHostingView(rootView: CallaFloatingCallView().environmentObject(viewModel))
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
    }

    /// One switch decides this for the notch and the window alike, so a call
    /// is never hidden in one place and visible in the other.
    private func applySharingType() {
        panel?.sharingType = Defaults[.hideFromScreenRecording] ? .none : .readWrite
    }

    // MARK: - Where it goes

    /// The screen the window should appear on: the one under the pointer,
    /// which is where the reader was looking when they asked for it.
    private func targetScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func restoredFrame() -> CGRect {
        guard let screen = targetScreen() else { return CGRect(origin: .zero, size: Self.defaultSize) }
        let visible = screen.visibleFrame
        if let uuid = screen.displayUUID,
           let stored = Defaults[.callaFloatingFrames][uuid] {
            let frame = NSRectFromString(stored)
            if frame.width > 0, frame.height > 0 {
                return FloatingPanelGeometry.clamped(frame, to: visible)
            }
        }
        return FloatingPanelGeometry.initialFrame(size: Self.defaultSize, in: visible)
    }

    private func remember(_ frame: CGRect, on screen: NSScreen?) {
        guard let screen, let uuid = screen.displayUUID else { return }
        // Never remember a frame that would dock the window straight away.
        guard !FloatingPanelGeometry.shouldDock(window: frame, visible: screen.visibleFrame) else { return }
        Defaults[.callaFloatingFrames][uuid] = NSStringFromRect(frame)
    }

    // MARK: - Docking

    func windowDidMove(_ notification: Notification) {
        guard let panel, let screen = panel.screen else { return }
        let near = FloatingPanelGeometry.shouldDock(window: panel.frame, visible: screen.visibleFrame)
        if CallaFloatingCallState.shared.nearDock != near {
            withAnimation(.smooth(duration: 0.18)) { CallaFloatingCallState.shared.nearDock = near }
        }
        // A move has no "ended" callback, so wait for the button to come up.
        settleTask?.cancel()
        settleTask = Task { @MainActor [weak self] in
            while NSEvent.pressedMouseButtons != 0 {
                try? await Task.sleep(for: .milliseconds(60))
                if Task.isCancelled { return }
            }
            self?.settle()
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let panel else { return }
        remember(panel.frame, on: panel.screen)
    }

    /// The drag is over: dock if it was dropped on the notch, otherwise keep
    /// it fully on screen and remember where it went.
    private func settle() {
        guard let panel, panel.isVisible, let screen = panel.screen else { return }
        CallaFloatingCallState.shared.nearDock = false
        if FloatingPanelGeometry.shouldDock(window: panel.frame, visible: screen.visibleFrame) {
            CopilotLiveSession.shared.dock()
            return
        }
        let clamped = FloatingPanelGeometry.clamped(panel.frame, to: screen.visibleFrame)
        if clamped != panel.frame { panel.setFrame(clamped, display: true, animate: true) }
        remember(clamped, on: screen)
    }
}

/// What the window's own view needs to know about the drag.
@MainActor
final class CallaFloatingCallState: ObservableObject {
    static let shared = CallaFloatingCallState()
    /// The window is over the notch's drop zone: letting go puts it back.
    @Published var nearDock = false
}

/// Borderless, always on top, on every Space including full-screen ones, and
/// never the app's main window.
final class CallaFloatingCallPanel: NSPanel {
    /// A convenience initialiser, so the designated ones — and `init(coder:)`
    /// — are still inherited from `NSPanel`.
    convenience init(contentRect: CGRect) {
        self.init(contentRect: contentRect,
                  styleMask: [.borderless, .nonactivatingPanel, .resizable, .fullSizeContentView],
                  backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        minSize = CGSize(width: 340, height: 360)
    }

    /// Key only for typing — the "Answer this" field. Buttons work without it,
    /// so clicking the window never pulls focus out of the call app.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - The window's content

/// The floating window: a grab handle, the state and clock, Back to notch and
/// End, then the same live panel the notch draws, stacked into one column.
struct CallaFloatingCallView: View {
    @ObservedObject private var engine = CallaEngineClient.shared
    @ObservedObject private var session = CopilotLiveSession.shared
    @ObservedObject private var state = CallaFloatingCallState.shared

    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var copilot: CallaCopilotStatus { engine.status.copilot }

    private var mode: CallaCopilotPresentation.Mode {
        CallaCopilotPresentation.mode(
            available: copilot.available,
            running: copilot.running,
            systemAudioActive: copilot.systemAudioActive,
            hasSuggestion: !CallaCopilotLiveView.answersRetired && copilot.hasSuggestion)
    }

    private var line: CallaCopilotPresentation.ClosedLine {
        CallaCopilotPresentation.closedLine(
            mode: mode, floating: false,
            elapsed: CallaCopilotPresentation.elapsed(since: copilot.startedAt, now: now),
            latestStanding: nil, answerHeadline: nil,
            catchingUp: copilot.summaryWorking || copilot.working == "summary")
    }

    private var tint: Color {
        line.tone == .warning ? NotchAccent.attention : NotchAccent.call
    }

    private let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

    var body: some View {
        VStack(spacing: 0) {
            header
            CallaCopilotLiveView()
                .environment(\.callaPanelStacked, true)
        }
        .background(shape.fill(Color.black))
        .overlay(shape.strokeBorder(state.nearDock ? NotchAccent.quiz.opacity(0.8) : Color.white.opacity(0.14),
                                    lineWidth: state.nearDock ? 2 : 1))
        .clipShape(shape)
        .preferredColorScheme(.dark)
        .onReceive(tick) { now = $0 }
    }

    private var header: some View {
        VStack(spacing: 6) {
            // The handle says "this moves"; the header behind the controls
            // drags the window too.
            Capsule()
                .fill(Color.white.opacity(state.nearDock ? 0.6 : 0.28))
                .frame(width: 38, height: 5)
                .padding(.top, 8)
                .accessibilityHidden(true)

            HStack(spacing: 8) {
                NotchStateDot(tint: tint)
                if state.nearDock {
                    Text("Let go to put it back in the notch")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(NotchAccent.quiz)
                        .lineLimit(1)
                } else {
                    Text(line.lead.uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .tracking(notchCapsTracking)
                        .foregroundStyle(NotchInk.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(line.trail)
                    .font(.system(size: 11.5, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(NotchInk.secondary)
                CallaWingButton(symbol: "pip.enter") {
                    session.dock()
                }
                .help("Put back in the notch")
                .accessibilityLabel("Put the call panel back in the notch")
                CallaEndPill { engine.endCall(origin: "floatingEnd") }
                    .help("End the call")
                    .accessibilityLabel("End call")
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 4)
        .background(CallaWindowDragArea())
    }
}

/// Drags the window from wherever SwiftUI has not put a control. Relying on
/// `isMovableByWindowBackground` alone is not enough: a hosting view does not
/// reliably report its empty regions as draggable.
private struct CallaWindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}
