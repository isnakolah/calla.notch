//
//  NotchCard.swift
//  callaNotch
//

import KeyboardShortcuts
import SwiftUI

/// The vocabulary the notch's own surfaces are drawn from.
///
/// Settings was given `NotchDesignSystem` and the notch was not. What grew there
/// instead, across `PomodoroView`, `CallaTabView`, `CallaCopilotTabView` and
/// `CallaCopilotLiveView`, was fourteen distinct font sizes between 7 and 28pt,
/// twenty-seven distinct opacity values between 0.07 and 0.97, and three
/// independent copies of the same fix for the notch's inward-curving lower
/// corners. None of that was decided; it accumulated.
///
/// The surface treatment is taken from the Usage tab rather than invented: one
/// flat card at 4% white, a 6% border, radius 16, and columns separated by a
/// hairline that fades out at both ends. An earlier pass here used translucent
/// "glass" — a lit top lip, an inset highlight, a coloured bloom behind whatever
/// was live — which read as a different application sitting next to Home and
/// Usage. The notch already had a house style; this is it.
enum NotchInk {
    /// The answer the reader opened the notch for.
    static let primary = Color.white
    /// The sentence that explains it.
    static let secondary = Color.white.opacity(0.70)
    /// A sentence the reader is actually reading, at length, mid-interview.
    ///
    /// `secondary` is right for a supporting line beside something else. It is
    /// wrong for a paragraph that *is* the content — at 70% on a black slab, a
    /// two-line explanation read at a glance costs real effort.
    static let reading = Color.white.opacity(0.93)
    /// Labels, units, and anything that is off.
    ///
    /// 56%, not 42%: at 42% a 10pt label on the black slab fell below what can
    /// be read at a glance.
    static let tertiary = Color.white.opacity(0.56)
    /// A rule or a track. Never text.
    static let hairline = Color.white.opacity(0.12)
}

/// The card, exactly as the Usage tab draws it.
enum NotchPlane {
    static let fill = Color.white.opacity(0.04)
    static let border = Color.white.opacity(0.06)
    /// A control inside a card.
    static let chip = Color.white.opacity(0.08)
    static let control = Color.white.opacity(0.10)
    /// A progress track.
    static let track = Color.primary.opacity(0.1)
}

/// Six sizes. SF Rounded carries the figures and nothing else, because the notch
/// is nothing but corner radii and the figures are what change in place.
enum NotchGlassType {
    /// One per surface, at most. The number you read from across the desk.
    /// Sized to the Usage tab's own figure rather than larger: two tabs showing
    /// their headline number at different sizes is how a house style comes apart.
    static let hero = Font.system(size: 30, weight: .bold, design: .rounded).monospacedDigit()
    /// A count worth a glance — blocks today, lessons done.
    static let figure = Font.system(size: 24, weight: .bold, design: .rounded).monospacedDigit()
    /// The thing to read: a suggestion, a lesson step, a blocker.
    static let title = Font.system(size: 14, weight: .semibold)
    /// Fields, transcript turns, what you are working on.
    static let row = Font.system(size: 12)
    /// The explanation under a row.
    static let detail = Font.system(size: 11)
    /// Small print under a figure. The Usage tab's caption, by another name.
    static let caption = Font.system(size: 10)
    /// State and labels. Always tracked, always upper-cased at the call site.
    static let caps = Font.system(size: 10, weight: .bold)
    /// A figure inline with text — elapsed time, a count in a header.
    static let inlineFigure = Font.system(size: 11, design: .rounded).monospacedDigit()
    /// The smallest figure that still changes in place.
    static let minorFigure = Font.system(size: 10, design: .rounded).monospacedDigit()

    /// The live answer, collapsed — it has the card to itself, and this is the
    /// size it is read at from across a desk mid-sentence.
    static let answerLarge = Font.system(size: 16, weight: .semibold)
    /// The live answer, expanded — it shares the card with the transcript.
    static let answer = Font.system(size: 14, weight: .semibold)
    /// A primary button's label.
    static let action = Font.system(size: 12, weight: .semibold)
    /// A chip's label.
    static let chipLabel = Font.system(size: 11, weight: .medium)
    /// The state word in the header band either side of the camera housing.
    ///
    /// That band is not the card — it is narrower, split in two, and every label
    /// in it is `fixedSize`. Both live headers had reached for the same bare
    /// `.system(size: 11, weight: .semibold)` independently, which is how a
    /// seventh size gets into the vocabulary without anyone deciding on it.
    static let bandLabel = Font.system(size: 11, weight: .semibold)

    /// The closed notch's badges, either side of the camera housing.
    ///
    /// The seventh and eighth sizes, and the reason is written down: that band
    /// is about 22pt tall and the card's ramp does not fit in it. What it
    /// replaces is worse — the Pomodoro badge drew its figure at 12.5 and the
    /// usage badge drew its at 11.5, so the two things flanking one notch were
    /// a point apart from each other for no reason anyone chose.
    static let badgeFigure = Font.system(size: 11, weight: .bold, design: .rounded).monospacedDigit()
    static let badgeLabel = Font.system(size: 8, weight: .semibold, design: .rounded)
    static let badgeGlyph = Font.system(size: 14, weight: .semibold)

    /// Three glyph sizes, and no fourth. Icons had been drifting across 7, 8,
    /// 10, 12, 13 and 14pt in the same rows as each other.
    static let glyphSmall = Font.system(size: 9, weight: .semibold)
    static let glyph = Font.system(size: 11, weight: .medium)
    static let glyphLarge = Font.system(size: 13, weight: .bold)
    /// The disclosure arrow on a menu chip.
    static let chevron = Font.system(size: 8, weight: .bold)
}

enum NotchGlassRadius {
    static let card: CGFloat = 16
    static let chip: CGFloat = 10
    static let glyph: CGFloat = 7
}

enum NotchGlassSpace {
    /// A label to its own value.
    static let hair: CGFloat = 2
    /// Inside one control cluster.
    static let tight: CGFloat = 7
    /// Rows inside a card.
    static let snug: CGFloat = 6
    /// A card's own padding.
    static let card: CGFloat = 12
    /// Standard control height across every tab.
    static let control: CGFloat = 30
}

/// The closed notch's wings, either side of the camera housing.
///
/// One fact a side: icons and glyphs, never words. 116pt of content plus the
/// slab's own 14pt inset makes each wing about 120pt, so a closed notch with an
/// activity is the housing plus 240pt and nothing wider — except an inline song
/// change, which widens to 584pt overall.
enum NotchWing {
    static let width: CGFloat = 116
    static let inlineSongWidth: CGFloat = 196
    /// Hit-area growth for a closed notch with wings on both sides.
    static let chinGrowth: CGFloat = 240
}

/// The tracking on `NotchGlassType.caps`, applied wherever caps are drawn.
let notchCapsTracking: CGFloat = 0.8

// MARK: - Surfaces

extension View {
    /// The tab's one card. Same fill, border and radius as the Usage tab's.
    func notchCard() -> some View {
        background(
            RoundedRectangle(cornerRadius: NotchGlassRadius.card, style: .continuous)
                .fill(NotchPlane.fill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: NotchGlassRadius.card, style: .continuous)
                .strokeBorder(NotchPlane.border, lineWidth: 1)
        )
    }

    /// The insets every tab shares.
    ///
    /// The bottom one is load-bearing rather than cosmetic: the notch's lower
    /// corners curve inward, so a control row flush with the frame is drawn half
    /// outside the shape. Three views had each discovered that separately and
    /// written their own comment about it.
    ///
    /// What a tab actually gets is smaller than the notch, and this is the sum
    /// that two passes here got wrong. `openNotchSize` is 168pt, but
    /// `ContentView` draws the tab row above the tab at
    /// `max(24, vm.effectiveClosedNotchHeight)` — the real notch inset, 38pt on
    /// a 13-inch Air under the default `matchRealNotchSize`. So:
    ///
    ///     168 − 38 (tab row) − 14 (these insets) − 16 (card padding) ≈ 100pt
    ///
    /// One hundred points is the whole budget for a tab's content. A header
    /// line, a title, a caption and a control row is exactly that and nothing
    /// more; a fourth band does not fit, and the first version of these
    /// surfaces was drawn as though it did.
    func notchTabInsets() -> some View {
        padding(.top, 4)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
    }
}

/// The divider between two columns of one card, taken from the Usage tab: a
/// hairline that fades out at both ends rather than butting into the padding.
struct NotchColumnDivider: View {
    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [.clear, Color.primary.opacity(0.18), .clear],
                    startPoint: .top,
                    endPoint: .bottom)
            )
            .frame(width: 1)
            .padding(.vertical, 8)
    }
}

/// A progress track, drawn the way the Usage tab draws its quota bars.
struct NotchBar: View {
    let fraction: Double
    var tint: Color = .effectiveAccent
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(NotchPlane.track)
                Capsule()
                    .fill(tint)
                    .frame(width: geometry.size.width * max(0, min(1, fraction)))
            }
        }
        .frame(height: height)
    }
}

// MARK: - Shared pieces

/// Caps, tracked, in one ink step. The state of a surface — never its name: the
/// reader chose the tab and does not need to be told which one they opened.
struct NotchCaps: View {
    let text: String
    var tint: Color = NotchInk.tertiary

    init(_ text: String, tint: Color = NotchInk.tertiary) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text.uppercased())
            .font(NotchGlassType.caps)
            .tracking(notchCapsTracking)
            .foregroundStyle(tint)
            .lineLimit(1)
    }
}

/// Running, or not. Filled when live, an empty ring when idle — so the state
/// survives being read in greyscale or out of the corner of an eye.
struct NotchStatusDot: View {
    let live: Bool
    var tint: Color = .effectiveAccent

    var body: some View {
        Group {
            if live {
                Circle().fill(tint)
            } else {
                Circle().strokeBorder(NotchInk.tertiary, lineWidth: 1)
            }
        }
        .frame(width: 6, height: 6)
    }
}

/// A glyph button in a card's header line, styled like the Usage tab's refresh.
struct NotchGlyphButton: View {
    let symbol: String
    var help: String?
    /// Resting ink. Tertiary unless the glyph means something on its own —
    /// End is red, a held session is the accent.
    var tint: Color = NotchInk.tertiary
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(NotchGlassType.glyphSmall)
                .foregroundStyle(hovering && tint == NotchInk.tertiary ? NotchInk.primary : tint)
                .padding(4)
                .background(Circle().fill(hovering ? Color.primary.opacity(0.12) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help ?? "")
    }
}

/// The surface every chip and menu control in the notch sits on.
///
/// Three layers, because one flat wash was not enough on a black slab: a 8%
/// white rectangle over the notch had nothing to sit against and read as a gap
/// in the panel rather than as something you could press. Darkening first gives
/// the chip a floor; a top-lit gradient lifts it off that floor the way a
/// physical key catches light; and the border is brighter at the top edge than
/// the bottom, which is what makes it look raised rather than cut out.
///
/// Hover raises all three at once rather than swapping a colour, so a pointer
/// resting on a control reads as the control coming forward.
struct NotchChipBackground: View {
    var hovering = false
    var tint: Color?
    var radius: CGFloat = NotchGlassRadius.chip

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            shape.fill(Color.black.opacity(0.35))
            shape.fill(
                LinearGradient(
                    colors: tint.map {
                        [$0.opacity(hovering ? 0.38 : 0.28), $0.opacity(0.15)]
                    } ?? [
                        Color.white.opacity(hovering ? 0.24 : 0.17),
                        Color.white.opacity(hovering ? 0.12 : 0.07)
                    ],
                    startPoint: .top, endPoint: .bottom))
            shape.strokeBorder(
                LinearGradient(
                    colors: [
                        (tint ?? .white).opacity(hovering ? 0.46 : 0.30),
                        (tint ?? .white).opacity(0.08)
                    ],
                    startPoint: .top, endPoint: .bottom),
                lineWidth: 1)
        }
    }
}

/// A chip: the standard secondary control.
struct NotchChip<Content: View>: View {
    var tint: Color?
    var action: (() -> Void)?
    @ViewBuilder var content: Content

    @State private var hovering = false

    var body: some View {
        let body = HStack(spacing: NotchGlassSpace.tight) { content }
            .padding(.horizontal, 11)
            .frame(height: NotchGlassSpace.control)
            .background(NotchChipBackground(hovering: hovering && action != nil, tint: tint))
            .foregroundStyle(tint ?? (hovering ? NotchInk.primary : NotchInk.secondary))
            .font(.system(size: 11, weight: tint == nil ? .medium : .semibold))

        if let action {
            Button(action: action) { body.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
        } else {
            body
        }
    }
}

/// The header line inside a card: what state this is in, and the one or two
/// controls that belong to it.
///
/// This replaces a full-width chrome row that named the tab it was in. The tab
/// is already selected in the header above; saying "USAGE ·" again cost a band
/// of a 168pt surface to tell the reader something they did by hand.
struct NotchCardHeader<Trailing: View>: View {
    let state: String
    var live: Bool = false
    var tint: Color = .effectiveAccent
    var figure: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: NotchGlassSpace.tight) {
            NotchStatusDot(live: live, tint: tint)
            NotchCaps(state, tint: live ? NotchInk.secondary : NotchInk.tertiary)
            Spacer(minLength: 4)
            if let figure {
                Text(figure)
                    .font(NotchGlassType.inlineFigure)
                    .foregroundStyle(NotchInk.tertiary)
                    .lineLimit(1)
            }
            trailing
        }
        .frame(height: 18)
    }
}

extension NotchCardHeader where Trailing == EmptyView {
    init(state: String, live: Bool = false, tint: Color = .effectiveAccent, figure: String? = nil) {
        self.init(state: state, live: live, tint: tint, figure: figure) { EmptyView() }
    }
}

/// One key, or a pair of them, with the word that says what they do.
///
/// The word matters more than the glyph: an earlier version put an up arrow
/// beside `⌥⌘↑` and a left chevron beside `⌥⌘←`, so each item said the same
/// thing twice and nothing said what the key was *for*. Two directions of one
/// action belong together rather than reading as two unrelated bindings.
struct NotchKeyHint: View {
    let label: String
    let chords: [String]

    var body: some View {
        HStack(spacing: NotchGlassSpace.hair + 1) {
            Text(label)
                .font(NotchGlassType.caption)
                .foregroundStyle(NotchInk.tertiary)
            ForEach(chords, id: \.self) { chord in
                Text(chord)
                    .font(NotchGlassType.minorFigure)
                    .foregroundStyle(NotchInk.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(NotchPlane.chip,
                                in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// The keys that work on the live surface, drawn where they can be seen.
///
/// This was Quiz's alone. Every other live surface left its keys discoverable
/// only in Settings ▸ Shortcuts or behind a modal, which is not where anyone is
/// looking mid-question. Now that one key means one action on every surface
/// (`NotchSessionRouter`), one row can say so anywhere.
struct NotchSessionHints: View {
    let surface: NotchSessionSurface
    /// A live panel has room for a handful, not for the whole reference.
    var limit: Int = 6
    /// Keys that belong to this panel but not to the session vocabulary —
    /// Quiz's code wrapping, the notch pin. Drawn after the routed ones.
    var extras: [(label: String, name: KeyboardShortcuts.Name)] = []
    /// A surface's own word for a routed action, where the shared one is wrong
    /// for it — the call's `.surface` flips answers and recap, not history.
    var relabel: [NotchSessionAction: String] = [:]

    var body: some View {
        HStack(spacing: NotchGlassSpace.snug) {
            ForEach(hints, id: \.label) { hint in
                NotchKeyHint(label: hint.label, chords: hint.chords)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 16)
        // Every one of these is a global shortcut a VoiceOver reader reaches
        // without the notch. Reading the row out is noise.
        .accessibilityHidden(true)
    }

    private var hints: [(label: String, chords: [String])] {
        var result: [(label: String, chords: [String])] = []
        var used: Set<NotchSessionAction> = []

        func pair(_ label: String, _ actions: [NotchSessionAction]) {
            let chords = actions.compactMap { NotchSessionShortcuts.chord(for: $0) }
            guard chords.count == actions.count,
                  actions.allSatisfy({ NotchSessionRouter.effect(for: $0, on: surface) != nil })
            else { return }
            actions.forEach { used.insert($0) }
            result.append((label, chords))
        }

        // The two directions of one action, together.
        pair(relabel[.previous] ?? "Answer", [.previous, .next])
        pair("Scroll", [.scrollUp, .scrollDown])

        for action in NotchSessionRouter.hintedActions(for: surface) where !used.contains(action) {
            guard result.count < limit, let chord = NotchSessionShortcuts.chord(for: action) else { continue }
            result.append((relabel[action] ?? NotchSessionShortcuts.label(for: action), [chord]))
        }

        for extra in extras {
            guard result.count < limit,
                  let chord = KeyboardShortcuts.getShortcut(for: extra.name)?.description else { continue }
            result.append((extra.label, [chord]))
        }

        return Array(result.prefix(limit))
    }
}
