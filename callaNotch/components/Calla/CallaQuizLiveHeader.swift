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
    @EnvironmentObject private var vm: CallaViewModel

    @State private var now = Date()
    @State private var targets: [QuizWindowTarget] = []
    /// A live session is always out of shares and recordings (see
    /// `CallaNotchSkyLightWindow.updateSharingType`), whatever the setting says.
    private let hiddenFromCapture = true
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
        case 85...: NotchAccent.quiz
        case 60 ..< 85: NotchInk.secondary
        default: NotchAccent.attention
        }
    }

    var body: some View {
        // Each half is exactly its share of the band either side of the camera
        // housing, as in the call's band, and gives way inside itself: the
        // pills go first on the left, the capture state first on the right.
        GeometryReader { proxy in
            let half = max(0, (proxy.size.width - vm.closedNotchSize.width) / 2)
            HStack(spacing: 0) {
                ViewThatFits(in: .horizontal) {
                    leading(confidence: true, improved: true)
                    leading(confidence: true, improved: false)
                    leading(confidence: false, improved: false)
                }
                .frame(width: half, height: proxy.size.height, alignment: .leading)
                .clipped()
                // The camera housing. Nothing may be drawn here.
                Color.clear.frame(width: vm.closedNotchSize.width)
                ViewThatFits(in: .horizontal) {
                    trailing(showsCapture: true)
                    trailing(showsCapture: false)
                }
                .frame(width: half, height: proxy.size.height, alignment: .trailing)
            }
        }
        .padding(.leading, 22)
        .padding(.trailing, 16)
        .onReceive(clockTick) { now = $0 }
        .task { refreshTargets() }
    }

    private func leading(confidence: Bool, improved: Bool) -> some View {
        HStack(spacing: 9) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
                .background(Circle().fill(tint.opacity(quiz.active ? 0.22 : 0)).padding(-4))
            Text(CallaQuizPresentation.stateLine(for: quiz))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .fixedSize()
            if let elapsed {
                Text(elapsed)
                    .font(.system(size: 12, design: .monospaced).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.80))
                    .lineLimit(1)
                    .fixedSize()
                    .help("Time on this question")
                    .accessibilityLabel("This question has taken \(elapsed)")
            }
            // How sure, beside how long. Both are facts about the run rather
            // than parts of the answer, so they belong together up here.
            if confidence, let shown = position.answer, shown.verified {
                pill("\(shown.confidence)%", tint: confidenceTint(shown.confidence), rounded: true)
                    .help("How much the council agreed")
                    .accessibilityLabel("Confidence \(shown.confidence) percent")
                if improved, shown.isRefinement {
                    pill("Improved", tint: NotchAccent.home, rounded: false)
                        .help("A stronger model improved this answer")
                        .accessibilityLabel("Improved by a stronger model")
                }
            }
        }
        .fixedSize()
    }

    private func trailing(showsCapture: Bool) -> some View {
        let pinned = vm.isPinned || session.pinsNotchOpen
        return HStack(spacing: 2) {
            retargetMenu

            if quiz.state == .paused {
                CallaWingButton(symbol: "play.fill", tint: Color.white.opacity(0.80)) { send(.resume) }
                    .help(shortcutHelp("Resume Quiz", .sessionHold))
                    .accessibilityLabel("Resume Quiz")
            } else {
                CallaWingButton(symbol: "pause.fill", tint: Color.white.opacity(0.80)) { send(.pause) }
                    .help(shortcutHelp("Pause Quiz", .sessionHold))
                    .accessibilityLabel("Pause Quiz")
            }

            // Reports the setting rather than asserting a guarantee — the
            // same rule the call header follows.
            if showsCapture {
                CallaWingIndicator(symbol: hiddenFromCapture ? "eye.slash" : "eye",
                                   tint: hiddenFromCapture ? Color.white.opacity(0.70) : NotchAccent.attention)
                    .help(hiddenFromCapture
                          ? "Hidden from screen recordings and shares"
                          : "Visible in screen recordings and shares — turn on Hide from screen recording in Settings")
                    .accessibilityLabel(hiddenFromCapture ? "Hidden from screen recording"
                                                          : "Visible in screen recording")
            }

            CallaWingButton(symbol: pinned ? "pin.fill" : "pin",
                            tint: pinned ? NotchAccent.quiz : Color.white.opacity(0.70)) {
                AppDelegate.shared?.toggleUniversalNotchPin(for: vm)
            }
            .help(pinned ? "Unpin notch" : "Pin notch open")
            .accessibilityLabel(pinned ? "Unpin notch" : "Pin notch open")

            CallaWingButton(symbol: session.layout == .full
                            ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                session.toggleLayout()
            }
            .help(session.layout == .full ? "Compact panel" : "Expanded panel")
            .accessibilityLabel(session.layout == .full ? "Compact panel" : "Expanded panel")

            CallaEndPill(title: "Stop") { send(.stop) }
                .help("Stop Quiz")
                .accessibilityLabel("Stop Quiz")
        }
        .fixedSize()
    }

    private func pill(_ text: String, tint: Color, rounded: Bool) -> some View {
        Text(text)
            .font(.system(size: rounded ? 11 : 10, weight: .bold, design: rounded ? .rounded : .default)
                .monospacedDigit())
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(Capsule().fill(tint.opacity(0.18)))
            .lineLimit(1)
            .fixedSize()
    }

    private var tint: Color {
        switch stage {
        case .failed: NotchAccent.stop
        case .paused, .stopping: NotchInk.tertiary
        case .collecting: NotchAccent.attention
        default: NotchAccent.quiz
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
            Text(CallaQuizPresentation.targetLabel(for: quiz.target))
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.80))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 8)
                .frame(maxWidth: 84)
                .frame(height: 22)
                .background(Capsule().fill(Color.white.opacity(0.08)))
                .frame(height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.trailing, 2)
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
