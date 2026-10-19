import CallaContracts
import SwiftUI

/// The live call, beside a closed notch.
///
/// A call is the one thing running here that the user is *inside* — they cannot
/// look away to check on it, and opening the notch mid-sentence to see whether the
/// copilot is still listening defeats the point of it. So the closed state carries
/// the two facts worth having at a glance: who is talking, and whether an answer is
/// waiting.
///
/// Takes the slot ahead of the Pomodoro and usage badges while a call runs: a
/// timer can wait, a conversation cannot.
struct CopilotNotchBadge: View {
    let notchWidth: CGFloat
    let height: CGFloat
    /// Called on hover — opens the notch on the copilot, mirroring the other badges.
    var onBadgeHover: (() -> Void)? = nil

    @ObservedObject private var engine = CallaEngineClient.shared

    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()


    private var copilot: CallaCopilotStatus { engine.status.copilot }
    private var quiz: QuizSessionSnapshot { engine.status.quiz }

    /// A Quiz session reaches this badge through the same `isLive` flag as a
    /// call, but shares none of its facts. Reading `copilot.*` regardless meant a
    /// running Quiz showed a clock frozen at `0:00` (there is no
    /// `copilot.startedAt`), an amber tint, and help text about a microphone Quiz
    /// never opens.
    private var isQuiz: Bool { quiz.active }

    private var quizWorking: Bool {
        [.solving, .arbitrating, .retrying].contains(quiz.state)
    }

    var body: some View {
        // Left says what is running — the state dot and the clock; right says
        // how it is going — who is talking, and whether an answer is waiting.
        // Both wings are the same width so the gap stays centred on the housing.
        HStack(spacing: 0) {
            readout
                .frame(width: NotchWing.width, alignment: .leading)

            Rectangle()
                .fill(.black)
                .frame(width: notchWidth)

            activity
                .frame(width: NotchWing.width, alignment: .trailing)
        }
        .fixedSize()
        .frame(height: height, alignment: .center)
        .onReceive(tick) { now = $0 }
        .onHover { hovering in
            if hovering { onBadgeHover?() }
        }
    }

    /// Right of the notch: who is speaking, or that the copilot is working, and
    /// a dot when there is an answer on the table.
    ///
    /// Glyph only. There is no room for a word here, and the colours are the same
    /// ones the open panel uses, so the two surfaces teach the same code.
    private var activity: some View {
        HStack(spacing: 6) {
            if answerWaiting {
                // The one thing worth interrupting for: an answer exists and the
                // panel is closed.
                Circle()
                    .fill(NotchAccent.focus)
                    .frame(width: 6, height: 6)
                    .transition(.scale.combined(with: .opacity))
            }
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect)
                .symbolEffect(.variableColor.iterative,
                              isActive: isQuiz ? quizWorking : copilot.thinking)
        }
        .animation(.smooth(duration: 0.2), value: answerWaiting)
        .help(helpText)
    }

    /// Left of the notch: the state dot and how long the call has run.
    private var readout: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(dotTint)
                .frame(width: 7, height: 7)
                .background(Circle().fill(dotTint.opacity(0.22)).padding(-3))
            Text(readoutText)
                .font(.system(size: 12, design: .monospaced).monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.90))
                .fixedSize()
        }
        .padding(.leading, 3)
    }

    /// Mint while it is running as it should; orange when it is only hearing
    /// one side or Quiz has failed; grey when paused.
    private var dotTint: Color {
        if isQuiz {
            switch quiz.state {
            case .failed: return NotchAccent.stop
            case .paused: return NotchInk.tertiary
            default: return NotchAccent.quiz
            }
        }
        return copilot.systemAudioActive ? NotchAccent.call : NotchAccent.attention
    }

    /// Quiz has no start date on the wire, so the count of answers so far is the
    /// fact worth the space instead of a clock that cannot advance.
    private var readoutText: String {
        if isQuiz {
            let count = quiz.answerHistory.count
            return count == 0 ? "—" : "\(count)"
        }
        return CallaCopilotPresentation.elapsed(since: copilot.startedAt, now: now) ?? "0:00"
    }

    private var answerWaiting: Bool {
        if isQuiz { return quiz.answer != nil }
        return copilot.answering && copilot.hasSuggestion
    }

    private var symbol: String {
        if isQuiz {
            switch quiz.state {
            case .solving, .arbitrating, .retrying: return "sparkles"
            case .paused: return "pause.circle.fill"
            case .failed: return "exclamationmark.triangle.fill"
            case .answered: return "checkmark.circle.fill"
            default: return "macwindow"
            }
        }
        if copilot.working == "summary" { return "text.append" }
        if copilot.thinking { return "sparkles" }
        switch copilot.speaking {
        case "them": return "waveform"
        case "me": return "mic.fill"
        default: return "ear"
        }
    }

    private var tint: Color {
        if isQuiz {
            switch quiz.state {
            case .failed: return NotchAccent.stop
            case .paused: return NotchInk.secondary
            case .answered: return NotchAccent.call
            default: return NotchAccent.quiz
            }
        }
        // The panel's own vocabulary, so the closed badge and the open surface
        // teach the same code: mint is the call working, white is you, and
        // orange is the one state worth checking.
        if copilot.working == "summary" { return NotchAccent.call.opacity(0.65) }
        if copilot.thinking { return NotchAccent.call }
        switch copilot.speaking {
        case "them": return NotchAccent.call
        case "me": return NotchInk.primary.opacity(0.85)
        // Not grey: a call that is running but hearing nothing still needs to read
        // as running, or the badge becomes indistinguishable from a stopped one.
        default: return copilot.systemAudioActive ? NotchInk.secondary : NotchAccent.attention
        }
    }

    private var helpText: String {
        if isQuiz {
            switch quiz.state {
            case .solving, .arbitrating, .retrying: return "Reasoning about the question on screen"
            case .paused: return "Quiz is paused"
            case .failed: return quiz.failure ?? "Quiz stopped unexpectedly"
            case .answered: return "An answer is ready"
            default: return "Watching the target window"
            }
        }
        if copilot.working == "summary" { return "Catching the summary up" }
        if copilot.thinking { return "Finding an answer" }
        switch copilot.speaking {
        case "them": return "They are speaking"
        case "me": return "You are speaking"
        default:
            return copilot.systemAudioActive
                ? "Listening to both sides"
                : "Only your microphone is being captured"
        }
    }
}
