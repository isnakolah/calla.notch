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

        CallaFloatingCallState.shared.$strip
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] strip in self?.applyStrip(strip) }
            .store(in: &cancellables)
    }

    /// The window's height before it shrank to a strip, to grow back to.
    private var fullHeight: CGFloat?
    static let stripHeight: CGFloat = 58

    /// Shrinks to the one-line strip or grows back, keeping the top edge where
    /// it is so the window does not jump away from where the reader put it.
    private func applyStrip(_ strip: Bool) {
        guard let panel, panel.isVisible else { return }
        let frame = panel.frame
        let height: CGFloat
        if strip {
            fullHeight = frame.height
            panel.minSize = CGSize(width: 300, height: Self.stripHeight)
            height = Self.stripHeight
        } else {
            panel.minSize = CGSize(width: 340, height: 360)
            height = max(360, fullHeight ?? Self.defaultSize.height)
        }
        var target = CGRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)
        if let visible = panel.screen?.visibleFrame {
            target = FloatingPanelGeometry.clamped(target, to: visible)
        }
        panel.setFrame(target, display: true, animate: true)
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
        if CallaFloatingCallState.shared.strip {
            CallaFloatingCallState.shared.strip = false
            panel?.minSize = CGSize(width: 340, height: 360)
            if let panel, let height = fullHeight {
                let frame = panel.frame
                panel.setFrame(CGRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height),
                               display: false)
            }
        }
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
        // A strip is a passing state; the window comes back at its full size.
        guard !CallaFloatingCallState.shared.strip else { return }
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
    /// Shrunk to one line: the newest point and the clock.
    @Published var strip = false
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

/// The floating window: a small, calm instrument beside the faces.
///
/// Glass that lets the desktop through, one hairline, one soft shadow. The
/// meeting's name and the state sit at the top, where the window is dragged;
/// where the call stands is the hero, with what is settled and still open
/// under it; then the live transcript, people drawn as their initials with the
/// one speaking marked; End at the foot. It shrinks to a one-line strip.
struct CallaFloatingCallView: View {
    @ObservedObject private var engine = CallaEngineClient.shared
    @ObservedObject private var session = CopilotLiveSession.shared
    @ObservedObject private var state = CallaFloatingCallState.shared
    @ObservedObject private var zenState = CallaZenState.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @State private var now = Date()
    @State private var turns: [CallaCallTurn] = []
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let transcriptTick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private var copilot: CallaCopilotStatus { engine.status.copilot }
    private var halfDeaf: Bool { copilot.running && !copilot.systemAudioActive }
    private var account: CallaCallAccount { CallaCallAccount(copilot.summary) }
    private var points: [String] { (account.standing.isEmpty ? [] : [account.standing]) + account.points }
    private var tint: Color { halfDeaf ? CallaCallInk.problem : CallaCallInk.summary }
    private var elapsed: String { CallaCopilotPresentation.elapsed(since: copilot.startedAt, now: now) ?? "0:00" }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: state.strip ? CallaFloatingCallWindow.stripHeight / 2 : 24,
                         style: .continuous)
    }

    var body: some View {
        Group {
            if state.strip { strip } else { window }
        }
        .background { glass }
        .overlay(shape.strokeBorder(state.nearDock ? NotchAccent.quiz.opacity(0.85) : Color.white.opacity(0.13),
                                    lineWidth: state.nearDock ? 2 : 1))
        .overlay(alignment: .top) {
            // The lit top edge that makes the pane read as glass.
            shape
                .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.10), .clear],
                                             startPoint: .top, endPoint: .center), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .clipShape(shape)
        .foregroundStyle(NotchInk.primary)
        .preferredColorScheme(.dark)
        .animation(.smooth(duration: 0.3), value: state.strip)
        .onReceive(tick) { now = $0 }
        .onReceive(transcriptTick) { _ in refreshTranscript() }
        .onAppear { zenState.note(account.currentTopic) }
        .onChange(of: account.currentTopic) { _, topic in zenState.note(topic) }
    }

    /// Material where the desktop should show through, tinted dark enough
    /// that white text holds over a bright page; plain near-black otherwise.
    @ViewBuilder private var glass: some View {
        if reduceTransparency {
            shape.fill(Color(white: 0.09))
        } else {
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(Color.black.opacity(0.55))
            }
        }
    }

    // MARK: Strip

    private var strip: some View {
        HStack(spacing: 12) {
            NotchStateDot(tint: tint)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 8) {
                    if zenState.isNew(at: context.date) && !halfDeaf {
                        Text("NEW")
                            .font(.system(size: 10.5, weight: .bold))
                            .tracking(notchCapsTracking)
                            .foregroundStyle(CallaCallInk.summary)
                    }
                    Text(stripLine)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
            Text(elapsed)
                .font(.system(size: 11.5, design: .monospaced).monospacedDigit())
                .foregroundStyle(NotchInk.secondary)
            CallaWingButton(symbol: "chevron.down") { state.strip = false }
                .help("Show the whole call")
                .accessibilityLabel("Expand the window")
        }
        .padding(.leading, 20)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CallaWindowDragArea())
    }

    private var stripLine: String {
        if halfDeaf { return "Their side isn’t coming through" }
        return points.last.map { CallaCopilotPresentation.headlineLine($0, limit: 120) ?? $0 }
            ?? (copilot.meetingTitle ?? "Listening")
    }

    // MARK: Window

    private var window: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Group {
                if halfDeaf { trouble } else { standing }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)

            Rectangle()
                .fill(Color.white.opacity(0.09))
                .frame(height: 1)
                .padding(.horizontal, 20)
                .padding(.top, 16)

            transcript
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .opacity(halfDeaf ? 0.45 : 1)
                .frame(maxHeight: .infinity, alignment: .top)

            footer
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Capsule()
                .fill(Color.white.opacity(state.nearDock ? 0.6 : 0.24))
                .frame(width: 36, height: 5)
                .padding(.top, 9)
                .accessibilityHidden(true)
            HStack(spacing: 12) {
                NotchStateDot(tint: tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(copilot.meetingTitle.flatMap { $0.isEmpty ? nil : $0 } ?? "Call")
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(1)
                    if state.nearDock {
                        Text("Let go to put it back in the notch")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(NotchAccent.quiz)
                    } else {
                        (Text(halfDeaf ? "Only hearing you · " : "Listening to both sides · ")
                         + Text(elapsed).font(.system(size: 11.5, design: .monospaced).monospacedDigit()))
                            .font(.system(size: 11.5))
                            .foregroundStyle(halfDeaf ? CallaCallInk.problem : NotchInk.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                CallaWingButton(symbol: "minus") { state.strip = true }
                    .help("Shrink to a strip")
                    .accessibilityLabel("Shrink to a strip")
                CallaWingButton(symbol: "pip.enter") { session.dock() }
                    .help("Put back in the notch")
                    .accessibilityLabel("Put the call panel back in the notch")
            }
            .padding(.leading, 20)
            .padding(.trailing, 12)
        }
        .background(CallaWindowDragArea())
    }

    private var standing: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text("WHERE IT STANDS")
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(notchCapsTracking)
                    .foregroundStyle(CallaCallInk.summary)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if zenState.isNew(at: context.date) {
                        Text("NEW")
                            .font(.system(size: 9.5, weight: .bold))
                            .tracking(notchCapsTracking)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
            }
            if let newest = points.last {
                Text(newest)
                    .font(.system(size: 19, weight: .medium))
                    .tracking(-0.2)
                    .lineSpacing(3)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .id(newest)
                    .transition(.opacity)
            } else {
                let content = CallaZenReading.content(now: now, level: .brief)
                Text(content.before ?? "Listening")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
            let settled = Array(points.dropLast().suffix(2))
            let open = Array(copilot.openQuestions.prefix(2))
            if !settled.isEmpty || !open.isEmpty {
                HStack(alignment: .top, spacing: 18) {
                    column("Settled", tint: NotchInk.tertiary, lines: settled) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8.5, weight: .heavy))
                            .foregroundStyle(CallaCallInk.summary)
                    }
                    column("Still open", tint: CallaCallInk.answer, lines: open) {
                        Circle().strokeBorder(CallaCallInk.answer, lineWidth: 1.6).frame(width: 8, height: 8)
                    }
                }
                .padding(.top, 8)
            }
        }
        .animation(.smooth(duration: 0.4), value: points)
    }

    private func column<Mark: View>(_ title: String, tint: Color, lines: [String],
                                    @ViewBuilder mark: @escaping () -> Mark) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if !lines.isEmpty {
                Text(title.uppercased())
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(notchCapsTracking)
                    .foregroundStyle(tint)
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        mark().frame(width: 10)
                        Text(line)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(2)
                            .help(line)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var trouble: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Their side isn’t coming through")
                .font(.system(size: 20, weight: .semibold))
                .tracking(-0.2)
            Text("Only your microphone is being captured, so you are still being written down. Allow call audio so the other side is heard too.")
                .font(.system(size: 13))
                .lineSpacing(2)
                .foregroundStyle(NotchInk.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Text("Allow call audio")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(NotchAccent.onAccent)
                    .padding(.horizontal, 16)
                    .frame(height: 32)
                    .background(Capsule().fill(CallaCallInk.problem))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Text("LIVE TRANSCRIPT")
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(notchCapsTracking)
                    .foregroundStyle(NotchInk.tertiary)
                Spacer(minLength: 4)
                if let speaker = speakingLabel {
                    CallaWaveBars(tint: CallaCallInk.summary, active: true)
                    Text(speaker)
                        .font(.system(size: 11))
                        .foregroundStyle(NotchInk.secondary)
                }
            }
            if turns.isEmpty {
                Text("Turns appear here as they are transcribed on this Mac.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(NotchInk.tertiary)
            } else {
                let shown = Array(turns.suffix(4))
                VStack(alignment: .leading, spacing: 11) {
                    ForEach(shown, id: \.seq) { turn in
                        turnRow(turn, newest: turn.seq == shown.last?.seq)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .clipped()
                .mask(alignment: .bottom) {
                    LinearGradient(colors: [.clear, .black, .black],
                                   startPoint: .top, endPoint: .init(x: 0.5, y: 0.22))
                }
                .animation(.easeOut(duration: 0.2), value: turns.last?.seq)
            }
        }
    }

    private var speakingLabel: String? {
        switch copilot.speaking {
        case "them": return turns.last(where: \.isRemote).map { "\($0.speakerLabel) is speaking" } ?? "They are speaking"
        case "me": return "You are speaking"
        default: return nil
        }
    }

    private func turnRow(_ turn: CallaCallTurn, newest: Bool) -> some View {
        let speaking = newest && ((turn.isRemote && copilot.speaking == "them") || (!turn.isRemote && copilot.speaking == "me"))
        return HStack(alignment: .top, spacing: 10) {
            CallaInitials(name: turn.speakerLabel, isYou: !turn.isRemote, speaking: speaking)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(turn.speakerLabel)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.86))
                    Text(turn.clock)
                        .font(.system(size: 10.5, design: .monospaced).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.42))
                }
                Text(turn.text)
                    .font(.system(size: 12.5))
                    .lineSpacing(1.5)
                    .foregroundStyle(newest ? NotchInk.primary : .white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .transition(.opacity.combined(with: .offset(y: 6)))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(copilot.screenshotCount > 0
                 ? "\(copilot.screenshotCount) screenshot\(copilot.screenshotCount == 1 ? "" : "s") added"
                 : "Hidden from screen sharing when that setting is on")
                .font(.system(size: 11))
                .foregroundStyle(NotchInk.tertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
            CallaEndPill(title: "End call") { engine.endCall(origin: "floatingEnd") }
                .help("End the call")
                .accessibilityLabel("End call")
        }
        .padding(.leading, 20)
        .padding(.trailing, 14)
        .padding(.vertical, 14)
    }

    private func refreshTranscript() {
        guard copilot.running, !state.strip else { return }
        engine.fetchTranscript(since: turns.last?.seq) { fresh in
            guard !fresh.isEmpty else { return }
            let known = Set(turns.map(\.seq))
            turns.append(contentsOf: fresh.filter { !known.contains($0.seq) })
            if turns.count > 60 { turns.removeFirst(turns.count - 60) }
        }
    }
}

/// A person in the call, as their initial on a colour of their own — the
/// same colour every time their name comes up. A ring marks who is speaking.
struct CallaInitials: View {
    let name: String
    let isYou: Bool
    let speaking: Bool

    private static let palette: [(Color, Color)] = [
        (Color(notchHex: 0x3A4A5E), Color(notchHex: 0xCFE2F7)),
        (Color(notchHex: 0x4E3F5C), Color(notchHex: 0xE7D6F5)),
        (Color(notchHex: 0x3F5A4A), Color(notchHex: 0xD3F0DE)),
        (Color(notchHex: 0x5E4A3A), Color(notchHex: 0xF7E2CF)),
        (Color(notchHex: 0x5A3F4A), Color(notchHex: 0xF0D3DE))
    ]

    private var colours: (Color, Color) {
        if isYou { return (Color(notchHex: 0x5C4A36), Color(notchHex: 0xF5E3CC)) }
        // Stable across launches, unlike `hashValue`.
        let sum = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return Self.palette[sum % Self.palette.count]
    }

    var body: some View {
        let initial = name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?"
        Text(initial)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(colours.1)
            .frame(width: 24, height: 24)
            .background(Circle().fill(colours.0))
            .overlay(Circle().strokeBorder(CallaCallInk.summary, lineWidth: speaking ? 2 : 0))
            .accessibilityHidden(true)
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
