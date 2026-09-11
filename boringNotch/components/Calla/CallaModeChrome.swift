//
//  CallaModeChrome.swift
//  boringNotch
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
    /// Quiz and the plain call are both behind settings. The switcher shows
    /// only what is switched on, and hides itself entirely when that leaves one
    /// segment — a control with a single option is a control that cannot do
    /// anything.
    var includesQuiz: Bool = true
    var includesPlainCall: Bool = false

    private var modes: [CallaMode] {
        CallaMode.available(plainCall: includesPlainCall, quiz: includesQuiz)
    }

    var body: some View {
        if modes.count > 1 { switcher }
    }

    private var switcher: some View {
        HStack(spacing: 2) {
            ForEach(modes) { mode in
                let active = CallaMode.resolved(selection, plainCall: includesPlainCall, quiz: includesQuiz) == mode
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
            case .blocking: NotchTint.stuck
            case .working: NotchTint.active
            case .unknown: NotchInk.tertiary
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

/// The readiness of a session in one strip of glyphs.
///
/// Ready is deliberately quiet — a green glyph at 11pt is a colour you notice
/// only when it stops being green. Anything not ready is red, and it is the
/// only red on the panel.
///
/// Hovering one says what it is, in the detail line under the headline. The
/// system tooltip is set too, but a borderless SkyLight window is not a place to
/// rely on one: the answer to "what is that glyph?" has to be somewhere the
/// panel can draw it itself. `hovered` is how the card gets told.
struct CallaCheckStrip: View {
    let checks: [CallaCheck]
    @Binding var hovered: CallaCheck.ID?

    var body: some View {
        HStack(spacing: 9) {
            ForEach(checks) { check in
                Image(systemName: check.symbol)
                    .font(NotchGlassType.glyph)
                    .foregroundStyle(check.state.tint)
                    .frame(width: 14, height: 18)
                    .scaleEffect(hovered == check.id ? 1.18 : 1)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        withAnimation(.easeOut(duration: 0.12)) {
                            hovered = inside ? check.id : (hovered == check.id ? nil : hovered)
                        }
                    }
                    .help("\(check.label): \(check.value)")
                    .accessibilityLabel("\(check.label), \(check.value)")
            }
        }
        .fixedSize()
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
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(NotchGlassType.glyph)
                Text(title).font(NotchGlassType.action).lineLimit(1)
            }
            .foregroundStyle(NotchInk.primary)
            .padding(.horizontal, 13)
            .frame(height: NotchGlassSpace.control)
            .background(tint.opacity(enabled ? 1 : 0.35),
                        in: RoundedRectangle(cornerRadius: NotchGlassRadius.chip, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
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
        .background(NotchChipBackground(hovering: hovering, tint: tint ?? .effectiveAccent))
        .onHover { hovering = $0 }
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
                    .font(NotchGlassType.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(NotchGlassType.chevron)
                    .foregroundStyle(NotchInk.tertiary)
            }
            .foregroundStyle(hovering ? NotchInk.primary : tint)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .frame(maxWidth: 140, alignment: .leading)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .background(NotchChipBackground(hovering: hovering, radius: 7))
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
    var includesPlainCall: Bool = false

    /// The one thing that would stop this working, or what it is ready to do.
    let headline: String
    var headlineTint: Color = NotchInk.primary
    /// One line. Never two — the second line is the band that pushes the control
    /// row through the notch's lower curve.
    let detail: String
    let checks: [CallaCheck]

    /// What this session is about, in the header's leading group.
    @ViewBuilder var context: Context
    /// The rail at the foot of the card.
    @ViewBuilder var controls: Controls
    /// One glyph in the header's trailing corner — history, or settings.
    @ViewBuilder var utility: Utility

    /// Which readiness glyph the pointer is on, if any.
    @State private var hoveredCheck: CallaCheck.ID?

    /// The glyph strip has no room for labels, so hovering one borrows the
    /// detail line. Nothing moves and nothing is covered: the line is already
    /// one line of explanation, and for as long as the pointer is on a glyph it
    /// explains that glyph instead.
    private var hovered: CallaCheck? {
        guard let hoveredCheck else { return nil }
        return checks.first { $0.id == hoveredCheck }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NotchGlassSpace.snug) {
            header
            Text(headline)
                .font(NotchGlassType.title)
                .foregroundStyle(headlineTint)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(hovered.map { "\($0.label) · \($0.value)" } ?? detail)
                .font(NotchGlassType.caption)
                .foregroundStyle(hovered.map { $0.state.tint } ?? NotchInk.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .animation(.easeOut(duration: 0.12), value: hoveredCheck)
            HStack(spacing: NotchGlassSpace.tight) {
                controls
                Spacer(minLength: 10)
                CallaCheckStrip(checks: checks, hovered: $hoveredCheck)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .notchCard()
        .notchTabInsets()
    }

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
            Spacer(minLength: 6)
            CallaModeSwitcher(selection: $mode,
                              enabled: switcherEnabled,
                              includesQuiz: includesQuiz,
                              includesPlainCall: includesPlainCall)
            utility
        }
        .frame(height: 20)
    }
}
