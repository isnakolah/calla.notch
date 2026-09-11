import AppKit
import CallaContracts
import SwiftUI

/// What a finished Quiz leaves behind.
///
/// `.finished` and `.failed` both make `QuizSessionSnapshot.active` false, which
/// dropped `isLive`, unpinned the notch, and tore the panel down — so the last
/// answer and any failure reason vanished with no acknowledgement. The call flow
/// has `CallaCopilotEndingView` and `CallaCopilotStartFailure` for this moment;
/// this is Quiz's.
///
/// It holds the notch until dismissed, and keeps the whole session's answers
/// reachable rather than only the last one.
struct CallaQuizEndedView: View {
    @ObservedObject private var session = CopilotLiveSession.shared
    @State private var copied = false

    private var outcome: QuizSessionSnapshot? { session.quizOutcome }
    private var history: [QuizFinalAnswer] { outcome?.answerHistory ?? [] }
    private var position: CallaQuizPresentation.Position {
        CallaQuizPresentation.position(session.quizAnswerCursor, history: history)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NotchGlassSpace.snug) {
            header
            if let failure = outcome?.failure, !failure.isEmpty {
                HStack(spacing: NotchGlassSpace.hair + 3) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(NotchGlassType.glyphSmall)
                        .foregroundStyle(NotchTint.stuck)
                    Text(failure)
                        .font(NotchGlassType.detail)
                        .foregroundStyle(NotchInk.secondary)
                        .lineLimit(2)
                }
            }
            answerArea
        }
        .padding(NotchGlassSpace.card)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .notchCard()
        .notchTabInsets()
        .onChange(of: position.answer?.id) { _, _ in copied = false }
    }

    private var header: some View {
        NotchCardHeader(state: history.isEmpty ? "Quiz stopped" : "Quiz finished",
                        live: false,
                        tint: outcome?.failure?.isEmpty == false ? NotchTint.stuck : NotchTint.healthy,
                        figure: history.isEmpty ? nil : "\(history.count) answered") {
            if position.count > 1 {
                NotchGlyphButton(symbol: "chevron.left", help: "Previous answer") {
                    session.quizAnswerBack(history: history)
                }
                .disabled(!position.canGoBack)
                .opacity(position.canGoBack ? 1 : 0.35)
                .accessibilityLabel("Previous answer")
                NotchGlyphButton(symbol: "chevron.right", help: "Next answer") {
                    session.quizAnswerForward(history: history)
                }
                .disabled(!position.canGoForward)
                .opacity(position.canGoForward ? 1 : 0.35)
                .accessibilityLabel("Next answer")
            }
            NotchGlyphButton(symbol: "xmark", help: "Dismiss") {
                session.dismissQuizOutcome()
            }
            .accessibilityLabel("Dismiss")
        }
    }

    @ViewBuilder
    private var answerArea: some View {
        if let answer = position.answer {
            VStack(alignment: .leading, spacing: NotchGlassSpace.hair) {
                HStack(spacing: NotchGlassSpace.tight) {
                    NotchCaps(answer.verified ? "Last answer" : "No answer",
                              tint: answer.verified ? NotchInk.secondary : NotchTint.attention)
                    if answer.verified {
                        Text("\(answer.confidence)%")
                            .font(NotchGlassType.minorFigure)
                            .foregroundStyle(NotchInk.tertiary)
                            .accessibilityLabel("Confidence \(answer.confidence) percent")
                    }
                    if let label = position.label {
                        Text(label)
                            .font(NotchGlassType.minorFigure)
                            .foregroundStyle(NotchInk.tertiary)
                            .accessibilityLabel("Answer \(label)")
                    }
                    Spacer(minLength: 4)
                    if answer.verified {
                        NotchGlyphButton(symbol: copied ? "checkmark" : "doc.on.doc",
                                         help: copied ? "Copied" : "Copy complete answer") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                CallaQuizPresentation.copyableText(for: answer), forType: .string)
                            copied = true
                        }
                        .accessibilityLabel(copied ? "Answer copied" : "Copy complete answer")
                    }
                }
                if let summary = answer.summary, !summary.isEmpty {
                    Text(summary)
                        .font(NotchGlassType.caption)
                        .foregroundStyle(NotchInk.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .accessibilityLabel("Question: \(summary)")
                }
                ScrollView(.vertical) {
                    Text(answer.verified ? answer.answer
                         : "The council could not agree on this question.")
                        .font(answer.kind == .code
                              ? .system(size: 12, design: .monospaced) : NotchGlassType.answer)
                        .foregroundStyle(answer.verified ? NotchInk.primary : NotchInk.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            Text("No questions were answered in this session.")
                .font(NotchGlassType.row)
                .foregroundStyle(NotchInk.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }
}
