import AppKit
import SwiftUI

// MARK: - Corner grip

/// The notch's bottom-right corner, repeated a few points outside itself.
///
/// The first version of this traced the corner too, but with a hardcoded radius
/// that did not match the shape's own, drawn hard against the edge — so it read
/// as a seam in the panel rather than as a handle. This one is concentric with
/// the real curve, driven by the same radius `NotchShape` is drawing, and it is
/// separated from the panel by clear air. The gap is the whole trick: an arc
/// touching the edge is part of the notch, and an arc floating beside it is
/// something you can take hold of.
struct NotchResizeGrip: View {
    /// The radius the notch is drawing its bottom corners at, right now.
    var cornerRadius: CGFloat = 24
    /// How far the shape's straight right edge sits inside its own bounds.
    ///
    /// `NotchShape` flares outward at the top, so its vertical sides run at
    /// `maxX - topCornerRadius`, not at `maxX` — the bottom-right corner point
    /// is that far in from the layout's trailing edge. Without this the arc is
    /// concentric with a corner the panel does not have.
    var sideInset: CGFloat = 19
    /// Clear air between the panel edge and the arc.
    var gap: CGFloat = 5

    @ObservedObject private var session = NotchResizeSession.shared

    /// Published by the panel, not by `onHover` — see `hoveredControl`.
    private var hovering: Bool { session.hoveredControl == "resize-grip" }
    private var active: Bool { session.isDragging }

    /// Large enough to hold the outer bracket and its tails, and to be grabbed
    /// without pixel aim while the corner is moving with the pointer.
    ///
    /// Public because the grip is placed by its bottom-right corner rather than
    /// by an alignment guide — see `NotchPaintedRectKey`.
    static let boxSize: CGFloat = 58
    private var box: CGFloat { Self.boxSize }
    private let tail: CGFloat = 11

    private var radius: CGFloat { cornerRadius + gap }
    private var lineWidth: CGFloat { active ? 3 : (hovering ? 2.8 : 2.2) }
    private var tint: Color {
        active ? Color.effectiveAccent : Color.white.opacity(hovering ? 0.92 : 0.44)
    }

    var body: some View {
        ZStack {
            Color.clear

            // Carries the arc over a bright wallpaper. Blurred rather than
            // hard-stroked: a crisp black outline beside the panel is the seam
            // this design exists to stop drawing.
            CornerArc(radius: radius, tail: tail)
                .stroke(Color.black.opacity(0.45),
                        style: StrokeStyle(lineWidth: lineWidth + 3, lineCap: .round))
                .blur(radius: 2)

            if hovering || active {
                CornerArc(radius: radius, tail: tail)
                    .stroke(Color.effectiveAccent.opacity(active ? 0.55 : 0.32),
                            style: StrokeStyle(lineWidth: lineWidth + 5, lineCap: .round))
                    .blur(radius: 7)
            }

            CornerArc(radius: radius, tail: tail)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

            // A second, shorter bracket outside the first. Two concentric arcs
            // read as a grip; one reads as an edge. It is only drawn under the
            // pointer, so the resting state stays as quiet as the panel.
            CornerArc(radius: radius + 6, tail: tail * 0.55)
                .stroke(tint.opacity(hovering || active ? 0.55 : 0),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
        .frame(width: box, height: box)
        // The box's bottom-right corner lands on the notch's own corner point,
        // offset outward by the gap — which puts the straight tails exactly
        // `gap` off each edge of the shape.
        .offset(x: gap - sideInset, y: gap)
        .contentShape(Rectangle())
        .highPriorityGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    session.drag(translation: value.translation)
                }
                .onEnded { _ in session.endDrag() }
        )
        .accessibilityElement()
        .accessibilityLabel("Resize notch")
        .accessibilityValue(
            "\(Int(session.liveSize.width)) by \(Int(session.liveSize.height)) points"
        )
        .help("Drag to resize · arrow keys nudge · Escape closes")
        .background(
            NotchInteractiveRegionReporter(
                id: "resize-grip",
                hitPadding: 8,
                priority: 20,
                cursor: .resizeCorner
            )
        )
        .animation(.easeOut(duration: 0.14), value: hovering)
        .animation(.easeOut(duration: 0.14), value: active)
    }
}

/// One corner of `NotchShape`, drawn the same way it draws it — a quad curve
/// with the control point at the corner — with a straight lead-in along each
/// edge so the bracket has ends rather than stopping mid-turn.
private struct CornerArc: Shape {
    var radius: CGFloat
    var tail: CGFloat

    /// The radius animates with the notch's own, so the arc never lags the edge
    /// it is tracking during an open, a close, or a drag.
    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let corner = CGPoint(x: rect.maxX, y: rect.maxY)
        var path = Path()
        path.move(to: CGPoint(x: corner.x, y: corner.y - radius - tail))
        path.addLine(to: CGPoint(x: corner.x, y: corner.y - radius))
        path.addQuadCurve(to: CGPoint(x: corner.x - radius, y: corner.y), control: corner)
        path.addLine(to: CGPoint(x: corner.x - radius - tail, y: corner.y))
        return path
    }
}

// MARK: - The tray

/// The detached control bar under the notch.
///
/// One row of controls and, until the corner has been dragged once, a hint line
/// telling the reader where the handle is. The hint lives here rather than as a
/// floating marker beside the corner: a label the panel already has room for
/// costs nothing, where a second overlay next to the grip was one more thing
/// drawn over the desktop.
struct NotchResizeEditorBar: View {
    @ObservedObject private var session = NotchResizeSession.shared
    @Namespace private var segment

    var body: some View {
        VStack(spacing: 0) {
            controls
            if !session.hasDragged {
                hint
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(6)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.black.opacity(0.46))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.55), radius: 14, y: 6)
        .fixedSize()
        .background(
            NotchInteractiveRegionReporter(
                id: "resize-editor",
                hitPadding: 22,
                priority: 10,
                cursor: .standard
            )
        )
        .animation(.easeOut(duration: 0.18), value: session.hasDragged)
        .accessibilityElement(children: .contain)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            profileSelector

            sizeReadout

            resetButton

            doneButton
        }
    }

    // MARK: Profile picker

    private var profileSelector: some View {
        HStack(spacing: 2) {
            segmentButton(.normal, title: "Normal")
            segmentButton(.callExpanded, title: "Call · Full")
            segmentButton(.callCollapsed, title: "Call · Compact")
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(.black.opacity(0.32))
        )
    }

    private func segmentButton(_ profile: NotchSizeProfile, title: String) -> some View {
        let selected = session.activeProfile == profile
        return Button { select(profile) } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(selected ? Color.white : Color.white.opacity(0.55))
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background {
                    if selected {
                        // Matched geometry so the pill slides between segments
                        // instead of blinking out of one and into the next.
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.white.opacity(0.16))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                            )
                            .matchedGeometryEffect(id: "segment", in: segment)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(profile.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func select(_ profile: NotchSizeProfile) {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            session.select(profile)
        }
    }

    // MARK: Readout

    /// The live size, and nothing else. It turns amber the moment the corner
    /// stops following the pointer, which is the only time a reader wonders
    /// whether the drag or the app is at fault.
    private var sizeReadout: some View {
        HStack(spacing: 3) {
            Text("\(Int(session.liveSize.width))")
            Text("×").foregroundStyle(.white.opacity(0.32))
            Text("\(Int(session.liveSize.height))")
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(session.isAtLimit ? NotchTint.attention : .white.opacity(0.66))
        .contentTransition(.numericText())
        .frame(width: 82, height: 26)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(0.05))
        )
        .help(readoutHelp)
        .accessibilityLabel("Size")
        .accessibilityValue("\(Int(session.liveSize.width)) by \(Int(session.liveSize.height))")
    }

    private var readoutHelp: String {
        if let floor = session.activeFloor {
            return "This tab never opens below \(Int(floor.width)) × \(Int(floor.height)), so the panel is drawn at that size"
        }
        if session.isAtLimit {
            return "This size is at the limit for \(session.activeProfile.title)"
        }
        return "Width × height, in points"
    }

    // MARK: Buttons

    private var resetButton: some View {
        Button { session.resetActiveProfile() } label: {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.78))
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.white.opacity(0.08))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Reset \(session.activeProfile.title) to its default size")
        .accessibilityLabel("Reset \(session.activeProfile.title)")
    }

    private var doneButton: some View {
        Button { session.finish() } label: {
            HStack(spacing: 5) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                Text("Done")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Finish resizing · Escape")
        .accessibilityLabel("Done")
    }

    // MARK: Hint

    private var hint: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.up.right")
                .font(.system(size: 8, weight: .bold))
            Text("Drag the corner arc to resize · arrows nudge · esc closes")
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.42))
        .padding(.top, 7)
        .padding(.bottom, 1)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(height: 1)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Call preview

/// The notch's own header band while a call profile is being sized.
///
/// A copy of `CallaCopilotLiveHeader`'s shape with fixed values in place of the
/// engine's. The point of sizing a call layout is to see the call, so the panel
/// wears the call's chrome — the pulse, the heading, the clock, the capture
/// glyphs either side of the camera housing — rather than the tab row, which is
/// hidden for the whole length of a real call and would size the panel against
/// a header it will never have.
struct NotchResizeCallHeader: View {
    let profile: NotchSizeProfile
    @EnvironmentObject private var vm: CallaViewModel

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: NotchGlassSpace.tight) {
                LivePulse(active: true)
                Text("Answer")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(NotchInk.primary)
                    .lineLimit(1)
                    .fixedSize()
                Text("12:48")
                    .font(NotchGlassType.inlineFigure)
                    .foregroundStyle(NotchInk.secondary)
                    .lineLimit(1)
                    .fixedSize()
                if profile == .callExpanded {
                    CallaPill(text: "Preview", tint: NotchInk.tertiary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // The camera housing. Nothing may be drawn here.
            Color.clear.frame(width: vm.closedNotchSize.width)

            HStack(spacing: NotchGlassSpace.tight) {
                Spacer(minLength: 0)
                Image(systemName: "mic.fill")
                    .font(NotchGlassType.glyphSmall)
                    .foregroundStyle(NotchInk.secondary)
                Image(systemName: "eye.slash.fill")
                    .font(NotchGlassType.glyphSmall)
                    .foregroundStyle(NotchInk.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Call panel header preview")
    }
}

/// Static call content for sizing, laid out exactly as the live panel lays it
/// out: the same columns, paddings, type ramp and bottom control allowance. A
/// preview whose metrics differ from the real thing sizes the panel to the
/// wrong content, which is the one way this editor can be worse than no editor.
struct NotchResizeCallPreview: View {
    let profile: NotchSizeProfile

    private var isFull: Bool { profile == .callExpanded }

    var body: some View {
        VStack(alignment: .leading, spacing: NotchGlassSpace.snug) {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    answerColumn
                        .frame(width: isFull
                               ? max(0, (geometry.size.width - 1) * 0.54)
                               : geometry.size.width,
                               alignment: .leading)
                    if isFull {
                        NotchColumnDivider()
                        transcriptColumn
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(width: geometry.size.width - 4,
                       height: geometry.size.height - 2,
                       alignment: .leading)
                .padding(.top, 2)
                .padding(.horizontal, 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The strip the live panel reserves for its hover controls. Sizing
            // without it produces a panel whose last line is under the buttons.
            .padding(.bottom, isFull ? NotchGlassSpace.control + 8 : 0)
            .clipped()
            .overlay(alignment: .bottom) {
                if isFull { controlsGhost }
            }
        }
        .padding(.top, 0)
        .padding(.horizontal, 6)
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(NotchInk.primary)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Inert call panel size preview")
    }

    // MARK: Answer

    private var answerColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: isFull ? 11 : 8) {
                Text("I can start Monday. I’ll send milestones and owners before end of day.")
                    .font(isFull ? NotchGlassType.answer : NotchGlassType.answerLarge)
                    .foregroundStyle(NotchInk.primary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(2)
                if isFull {
                    supportingLine("Name the two milestones before scope comes up.",
                                   tint: NotchInk.hairline)
                    supportingLine("Check the start date against the holiday week.",
                                   tint: NotchTint.attention.opacity(0.6))
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !isFull {
                captionStrip
                    .padding(.bottom, 4)
                    .layoutPriority(1)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .clipped()
    }

    private var captionStrip: some View {
        VStack(alignment: .leading, spacing: 5) {
            Rectangle()
                .fill(NotchInk.hairline)
                .frame(height: 1)
            Text("When could your team begin?  Monday works. We’ll confirm scope today.")
                .font(NotchGlassType.detail)
                .foregroundStyle(NotchInk.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(height: 15, alignment: .bottomLeading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func supportingLine(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(NotchGlassType.detail)
            .foregroundStyle(NotchInk.secondary)
            .lineLimit(2)
            .padding(.leading, 12)
            .background(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(tint)
                    .frame(width: 3)
            }
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Transcript

    private var transcriptColumn: some View {
        VStack(alignment: .leading, spacing: NotchGlassSpace.snug) {
            HStack(spacing: NotchGlassSpace.tight) {
                NotchCaps("Transcript")
                Rectangle().fill(NotchInk.hairline).frame(height: 1)
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 9) {
                turn("Them", text: "We need someone who can pick this up quickly.",
                     newest: false, indented: false)
                turn("You", text: "We’ve shipped the same integration twice this quarter.",
                     newest: false, indented: true)
                turn("Them · now", text: "When could your team begin?",
                     newest: true, indented: false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .mask(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black, .black],
                               startPoint: .top,
                               endPoint: .init(x: 0.5, y: 0.22))
            }
        }
        .padding(.horizontal, 10)
        .clipped()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func turn(_ speaker: String, text: String, newest: Bool, indented: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            NotchCaps(speaker, tint: newest ? Color.effectiveAccent : NotchInk.tertiary)
            Text(text)
                .font(NotchGlassType.detail)
                .foregroundStyle(newest ? NotchInk.primary : NotchInk.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, indented ? 14 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The controls the live panel fades in on hover, drawn dim and inert. The
    /// row is what the reserved strip is *for*; leaving it empty made the space
    /// look like padding that could be sized away.
    private var controlsGhost: some View {
        HStack(spacing: 8) {
            ghostChip("Answers")
            ghostChip("So far")
            Spacer(minLength: 0)
            ghostChip("Collapse")
            ghostChip("End call")
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 2)
        .frame(height: NotchGlassSpace.control)
        .opacity(0.35)
    }

    private func ghostChip(_ title: String) -> some View {
        Text(title)
            .font(NotchGlassType.chipLabel)
            .foregroundStyle(NotchInk.secondary)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: NotchGlassRadius.glyph, style: .continuous)
                    .fill(NotchPlane.chip)
            )
    }
}

/// The bounds of the notch's painted shape, published to the view that places
/// the grip.
///
/// The grip cannot live inside that painted view: `.contentShape(currentNotchShape)`
/// further out replaces the hit region of everything under it with the notch's
/// own outline, and the arc is deliberately *outside* that outline — so a grip
/// anchored there draws in the right place and cannot be clicked. It cannot be
/// anchored to the outer frame either: that frame is `notchSize`, which the
/// layout does not always fill, and the painted shape ends up centred inside it.
/// So the painted view reports where it is, and the grip is placed from outside.
struct NotchPaintedRectKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

// MARK: - Hit-test islands

enum NotchPointerCursor {
    case standard
    case resizeCorner

    var cursor: NSCursor? {
        switch self {
        case .standard: nil
        case .resizeCorner:
            if #available(macOS 15.0, *) {
                NSCursor.frameResize(position: .bottomRight, directions: .all)
            } else {
                NSCursor.resizeLeftRight
            }
        }
    }
}

/// Registers one painted island with the panel.
///
/// The panel reads the view's frame when it needs it rather than being told,
/// because the two things that move these controls — the notch growing under a
/// drag and the bar sliding when the profile changes — are animations, and an
/// animation moves a view without re-running the body that would have reported
/// the new position. The rect that used to be pushed here went stale for the
/// whole length of the session, and a stale rect is a control that cannot be
/// clicked back to life.
struct NotchInteractiveRegionReporter: NSViewRepresentable {
    let id: String
    var hitPadding: CGFloat = 0
    /// Highest island under the pointer wins the cursor.
    var priority: Int = 0
    var cursor: NotchPointerCursor = .standard

    func makeNSView(context: Context) -> NSView {
        IslandView(id: id, hitPadding: hitPadding, priority: priority, cursor: cursor.cursor)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let island = nsView as? IslandView else { return }
        island.hitPadding = hitPadding
        island.priority = priority
        island.cursor = cursor.cursor
        island.register()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? IslandView)?.unregister()
    }

    final class IslandView: NSView {
        let id: String
        var hitPadding: CGFloat
        var priority: Int
        var cursor: NSCursor?
        private weak var registeredPanel: CallaNotchSkyLightWindow?

        init(id: String, hitPadding: CGFloat, priority: Int, cursor: NSCursor?) {
            self.id = id
            self.hitPadding = hitPadding
            self.priority = priority
            self.cursor = cursor
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                unregister()
            } else {
                register()
            }
        }

        func register() {
            guard let panel = window as? CallaNotchSkyLightWindow else { return }
            registeredPanel = panel
            panel.registerInteractiveView(
                self, id: id, padding: hitPadding, priority: priority, cursor: cursor
            )
        }

        func unregister() {
            registeredPanel?.unregisterInteractiveView(id: id, view: self)
            registeredPanel = nil
        }
    }
}
