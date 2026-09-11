import CallaContracts
import Defaults
import KeyboardShortcuts
import SwiftUI

/// The band either side of the camera housing during a live Quiz.
///
/// This carries everything that is *about* the session — state, the clock, the
/// controls — so that the slab below the notch is left entirely to the answer.
/// It is the same division the live call uses, and the reason for it is that the
/// answer is the only thing worth reading from across a desk; a control row
/// drawn above it costs a band of a surface that has about a hundred points to
/// spend.
///
/// A live Quiz used to be given `CallaCopilotLiveHeader`, which reads `copilot.*`
/// exclusively. Every fact in it was wrong here: the pulse was dead, the clock
/// read from a `startedAt` that is nil for Quiz so no clock appeared, the persona
/// pill described a call, and an amber `mic.slash.fill` announced "Your
/// microphone is not being captured" on every session — about a microphone Quiz
/// does not open.
struct CallaQuizLiveHeader: View {
    @ObservedObject private var engine = CallaEngineClient.shared
    @ObservedObject private var session = CopilotLiveSession.shared
    @EnvironmentObject private var vm: BoringViewModel

    @State private var now = Date()
    @State private var targets: [QuizWindowTarget] = []
    @Default(.hideFromScreenRecording) private var hiddenFromCapture
    private let clockTick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var quiz: QuizSessionSnapshot { engine.status.quiz }
    private var history: [QuizFinalAnswer] { quiz.answerHistory }
    private var stage: CallaQuizPresentation.Stage {
        CallaQuizPresentation.stage(for: quiz)
    }
    private var position: CallaQuizPresentation.Position {
        CallaQuizPresentation.position(session.quizAnswerCursor, history: history)
    }

    private func confidenceTint(_ confidence: Int) -> Color {
        switch confidence {
        case 85...: NotchTint.healthy
        case 60 ..< 85: NotchInk.secondary
        default: NotchTint.attention
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Both halves are narrower than they look, so every label is
            // `fixedSize` rather than allowed to wrap mid-word.
            HStack(spacing: NotchGlassSpace.tight) {
                NotchStatusDot(live: quiz.active, tint: tint)
                Text(CallaQuizPresentation.stateLine(for: quiz))
                    .font(NotchGlassType.bandLabel)
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .fixedSize()
                if let elapsed {
                    Text(elapsed)
                        .font(NotchGlassType.inlineFigure)
                        .foregroundStyle(NotchInk.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .help("Time on this question")
                        .accessibilityLabel("This question has taken \(elapsed)")
                }
                // How sure, beside how long. Both are facts about the run rather
                // than parts of the answer, so they belong together up here.
                if let shown = position.answer, shown.verified {
                    Text("\(shown.confidence)%")
                        .font(NotchGlassType.inlineFigure)
                        .foregroundStyle(confidenceTint(shown.confidence))
                        .lineLimit(1)
                        .fixedSize()
                        .help("How much the council agreed")
                        .accessibilityLabel("Confidence \(shown.confidence) percent")
                    if shown.isRefinement {
                        Image(systemName: "wand.and.stars")
                            .font(NotchGlassType.glyphSmall)
                            .foregroundStyle(NotchTint.healthy)
                            .help("A stronger model improved this answer")
                            .accessibilityLabel("Improved answer")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: NotchGlassSpace.tight) {
                retargetMenu
                NotchGlyphButton(symbol: session.layout == .full
                                 ? "rectangle.compress.vertical" : "rectangle.expand.vertical",
                                 help: session.layout == .full ? "Compact panel" : "Expanded panel") {
                    session.toggleLayout()
                }
                .accessibilityLabel(session.layout == .full ? "Compact panel" : "Expanded panel")

                if quiz.state == .paused {
                    NotchGlyphButton(symbol: "play.fill", help: shortcutHelp("Resume Quiz", .sessionHold)) { send(.resume) }
                        .accessibilityLabel("Resume Quiz")
                } else {
                    NotchGlyphButton(symbol: "pause.fill", help: shortcutHelp("Pause Quiz", .sessionHold)) { send(.pause) }
                        .accessibilityLabel("Pause Quiz")
                }

                // Reports the setting rather than asserting a guarantee — the
                // same rule the call header follows.
                Image(systemName: hiddenFromCapture ? "eye.slash.fill" : "eye.fill")
                    .font(NotchGlassType.glyphSmall)
                    .foregroundStyle(hiddenFromCapture ? NotchInk.secondary : NotchTint.attention)
                    .help(hiddenFromCapture
                          ? "Hidden from screen recordings and shares"
                          : "Visible in screen recordings and shares — turn on Hide from screen recording in Settings")

                NotchGlyphButton(symbol: (vm.isPinned || session.pinsNotchOpen) ? "pin.fill" : "pin",
                                 help: (vm.isPinned || session.pinsNotchOpen) ? "Unpin notch" : "Pin notch open") {
                    AppDelegate.shared?.toggleUniversalNotchPin(for: vm)
                }
                .accessibilityLabel((vm.isPinned || session.pinsNotchOpen) ? "Unpin notch" : "Pin notch open")

                NotchGlyphButton(symbol: "stop.fill", help: "Stop Quiz") { send(.stop) }
                    .accessibilityLabel("Stop Quiz")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .onReceive(clockTick) { now = $0 }
        .task { refreshTargets() }
    }

    private var tint: Color {
        switch stage {
        case .failed: NotchTint.stuck
        case .paused: NotchTint.paused
        case .answered: NotchTint.healthy
        default: .effectiveAccent
        }
    }

    /// How long the answer on screen took, from noticing the question to
    /// publishing it — or the live count while one is still being worked out.
    ///
    /// Read off the displayed answer rather than a running clock. The clock
    /// restarts with each question, so once the next one arrived it could no
    /// longer say what the answer being read had cost; and stepping back through
    /// the history showed the newest question's time against an old answer.
    private var elapsed: String? {
        if let shown = position.answer, let took = shown.elapsed {
            return format(took)
        }
        guard let started = quiz.questionStartedAt else { return nil }
        return format(now.timeIntervalSince(started))
    }

    private func format(_ seconds: Double) -> String? {
        let value = max(0, seconds)
        guard value < 3_600 else { return nil }
        // Under a minute, tenths: the difference between 4s and 11s is the whole
        // question when the flow feels slow.
        if value < 60 { return String(format: "%.1fs", value) }
        return String(format: "%d:%02d", Int(value) / 60, Int(value) % 60)
    }

    private var retargetMenu: some View {
        Menu {
            if targets.isEmpty { Text("No capturable windows") }
            ForEach(targets) { target in
                Button("\(target.applicationName) — \(target.windowTitle)") {
                    guard let sessionID = quiz.sessionID else { return }
                    engine.sendQuiz(.init(sessionID: sessionID, command: .retarget, target: target))
                }
            }
            Divider()
            Button("Refresh windows") { refreshTargets() }
        } label: {
            Image(systemName: "scope").font(NotchGlassType.glyphSmall)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(NotchInk.tertiary)
        .help("Capturing \(CallaQuizPresentation.targetLabel(for: quiz.target)) — click to retarget")
        .accessibilityLabel("Capturing \(CallaQuizPresentation.targetLabel(for: quiz.target)). Retarget window")
        // The list goes stale the moment a window closes, and the menu is the
        // only place it is read.
        .onTapGesture { refreshTargets() }
    }

    private func send(_ command: QuizCommandKind) {
        guard let sessionID = quiz.sessionID else { return }
        engine.sendQuiz(.init(sessionID: sessionID, command: command))
    }

    private func shortcutHelp(_ label: String, _ name: KeyboardShortcuts.Name) -> String {
        guard let shortcut = KeyboardShortcuts.getShortcut(for: name) else { return label }
        return "\(label) — \(shortcut.description)"
    }

    private func refreshTargets() {
        engine.listQuizWindows { targets = $0 }
    }
}
