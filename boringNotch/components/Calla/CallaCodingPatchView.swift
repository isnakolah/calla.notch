import CallaContracts
import SwiftUI

/// The colours a step is drawn in.
///
/// Lifted from `CodingCodeFormatter`'s `NSColor` values so the panel keeps the
/// palette it had; what changes is what the palette is *applied to*.
enum CodingCodeInk {
    static let keyword = Color(red: 0.70, green: 0.65, blue: 1.00)
    static let string = Color(red: 0.64, green: 0.86, blue: 0.67)
    static let number = Color(red: 1.00, green: 0.76, blue: 0.50)
    static let comment = Color(white: 0.59)
    static let plain = Color(red: 0.89, green: 0.92, blue: 0.96)

    static let gutter = Color.white.opacity(0.30)
    static let plane = Color(red: 0.045, green: 0.055, blue: 0.065)
    static let planeBorder = Color.white.opacity(0.085)

    static func color(for role: CallaQuizPresentation.CodeTokenRole) -> Color {
        switch role {
        case .keyword: return keyword
        case .string: return string
        case .number: return number
        case .comment: return comment
        case .plain: return plain
        }
    }

    /// Added lines carry the interview accent; removed lines the stopped tint.
    static let added = Color(red: 0.52, green: 0.90, blue: 0.78)
    static let removed = NotchTint.stuck
}

/// A step, drawn so the reader can see what is new without reading it.
///
/// What this replaces drew every line identically, numbered from 1, with the
/// guidance prose appended into the same scroll — so finding the two lines you
/// were meant to type meant reading all of them, and finding out why meant
/// scrolling past them. Four things fix that, and all four need the model to
/// have said something (`CodingPatch`): a change sign per line, real file line
/// numbers, context dimmed against the new code, and notes anchored to the line
/// they are about instead of appended as paragraphs.
struct CodingPatchView: View {
    let display: CodingPatchDisplay
    /// The compact panel drops the context marker and the notes; the code is
    /// the part that cannot be reconstructed by listening.
    var compact: Bool = false

    private var lineHeight: CGFloat { compact ? 15.5 : 16.5 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !compact, let above = display.linesAbove, above > 0 {
                contextMarker(above)
            }

            ForEach(display.rows) { row in
                line(row)
            }

            Spacer(minLength: 0)

            if !compact, !display.notes.isEmpty {
                Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(display.notes) { note in
                        HStack(alignment: .top, spacing: 8) {
                            NoteMarker(id: note.id)
                            Text(note.text)
                                .font(NotchGlassType.detail)
                                .foregroundStyle(NotchInk.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 7)
                .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(CodingCodeInk.plane.opacity(0.94),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(CodingCodeInk.planeBorder))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityReadout)
    }

    /// How much of the file is above the window, so a step anchored at line 118
    /// does not read as the top of the file.
    private func contextMarker(_ above: Int) -> some View {
        HStack(spacing: 0) {
            Text("⋯")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.22))
                .frame(width: 30, alignment: .trailing)
            Text("\(above) lines above")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(CodingCodeInk.gutter)
                .padding(.leading, 16)
        }
        .frame(height: 16)
    }

    private func line(_ row: CodingPatchRow) -> some View {
        HStack(spacing: 0) {
            Text(row.number.map(String.init) ?? "")
                .font(.system(size: 10, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(numberInk(row))
                .frame(width: 30, alignment: .trailing)

            Text(sign(row))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(signInk(row))
                .frame(width: 16, alignment: .center)

            source(row)
                .lineLimit(1)
                .truncationMode(.tail)

            if let note = row.note {
                NoteMarker(id: note).padding(.leading, 10)
            }

            Spacer(minLength: 0)
        }
        .frame(height: lineHeight)
        .background(rowFill(row))
        .overlay(alignment: .leading) {
            if row.kind != .context {
                Rectangle()
                    .fill(row.kind == .add ? CodingCodeInk.added : CodingCodeInk.removed)
                    .frame(width: 2)
            }
        }
    }

    private func source(_ row: CodingPatchRow) -> some View {
        // One `Text` per token rather than an attributed string: the row has to
        // stay a view so the sign, the fill and the note marker can lay out
        // beside it.
        CallaQuizPresentation.tokenize(row.text)
            .enumerated()
            .reduce(Text("")) { partial, token in
                partial + Text(token.element.text)
                    .foregroundColor(CodingCodeInk.color(for: token.element.role))
            }
            .font(.system(size: 11, design: .monospaced))
            // Context is dimmed so the eye lands on what is new — but only when
            // there is something new to land on. A step that is all context (a
            // move published before patches existed) has nothing to contrast
            // with, and dimming all of it would just make it hard to read.
            .opacity(display.hasChanges && row.kind == .context ? 0.55 : 1)
    }

    private func sign(_ row: CodingPatchRow) -> String {
        switch row.kind {
        case .add: return "+"
        case .remove: return "−"
        case .context: return display.hasChanges ? "·" : ""
        }
    }

    private func numberInk(_ row: CodingPatchRow) -> Color {
        row.kind == .remove ? CodingCodeInk.removed.opacity(0.55) : CodingCodeInk.gutter
    }

    private func signInk(_ row: CodingPatchRow) -> Color {
        switch row.kind {
        case .add: return CodingCodeInk.added
        case .remove: return CodingCodeInk.removed
        case .context: return Color.white.opacity(0.22)
        }
    }

    private func rowFill(_ row: CodingPatchRow) -> Color {
        switch row.kind {
        case .add: return CodingCodeInk.added.opacity(0.07)
        case .remove: return CodingCodeInk.removed.opacity(0.07)
        case .context: return .clear
        }
    }

    /// VoiceOver gets the shape of the step, not sixty characters of syntax.
    private var accessibilityReadout: String {
        guard display.hasChanges else {
            return "Code, \(display.rows.count) lines"
        }
        var parts: [String] = []
        if display.addedCount > 0 { parts.append("\(display.addedCount) lines added") }
        if display.removedCount > 0 { parts.append("\(display.removedCount) removed") }
        if let above = display.linesAbove, above > 0 { parts.append("from line \(above + 1)") }
        let notes = display.notes.map(\.text).joined(separator: ". ")
        return (parts.joined(separator: ", ") + (notes.isEmpty ? "" : ". " + notes))
    }
}

/// The circled number tying a line to the sentence about it.
private struct NoteMarker: View {
    let id: Int

    var body: some View {
        Text("\(id)")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(Color(red: 0.02, green: 0.07, blue: 0.055))
            .frame(width: 13, height: 13)
            .background(CodingCodeInk.added, in: Circle())
            .accessibilityHidden(true)
    }
}
