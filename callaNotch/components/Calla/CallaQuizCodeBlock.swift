import AppKit
import Defaults
import SwiftUI

/// A code answer, drawn to be read in a notch.
///
/// The panel used to put the raw answer through one `Text` in flat white
/// monospace inside a two-axis `ScrollView`. That meant the ``` fences showed on
/// screen, every line was the same colour, and a long line could only be reached
/// by scrolling sideways — which, in a panel a few hundred points wide, means
/// losing your place vertically to read the end of a line.
///
/// So: fences gone, one row per line with a fixed gutter, long lines wrapped with
/// their continuation indented under the code rather than under the number, and
/// enough colour to see structure without turning the slab into a rainbow.
struct CallaQuizCodeBlock: View {
    let code: CallaQuizPresentation.CodeAnswer
    /// Compact panels take a little off the face; the code is the whole surface
    /// either way.
    var compact: Bool = false
    @Binding var wraps: Bool

    @Default(.callaQuizCodeFont) private var fontName
    @Default(.callaQuizCodeFontSize) private var fontSize
    @Default(.callaQuizCodeLineNumbers) private var showsLineNumbers
    @ObservedObject private var session = CopilotLiveSession.shared
    /// Where the keyboard has scrolled to, in lines.
    @State private var anchorLine = 0

    private var lines: [String] { code.lines }
    private var gutterWidth: CGFloat {
        // Enough for the widest line number, so the code edge never shifts.
        CGFloat(max(2, String(lines.count).count)) * (resolvedSize * 0.62) + 8
    }

    private var resolvedSize: CGFloat {
        let base = CGFloat(max(10, min(24, fontSize)))
        return compact ? max(10, base - 1) : base
    }

    /// The configured face, or the system monospaced one.
    ///
    /// `Font.custom` falls back to the *proportional* system font when a name is
    /// unknown, which is the one outcome code must never have — so the name is
    /// checked against AppKit first.
    private var face: Font {
        if !fontName.isEmpty, NSFont(name: fontName, size: resolvedSize) != nil {
            return .custom(fontName, fixedSize: resolvedSize)
        }
        return .system(size: resolvedSize, design: .monospaced)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The chrome is dropped in the compact panel rather than shrunk.
            //
            // A collapsed panel gives the answer around fifty points, and this
            // strip — a language tag, a line count and the wrap toggle — took
            // twenty of them. A one-line answer was therefore drawn half in and
            // half out of the card, cut through the middle by its own rounded
            // clip: the reader could see the caption saying "1 line" and not the
            // line. Nothing here is what the reader came for, and every one of
            // them is still there a keystroke away in the full layout.
            if !compact { header }
            ScrollViewReader { proxy in
                ScrollView(wraps ? [.vertical] : [.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: resolvedSize * 0.6 - 1) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { item in
                            row(number: item.offset + 1, line: item.element)
                                .id(item.offset)
                        }
                    }
                    .padding(.vertical, compact ? 8 : 14)
                    .frame(maxWidth: wraps ? .infinity : nil, alignment: .leading)
                }
                .onChange(of: session.quizAnswerScroll) { _, request in
                    guard request.tick > 0, !lines.isEmpty else { return }
                    let target = max(0, min(lines.count - 1, anchorLine + request.lines))
                    anchorLine = target
                    withAnimation(.smooth(duration: 0.18)) {
                        proxy.scrollTo(target, anchor: .top)
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Self.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: NotchGlassSpace.tight) {
            if let language = code.language {
                Text(language.uppercased())
                    .font(NotchGlassType.caps)
                    .tracking(notchCapsTracking)
                    .foregroundStyle(NotchInk.tertiary)
            }
            Text("\(lines.count) line\(lines.count == 1 ? "" : "s")")
                .font(NotchGlassType.minorFigure)
                .foregroundStyle(NotchInk.tertiary)
            Spacer(minLength: 4)
            // Wrapping is the default because sideways scrolling in a panel this
            // size loses your vertical place; the toggle is for the rare line
            // that genuinely reads better unbroken.
            NotchGlyphButton(symbol: wraps ? "text.alignleft" : "arrow.left.and.right",
                             help: wraps ? "Wrapping long lines" : "Long lines scroll sideways") {
                wraps.toggle()
            }
            .accessibilityLabel(wraps ? "Stop wrapping long lines" : "Wrap long lines")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.03))
    }

    /// A dark editor panel, so code reads as code against the slab.
    private static let panel = Color(notchHex: 0x0D1117)
    private static let ink = Color(notchHex: 0xE6EDF3)

    /// Names a solution reaches for that are the language's own, not the
    /// author's. Coloured apart from keywords and the author's functions.
    private static let builtins: Set<String> = [
        "print", "len", "range", "enumerate", "zip", "map", "filter", "sorted", "reversed",
        "sum", "min", "max", "abs", "any", "all", "list", "dict", "set", "tuple", "str",
        "int", "float", "bool", "isinstance", "heapq", "deque", "defaultdict", "Counter",
        "Math", "console", "Array", "Object", "String", "Number", "Set", "Map",
    ]

    private func row(number: Int, line: String) -> some View {
        HStack(alignment: .top, spacing: 0) {
            if showsLineNumbers, !(compact && lines.count == 1) {
                Text("\(number)")
                    .font(face)
                    .foregroundStyle(Color.white.opacity(0.32))
                    .frame(width: gutterWidth, alignment: .trailing)
                    .padding(.trailing, 8)
                    // The gutter is scaffolding, and reading it aloud line by
                    // line would bury the code.
                    .accessibilityHidden(true)
            }
            Text(highlighted(line))
                .font(face)
                .textSelection(.enabled)
                .fixedSize(horizontal: !wraps, vertical: true)
                .frame(maxWidth: wraps ? .infinity : nil, alignment: .leading)
        }
        .padding(.horizontal, compact ? 12 : 16)
    }

    /// Keywords lavender, the author's functions sky, the language's builtins
    /// aqua; strings mint, numbers sun, comments stepped back.
    private func highlighted(_ line: String) -> AttributedString {
        var result = AttributedString()
        let tokens = CallaQuizPresentation.tokenize(line)
        for (index, token) in tokens.enumerated() {
            var piece = AttributedString(token.text)
            let callsNext = tokens.dropFirst(index + 1).first { !$0.text.allSatisfy(\.isWhitespace) }?.text == "("
            switch token.role {
            case .keyword:
                piece.foregroundColor = Self.builtins.contains(token.text) ? NotchAccent.shelf : NotchAccent.home
            case .string: piece.foregroundColor = NotchAccent.call
            case .number: piece.foregroundColor = NotchAccent.focus
            case .comment: piece.foregroundColor = Color.white.opacity(0.45)
            case .plain:
                if Self.builtins.contains(token.text) {
                    piece.foregroundColor = NotchAccent.shelf
                } else if callsNext, token.text.first.map({ $0.isLetter || $0 == "_" }) == true {
                    piece.foregroundColor = NotchAccent.quiz
                } else {
                    piece.foregroundColor = Self.ink
                }
            }
            result.append(piece)
        }
        return result
    }
}
