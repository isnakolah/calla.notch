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
    @EnvironmentObject private var vm: BoringViewModel
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
        .padding(NotchGlassSpace.card)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .notchCard()
        // A long answer must scroll inside the card, never draw past its bottom
        // edge and out of the notch's curve.
        .clipShape(RoundedRectangle(cornerRadius: NotchGlassRadius.card, style: .continuous))
        .notchTabInsets()
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
            VStack(alignment: .leading, spacing: NotchGlassSpace.hair + 2) {
                answerHeader(answer)
                if answer.verified {
                    answerBody(answer)
                } else {
                    unanswered
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// The question, and the controls for stepping between answers.
    ///
    /// Confidence and the refinement note used to sit here. They are facts *about*
    /// the answer rather than the answer itself, and on a surface this small they
    /// pushed the thing the reader came for down the card — so confidence now sits
    /// in the band beside the clock, and the rationale in History.
    @ViewBuilder
    private func answerHeader(_ answer: QuizFinalAnswer) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: NotchGlassSpace.tight) {
            if let summary = answer.summary, !summary.isEmpty {
                Text(summary)
                    .font(NotchGlassType.caption)
                    .foregroundStyle(NotchInk.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityLabel("Question: \(summary)")
            }
            Spacer(minLength: 4)
            if working {
                Image(systemName: "circle.dotted")
                    .font(NotchGlassType.glyphSmall)
                    .foregroundStyle(Color.effectiveAccent)
                    .symbolEffect(.variableColor.iterative, isActive: true)
                    .help(workingLabel)
                    .accessibilityLabel(workingLabel)
            }
            answerNavigation
            if answer.verified {
                NotchGlyphButton(symbol: copied ? "checkmark" : "doc.on.doc",
                                 help: copied ? "Copied" : "Copy complete answer") {
                    copy(answer)
                }
                .accessibilityLabel(copied ? "Answer copied" : "Copy complete answer")
            }
        }
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
            HStack(spacing: NotchGlassSpace.hair) {
                NotchGlyphButton(symbol: "chevron.left", help: "Previous answer") {
                    session.quizAnswerBack(history: history)
                }
                .disabled(!position.canGoBack)
                .opacity(position.canGoBack ? 1 : 0.35)
                .accessibilityLabel("Previous answer")
                NotchGlyphButton(symbol: position.hasNewer ? "chevron.right.2" : "chevron.right",
                                 help: position.hasNewer ? "Newer answers" : "Next answer") {
                    session.quizAnswerForward(history: history)
                }
                .disabled(!position.canGoForward)
                .opacity(position.canGoForward ? 1 : 0.35)
                .accessibilityLabel(position.hasNewer ? "Jump to newer answers" : "Next answer")
            }
        }
    }

    @ViewBuilder
    private func answerBody(_ answer: QuizFinalAnswer) -> some View {
        if answer.kind == .code || CallaQuizPresentation.looksLikeCode(answer.answer) {
            let parsed = CallaQuizPresentation.code(from: answer.answer)
            if parsed.isEmpty {
                proseBody(answer)
            } else {
                CallaQuizCodeBlock(code: parsed, compact: session.layout != .full,
                                   wraps: $wrapsCode)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        } else {
            proseBody(answer)
        }
    }

    private func proseBody(_ answer: QuizFinalAnswer) -> some View {
        ScrollView(.vertical) {
            Text(answer.answer)
                .font(session.layout == .full ? NotchGlassType.answer
                                              : NotchGlassType.answerLarge)
                .foregroundStyle(NotchInk.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// An unverified answer carries no model text by contract — `QuizFinalAnswer`
    /// replaces it with a sentinel so unvetted output cannot reach the screen.
    /// Rendering that sentinel printed the same three words as heading and body.
    private var unanswered: some View {
        VStack(alignment: .leading, spacing: NotchGlassSpace.hair) {
            Text("The council could not agree on this question.")
                .font(NotchGlassType.row)
                .foregroundStyle(NotchInk.secondary)
            Text("Scroll the target or wait for the next question.")
                .font(NotchGlassType.caption)
                .foregroundStyle(NotchInk.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Other stages

    private var waiting: some View {
        VStack(spacing: NotchGlassSpace.snug) {
            if working {
                Image(systemName: "circle.dotted")
                    .font(NotchGlassType.glyphLarge)
                    .foregroundStyle(Color.effectiveAccent)
                    .symbolEffect(.variableColor.iterative, isActive: true)
            }
            Text(working ? workingLabel : "Watching for the first question…")
                .font(NotchGlassType.title)
                .foregroundStyle(working ? NotchInk.primary : NotchInk.tertiary)
                .accessibilityAddTraits(.updatesFrequently)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func centered(_ text: String) -> some View {
        Text(text)
            .font(NotchGlassType.row)
            .foregroundStyle(NotchInk.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    @ViewBuilder
    private func collecting(_ prompt: QuizCommandKind?) -> some View {
        VStack(spacing: NotchGlassSpace.snug) {
            Text(prompt == nil ? "Collecting the question…"
                 : "The question runs past the window edge.")
                .font(NotchGlassType.row)
                .foregroundStyle(NotchInk.secondary)
                .multilineTextAlignment(.center)
            if let prompt {
                NotchChip(tint: .effectiveAccent, action: { send(prompt) }) {
                    Image(systemName: prompt == .scrollUp ? "arrow.up" : "arrow.down")
                        .font(NotchGlassType.glyphSmall)
                    Text(prompt == .scrollUp ? "Scroll target up" : "Scroll target down")
                    if let shortcut = KeyboardShortcuts.getShortcut(
                        for: prompt == .scrollUp ? .sessionScrollUp : .sessionScrollDown) {
                        Text(shortcut.description)
                            .font(NotchGlassType.minorFigure)
                            .foregroundStyle(NotchInk.tertiary)
                    }
                }
                .accessibilityLabel(prompt == .scrollUp ? "Scroll target up" : "Scroll target down")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    @ViewBuilder
    private func paused(_ reason: String?) -> some View {
        VStack(spacing: NotchGlassSpace.snug) {
            Text(reason ?? "Paused")
                .font(NotchGlassType.row)
                .foregroundStyle(reason == nil ? NotchInk.secondary : NotchTint.attention)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            NotchChip(tint: .effectiveAccent, action: { send(.resume) }) {
                Image(systemName: "play.fill").font(NotchGlassType.glyphSmall)
                Text("Resume")
            }
            .accessibilityLabel("Resume Quiz")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    @ViewBuilder
    private func failed(_ reason: String) -> some View {
        VStack(spacing: NotchGlassSpace.snug) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(NotchGlassType.glyphLarge)
                .foregroundStyle(NotchTint.stuck)
            Text(reason)
                .font(NotchGlassType.row)
                .foregroundStyle(NotchInk.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            NotchChip(action: { SettingsWindowController.shared.showCopilotWindow(tab: "Quiz") }) {
                Text("Open Quiz settings")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .accessibilityAddTraits(.updatesFrequently)
    }

    // MARK: - Helpers

    private func confidenceTint(_ confidence: Int) -> Color {
        switch confidence {
        case 85...: NotchTint.healthy
        case 60 ..< 85: NotchInk.secondary
        default: NotchTint.attention
        }
    }

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
