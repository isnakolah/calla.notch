import AppKit
import CallaContracts
import KeyboardShortcuts
import SwiftUI

/// The Quiz answer, and nothing else.
///
/// State, the clock and every control live in `CallaQuizLiveHeader`, in the band
/// either side of the camera housing — so the whole slab below the notch belongs
/// to the answer. That is the division the live call already uses, and the reason
/// is that the answer is the only thing here worth reading from across a desk.
/// An earlier version of this view spent two of its four available bands on a
/// control row and a target line drawn above the answer.
///
/// What to draw is decided in `CallaQuizPresentation`, which is tested; this file
/// is layout only. The view this replaces made the decision inline and got the
/// order wrong — it checked for an answer before any lifecycle state, so Stop,
/// Pause and every failure message became unreachable once an answer had shown.
struct CallaQuizLiveView: View {
    @ObservedObject private var engine = CallaEngineClient.shared
    @ObservedObject private var session = CopilotLiveSession.shared
    @EnvironmentObject private var vm: CallaViewModel
    @State private var copied = false
    @State private var wrapsCode = true

    private var quiz: QuizSessionSnapshot { engine.status.quiz }
    private var stage: CallaQuizPresentation.Stage { CallaQuizPresentation.stage(for: quiz) }
    private var history: [QuizFinalAnswer] { quiz.answerHistory }
    private var position: CallaQuizPresentation.Position {
        CallaQuizPresentation.position(session.quizAnswerCursor, history: history)
    }

    /// The council is working on the next question.
    private var working: Bool {
        if case .working = stage { return true }
        if case .starting = stage { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NotchGlassSpace.snug) {
            Group {
                switch stage {
                case .answered, .working, .starting:
                    // A previous answer stays on screen while the next one is
                    // being worked out. Blanking the slab back to "Reasoning…"
                    // took away the thing the reader was still reading, for a
                    // word they already knew from the header.
                    if position.answer != nil {
                        answerCanvas
                    } else {
                        waiting
                    }
                case .watching:
                    if position.answer != nil { answerCanvas } else { waiting }
                case .collecting(let prompt):
                    collecting(prompt)
                case .paused(let reason):
                    paused(reason)
                case .stopping:
                    centered("Stopping Quiz…")
                case .failed(let reason):
                    failed(reason)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // One answer replaces another in place rather than the panel
            // reflowing around it.
            .animation(.smooth(duration: 0.25), value: position.answer?.id)
            .animation(.smooth(duration: 0.25), value: working)

            if session.layout == .full {
                // The shared row. It was Quiz's alone until one key came to mean
                // one action on every surface; now Call and Live Coding show the
                // same thing, and the words below are the same words there.
                NotchSessionHints(surface: .quiz, extras: [
                    ("Wrap", .quizToggleWrap),
                    ((vm.isPinned || session.pinsNotchOpen) ? "Unpin" : "Pin", .copilotTogglePin)
                ])
            }
        }
        // Straight on the slab, like the live call: the notch is the container.
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A long answer must scroll inside the panel, never draw past its
        // bottom edge and out of the notch's curve.
        .clipped()
        .onChange(of: history.count) { _, _ in
            session.reconcileQuizAnswerCursor(history: history)
        }
        .onChange(of: position.answer?.id) { _, _ in copied = false }
        .onReceive(NotificationCenter.default.publisher(for: .callaQuizToggleWrap)) { _ in
            wrapsCode.toggle()
        }
    }

    // MARK: - Answer

    @ViewBuilder
    private var answerCanvas: some View {
        if let answer = position.answer {
            let isCode = answer.verified
                && (answer.kind == .code || CallaQuizPresentation.looksLikeCode(answer.answer))
                && !CallaQuizPresentation.code(from: answer.answer).isEmpty
            VStack(alignment: .leading, spacing: 6) {
                answerHeader(answer, isCode: isCode)
                if answer.verified {
                    answerBody(answer, isCode: isCode)
                } else {
                    unanswered
                }
                if !isCode, let summary = answer.summary, !summary.isEmpty {
                    Spacer(minLength: 0)
                    Text("Q · \(summary)")
                        .font(.system(size: 12))
                        .foregroundStyle(NotchInk.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .accessibilityLabel("Question: \(summary)")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// The caps, then — for code, where the question has no room at the foot —
    /// the question, then the pager and Copy.
    ///
    /// Confidence and the refinement note sit in the band beside the clock: they
    /// are facts *about* the answer rather than the answer itself.
    @ViewBuilder
    private func answerHeader(_ answer: QuizFinalAnswer, isCode: Bool) -> some View {
        HStack(spacing: 8) {
            CallaEyebrow(answer.verified ? "Answer" : "No answer",
                         tint: answer.verified ? NotchAccent.quiz : NotchAccent.attention)
            if isCode, let summary = answer.summary, !summary.isEmpty {
                Text("Q · \(summary)")
                    .font(.system(size: 12))
                    .foregroundStyle(NotchInk.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityLabel("Question: \(summary)")
            }
            Spacer(minLength: 4)
            if working {
                Image(systemName: "circle.dotted")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(NotchAccent.quiz)
                    .symbolEffect(.variableColor.iterative, isActive: true)
                    .help(workingLabel)
                    .accessibilityLabel(workingLabel)
            }
            answerNavigation
            if answer.verified {
                Button { copy(answer) } label: {
                    Text(copied ? "Copied" : (isCode ? "Copy code" : "Copy"))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(isCode ? NotchAccent.onAccent : NotchAccent.quiz)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(Capsule().fill(isCode ? NotchAccent.quiz : NotchAccent.quiz.opacity(0.18)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(copied ? "Copied" : "Copy complete answer")
                .accessibilityLabel(copied ? "Answer copied" : "Copy complete answer")
            }
        }
        .frame(height: 28)
    }

    private var workingLabel: String {
        if case .working(let label) = stage { return label }
        if case .starting(let label) = stage { return label }
        return "Working…"
    }

    /// Stepping back through the session's answers.
    ///
    /// A new answer arriving while the reader is back here does not move them;
    /// `hasNewer` lights the forward affordance instead. Being yanked mid-read is
    /// worse than having to press once to catch up.
    @ViewBuilder
    private var answerNavigation: some View {
        if position.count > 1 {
            HStack(spacing: 6) {
                pagerButton("chevron.left", label: "Previous answer", enabled: position.canGoBack) {
                    session.quizAnswerBack(history: history)
                }
                if let label = position.label {
                    Text(label)
                        .font(.system(size: 12, design: .rounded).monospacedDigit())
                        .foregroundStyle(NotchInk.secondary)
                        .accessibilityLabel("Answer \(label)")
                }
                pagerButton(position.hasNewer ? "chevron.right.2" : "chevron.right",
                            label: position.hasNewer ? "Jump to newer answers" : "Next answer",
                            enabled: position.canGoForward) {
                    session.quizAnswerForward(history: history)
                }
            }
        }
    }

    private func pagerButton(_ symbol: String, label: String, enabled: Bool,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(enabled ? NotchInk.primary : Color.white.opacity(0.30))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.white.opacity(enabled ? 0.08 : 0.04)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private func answerBody(_ answer: QuizFinalAnswer, isCode: Bool) -> some View {
        if isCode {
            CallaQuizCodeBlock(code: CallaQuizPresentation.code(from: answer.answer),
                               compact: session.layout != .full, wraps: $wrapsCode)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            proseBody(answer)
        }
    }

    /// The answer's first line set large — the thing read from across a desk —
    /// and whatever follows it as the explanation.
    private func proseBody(_ answer: QuizFinalAnswer) -> some View {
        let parts = Self.split(answer.answer)
        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 6) {
                Text(parts.lead)
                    .font(.system(size: parts.lead.count > 70 ? 20 : 32, weight: .bold))
                    .tracking(parts.lead.count > 70 ? -0.2 : -0.5)
                    .lineSpacing(1)
                    .foregroundStyle(NotchInk.primary)
                    .minimumScaleFactor(0.7)
                if let rest = parts.rest {
                    Text(rest)
                        .font(.system(size: 14))
                        .lineSpacing(2.5)
                        .foregroundStyle(Color.white.opacity(0.82))
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The first non-empty line, and the rest of the text after it.
    static func split(_ answer: String) -> (lead: String, rest: String?) {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let newline = trimmed.firstIndex(of: "\n") else { return (trimmed, nil) }
        let lead = String(trimmed[..<newline]).trimmingCharacters(in: .whitespaces)
        let rest = String(trimmed[newline...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (lead, rest.isEmpty ? nil : rest)
    }

    /// An unverified answer carries no model text by contract — `QuizFinalAnswer`
    /// replaces it with a sentinel so unvetted output cannot reach the screen.
    /// Rendering that sentinel printed the same three words as heading and body.
    private var unanswered: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("The council could not agree on this question.")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(NotchInk.primary)
            Text("Scroll the target or wait for the next question.")
                .font(.system(size: 13))
                .foregroundStyle(NotchInk.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Other stages

    /// The title and sentence every non-answer stage leads with.
    private func stageText(_ title: String, detail: String?, caps: String? = nil,
                           capsTint: Color = NotchInk.tertiary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let caps { CallaEyebrow(caps, tint: capsTint) }
            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .tracking(-0.2)
                .foregroundStyle(NotchInk.primary)
                .lineLimit(2)
            if let detail {
                Text(detail)
                    .font(.system(size: 13))
                    .lineSpacing(2)
                    .foregroundStyle(NotchInk.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var waiting: some View {
        HStack(spacing: 18) {
            Image(systemName: working ? "circle.dotted" : "viewfinder")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(NotchAccent.quiz)
                .symbolEffect(.variableColor.iterative, isActive: working)
                .frame(width: 64, height: 64)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(NotchAccent.quiz.opacity(0.12)))
                .accessibilityHidden(true)
            stageText(working ? workingLabel : "Watching for the first question…",
                      detail: working ? nil
                        : "Reading \(CallaQuizPresentation.targetLabel(for: quiz.target)). An answer shows up here as soon as a question is on screen.")
                .accessibilityAddTraits(.updatesFrequently)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func centered(_ text: String) -> some View {
        stageText(text, detail: nil)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The question runs past the edge: both scroll directions, the one asked
    /// for (down when nothing was asked) as the primary.
    @ViewBuilder
    private func collecting(_ prompt: QuizCommandKind?) -> some View {
        let primary: QuizCommandKind = prompt == .scrollUp ? .scrollUp : .scrollDown
        VStack(alignment: .leading, spacing: 12) {
            stageText("Collecting the question…",
                      detail: prompt == nil ? "Reading what is on screen."
                        : "The question runs past the window edge. Scroll it so the rest is visible.",
                      caps: prompt == nil ? nil : "Needs a scroll", capsTint: NotchAccent.attention)
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                scrollButton(.scrollUp, primary: primary == .scrollUp)
                scrollButton(.scrollDown, primary: primary == .scrollDown)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func scrollButton(_ command: QuizCommandKind, primary: Bool) -> some View {
        let up = command == .scrollUp
        let title = up ? "Scroll target up" : "Scroll target down"
        let shortcut = KeyboardShortcuts.getShortcut(for: up ? .sessionScrollUp : .sessionScrollDown)
        return stageButton(title, symbol: up ? "arrow.up" : "arrow.down", primary: primary,
                           help: shortcut.map { "\(title) — \($0.description)" } ?? title) {
            send(command)
        }
    }

    private func stageButton(_ title: String, symbol: String?, primary: Bool, help: String? = nil,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if let symbol { Image(systemName: symbol).font(.system(size: 13, weight: .semibold)) }
                Text(title).font(.system(size: 13, weight: primary ? .bold : .semibold)).lineLimit(1)
            }
            .foregroundStyle(primary ? NotchAccent.onAccent : NotchInk.primary)
            .padding(.leading, symbol == nil ? 18 : 15)
            .padding(.trailing, 18)
            .frame(height: 46)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(primary ? NotchAccent.quiz : Color.white.opacity(0.08)))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help ?? title)
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private func paused(_ reason: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            stageText("Quiz is paused",
                      detail: reason ?? "Nothing is being read. Resume when the next question is on screen.")
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                stageButton("Resume", symbol: "play.fill", primary: true) { send(.resume) }
                stageButton("Open Quiz settings", symbol: nil, primary: false) {
                    SettingsWindowController.shared.showCopilotWindow(tab: "Quiz")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func failed(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            stageText(reason, detail: nil, caps: "Quiz stopped", capsTint: NotchAccent.stop)
            Spacer(minLength: 0)
            stageButton("Open Quiz settings", symbol: nil, primary: false) {
                SettingsWindowController.shared.showCopilotWindow(tab: "Quiz")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityAddTraits(.updatesFrequently)
    }

    // MARK: - Helpers

    private func copy(_ answer: QuizFinalAnswer) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(CallaQuizPresentation.copyableText(for: answer),
                                       forType: .string)
        copied = true
    }

    private func send(_ command: QuizCommandKind) {
        guard let sessionID = quiz.sessionID else { return }
        engine.sendQuiz(.init(sessionID: sessionID, command: command))
    }
}

extension Notification.Name {
    static let callaQuizToggleWrap = Notification.Name("callaQuizToggleWrap")
}
