import CallaContracts
import Combine
import SwiftUI

/// The live call, beside a closed notch.
///
/// A call is the one thing running here that the user is *inside* — they cannot
/// look away to check on it, and opening the notch mid-sentence to see whether the
/// copilot is still listening defeats the point of it. So the closed state says,
/// in words, what is happening — "Listening", "Only you", "Answer ready" — with
/// the clock on the other side of the camera.
///
/// Hovering does not open the panel. It grows the closed notch by one line: the
/// answer, or where the call stands (`NotchPeekPolicy`). That line is often all
/// the reader wanted, it covers nothing, and it never takes focus from the call
/// app. A click opens the panel — `ContentView` owns that.
///
/// Takes the slot ahead of the Pomodoro and usage badges while a call runs: a
/// timer can wait, a conversation cannot.
struct CopilotNotchBadge: View {
    let notchWidth: CGFloat
    let height: CGFloat
    /// Called on hover — opens the notch, for Quiz only. A call peeks instead.
    var onBadgeHover: (() -> Void)? = nil

    @ObservedObject private var engine = CallaEngineClient.shared
    @ObservedObject private var session = CopilotLiveSession.shared

    @State private var now = Date()
    @State private var peeking = false
    @State private var peekTask: Task<Void, Never>?
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
        Group {
            if isQuiz { quizBody } else { callBody }
        }
        .onReceive(tick) { now = $0 }
    }

    // MARK: - Call

    private var mode: CallaCopilotPresentation.Mode {
        CallaCopilotPresentation.mode(
            available: copilot.available,
            running: copilot.running,
            systemAudioActive: copilot.systemAudioActive,
            hasSuggestion: !CallaCopilotLiveView.answersRetired && copilot.answering && copilot.hasSuggestion)
    }

    private var line: CallaCopilotPresentation.ClosedLine {
        CallaCopilotPresentation.closedLine(
            mode: mode,
            floating: session.floating,
            elapsed: CallaCopilotPresentation.elapsed(since: copilot.startedAt, now: now),
            latestStanding: CallaCallAccount(copilot.summary).currentTopic,
            answerHeadline: copilot.headline,
            catchingUp: copilot.summaryWorking || copilot.working == "summary")
    }

    private var callTint: Color {
        switch line.tone {
        case .warning: return mode == .suggesting ? CallaCallInk.answer : NotchAccent.attention
        case .active, .ready: return NotchAccent.call
        }
    }

    private var callBody: some View {
        let line = self.line
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 7) {
                    NotchStateDot(tint: callTint)
                    Text(line.lead)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(NotchInk.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(width: NotchWing.callSentence, alignment: .trailing)
                .padding(.trailing, NotchWing.housingClearance)

                Rectangle()
                    .fill(.black)
                    .frame(width: notchWidth)

                HStack(spacing: 6) {
                    Text(line.trail)
                        .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(session.floating ? NotchInk.secondary : Color.white.opacity(0.85))
                        .lineLimit(1)
                    if !session.floating {
                        Image(systemName: speakingSymbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(speakingTint)
                            .contentTransition(.symbolEffect)
                    }
                }
                .frame(width: NotchWing.callSentence, alignment: .leading)
                .padding(.leading, NotchWing.housingClearance)
            }
            .frame(height: height, alignment: .center)

            if peeking {
                NotchPeekLine(text: line.peek, hint: line.peekHint)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .fixedSize()
        .contentShape(Rectangle())
        .onHover(perform: hover)
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(line.lead), \(line.trail). \(line.peek)")
        .accessibilityHint(line.peekHint)
    }

    private func hover(_ hovering: Bool) {
        peekTask?.cancel()
        let policy = NotchPeekPolicy.standard
        peekTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(hovering ? policy.peekDelay : policy.foldDelay))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.18)) { peeking = hovering }
        }
    }

    /// Who is talking, small, beside the clock — mint for them, white for you.
    private var speakingSymbol: String {
        if copilot.thinking { return "sparkles" }
        switch copilot.speaking {
        case "them": return "waveform"
        case "me": return "mic.fill"
        default: return "ear"
        }
    }

    private var speakingTint: Color {
        switch copilot.speaking {
        case "them": return NotchAccent.call
        case "me": return NotchInk.primary.opacity(0.85)
        default: return copilot.systemAudioActive ? NotchInk.secondary : NotchAccent.attention
        }
    }

    // MARK: - Quiz

    /// Left says what is running — the state dot and the count; right says how
    /// it is going. Both wings are the same width so the gap stays centred on
    /// the housing.
    private var quizBody: some View {
        HStack(spacing: 0) {
            readout
                .frame(width: NotchWing.call, alignment: .trailing)
                .padding(.trailing, NotchWing.housingClearance)

            Rectangle()
                .fill(.black)
                .frame(width: notchWidth)

            activity
                .frame(width: NotchWing.call, alignment: .leading)
                .padding(.leading, NotchWing.housingClearance)
        }
        .fixedSize()
        .frame(height: height, alignment: .center)
        .onHover { hovering in
            if hovering { onBadgeHover?() }
        }
    }

    private var activity: some View {
        HStack(spacing: 6) {
            Image(systemName: quizSymbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(quizTint)
                .contentTransition(.symbolEffect)
                .symbolEffect(.variableColor.iterative, isActive: quizWorking)
            if quiz.answer != nil {
                Circle()
                    .fill(NotchAccent.focus)
                    .frame(width: 6, height: 6)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.2), value: quiz.answer != nil)
        .help(helpText)
    }

    private var readout: some View {
        HStack(spacing: 7) {
            NotchStateDot(tint: quizDotTint)
            Text(quiz.answerHistory.isEmpty ? "—" : "\(quiz.answerHistory.count)")
                .font(.system(size: 12, design: .monospaced).monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.90))
                .fixedSize()
        }
    }

    private var quizDotTint: Color {
        switch quiz.state {
        case .failed: return NotchAccent.stop
        case .paused: return NotchInk.tertiary
        default: return NotchAccent.quiz
        }
    }

    private var quizSymbol: String {
        switch quiz.state {
        case .solving, .arbitrating, .retrying: return "sparkles"
        case .paused: return "pause.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .answered: return "checkmark.circle.fill"
        default: return "macwindow"
        }
    }

    private var quizTint: Color {
        switch quiz.state {
        case .failed: return NotchAccent.stop
        case .paused: return NotchInk.secondary
        case .answered: return NotchAccent.call
        default: return NotchAccent.quiz
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
        if session.floating { return "The call panel is floating. Click to put it back in the notch." }
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

// MARK: - Shared pieces

/// The state dot every closed badge leads with, with its soft halo.
struct NotchStateDot: View {
    let tint: Color

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: 7, height: 7)
            .background(Circle().fill(tint.opacity(0.22)).padding(-3))
    }
}

/// The one line a hovered closed notch grows by: what is worth reading, and
/// what a click will do. Drawn under the wings, inside the same black slab.
struct NotchPeekLine: View {
    let text: String
    let hint: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(NotchInk.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(hint)
                .font(.system(size: 11))
                .foregroundStyle(NotchInk.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, NotchWing.inset)
        .padding(.top, 2)
        .padding(.bottom, 10)
    }
}

// MARK: - A meeting getting close

/// Which linked meeting the closed notch is talking about, and in what phase.
///
/// Re-read every few seconds rather than only when the calendar changes,
/// because the phase is a function of the clock: the same event goes from a
/// grey time to "Get ready" to "Join" without the calendar saying anything.
@MainActor
final class MeetingApproachWatch: ObservableObject {
    static let shared = MeetingApproachWatch()

    struct Approach: Equatable {
        let event: EventModel
        let phase: MeetingApproach.Phase
    }

    @Published private(set) var current: Approach?
    /// A Join pressed in the closed notch, for the get-ready panel to carry
    /// out. The panel owns starting a call — the call type, the VPN, the notes
    /// — so the badge asks rather than duplicating that.
    @Published private(set) var joinRequest: String?

    private var cancellables: Set<AnyCancellable> = []

    private init() {
        CalendarManager.shared.$upcomingCallMeetings
            // `@Published` fires before the value lands; read it a beat later.
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        CallaEngineClient.shared.$status
            .map(\.copilot.running)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        Timer.publish(every: 5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    func refresh(now: Date = Date()) {
        let calendar = CalendarManager.shared
        let inCall = CallaEngineClient.shared.status.copilot.running
        let next = calendar.upcomingCallMeetings.lazy
            .filter { !calendar.callMeetingDismissed($0.id) }
            .compactMap { event -> Approach? in
                MeetingApproach.phase(start: event.start, end: event.end, now: now, joined: inCall)
                    .map { Approach(event: event, phase: $0) }
            }
            .first
        if next != current { current = next }
    }

    /// Joins the meeting the notch is showing: picks it for the get-ready
    /// panel, which opens its link and starts listening.
    func requestJoin() {
        guard let event = current?.event else { return }
        CalendarManager.shared.selectCallMeeting(event)
        joinRequest = event.id
    }

    /// Shows the meeting on the get-ready panel without joining it.
    func select() {
        guard let event = current?.event else { return }
        CalendarManager.shared.selectCallMeeting(event)
    }

    func consumeJoin() { joinRequest = nil }
}

/// A linked meeting, beside a closed notch, as its start gets close.
struct MeetingApproachBadge: View {
    let notchWidth: CGFloat
    let height: CGFloat

    @ObservedObject private var watch = MeetingApproachWatch.shared
    @State private var now = Date()
    @State private var peeking = false
    @State private var peekTask: Task<Void, Never>?
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if let approach = watch.current {
                content(approach)
            } else {
                Color.clear.frame(width: notchWidth, height: height)
            }
        }
        .onReceive(tick) { now = $0 }
    }

    private func words(for approach: MeetingApproachWatch.Approach) -> MeetingApproach.Line {
        let event = approach.event
        let others = event.participants.filter { !$0.isCurrentUser }.count
        return MeetingApproach.line(
            phase: approach.phase, title: event.title, start: event.start, now: now,
            startTime: event.start.formatted(date: .omitted, time: .shortened),
            people: others == 0 ? 0 : others + 1, notes: 0)
    }

    private func phaseTint(_ phase: MeetingApproach.Phase) -> Color {
        switch phase {
        case .quiet: return NotchInk.tertiary
        case .getReady, .starting: return NotchAccent.quiz
        case .late: return NotchAccent.attention
        }
    }

    private func content(_ approach: MeetingApproachWatch.Approach) -> some View {
        let line = words(for: approach)
        let tint = phaseTint(approach.phase)
        let quiet = approach.phase == .quiet
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 7) {
                    NotchStateDot(tint: tint)
                    Text(line.lead)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(quiet ? NotchInk.secondary : NotchInk.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(width: NotchWing.callSentence, alignment: .trailing)
                .padding(.trailing, NotchWing.housingClearance)

                Rectangle()
                    .fill(.black)
                    .frame(width: notchWidth)

                Group {
                    if approach.phase == .starting {
                        // The only moment the notch offers a button at rest.
                        Text(line.trail)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(NotchAccent.onAccent)
                            .padding(.horizontal, 11)
                            .frame(height: 22)
                            .background(Capsule().fill(NotchAccent.quiz))
                    } else {
                        Text(line.trail)
                            .font(.system(size: 12, weight: quiet ? .medium : .semibold, design: .rounded))
                            .foregroundStyle(quiet ? NotchInk.secondary : tint)
                            .lineLimit(1)
                    }
                }
                .frame(width: NotchWing.callSentence, alignment: .leading)
                .padding(.leading, NotchWing.housingClearance)
            }
            .frame(height: height, alignment: .center)

            if peeking {
                NotchPeekLine(text: line.peek, hint: line.peekHint)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .fixedSize()
        .contentShape(Rectangle())
        .onHover(perform: hover)
        .animation(.smooth(duration: 0.3), value: approach.phase)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(line.lead), \(line.trail). \(line.peek)")
        .accessibilityHint(line.peekHint)
        .accessibilityAddTraits(line.joins ? .isButton : [])
    }

    private func hover(_ hovering: Bool) {
        peekTask?.cancel()
        let policy = NotchPeekPolicy.standard
        peekTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(hovering ? policy.peekDelay : policy.foldDelay))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.18)) { peeking = hovering }
        }
    }
}
