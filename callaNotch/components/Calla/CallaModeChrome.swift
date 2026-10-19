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
                    .font(.system(size: 11, weight: active ? .bold : .semibold))
                    .foregroundStyle(active ? NotchAccent.onAccent : Color.white.opacity(0.75))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 20)
                    .background {
                        if active {
                            Capsule().fill(mode.accent)
                        }
                    }
                    .frame(minHeight: 26)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard enabled, !active else { return }
                        withAnimation(.easeOut(duration: 0.16)) { selection = mode.rawValue }
                    }
                    .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
                    .accessibilityLabel(mode.title)
            }
        }
        .padding(.horizontal, 2)
        .frame(height: 24)
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .opacity(enabled ? 1 : 0.4)
        .allowsHitTesting(enabled)
        .help(enabled ? "Switch mode" : "A session is running")
        .fixedSize()
    }
}

extension CallaMode {
    /// Each mode owns one accent: mint for a call, sky for Quiz.
    var accent: Color {
        switch self {
        case .call: NotchAccent.call
        case .quiz: NotchAccent.quiz
        }
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
            case .ready: NotchAccent.call
            case .blocking: NotchAccent.attention
            case .working: NotchAccent.quiz
            case .unknown: NotchInk.tertiary
            }
        }

        /// The mark inside a fact's chip in the grid.
        var symbol: String {
            switch self {
            case .ready: "checkmark"
            case .blocking: "exclamationmark"
            case .working: "arrow.down"
            case .unknown: "ellipsis"
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
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
            ForEach(Array(stride(from: 0, to: checks.count, by: 2)), id: \.self) { index in
                GridRow {
                    cell(checks[index])
                    if index + 1 < checks.count { cell(checks[index + 1]) }
                }
            }
        }
    }

    /// A tinted chip with its mark, the fact's name, and its status under it.
    private func cell(_ check: CallaCheck) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: check.state.symbol)
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(check.state.tint)
                    .frame(width: 15, height: 15)
                    .background(Circle().fill(check.state == .unknown
                                              ? Color.white.opacity(0.10)
                                              : check.state.tint.opacity(check.state == .blocking ? 0.20 : 0.18)))
                Text(check.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(hovered == check.id ? NotchInk.primary : NotchInk.primary.opacity(0.94))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            Text(check.value)
                .font(.system(size: 11))
                .foregroundStyle(check.state == .blocking ? NotchAccent.attention : NotchInk.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, 21)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
    var tint: Color = NotchAccent.call
    /// The label's colour. Every accent in the notch palette is light, so the
    /// label on it is near-black.
    var ink: Color = NotchAccent.onAccent
    var enabled: Bool = true
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 12, weight: .bold))
                Text(title).font(.system(size: 12, weight: .bold)).lineLimit(1)
            }
            .foregroundStyle(ink.opacity(enabled ? 1 : 0.6))
            .padding(.leading, 13)
            .padding(.trailing, 16)
            .frame(height: 34)
            .background {
                Capsule()
                    .fill(tint.opacity(enabled ? 1 : 0.35))
                    .brightness(hovering && enabled ? 0.06 : 0)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// The second thing you can press beside a primary pill: a quiet 30pt capsule.
struct CallaSecondaryButton: View {
    let title: String
    var symbol: String?
    var tint: Color?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(tint ?? Color.white.opacity(0.86))
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Capsule().fill((tint ?? .white).opacity(hovering ? 0.16 : 0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}

/// A round glyph button in a Calla header — history, settings. 24pt drawn,
/// 26pt to the pointer.
struct CallaHeaderGlyphButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hovering ? NotchInk.primary : NotchInk.secondary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(hovering ? Color.white.opacity(0.10) : .clear))
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
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
    var tint: Color = NotchAccent.call
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
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(NotchAccent.onAccent)
                    .frame(minWidth: 15, minHeight: 15)
                    .background(Circle().fill(tint))
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
    var tint: Color = Color.white.opacity(0.86)
    @ViewBuilder var content: Content

    @State private var hovering = false

    var body: some View {
        Menu {
            content
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .heavy))
            }
            .foregroundStyle(hovering ? NotchInk.primary : tint)
            .padding(.leading, 9)
            .padding(.trailing, 8)
            .frame(height: 22)
            .frame(maxWidth: 150, alignment: .leading)
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .background(Capsule().fill(Color.white.opacity(hovering ? 0.14 : 0.08)))
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
    /// The state dot and caps. The mode's accent when ready, orange when not.
    var tint: Color = NotchAccent.call
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
        VStack(alignment: .leading, spacing: 8) {
            header
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(headline)
                            .font(.system(size: 16, weight: .semibold))
                            .tracking(-0.1)
                            .foregroundStyle(headlineTint)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .truncationMode(.tail)
                        Text(hovered.map { "\($0.label) · \($0.value)" } ?? detail)
                            .font(NotchGlassType.detail)
                            .foregroundStyle(hovered.map { $0.state == .blocking ? $0.state.tint : NotchInk.secondary }
                                             ?? NotchInk.secondary)
                            .lineLimit(2)
                            .lineSpacing(1)
                            .truncationMode(.tail)
                            .animation(.easeOut(duration: 0.12), value: hoveredCheck)
                    }
                    Spacer(minLength: 6)
                    HStack(spacing: 6) {
                        controls
                        if let note {
                            ViewThatFits(in: .horizontal) {
                                NotchCaps(note).fixedSize().padding(.leading, 4)
                                Color.clear.frame(width: 0, height: 0)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                CallaCheckGrid(checks: checks, hovered: $hoveredCheck)
                    .padding(.leading, 14)
                    .frame(width: 204)
                    .frame(maxHeight: .infinity)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(NotchInk.hairline).frame(width: 1)
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // One margin on the three sides the notch draws: ContentView already
        // insets the copilot glass by 4 at the sides and 12 at the foot, so
        // these make it 18 all round — enough to clear the lower corners'
        // curve. The top sits under the tab row, which brings its own air.
        .padding(EdgeInsets(top: 2, leading: Self.edge - 4, bottom: Self.edge - 12, trailing: Self.edge - 4))
    }

    private static var edge: CGFloat { 18 }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
            NotchCaps(state, tint: tint)
                .fixedSize()
            if let figure {
                Text(figure)
                    .font(.system(size: 11, design: .monospaced).monospacedDigit())
                    .foregroundStyle(NotchInk.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            context
            Spacer(minLength: 6)
            CallaModeSwitcher(selection: $mode,
                              enabled: switcherEnabled,
                              includesQuiz: includesQuiz)
            utility
        }
        .frame(height: 24)
    }
}
