//
//  CallaModeChrome.swift
//  callaNotch
//
//  The frame every Calla mode is drawn in, at rest.
//
//  Call, Quiz and Code are three answers to the same question — *will this work
//  if I press the button?* — and until this file existed they were three
//  unrelated panels. Each had invented its own header: the mode switcher sat on
//  the left in one and the right in the next, the state caps were present in
//  one and squeezed out of existence in another, Call drew its checks with a
//  bare `checkmark` while Code drew filled green circles, and Code reached for
//  `.buttonStyle(.bordered)` and `.textFieldStyle(.roundedBorder)`, which is a
//  System Settings sheet wearing a notch.
//
//  So the skeleton is written once here and the three modes fill it in:
//
//      ● READY  ⟨context ⌄⟩            [ Call │ Quiz │ Code ]  ⚙
//      ────────────────────────────────────────────────────────
//      Headline                        ✓ Microphone    allowed
//      one line of detail              ✓ Other side  captured
//                                      ✓ Agy        signed in
//      [chip] [ Primary ]              ✓ Speech          small
//
//  The height is the reason it is a component rather than a convention. A tab
//  gets about 100pt of content (see `notchTabInsets`), and that is the header,
//  the headline, the detail and the control row exactly — a fifth band does not
//  fit. Code had a fifth, a sixth and a seventh, and its buttons were drawn
//  through the notch's lower curve where nobody could press them.
//

import SwiftUI

// MARK: - Which mode

/// The mode switcher, drawn in the notch's own vocabulary.
///
/// It was a stock `Picker(.segmented)`, which paints its selection in the
/// system's saturated blue at full strength. On a black slab that reads as the
/// loudest thing on the panel — louder than the answer, louder than the primary
/// button, which is also accent-coloured — so the eye landed on a control that
/// says nothing about whether the call will work. Here the selection is a lift
/// in the ink rather than a colour, and the accent stays spent on one thing.
///
/// It is always the same modes, in the same order, at the same width, in the
/// same corner. Quiz used to be missing from the Quiz panel's own switcher, so
/// the only way back to Code from Quiz was through Call.
struct CallaModeSwitcher: View {
    @Binding var selection: String
    var enabled: Bool = true
    /// Quiz is behind a setting. The switcher shows only what is switched on,
    /// and hides itself entirely when that leaves one segment — a control with
    /// a single option is a control that cannot do anything.
    var includesQuiz: Bool = true

    private var modes: [CallaMode] {
        CallaMode.available(quiz: includesQuiz)
    }

    var body: some View {
        if modes.count > 1 { switcher }
    }

    private var switcher: some View {
        HStack(spacing: 2) {
            ForEach(modes) { mode in
                let active = CallaMode.resolved(selection, quiz: includesQuiz) == mode
                Text(mode.title)
                    .font(.system(size: 11, weight: active ? .semibold : .medium))
                    .foregroundStyle(active ? NotchInk.primary : NotchInk.tertiary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    // Sized to its label, not to a number. The fixed 44pt was
                    // chosen when every mode was a four-letter word; "Interview"
                    // rendered as "Interv…", which is a control that cannot say
                    // what it does. The minimum keeps the short labels from
                    // collapsing into something too small to hit.
                    .padding(.horizontal, 8)
                    .frame(minWidth: 44, minHeight: 20)
                    .background {
                        if active {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.white.opacity(0.14))
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard enabled, !active else { return }
                        withAnimation(.easeOut(duration: 0.16)) { selection = mode.rawValue }
                    }
                    .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
                    .accessibilityLabel(mode.title)
            }
        }
        .padding(2)
        .background {
            let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
            ZStack {
                shape.fill(Color.black.opacity(0.30))
                shape.fill(Color.white.opacity(0.05))
                shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
            }
        }
        .opacity(enabled ? 1 : 0.4)
        .allowsHitTesting(enabled)
        .help(enabled ? "Switch mode" : "A session is running")
        .fixedSize()
    }
}

// MARK: - Readiness

/// One fact a session needs, and whether it has it.
///
/// It is a glyph, not a row. The four facts had been a labelled column 190pt
/// wide, which is a third of a 512pt notch spent on four words that do not
/// change from one week to the next — and, worse, the column plus the header's
/// own controls asked for more width than the notch has, so the panel grew past
/// the width set in Settings and stopped matching every other tab.
///
/// What the reader actually needs from this band is "is anything red?". The
/// headline already names the one thing that is wrong and the primary button
/// already names the fix, so the detail belongs in the tooltip, where it costs
/// nothing until it is asked for.
struct CallaCheck: Identifiable {
    enum State {
        /// Armed and known good.
        case ready
        /// The thing standing between you and a working session.
        case blocking
        /// Working on it. Not a failure.
        case working
        /// Nobody has asked yet, which is not the same as denied.
        case unknown

        var tint: Color {
            switch self {
            case .ready: NotchTint.healthy
            case .blocking: NotchTint.attention
            case .working: NotchTint.active
            case .unknown: NotchInk.tertiary
            }
        }

        /// The mark beside a fact's name in the grid.
        var symbol: String {
            switch self {
            case .ready: "checkmark"
            case .blocking: "exclamationmark.triangle.fill"
            case .working: "arrow.down.circle"
            case .unknown: "circle.dotted"
            }
        }

        var word: String {
            switch self {
            case .ready: "ready"
            case .blocking: "not ready"
            case .working: "working"
            case .unknown: "not checked"
            }
        }
    }

    /// Named in the tooltip, not on the panel.
    let label: String
    let value: String
    let symbol: String
    let state: State

    var id: String { label }

    init(_ label: String, symbol: String, value: String, state: State) {
        self.label = label
        self.symbol = symbol
        self.value = value
        self.state = state
    }

    /// The common shape: one boolean, one word either way.
    init(_ label: String, symbol: String, ready: Bool, yes: String, no: String) {
        self.init(label, symbol: symbol, value: ready ? yes : no,
                  state: ready ? .ready : .blocking)
    }
}

/// The readiness of a session, as four named facts in two columns.
///
/// It was a strip of four unlabelled glyphs, which answered "is anything
/// wrong?" only for someone who had already learnt what each glyph meant. The
/// names cost one column beside the headline and nothing else: ready is a
/// quiet green tick, anything not ready is an orange warning and the name
/// itself turns orange, so the eye finds it without reading.
///
/// Hovering one says what it is, in the detail line under the headline. The
/// system tooltip is set too, but a borderless SkyLight window is not a place to
/// rely on one.
struct CallaCheckGrid: View {
    let checks: [CallaCheck]
    @Binding var hovered: CallaCheck.ID?

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
            ForEach(Array(stride(from: 0, to: checks.count, by: 2)), id: \.self) { index in
                GridRow {
                    cell(checks[index])
                    if index + 1 < checks.count { cell(checks[index + 1]) }
                }
            }
        }
        .fixedSize()
    }

    private func cell(_ check: CallaCheck) -> some View {
        HStack(spacing: 6) {
            Image(systemName: check.state.symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(check.state.tint)
                .frame(width: 12)
            Text(check.label)
                .font(NotchGlassType.detail)
                .foregroundStyle(check.state == .blocking ? NotchTint.attention
                                 : hovered == check.id ? NotchInk.primary : NotchInk.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) {
                hovered = inside ? check.id : (hovered == check.id ? nil : hovered)
            }
        }
        .help("\(check.label): \(check.value)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(check.label), \(check.value)")
    }
}

// MARK: - Controls

/// One primary button, and it says what pressing it does.
///
/// A panel that offers "Start" while the microphone is denied is lying by
/// omission: the session starts and hears nothing. The button becomes the fix
/// instead, so the next step is always the obvious one.
struct CallaPrimaryButton: View {
    let title: String
    let symbol: String
    var tint: Color = .effectiveAccent
    /// The label's colour. White on the accent; near-black on a light fill
    /// such as the orange a fix wears, where white would not read.
    var ink: Color = NotchInk.primary
    var enabled: Bool = true
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(NotchGlassType.glyph)
                Text(title).font(NotchGlassType.action).lineLimit(1)
            }
            .foregroundStyle(ink)
            .padding(.horizontal, 15)
            .frame(height: NotchGlassSpace.control)
            .background {
                RoundedRectangle(cornerRadius: NotchGlassRadius.chip, style: .continuous)
                    .fill(tint.opacity(enabled ? 1 : 0.35))
                    .brightness(hovering && enabled ? 0.06 : 0)
                    .shadow(color: tint.opacity(enabled ? 0.40 : 0), radius: 8, y: 3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel(title)
    }
}

/// A chip that opens a menu — the second control on a preflight's rail, never
/// the first. Same surface and metrics as `NotchChip`, so the rail reads as one
/// strip rather than as a button beside a piece of text.
///
/// Its glyph carries the accent. A menu chip in flat grey next to a filled
/// primary button reads as a caption that happens to be clickable, which is
/// exactly what "Context" and "Choose window" had become — and they are the one
/// decision each of those panels actually asks for.
struct CallaMenuChip<Content: View>: View {
    let title: String
    var symbol: String?
    var tint: Color?
    @ViewBuilder var content: Content

    @State private var hovering = false

    var body: some View {
        Menu {
            content
        } label: {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol).font(NotchGlassType.glyph)
                }
                Text(title)
                    .font(NotchGlassType.chipLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down").font(NotchGlassType.chevron)
            }
            .foregroundStyle(NotchInk.primary)
            .padding(.horizontal, 11)
            .frame(height: NotchGlassSpace.control)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        // Outside the label, not inside it. A `Menu`'s borderless style draws
        // its own chrome over the label's background on macOS, so a chip built
        // the way `NotchChip` builds one came out as bare text floating on the
        // card — the one control the reader has to find looked like a caption.
        //
        // Tinted, not grey. These are the *other* thing you can press on a
        // panel whose primary button is solid accent, and grey-on-black reads
        // as disabled next to it. A wash of the same accent at a fifth of the
        // strength says "same family, second in line" without competing.
        .background(NotchChipBackground(hovering: hovering, tint: tint))
        .onHover { hovering = $0 }
    }
}

/// A menu behind a single glyph, square and as tall as the primary button
/// beside it — for a secondary choice whose icon already says what it is.
///
/// Flat on purpose: no border, no gradient, just a faint fill that lifts on
/// hover, so it sits next to the primary button without competing with it. A
/// count, when there is one, rides the corner instead of becoming a label.
struct CallaMenuIconButton<Content: View>: View {
    let symbol: String
    var count: Int = 0
    @ViewBuilder var content: Content

    @State private var hovering = false

    var body: some View {
        Menu {
            content
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovering || count > 0 ? NotchInk.primary : NotchInk.secondary)
                .frame(width: NotchGlassSpace.control, height: NotchGlassSpace.control)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .background(
            RoundedRectangle(cornerRadius: NotchGlassRadius.chip, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.14 : 0.08))
        )
        .overlay(alignment: .topTrailing) {
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 9, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(minWidth: 14, minHeight: 14)
                    .background(Circle().fill(Color.effectiveAccent))
                    .offset(x: 4, y: -4)
                    .allowsHitTesting(false)
            }
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// The small chip in the header's leading group: what this session is *about* —
/// the persona, the meeting, the project. One per mode, and never more.
struct CallaContextChip<Content: View>: View {
    let title: String
    var symbol: String?
    var tint: Color = NotchInk.secondary
    @ViewBuilder var content: Content

    @State private var hovering = false

    var body: some View {
        Menu {
            content
        } label: {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(NotchGlassType.glyphSmall)
                        .foregroundStyle(NotchInk.tertiary)
                }
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(NotchGlassType.chevron)
                    .foregroundStyle(NotchInk.tertiary)
            }
            .foregroundStyle(hovering ? NotchInk.primary : tint)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .frame(maxWidth: 150, alignment: .leading)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.14 : 0.08))
        )
        .onHover { hovering = $0 }
    }
}

// MARK: - The frame

/// The card every Calla mode is drawn in at rest.
///
/// Two columns, always: the verdict on the left, the facts behind it on the
/// right. The left column is a fixed four bands — header, headline, detail,
/// controls — because that is what 100pt holds. Anything a mode wants beyond
/// those four belongs in Settings, in a menu, or in the detail line.
struct CallaPreflightCard<Context: View, Controls: View, Utility: View>: View {
    /// What state this is in — never the name of the mode. The reader chose the
    /// mode; the switcher on the right already says which one.
    let state: String
    var live: Bool = false
    var tint: Color = .effectiveAccent
    /// A running clock, or a count. Sits after the state.
    var figure: String?

    @Binding var mode: String
    var switcherEnabled: Bool = true
    var includesQuiz: Bool = true

    /// The one thing that would stop this working, or what it is ready to do.
    let headline: String
    var headlineTint: Color = NotchInk.primary
    /// One line. Never two — the second line is the band that pushes the control
    /// row through the notch's lower curve.
    let detail: String
    let checks: [CallaCheck]

    /// A quiet line at the trailing end of the rail — the next meeting, say.
    var note: String? = nil

    /// What this session is about, in the header's leading group.
    @ViewBuilder var context: Context
    /// The rail at the foot of the card.
    @ViewBuilder var controls: Controls
    /// One glyph in the header's trailing corner — history, or settings.
    @ViewBuilder var utility: Utility

    /// Which readiness fact the pointer is on, if any.
    @State private var hoveredCheck: CallaCheck.ID?

    /// The fact grid has no room for values, so hovering one borrows the
    /// detail line. Nothing moves and nothing is covered.
    private var hovered: CallaCheck? {
        guard let hoveredCheck else { return nil }
        return checks.first { $0.id == hoveredCheck }
    }

    var body: some View {
        // Straight on the notch, not in a card of its own: the notch is
        // already the container, and a second outline inside it only ate
        // space and doubled the corners.
        VStack(alignment: .leading, spacing: 0) {
            header
            Spacer(minLength: 6)
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(headlineTint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .truncationMode(.tail)
                    Text(hovered.map { "\($0.label) · \($0.value)" } ?? detail)
                        .font(NotchGlassType.detail)
                        .foregroundStyle(hovered.map { $0.state == .ready ? NotchInk.secondary : $0.state.tint }
                                         ?? NotchInk.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .animation(.easeOut(duration: 0.12), value: hoveredCheck)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                CallaCheckGrid(checks: checks, hovered: $hoveredCheck)
                    .padding(.top, 2)
            }
            Spacer(minLength: 6)
            HStack(spacing: NotchGlassSpace.tight) {
                controls
                Spacer(minLength: 10)
                if let note {
                    NotchCaps(note)
                        .truncationMode(.tail)
                        .layoutPriority(-1)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // One margin on the three sides the notch draws: ContentView already
        // insets the copilot glass by 4 at the sides and 12 at the foot, so
        // these make it 18 all round — enough to clear the lower corners'
        // curve. The top sits under the tab row, which brings its own air.
        .padding(EdgeInsets(top: 8, leading: Self.edge - 4, bottom: Self.edge - 12, trailing: Self.edge - 4))
    }

    private static var edge: CGFloat { 18 }

    private var header: some View {
        HStack(spacing: NotchGlassSpace.tight) {
            NotchStatusDot(live: live, tint: tint)
            NotchCaps(state, tint: live ? NotchInk.secondary : NotchInk.tertiary)
                .fixedSize()
            if let figure {
                Text(figure)
                    .font(NotchGlassType.inlineFigure)
                    .foregroundStyle(NotchInk.tertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
            context
            // A rule rather than a gap, so the header reads as one line with
            // its controls at the end of it.
            Rectangle()
                .fill(NotchInk.hairline)
                .frame(height: 1)
                .frame(minWidth: 6)
            CallaModeSwitcher(selection: $mode,
                              enabled: switcherEnabled,
                              includesQuiz: includesQuiz)
            utility
        }
        .frame(height: 20)
    }
}
