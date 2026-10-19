//
//  CallaCopilotLiveView.swift
//  callaNotch
//

import AppKit
import CallaContracts
import Defaults
import KeyboardShortcuts
import SwiftUI

/// The notch during a live call, at either of its open sizes.
///
/// Lives in the notch rather than a window because a window is visible in every
/// screen share — for a call copilot, the one failure that cannot be traded away.
///
/// **Compact** is for being in the call, not reading it: what is being heard,
/// the controls as buttons big enough to hit without looking, and the
/// transcript running along the bottom like a news strip. **Full** puts the
/// running account beside the live transcript. Zen, the resting size, is
/// `CallaCopilotAmbientView`.
///
/// Answers are retired for now (`answersRetired`): they chased every question
/// on the call, including ones put to someone else, and the panel kept jumping
/// between them. The host no longer drafts them; nothing here draws them.
///
/// Colour: amber is an answer, blue is the account, coral is capture trouble
/// (`CallaCallInk`). Nothing else is tinted.
struct CallaCopilotLiveView: View {
    @ObservedObject private var engine = CallaEngineClient.shared
    @ObservedObject private var session = CopilotLiveSession.shared
    @EnvironmentObject private var vm: CallaViewModel

    @State private var turns: [CallaCallTurn] = []
    @State private var showsManualQuestion = false
    @State private var manualQuestion = ""

    @Default(.callaCopilotPanelSurface) private var surface

    /// Answers as they arrive, newest last.
    ///
    /// The engine only ever carries the *latest* suggestion — it is a status poll,
    /// not a feed — so a call's earlier pointers were simply lost. Keeping them here
    /// is what lets the panel fall back to the previous answer rather than to blank.
    @State private var answers: [LiveAnswer] = []
    @State private var answerHistoryOffset = 0
    struct LiveAnswer: Identifiable, Equatable {
        let id: Int
        let question: String?
        let headline: String
        let angles: [String]
        let warning: String?
        let citations: [String]
        let latencyMs: Int?
    }

    /// Fast enough that a turn appears while it is still the thing being
    /// answered. The engine hands back only what is newer than `lastSeq`, so
    /// the cost of the shorter interval is a near-empty reply, not a re-read.
    private let transcriptTick = Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()

    private var copilot: CallaCopilotStatus { engine.status.copilot }

    private var mode: CallaCopilotPresentation.Mode {
        CallaCopilotPresentation.mode(
            available: copilot.available,
            running: copilot.running,
            systemAudioActive: copilot.systemAudioActive,
            hasSuggestion: copilot.hasSuggestion
        )
    }

    private var compact: Bool { session.layout == .compact }

    /// Answers are off until they can be trusted to answer the right question.
    static let answersRetired = true

    var body: some View {
        Group {
            if compact {
                compactPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        primary
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        if content == .answer, let lead = account.lead {
                            standingStrip(lead)
                        }
                    }
                    .padding(.trailing, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 1)
                    transcriptColumn
                        .padding(.leading, 14)
                        .frame(width: 230)
                        .frame(maxHeight: .infinity, alignment: .topLeading)
                        .transition(.opacity)
                }
            }
        }
        .foregroundStyle(NotchInk.primary)
        // One padding for both layouts, so collapsing changes the size of the
        // content and nothing around it jumps.
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.smooth(duration: 0.35), value: content)
        .animation(.smooth(duration: 0.35), value: displayedAnswer?.id)
        .onChange(of: copilot.suggestionAfterSeq) { _, _ in
            guard !Self.answersRetired, captureCurrentAnswer() else { return }
            // Never take the panel. A new answer — even one to a question put
            // to you — lights the unread dot in the band and waits; the reader
            // switches to Answers when they choose to.
            if surface != "question" { session.markUnreadAnswer() }
        }
        .onReceive(transcriptTick) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .callaCallAskQuestion)) { _ in
            beginManualQuestion()
        }
        .onReceive(NotificationCenter.default.publisher(for: .callaCallToggleSurface)) { _ in
            toggleSurface()
        }
        .onReceive(NotificationCenter.default.publisher(for: .callaCallPreviousAnswer)) { _ in
            answerHistoryOffset = min(answerHistoryOffset + 1, max(0, answers.count - 1))
        }
        .onReceive(NotificationCenter.default.publisher(for: .callaCallNextAnswer)) { _ in
            answerHistoryOffset = max(0, answerHistoryOffset - 1)
        }
        .onAppear {
            refresh()
            restoreAnswers()
            // `onChange` fires only for changes *after* this view exists, so an
            // answer that landed before the panel was drawn — or before a layout
            // swap rebuilt it — was never recorded.
            _ = captureCurrentAnswer()
        }
        .alert("Answer this", isPresented: $showsManualQuestion) {
            TextField("Selected transcript text", text: $manualQuestion, axis: .vertical)
            Button("Answer") {
                let text = manualQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                engine.answerSelectedText(text)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Ask Copilot about selected or pasted transcript text.")
        }
    }

    // MARK: - What is shown

    private enum Content { case answer, noAnswer, recap, listening, halfDeaf }

    /// The engine is working on one right now, so the empty lane says "coming"
    /// rather than "none" — four seconds of "No answer yet" while one is being
    /// written reads as the feature having given up.
    private var answerIsComing: Bool {
        copilot.questionWorking || copilot.working == "answer"
    }

    private var catchingUp: Bool {
        copilot.summaryWorking || copilot.working == "summary"
    }

    /// What the panel shows. **The reader's choice owns this**, and an arriving
    /// answer never takes the panel away from them — a new answer while the
    /// recap is up lights the unread dot in the band and waits to be asked for.
    private var content: Content {
        if Self.answersRetired {
            if mode == .halfDeaf { return .halfDeaf }
            return account.isEmpty ? .listening : .recap
        }
        if mode == .halfDeaf, answers.isEmpty { return .halfDeaf }
        if surface == "question" {
            if !answers.isEmpty { return .answer }
            if let headline = copilot.headline, !headline.isEmpty { return .answer }
            // A question has been heard and its answer is being written: show
            // the question now, not the recap, so the wait has a subject.
            if answerIsComing || copilot.detectedQuestion != nil { return .noAnswer }
            if !account.isEmpty { return .recap }
            return .noAnswer
        }
        if !account.isEmpty { return .recap }
        return .listening
    }

    private var account: CallaCallAccount { CallaCallAccount(copilot.summary) }

    private var displayedAnswer: LiveAnswer? {
        guard !answers.isEmpty else { return nil }
        return answers[max(0, answers.count - 1 - min(answerHistoryOffset, answers.count - 1))]
    }

    @ViewBuilder private var primary: some View {
        switch content {
        case .answer: answerBlock
        case .recap: accountBlock
        case .noAnswer: pendingBlock
        case .halfDeaf: halfDeafBlock
        case .listening: listeningBlock
        }
    }

    // MARK: - Answer

    /// The question in small type, the line to say set large, then the order to
    /// say it in. Read in the half-second before speaking, so the line is the
    /// only thing at full ink.
    private var answerBlock: some View {
        let latest = displayedAnswer
        let question = (latest?.question ?? copilot.detectedQuestion).flatMap { $0.isEmpty ? nil : $0 }
        let headline = CallaCopilotPresentation.headlineLine(latest?.headline ?? copilot.headline, limit: 200)
        let beats = CallaCopilotPresentation.angleLines(latest?.angles ?? copilot.angles,
                                                       limit: 3, characters: 120)
        let warning = (latest?.warning ?? copilot.confirm.first).flatMap { $0.isEmpty ? nil : $0 }

        return VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            HStack(spacing: 8) {
                CallaEyebrow(answerEyebrow, tint: CallaCallInk.answer)
                Spacer(minLength: 4)
                if let source = answerSource {
                    Text(source)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(NotchInk.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(source)
                }
                if answers.count > 1 { pager }
            }
            .frame(height: 22)

            if let question {
                Text("“\(question)”")
                    .font(CallaCallType.question)
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(compact ? 1 : 2)
                    .help(question)
                    .textSelection(.enabled)
            }

            // Scrolls rather than clips: a long answer is read in full, never cut
            // off at whatever the panel happens to hold.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: compact ? 9 : 12) {
                    if let headline {
                        Text(headline)
                            .font(.system(size: compact ? 17 : 19, weight: .semibold))
                            .tracking(-0.2)
                            .lineSpacing(1)
                            .foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    if let warning {
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            CallaTag(text: "check", tint: CallaCallInk.problem)
                            Text(warning)
                                .font(.system(size: 11.5))
                                .foregroundStyle(NotchInk.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if !beats.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            if compact {
                                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                                    .padding(.bottom, 9)
                            }
                            CallaBeats(beats: beats, horizontal: compact)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .id(latest?.id)
            .transition(.opacity.combined(with: .offset(y: -4)))
        }
    }

    private var answerEyebrow: String {
        guard let answer = displayedAnswer,
              let turn = turns.last(where: { $0.seq <= answer.id && $0.isRemote }) else { return "They asked" }
        return "They asked · \(turn.clock)"
    }

    /// What the answer stands on, and how long it took.
    private var answerSource: String? {
        var parts = Array((displayedAnswer?.citations ?? copilot.citationLabels).prefix(compact ? 1 : 2))
        if let latency = displayedAnswer?.latencyMs ?? copilot.answerLatencyMs {
            parts.append(String(format: "%.1fs", Double(latency) / 1000))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Older and newer answers. The keys do the same; this is for the pointer.
    private var pager: some View {
        HStack(spacing: 5) {
            pagerButton("chevron.left", label: "Older answer",
                        enabled: answerHistoryOffset < answers.count - 1) {
                NotificationCenter.default.post(name: .callaCallPreviousAnswer, object: nil)
            }
            Text("\(answers.count - answerHistoryOffset) / \(answers.count)")
                .font(CallaCallType.figure)
                .foregroundStyle(NotchInk.secondary)
                .fixedSize()
            pagerButton("chevron.right", label: "Newer answer", enabled: answerHistoryOffset > 0) {
                NotificationCenter.default.post(name: .callaCallNextAnswer, object: nil)
            }
        }
    }

    private func pagerButton(_ symbol: String, label: String, enabled: Bool,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(enabled ? 0.08 : 0.04)))
                .foregroundStyle(.white.opacity(enabled ? 0.75 : 0.3))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    // MARK: - Account

    /// Where the call stands in one sentence, then what has settled and what is
    /// still open — the two questions a reader actually has mid-call.
    private var accountBlock: some View {
        let account = account
        let lately = account.trail(compact ? 2 : 3)
        let open = Array(copilot.openQuestions.prefix(2))

        return VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            HStack(spacing: 8) {
                CallaEyebrow(surface == "question" ? "No answer yet · where it stands" : "Where it stands",
                             tint: CallaCallInk.summary)
                Spacer(minLength: 4)
                if catchingUp {
                    HStack(spacing: 6) {
                        CallaWaveBars(tint: CallaCallInk.summary)
                        Text("catching up")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(NotchInk.tertiary)
                    }
                    .transition(.opacity)
                }
            }
            .frame(height: 22)

            if let lead = account.lead {
                Text(lead)
                    .font(.system(size: compact ? 15.5 : 17, weight: .medium))
                    .tracking(-0.15)
                    .lineSpacing(1.5)
                    .foregroundStyle(.white.opacity(0.96))
                    .lineLimit(compact ? 3 : 4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .help(lead)
                    .id(lead)
                    .transition(.opacity)
            }

            if !lately.isEmpty || !open.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                        .padding(.bottom, 9)
                    HStack(alignment: .top, spacing: 16) {
                        if !lately.isEmpty {
                            accountColumn("Lately", symbol: "checkmark", tint: CallaCallInk.summary,
                                          lines: lately, ink: .white.opacity(0.72))
                        }
                        if !open.isEmpty {
                            accountColumn("Still open", symbol: "circle", tint: CallaCallInk.answer,
                                          lines: open, ink: .white.opacity(0.9))
                        }
                    }
                }
            }
        }
    }

    private func accountColumn(_ title: String, symbol: String, tint: Color,
                               lines: [String], ink: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(tint)
                CallaEyebrow(title, tint: NotchInk.tertiary)
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 11.5))
                    .foregroundStyle(ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(line)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Under the answer in full: the account, cut to its one sentence.
    private func standingStrip(_ lead: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            CallaEyebrow("Where it stands", tint: CallaCallInk.summary)
            Text(lead)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(2)
                .help(lead)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11).fill(Color.white.opacity(0.05)))
    }

    // MARK: - Between answers

    /// A question is in and its answer is being written — or the reader asked
    /// for answers before there was one.
    private var pendingBlock: some View {
        let question = copilot.detectedQuestion.flatMap { $0.isEmpty ? nil : $0 }
        let uncertain = question != nil && !copilot.confirm.isEmpty

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                CallaEyebrow(uncertain ? "Check the question"
                                : (answerIsComing ? (question == nil ? "Finding an answer" : "Question heard")
                                                  : "No answer yet"),
                             tint: uncertain ? CallaCallInk.problem : CallaCallInk.answer)
                Spacer(minLength: 4)
                if answerIsComing { CallaWaveBars(tint: CallaCallInk.answer) }
            }
            .frame(height: 22)

            if let question {
                Text("“\(question)”")
                    .font(.system(size: compact ? 15.5 : 17, weight: .medium))
                    .foregroundStyle(.white.opacity(0.96))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if answerIsComing {
                VStack(alignment: .leading, spacing: 7) {
                    CallaShimmerLine(widthFraction: 0.92)
                    CallaShimmerLine(widthFraction: 0.6)
                }
                .padding(.top, 2)
            } else {
                Text(uncertain
                     ? "The transcript is uncertain. Edit the question and press Answer."
                     : "One appears here the moment a question worth answering is asked.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(NotchInk.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var listeningBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                CallaEyebrow("Listening", tint: CallaCallInk.summary)
                Spacer(minLength: 4)
                CallaWaveBars(tint: CallaCallInk.summary, active: copilot.speaking != nil)
            }
            .frame(height: 22)
            Text("What's said becomes a running account here as the call goes on.")
                .font(.system(size: compact ? 15 : 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var halfDeafBlock: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "speaker.slash.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(CallaCallInk.problem)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 10).fill(CallaCallInk.problem.opacity(0.14)))
            VStack(alignment: .leading, spacing: 5) {
                Text("Their side isn't coming through")
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Only your microphone is being captured, so the account has one side of the call. Grant Screen Recording so the other side is transcribed too.")
                    .font(.system(size: 12))
                    .foregroundStyle(NotchInk.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Text("Open Screen Recording settings")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.95)))
                }
                .buttonStyle(.plain)
                .padding(.top, 3)
            }
        }
        .padding(.top, 6)
    }

    // MARK: - Compact

    /// Being in the call: what is being heard, the four things you might press,
    /// and the words going by underneath.
    private var compactPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            compactStatus
            HStack(spacing: 10) {
                CallaLargeButton(title: copilot.screenshotCount > 0
                                    ? "Screenshot · \(copilot.screenshotCount)" : "Screenshot",
                                 symbol: "camera") {
                    engine.takeScreenshot()
                    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                }
                CallaLargeButton(title: pinned ? "Unpin" : "Keep open",
                                 symbol: pinned ? "pin.slash" : "pin",
                                 selected: pinned) {
                    AppDelegate.shared?.toggleUniversalNotchPin(for: vm)
                }
                CallaLargeButton(title: "Full view", symbol: "arrow.up.left.and.arrow.down.right") {
                    session.toggleLayout()
                }
                Spacer(minLength: 0)
                CallaLargeButton(title: "End call", symbol: "stop.fill", role: .destructive) {
                    engine.endCall()
                }
            }
            Spacer(minLength: 0)
            CallaTranscriptTicker(turns: turns)
        }
        .padding(.top, 4)
    }

    private var pinned: Bool { vm.isPinned || session.pinsNotchOpen }

    private var compactStatus: some View {
        HStack(spacing: 10) {
            CallaWaveBars(tint: mode == .halfDeaf ? CallaCallInk.problem : CallaCallInk.summary,
                          active: copilot.speaking != nil)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(mode == .halfDeaf ? "Only hearing you" : "Listening to both sides")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(mode == .halfDeaf ? CallaCallInk.problem : NotchInk.primary)
                Text(compactDetail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(NotchInk.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var compactDetail: String {
        if mode == .halfDeaf { return "Screen Recording is off for the call host, so their side is not transcribed." }
        var parts: [String] = []
        switch copilot.speaking {
        case "me": parts.append("You are speaking")
        case "them": parts.append("They are speaking")
        default: break
        }
        parts.append("\(copilot.turnCount) turn\(copilot.turnCount == 1 ? "" : "s") so far")
        return parts.joined(separator: " · ")
    }

    // MARK: - Transcript

    /// Whole turns, newest at the floor and dissolved at the top so the oldest
    /// is what leaves. The turn that was answered is marked, so the reader can
    /// see what the answer beside it is answering.
    private var transcriptColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                CallaEyebrow("Transcript", tint: NotchInk.tertiary)
                Spacer(minLength: 4)
                Text(copilot.systemAudioActive ? "Both sides" : "Only you")
                    .font(.system(size: 10.5))
                    .foregroundStyle(copilot.systemAudioActive ? NotchInk.tertiary : CallaCallInk.problem)
            }
            .frame(height: 22)

            if turns.isEmpty {
                Text(copilot.systemAudioActive
                     ? "Turns appear here as they are transcribed on this Mac."
                     : "Grant Screen Recording so the other side is transcribed too.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(NotchInk.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            } else {
                let shown = Array(turns.suffix(6))
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(shown, id: \.seq) { turn in
                        turnRow(turn, isNewest: turn.seq == shown.last?.seq,
                                isQuestion: turn.seq == questionTurnSeq)
                    }
                }
                .animation(.easeOut(duration: 0.2), value: turns.last?.seq)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .clipped()
                .mask(alignment: .bottom) {
                    LinearGradient(colors: [.clear, .black, .black],
                                   startPoint: .top, endPoint: .init(x: 0.5, y: 0.25))
                }
            }
        }
    }

    /// The last thing they said before the displayed answer was written.
    private var questionTurnSeq: Int? {
        guard content == .answer, let answer = displayedAnswer else { return nil }
        return turns.last(where: { $0.seq <= answer.id && $0.isRemote })?.seq
    }

    private func turnRow(_ turn: CallaCallTurn, isNewest: Bool, isQuestion: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(turn.clock)
                .font(.system(size: 9.5, design: .monospaced).monospacedDigit())
                .foregroundStyle(NotchInk.tertiary)
                .frame(width: 34, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(turn.speakerLabel)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(turn.isRemote ? CallaCallInk.summary : NotchInk.tertiary)
                    if isQuestion {
                        CallaEyebrow("question", tint: CallaCallInk.answer)
                    }
                }
                Text(turn.text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(isNewest || isQuestion ? 0.9 : 0.6))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(isQuestion ? 7 : 0)
        .background {
            if isQuestion {
                RoundedRectangle(cornerRadius: 9).fill(CallaCallInk.answer.opacity(0.10))
            }
        }
        .padding(.horizontal, isQuestion ? -7 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity.combined(with: .offset(y: 6)))
    }

    // MARK: - Actions

    private func beginManualQuestion() {
        guard copilot.running else { return }
        manualQuestion = copilot.detectedQuestion ?? turns.last?.text ?? ""
        showsManualQuestion = true
    }

    private func toggleSurface() {
        guard copilot.running else { return }
        surface = surface == "question" ? "summary" : "question"
        if surface == "question" { session.clearUnreadAnswer() }
    }

    // MARK: - Data

    /// Records the engine's current suggestion, if it is one we have not kept.
    /// Returns whether anything was added.
    @discardableResult
    private func captureCurrentAnswer() -> Bool {
        guard let seq = copilot.suggestionAfterSeq,
              let headline = copilot.headline?.trimmingCharacters(in: .whitespacesAndNewlines),
              !headline.isEmpty,
              answers.last?.id != seq,
              answers.last?.headline != headline
        else { return false }
        answers.append(LiveAnswer(id: seq, question: copilot.detectedQuestion,
                                  headline: headline, angles: copilot.angles,
                                  warning: copilot.confirm.first,
                                  citations: copilot.citationLabels,
                                  latencyMs: copilot.answerLatencyMs))
        answerHistoryOffset = 0
        // A long call would otherwise grow this without bound.
        if answers.count > 30 { answers.removeFirst(answers.count - 30) }
        return true
    }

    private func refresh() {
        guard copilot.running else { return }
        engine.fetchTranscript(since: turns.last?.seq) { fresh in
            guard !fresh.isEmpty else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                // The engine only returns turns newer than the cursor, but a
                // reconnect can replay one; `seq` is monotonic per call, so
                // filtering on it is enough to stay ordered and duplicate-free.
                let known = Set(turns.map(\.seq))
                turns.append(contentsOf: fresh.filter { !known.contains($0.seq) })
                // Only the tail is drawn; a long call would otherwise hold every turn.
                if turns.count > 200 { turns.removeFirst(turns.count - 200) }
            }
        }
    }

    private func restoreAnswers() {
        guard let callID = copilot.callID else { return }
        engine.fetchCallSuggestions(callID) { stored in
            let restored = stored.compactMap { item -> LiveAnswer? in
                let headline = item.headline.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !headline.isEmpty else { return nil }
                return LiveAnswer(id: item.afterSeq, question: item.question,
                                  headline: headline, angles: item.angles,
                                  warning: item.confirm.first,
                                  citations: item.citations ?? [], latencyMs: item.latencyMs)
            }
            guard !restored.isEmpty else { return }
            answers = Array(restored.suffix(30))
            answerHistoryOffset = 0
        }
    }
}

extension Notification.Name {
    static let callaCallAskQuestion = Notification.Name("callaCallAskQuestion")
    static let callaCallToggleSurface = Notification.Name("callaCallToggleSurface")
    static let callaCallPreviousAnswer = Notification.Name("callaCallPreviousAnswer")
    static let callaCallNextAnswer = Notification.Name("callaCallNextAnswer")
}

/// A short tinted label. Used in the header band either side of the housing,
/// where there is room for a word but not for a row.
struct CallaPill: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(NotchGlassType.caps)
            .tracking(notchCapsTracking)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.20), in: Capsule())
            .foregroundStyle(tint)
            .fixedSize()
    }
}

/// A recording dot that breathes while both legs are being captured.
struct LivePulse: View {
    let active: Bool
    @State private var expanded = false

    var body: some View {
        Circle()
            .fill(active ? NotchTint.healthy : NotchTint.attention)
            .frame(width: 6, height: 6)
            .scaleEffect(expanded ? 1.35 : 1)
            .opacity(expanded ? 0.55 : 1)
            .animation(active ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true) : .default,
                       value: expanded)
            .onAppear { expanded = active }
            .onChange(of: active) { _, value in expanded = value }
    }
}

/// The live call's status and controls, drawn either side of the camera housing.
///
/// Lives in the notch's own header band rather than inside the panel below it.
/// That band is dead space during a call — the panel is wider than the physical
/// cutout and the tab row is hidden — so putting the status on one side and the
/// controls on the other buys the answer plane a full row of height it would
/// otherwise spend on a status line. It is also why the panel below carries no
/// chrome of its own: this *is* the chrome.
struct CallaCopilotLiveHeader: View {
    @ObservedObject private var engine = CallaEngineClient.shared
    @ObservedObject private var session = CopilotLiveSession.shared
    @EnvironmentObject private var vm: CallaViewModel

    @State private var now = Date()
    @Default(.hideFromScreenRecording) private var hiddenFromCapture
    @Default(.callaIntelligenceProvider) private var preferredProvider
    private let clockTick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var copilot: CallaCopilotStatus { engine.status.copilot }

    @Default(.callaCopilotPanelSurface) private var surface

    /// What the screenshot button last did, said in the heading's place for a
    /// moment so a press never goes unanswered.
    @State private var shotNote: (text: String, failed: Bool)?
    @State private var shotNoteTask: Task<Void, Never>?
    @State private var shutter = false
    /// The control under the pointer, named in the band.
    @State private var hint: NotchHint?

    private func noteShot(_ text: String, failed: Bool = false, for seconds: Double) {
        withAnimation(.smooth(duration: 0.2)) { shotNote = (text, failed) }
        shotNoteTask?.cancel()
        shotNoteTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.3)) { shotNote = nil }
        }
    }

    private func takeScreenshot() {
        engine.takeScreenshot()
        // The shutter: a quick blink of the glyph, then the note.
        withAnimation(.easeOut(duration: 0.08)) { shutter = true }
        withAnimation(.easeIn(duration: 0.3).delay(0.12)) { shutter = false }
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        noteShot("Taking screenshot…", for: 20)
    }

    private var mode: CallaCopilotPresentation.Mode {
        CallaCopilotPresentation.mode(
            available: copilot.available,
            running: copilot.running,
            systemAudioActive: copilot.systemAudioActive,
            hasSuggestion: copilot.hasSuggestion)
    }

    /// The panel's own heading, drawn up here.
    private var heading: String {
        CallaCopilotPresentation.panelHeading(
            surface: surface,
            hasAnswer: copilot.hasSuggestion,
            hasSummary: !(copilot.summary ?? "").isEmpty,
            mode: mode,
            working: workingLabel)
    }

    private var workingLabel: String? {
        if CallaCopilotLiveView.answersRetired {
            return copilot.summaryWorking || copilot.working == "summary" ? "Catching up" : nil
        }
        if copilot.questionWorking { return "Finding an answer" }
        if copilot.summaryWorking { return "Catching up" }
        switch copilot.working {
        case "answer": return "Finding an answer"
        case "summary": return "Catching up"
        default: return nil
        }
    }

    private var headingTint: Color {
        if copilot.questionWorking || copilot.working == "answer" { return CallaCallInk.answer }
        if workingLabel != nil { return CallaCallInk.summary }
        if mode == .halfDeaf { return CallaCallInk.problem }
        return NotchInk.primary
    }

    var body: some View {
        // Each half is exactly its share of the band. The halves used to size to
        // their labels, and a longer one — "Taking screenshot…" — pushed the band
        // past the panel, and the black slab grew with it. Now a label that does
        // not fit gives way inside its half and the notch keeps its width.
        GeometryReader { proxy in
            let half = max(0, (proxy.size.width - vm.closedNotchSize.width) / 2)
            HStack(spacing: 0) {
                leading
                    .frame(width: half, height: proxy.size.height, alignment: .leading)
                    .clipped()
                // The camera housing. Nothing may be drawn here.
                Color.clear.frame(width: vm.closedNotchSize.width)
                trailing
                    .frame(width: half, height: proxy.size.height, alignment: .trailing)
                    // A hovered control names itself in the band, on the left,
                    // instead of in a bubble that has nowhere good to go: over
                    // the glyphs, or down across the answer being read.
                    .environment(\.notchHintSink) { next in
                        withAnimation(.easeOut(duration: 0.12)) { hint = next }
                    }
            }
        }
        .padding(.horizontal, 14)
        .onReceive(clockTick) { now = $0 }
        .onChange(of: copilot.screenshotCount) { old, new in
            guard new > old else { return }
            noteShot(new == 1 ? "Screenshot added" : "Screenshot added · \(new)", for: 2.2)
        }
        .onChange(of: copilot.lastResult) { _, result in
            guard let result, shotNote != nil,
                  result.localizedCaseInsensitiveContains("screenshot"),
                  !result.localizedCaseInsensitiveContains("added"),
                  !result.localizedCaseInsensitiveContains("taking") else { return }
            noteShot(result.count > 60 ? "Screenshot failed" : result, failed: true, for: 4)
        }
    }

    /// The pulse, the Summary | Answers switch, and the clock — or, while a
    /// control on the right is hovered, that control's name and key. The pills
    /// are the first to go when the half is short; the clock is the last.
    @ViewBuilder private var leading: some View {
        if let hint {
            hintRow(hint)
                .transition(.opacity)
        } else if let shotNote {
            HStack(spacing: NotchGlassSpace.tight) {
                LivePulse(active: copilot.running && copilot.systemAudioActive)
                Label(shotNote.text, systemImage: shotNote.failed ? "exclamationmark.triangle.fill" : "camera.fill")
                    .font(NotchGlassType.bandLabel)
                    .foregroundStyle(shotNote.failed ? CallaCallInk.problem : CallaCallInk.summary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .transition(.opacity)
        } else {
            ViewThatFits(in: .horizontal) {
                leadingRow(badge: true, persona: session.layout == .full)
                leadingRow(badge: true, persona: false)
                leadingRow(badge: false, persona: false)
            }
            .transition(.opacity)
        }
    }

    private func hintRow(_ hint: NotchHint) -> some View {
        HStack(spacing: 7) {
            if let symbol = hint.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            Text(hint.text)
                .font(NotchGlassType.bandLabel)
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.tail)
            if let shortcut = hint.shortcut {
                Text(shortcut)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
                    .fixedSize()
            }
        }
    }

    private func leadingRow(badge: Bool, persona: Bool) -> some View {
        HStack(spacing: NotchGlassSpace.tight) {
            LivePulse(active: copilot.running && copilot.systemAudioActive)
            if CallaCopilotLiveView.answersRetired {
                Text(workingLabel ?? (mode == .halfDeaf ? "Only you" : "Listening"))
                    .font(NotchGlassType.bandLabel)
                    .foregroundStyle(workingLabel != nil ? CallaCallInk.summary
                                     : mode == .halfDeaf ? CallaCallInk.problem : NotchInk.secondary)
                    .lineLimit(1)
                    .fixedSize()
            } else {
                surfaceSwitch
            }
            if let elapsed = CallaCopilotPresentation.elapsed(since: copilot.startedAt, now: now) {
                Text(elapsed)
                    .font(NotchGlassType.inlineFigure)
                    .foregroundStyle(NotchInk.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .layoutPriority(2)
            }
            // Shown only when the brain answering is not the one chosen in
            // Settings — an automatic handover to the gateway is otherwise
            // indistinguishable from a copilot that has quietly gone vague.
            if badge, let pill = CallaCopilotPresentation.providerBadge(
                active: copilot.activeProvider,
                preferred: preferredProvider,
                running: copilot.running
            ) {
                CallaPill(text: pill.text, tint: tint(for: pill.tone))
            }
            if persona {
                CallaPill(text: CallaCopilotPersona.title(copilot.persona), tint: NotchInk.tertiary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// What the panel shows, as two labelled segments rather than one glyph
    /// whose picture had to be decoded. Each segment carries its own colour and
    /// its own working state; Answers carries the unread dot.
    private var surfaceSwitch: some View {
        let answering = copilot.questionWorking || copilot.working == "answer"
        let catchingUp = copilot.summaryWorking || copilot.working == "summary"
        return HStack(spacing: 1) {
            surfaceSegment("Summary", value: "summary", tint: CallaCallInk.summary,
                           working: catchingUp, dot: false)
            surfaceSegment("Answers", value: "question", tint: CallaCallInk.answer,
                           working: answering, dot: session.unreadAnswer)
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.07)))
        .fixedSize()
        .help(shortcutHelp("Switch between the summary and answers", .sessionSurface))
    }

    private func surfaceSegment(_ title: String, value: String, tint: Color,
                                working: Bool, dot: Bool) -> some View {
        let selected = surface == value
        return Button {
            guard surface != value else { return }
            NotificationCenter.default.post(name: .callaCallToggleSurface, object: nil)
        } label: {
            HStack(spacing: 4) {
                if working {
                    CallaWaveBars(tint: selected ? .black : tint)
                        .scaleEffect(0.75)
                        .frame(width: 10)
                }
                Text(title)
                    .font(.system(size: 10.5, weight: selected ? .semibold : .medium))
                if dot && !selected {
                    Circle().fill(tint).frame(width: 5, height: 5)
                }
            }
            .foregroundStyle(selected ? Color.black : Color.white.opacity(0.7))
            .padding(.horizontal, 8)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(selected ? tint : Color.clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .animation(.smooth(duration: 0.2), value: selected)
    }

    private var trailing: some View {
        HStack(spacing: NotchGlassSpace.tight) {
            Image(systemName: copilot.micActive ? "mic.fill" : "mic.slash.fill")
                .font(NotchGlassType.glyphSmall)
                .foregroundStyle(copilot.micActive ? NotchInk.secondary : NotchTint.attention)
                .padding(2)
                .contentShape(Rectangle())
                .notchTooltip(copilot.micActive ? "Your microphone is being captured"
                                                : "Your microphone is not being captured",
                              symbol: copilot.micActive ? "mic.fill" : "mic.slash.fill")
            // Reports the setting rather than asserting a guarantee: hidden from
            // captures when "Hide from screen recording" is on, visible when off.
            Image(systemName: hiddenFromCapture ? "eye.slash.fill" : "eye.fill")
                .font(NotchGlassType.glyphSmall)
                .foregroundStyle(hiddenFromCapture ? NotchInk.secondary : NotchTint.attention)
                .padding(2)
                .contentShape(Rectangle())
                .notchTooltip(hiddenFromCapture ? "Hidden from screen shares"
                                                : "Visible in screen shares — turn on Hide in Settings",
                              symbol: hiddenFromCapture ? "eye.slash.fill" : "eye.fill")

            if !CallaCopilotLiveView.answersRetired {
                NotchGlyphButton(symbol: "questionmark.bubble") {
                    NotificationCenter.default.post(name: .callaCallAskQuestion, object: nil)
                }
                .notchTooltip("Ask about what was just said", symbol: "questionmark.bubble",
                              shortcut: shortcutKeys(.sessionAsk))
                .accessibilityLabel("Ask about what was just said")
            }

            // Compact draws these as large buttons in the panel itself.
            if session.layout == .full {
            // What is being shared becomes context: the words on it go to
            // the copilot, and the picture is filed with the call.
            NotchGlyphButton(symbol: "camera",
                             tint: shotNote == nil ? NotchInk.tertiary : CallaCallInk.summary) {
                takeScreenshot()
            }
            .scaleEffect(shutter ? 0.78 : 1)
            .opacity(shutter ? 0.4 : 1)
            .overlay(alignment: .topTrailing) {
                if copilot.screenshotCount > 0 {
                    CallaSuperscript(count: copilot.screenshotCount)
                        .offset(x: 4, y: -1)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: copilot.screenshotCount)
            .notchTooltip(copilot.screenshotCount > 0
                          ? "Screenshot the shared screen · \(copilot.screenshotCount) so far"
                          : "Screenshot the shared screen",
                          symbol: "camera")
            .accessibilityLabel("Take a screenshot for context")

            // Collapse to the answer alone and back.
            NotchGlyphButton(symbol: session.layout == .full
                                ? "arrow.down.right.and.arrow.up.left"
                                : "arrow.up.left.and.arrow.down.right") {
                session.toggleLayout()
            }
            .notchTooltip(session.layout == .full ? "Compact" : "Full, with the transcript",
                          symbol: session.layout == .full ? "arrow.down.right.and.arrow.up.left"
                                                          : "arrow.up.left.and.arrow.down.right",
                          shortcut: shortcutKeys(.copilotToggleLayout))
            .accessibilityLabel(session.layout == .full ? "Compact layout" : "Full layout")

            // Pin belongs to the notch, while Call contributes a temporary
            // automatic hold. The same action is available system-wide.
            NotchGlyphButton(symbol: (vm.isPinned || session.pinsNotchOpen) ? "pin.fill" : "pin") {
                AppDelegate.shared?.toggleUniversalNotchPin(for: vm)
            }
            .notchTooltip((vm.isPinned || session.pinsNotchOpen) ? "Unpin the notch" : "Pin the notch open",
                          symbol: (vm.isPinned || session.pinsNotchOpen) ? "pin.fill" : "pin")
            .accessibilityLabel((vm.isPinned || session.pinsNotchOpen) ? "Unpin notch" : "Pin notch open")

            NotchGlyphButton(symbol: "stop.fill", tint: NotchTint.stuck) {
                engine.endCall()
            }
            .notchTooltip("End the call", symbol: "stop.fill", shortcut: shortcutKeys(.copilotToggleCall))
            .accessibilityLabel("End call")
            }
        }
    }

    private func shortcutKeys(_ name: KeyboardShortcuts.Name) -> String? {
        KeyboardShortcuts.getShortcut(for: name)?.description
    }

    private func shortcutHelp(_ label: String, _ name: KeyboardShortcuts.Name) -> String {
        guard let shortcut = KeyboardShortcuts.getShortcut(for: name) else { return label }
        return "\(label) — \(shortcut.description)"
    }

    private func tint(for tone: CallaCopilotPresentation.Tone) -> Color {
        switch tone {
        case .active: return NotchTint.healthy
        case .ready: return .effectiveAccent
        case .warning: return NotchTint.attention
        }
    }
}

// MARK: - Ambient (zen)

/// The band beside the notch while a call rests in zen mode: the clock on the
/// left, what the copilot is doing on the right. The hardware cutout sits
/// between them, so the band reads as the notch itself carrying status.
struct CallaAmbientWings: View {
    @ObservedObject private var engine = CallaEngineClient.shared
    @EnvironmentObject private var vm: CallaViewModel
    @State private var now = Date()
    private let clockTick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var copilot: CallaCopilotStatus { engine.status.copilot }

    /// What is happening, in the colour of what it will produce.
    private var status: (text: String, tint: Color, moving: Bool) {
        if copilot.running && !copilot.systemAudioActive { return ("Only you", CallaCallInk.problem, false) }
        if !CallaCopilotLiveView.answersRetired, copilot.questionWorking || copilot.working == "answer" {
            return ("Drafting", CallaCallInk.answer, true)
        }
        if copilot.summaryWorking || copilot.working == "summary" { return ("Catching up", CallaCallInk.summary, true) }
        if !CallaCopilotLiveView.answersRetired, copilot.hasSuggestion {
            return ("Answer", CallaCallInk.answer, copilot.speaking != nil)
        }
        return ("Listening", CallaCallInk.summary, copilot.speaking != nil)
    }

    var body: some View {
        let status = status
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(status.tint)
                    .frame(width: 6, height: 6)
                    .background(Circle().fill(status.tint.opacity(0.25)).frame(width: 12, height: 12))
                if let elapsed = CallaCopilotPresentation.elapsed(since: copilot.startedAt, now: now) {
                    Text(elapsed)
                        .font(.system(size: 11.5, design: .monospaced).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.88))
                }
                Spacer(minLength: 0)
            }
            .lineLimit(1)
            .padding(.leading, 20)
            .frame(maxWidth: .infinity)

            // The camera housing. Nothing may be drawn here.
            Color.clear.frame(width: vm.closedNotchSize.width)

            HStack(spacing: 7) {
                Spacer(minLength: 0)
                if copilot.screenshotCount > 0 {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .overlay(alignment: .topTrailing) {
                            CallaSuperscript(count: copilot.screenshotCount)
                                .offset(x: 6, y: -4)
                        }
                        .padding(.trailing, 6)
                        .accessibilityLabel("\(copilot.screenshotCount) screenshots")
                }
                CallaWaveBars(tint: status.tint, active: status.moving)
                Text(status.text)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(status.tint)
                    .contentTransition(.opacity)
            }
            .lineLimit(1)
            .padding(.trailing, 20)
            .frame(maxWidth: .infinity)
        }
        .animation(.smooth(duration: 0.3), value: status.text)
        .onReceive(clockTick) { now = $0 }
    }
}

/// The call at rest: the notch grown into an island showing where the
/// conversation has got to. One sentence set large, the newest points under
/// it, and anything still waiting on you tagged open. A fresh answer takes the
/// island for a while — the line to say, large — then the account returns.
/// Hovering opens the compact panel.
struct CallaCopilotAmbientView: View {
    @ObservedObject private var engine = CallaEngineClient.shared
    @ObservedObject private var session = CopilotLiveSession.shared
    @EnvironmentObject private var vm: CallaViewModel
    @State private var answer: HeldAnswer?
    @State private var answerTask: Task<Void, Never>?

    struct HeldAnswer: Equatable {
        let question: String?
        let headline: String
        let angles: [String]
        let shownAt: Date
    }

    /// How long a fresh answer holds the island before the account returns.
    static let answerSeconds: Double = 25
    /// The island grows with its text up to this, then the oldest lines give way.
    static let maximumHeight: CGFloat = 300

    private var copilot: CallaCopilotStatus { engine.status.copilot }
    private var account: CallaCallAccount { CallaCallAccount(copilot.summary) }

    var body: some View {
        Group {
            if let answer, !CallaCopilotLiveView.answersRetired {
                answerView(answer)
                    .transition(.opacity.combined(with: .offset(y: -6)))
            } else if !CallaCopilotLiveView.answersRetired,
                      copilot.questionWorking || copilot.working == "answer",
                      let question = copilot.detectedQuestion, !question.isEmpty {
                heardView(question)
                    .transition(.opacity)
            } else if let lead = account.lead {
                accountView(lead)
                    .transition(.opacity)
            }
            // Nothing yet: nothing below the notch. "Listening" is already
            // said in the band beside the camera.
        }
        // Every line in full: wrapping, never an ellipsis.
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 6)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: AmbientHeightKey.self, value: proxy.size.height)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .bottom) {
            if let answer, !CallaCopilotLiveView.answersRetired { holdBar(answer) }
        }
        .onPreferenceChange(AmbientHeightKey.self) { content in
            // The notch band, this text, and the island's bottom inset — or the
            // band alone when there is nothing to show under it.
            let band = vm.effectiveClosedNotchHeight
            let wanted = content < 8
                ? band + 12
                : min(Self.maximumHeight, max(96, band + content + 28))
            guard abs(wanted - session.ambientHeight) > 1 else { return }
            session.ambientHeight = wanted
            NotificationCenter.default.post(name: .copilotLiveDidChange, object: nil)
        }
        // Movement only to mark an update.
        .animation(.smooth(duration: 0.45), value: account)
        .animation(.smooth(duration: 0.45), value: answer)
        .animation(.smooth(duration: 0.45), value: copilot.questionWorking)
        .onChange(of: copilot.suggestionAfterSeq) { _, _ in
            guard !CallaCopilotLiveView.answersRetired else { return }
            showLatestAnswer()
        }
        .onDisappear { answerTask?.cancel() }
    }

    private func accountView(_ lead: String) -> some View {
        let trail = account.trail(2)
        let open = copilot.openQuestions.first
        return VStack(alignment: .leading, spacing: 9) {
            CallaEyebrow("Where it stands", tint: CallaCallInk.summary)
            Text(lead)
                .font(.system(size: 15.5, weight: .medium))
                .tracking(-0.15)
                .lineSpacing(1.5)
                .foregroundStyle(.white.opacity(0.96))
            if !trail.isEmpty || open != nil {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(trail.enumerated()), id: \.element) { index, point in
                        pointRow(point, ink: .white.opacity(index == trail.count - 1 ? 0.7 : 0.5))
                    }
                    if let open {
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            marker(CallaCallInk.answer)
                            Text(open)
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.9))
                            CallaTag(text: "open", tint: CallaCallInk.answer)
                        }
                    }
                }
            }
        }
    }

    private func pointRow(_ point: String, ink: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            marker(.white.opacity(0.3))
            Text(point)
                .font(.system(size: 12))
                .foregroundStyle(ink)
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private func marker(_ tint: Color) -> some View {
        Circle().fill(tint).frame(width: 4, height: 4)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
    }

    private func heardView(_ question: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            CallaEyebrow("Question heard", tint: CallaCallInk.answer)
            Text("“\(question)”")
                .font(.system(size: 15.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.96))
            VStack(alignment: .leading, spacing: 6) {
                CallaShimmerLine(widthFraction: 0.92, height: 8)
                CallaShimmerLine(widthFraction: 0.6, height: 8)
            }
            .padding(.top, 2)
        }
    }

    private func answerView(_ answer: HeldAnswer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CallaEyebrow("They asked", tint: CallaCallInk.answer)
            if let question = answer.question {
                Text("“\(question)”")
                    .font(CallaCallType.question)
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(2)
            }
            Text(answer.headline)
                .font(.system(size: 17, weight: .semibold))
                .tracking(-0.2)
                .lineSpacing(1)
                .foregroundStyle(.white)
            if !answer.angles.isEmpty {
                // Both follow-ups when they fit side by side; the first alone
                // when they do not, rather than a chip cut mid-word.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        ForEach(Array(answer.angles.prefix(2).enumerated()), id: \.offset) { _, angle in
                            CallaChip(text: angle).fixedSize()
                        }
                    }
                    CallaChip(text: answer.angles[0])
                }
                .padding(.top, 2)
            }
        }
        .padding(.bottom, 8)
    }

    /// How long until the account comes back, as a draining line.
    private func holdBar(_ answer: HeldAnswer) -> some View {
        TimelineView(.periodic(from: answer.shownAt, by: 0.1)) { context in
            let left = max(0, 1 - context.date.timeIntervalSince(answer.shownAt) / Self.answerSeconds)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(CallaCallInk.answer.opacity(0.8))
                        .frame(width: proxy.size.width * left)
                }
            }
            .frame(height: 2)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
        .accessibilityHidden(true)
    }

    private func showLatestAnswer() {
        guard let headline = copilot.headline?.trimmingCharacters(in: .whitespacesAndNewlines),
              !headline.isEmpty else { return }
        let question = copilot.detectedQuestion.flatMap { $0.isEmpty ? nil : $0 }
        let angles = CallaCopilotPresentation.angleLines(copilot.angles, limit: 2, characters: 60)
        answer = HeldAnswer(question: question, headline: headline, angles: angles, shownAt: Date())
        answerTask?.cancel()
        answerTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.answerSeconds))
            guard !Task.isCancelled else { return }
            answer = nil
        }
    }
}

private struct AmbientHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - Call design vocabulary

/// The live call's own vocabulary, shared by zen, compact and full so the three
/// read as one surface that changes size rather than three panels.
///
/// One colour per job, so what the notch is showing is known before a word of
/// it is read: amber is an answer, blue is the running account, coral is
/// something wrong with capture. Nothing else in a call is tinted.
enum CallaCallInk {
    static let answer = Color(red: 1.0, green: 0.70, blue: 0.14)
    static let summary = Color(red: 0.49, green: 0.72, blue: 1.0)
    static let problem = Color(red: 1.0, green: 0.52, blue: 0.40)
    static let ended = Color.white.opacity(0.55)
}

enum CallaCallType {
    static let eyebrow = Font.system(size: 9.5, weight: .medium, design: .monospaced)
    static let figure = Font.system(size: 11, weight: .regular, design: .monospaced).monospacedDigit()
    static let question = Font.system(size: 12.5)
}

/// The caps label that names what a block is — "They asked", "Where it stands".
struct CallaEyebrow: View {
    let text: String
    let tint: Color

    init(_ text: String, tint: Color) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text.uppercased())
            .font(CallaCallType.eyebrow)
            .tracking(1.3)
            .foregroundStyle(tint)
            .lineLimit(1)
            .fixedSize()
    }
}

/// Five bars that move while someone is talking or the copilot is working.
/// Still when nothing is happening: a meter that always moves reports nothing.
struct CallaWaveBars: View {
    let tint: Color
    var active = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let phases: [Double] = [0, 0.55, 1.1, 0.3, 0.85]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !active || reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(phases.indices, id: \.self) { index in
                    let level = active && !reduceMotion
                        ? 0.3 + 0.7 * (0.5 + 0.5 * sin(t * 5.6 + phases[index] * .pi))
                        : 0.3
                    Capsule()
                        .fill(tint)
                        .frame(width: 2, height: 12 * level)
                }
            }
            .frame(height: 12)
        }
        .accessibilityHidden(true)
    }
}

/// A small outlined tag beside a line — "open".
struct CallaTag: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 8.5, weight: .medium, design: .monospaced))
            .tracking(0.8)
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(tint.opacity(0.8), lineWidth: 1))
            .fixedSize()
    }
}

/// A follow-up angle as a pill.
struct CallaChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.78))
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .help(text)
    }
}

/// The order to say an answer in: numbered beats in the answer's colour.
/// Side by side in compact, where height is scarce; stacked in full.
struct CallaBeats: View {
    let beats: [String]
    let horizontal: Bool

    var body: some View {
        if horizontal {
            HStack(alignment: .top, spacing: 14) {
                ForEach(Array(beats.enumerated()), id: \.offset) { index, beat in
                    VStack(alignment: .leading, spacing: 3) {
                        number(index)
                        Text(beat)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.74))
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(beats.enumerated()), id: \.offset) { index, beat in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        number(index)
                        Text(beat)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.white.opacity(0.76))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func number(_ index: Int) -> some View {
        Text(String(format: "%02d", index + 1))
            .font(CallaCallType.figure)
            .foregroundStyle(CallaCallInk.answer)
    }
}

/// The running account as the recap writes it: a standing paragraph, a blank
/// line, then one point per line. With no blank line everything is points.
struct CallaCallAccount: Equatable {
    let standing: String
    let points: [String]

    init(_ summary: String?) {
        let summary = summary ?? ""
        func split(_ text: String) -> [String] {
            text.split(separator: "\n", omittingEmptySubsequences: true)
                // Strips bullets a model added despite being asked not to.
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t-•*·")) }
                .filter { !$0.isEmpty }
        }
        if let gap = summary.range(of: "\n\n") {
            standing = String(summary[..<gap.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            points = split(String(summary[gap.upperBound...]))
        } else {
            standing = ""
            points = split(summary)
        }
    }

    var isEmpty: Bool { standing.isEmpty && points.isEmpty }

    /// The sentence set large: the standing paragraph, or the newest point when
    /// the writer gave none.
    var lead: String? { standing.isEmpty ? points.last : standing }

    /// The points under the lead, newest last, never repeating it.
    func trail(_ count: Int) -> [String] {
        Array((standing.isEmpty ? points.dropLast() : points[...]).suffix(count))
    }
}

/// A placeholder line for text that is still being written.
struct CallaShimmerLine: View {
    var widthFraction: CGFloat = 1
    var height: CGFloat = 9
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(Color.white.opacity(0.07))
                    .overlay {
                        if !reduceMotion {
                            LinearGradient(colors: [.clear, .white.opacity(0.12), .clear],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: proxy.size.width * 0.5)
                                .offset(x: proxy.size.width * (CGFloat(phase) * 1.5 - 0.75))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: height / 2))
                    .frame(width: proxy.size.width * widthFraction)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// A count set as a superscript on a glyph — screenshots taken.
struct CallaSuperscript: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.system(size: 8, weight: .bold).monospacedDigit())
            .foregroundStyle(.white)
            .fixedSize()
            .accessibilityHidden(true)
    }
}

/// What a hovered control is called, and its key.
struct NotchHint: Equatable {
    let symbol: String?
    let text: String
    let shortcut: String?
}

private struct NotchHintSinkKey: EnvironmentKey {
    static let defaultValue: ((NotchHint?) -> Void)? = nil
}

extension EnvironmentValues {
    /// Where a hovered control reports its name. The call band sets it and
    /// draws the name inline; `.help` never appears in the notch, which is a
    /// non-activating panel, and a floating bubble had nowhere good to go.
    var notchHintSink: ((NotchHint?) -> Void)? {
        get { self[NotchHintSinkKey.self] }
        set { self[NotchHintSinkKey.self] = newValue }
    }
}

struct NotchTooltip: ViewModifier {
    let hint: NotchHint
    @Environment(\.notchHintSink) private var sink

    func body(content: Content) -> some View {
        content
            .onHover { inside in sink?(inside ? hint : nil) }
            .onDisappear { sink?(nil) }
            .accessibilityHint(hint.text)
    }
}

extension View {
    func notchTooltip(_ text: String, symbol: String? = nil, shortcut: String? = nil) -> some View {
        modifier(NotchTooltip(hint: NotchHint(symbol: symbol, text: text, shortcut: shortcut)))
    }
}

// MARK: - Compact controls

/// A control big enough to hit mid-sentence without looking: 40pt tall, the
/// glyph and its name, and a press you can feel.
struct CallaLargeButton: View {
    let title: String
    let symbol: String
    var selected = false
    var role: ButtonRole?
    let action: () -> Void

    @State private var hovering = false

    private var destructive: Bool { role == .destructive }

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(destructive || selected ? Color.white : NotchInk.primary.opacity(0.9))
            .padding(.horizontal, 16)
            .frame(height: 40)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(fill)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(CallaPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel(title)
    }

    private var fill: Color {
        if destructive { return Color(red: 0.86, green: 0.23, blue: 0.19).opacity(hovering ? 1 : 0.9) }
        if selected { return Color.effectiveAccent.opacity(hovering ? 0.75 : 0.6) }
        return Color.white.opacity(hovering ? 0.16 : 0.10)
    }
}

/// Shrinks a touch while held, so a press registers before anything happens.
private struct CallaPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Ticker

/// The transcript as a news strip: one line, the newest words arriving from
/// the right and older ones leaving on the left.
///
/// It scrolls only while there is something new to show. Words are fed in at
/// a reading pace and, once the strip has caught up with the call, it rests
/// with the latest line against its right edge rather than looping old text
/// back round — a ticker that repeats itself reads as new speech.
struct CallaTranscriptTicker: View {
    let turns: [CallaCallTurn]

    /// How far behind the live end the strip is drawn, in points, as of `since`.
    @State private var lag: CGFloat = 0
    @State private var since = Date()
    @State private var speed: CGFloat = 60
    @State private var width: CGFloat = 0

    /// Pace: steady reading speed, faster when a long turn lands at once so
    /// the strip never falls more than a few seconds behind the call.
    private static let readingSpeed: CGFloat = 60
    private static let maximumDelay: CGFloat = 4

    private var shown: [CallaCallTurn] { Array(turns.suffix(24)) }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(NotchInk.hairline).frame(height: 1)
            // The strip is far wider than the notch. It hangs in an overlay so
            // its width never reaches the layout: as a child it became the
            // panel's ideal width and stretched the notch across the screen.
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .overlay(alignment: .trailing) {
                    TimelineView(.animation(paused: lag <= 0)) { context in
                        let elapsed = CGFloat(context.date.timeIntervalSince(since))
                        let offset = max(0, lag - speed * elapsed)
                        strip
                            .fixedSize()
                            .background {
                                GeometryReader { proxy in
                                    Color.clear.preference(key: TickerWidthKey.self, value: proxy.size.width)
                                }
                            }
                            // Pinned to the right edge; the lag pushes it right, so the
                            // newest words slide in from beyond that edge.
                            .offset(x: offset)
                    }
                }
            .clipped()
            .mask {
                LinearGradient(stops: [.init(color: .clear, location: 0),
                                       .init(color: .black, location: 0.08),
                                       .init(color: .black, location: 0.96),
                                       .init(color: .clear, location: 1)],
                               startPoint: .leading, endPoint: .trailing)
            }
        }
        .onPreferenceChange(TickerWidthKey.self) { newWidth in
            defer { width = newWidth }
            // Older turns trimmed off the front shrink the strip without
            // anything new arriving; only growth is new speech to feed in.
            guard width > 0, newWidth > width else { return }
            let now = Date()
            let current = max(0, lag - speed * CGFloat(now.timeIntervalSince(since)))
            lag = current + (newWidth - width)
            since = now
            speed = max(Self.readingSpeed, lag / Self.maximumDelay)
            // Once caught up, stop the timeline rather than redrawing a still strip.
            let stamp = now
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(lag / speed) + 0.05) {
                if since == stamp { lag = 0 }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Transcript")
        .accessibilityValue(turns.last.map { "\($0.speakerLabel): \($0.text)" } ?? "Nothing yet")
    }

    @ViewBuilder private var strip: some View {
        if shown.isEmpty {
            Text("The transcript runs here as people speak.")
                .font(.system(size: 12))
                .foregroundStyle(NotchInk.tertiary)
        } else {
            HStack(spacing: 18) {
                ForEach(Array(shown.enumerated()), id: \.element.seq) { index, turn in
                    HStack(spacing: 7) {
                        Text(turn.speakerLabel.uppercased())
                            .font(.system(size: 9.5, weight: .bold))
                            .tracking(0.6)
                            .foregroundStyle(turn.isRemote ? CallaCallInk.summary : NotchInk.tertiary)
                        Text(turn.text)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.white.opacity(index == shown.count - 1 ? 0.95 : 0.6))
                    }
                    .lineLimit(1)
                }
            }
        }
    }
}

private struct TickerWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
