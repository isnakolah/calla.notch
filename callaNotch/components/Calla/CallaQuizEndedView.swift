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

    private var failed: Bool { outcome?.failure?.isEmpty == false }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CallaEyebrow(capsLine, tint: failed ? NotchAccent.stop : NotchInk.tertiary)
            if let failure = outcome?.failure, !failure.isEmpty {
                Text(failure)
                    .font(.system(size: 13))
                    .foregroundStyle(NotchInk.secondary)
                    .lineLimit(2)
            }
            answerArea
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                if let answer = position.answer, answer.verified {
                    button(copied ? "Copied" : "Copy answer", primary: false) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            CallaQuizPresentation.copyableText(for: answer), forType: .string)
                        copied = true
                    }
                    .accessibilityLabel(copied ? "Answer copied" : "Copy complete answer")
                }
                button("Done", primary: true) { session.dismissQuizOutcome() }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: position.answer?.id) { _, _ in copied = false }
    }

    private var capsLine: String {
        let state = history.isEmpty ? "Quiz stopped" : "Quiz finished"
        return history.isEmpty ? state : "\(state) · \(history.count) answered"
    }

    private func button(_ title: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: primary ? .bold : .semibold))
                .foregroundStyle(primary ? NotchAccent.onAccent : NotchInk.primary)
                .padding(.horizontal, primary ? 18 : 16)
                .frame(height: 40)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(primary ? NotchAccent.quiz : Color.white.opacity(0.08)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }

    /// The last answer in a card, with the pager beside it.
    @ViewBuilder
    private var answerArea: some View {
        if let answer = position.answer {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text((answer.verified ? "Last answer" : "No answer").uppercased())
                            .font(.system(size: 10, weight: .bold))
                            .tracking(notchCapsTracking)
                            .foregroundStyle(answer.verified ? NotchAccent.quiz : NotchAccent.attention)
                        if answer.verified {
                            Text("\(answer.confidence)%")
                                .font(.system(size: 10, weight: .bold, design: .rounded).monospacedDigit())
                                .foregroundStyle(NotchAccent.quiz)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(NotchAccent.quiz.opacity(0.18)))
                                .accessibilityLabel("Confidence \(answer.confidence) percent")
                        }
                    }
                    Text(answer.verified ? CallaQuizLiveView.split(answer.answer).lead
                         : "The council could not agree on this question.")
                        .font(answer.kind == .code
                              ? .system(size: 14, design: .monospaced) : .system(size: 20, weight: .bold))
                        .foregroundStyle(answer.verified ? NotchInk.primary : NotchInk.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    if let summary = answer.summary, !summary.isEmpty {
                        Text("Q · \(summary)")
                            .font(.system(size: 12))
                            .foregroundStyle(NotchInk.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .accessibilityLabel("Question: \(summary)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if position.count > 1 {
                    HStack(spacing: 6) {
                        pager("chevron.left", label: "Previous answer", enabled: position.canGoBack) {
                            session.quizAnswerBack(history: history)
                        }
                        if let label = position.label {
                            Text(label)
                                .font(.system(size: 12, design: .rounded).monospacedDigit())
                                .foregroundStyle(NotchInk.secondary)
                                .accessibilityLabel("Answer \(label)")
                        }
                        pager("chevron.right", label: "Next answer", enabled: position.canGoForward) {
                            session.quizAnswerForward(history: history)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.05)))
        } else {
            Text("No questions were answered in this session.")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(NotchInk.secondary)
        }
    }

    private func pager(_ symbol: String, label: String, enabled: Bool,
                       action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(enabled ? NotchInk.primary : Color.white.opacity(0.30))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.white.opacity(enabled ? 0.08 : 0.04)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel(label)
    }
}
