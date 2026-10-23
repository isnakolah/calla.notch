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
    @ObservedObject private var callVPN = CallVPNManager.shared
    @EnvironmentObject private var vm: CallaViewModel

    @State private var turns: [CallaCallTurn] = []
    @State private var showsManualQuestion = false
    @State private var manualQuestion = ""

    @Default(.callaCopilotPanelSurface) private var surface
    @ObservedObject private var zenState = CallaZenState.shared

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

    /// Drawn in the floating window: one column, the transcript under the
    /// account, because a window narrow enough to sit beside the video has no
    /// room for the two side by side.
    @Environment(\.callaPanelStacked) private var stacked

    private var compact: Bool { !stacked && session.layout == .compact }

    /// Answers are off until they can be trusted to answer the right question.
    static let answersRetired = true

    var body: some View {
        Group {
            if compact {
                compactPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if stacked {
                VStack(alignment: .leading, spacing: 12) {
                    primary
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .layoutPriority(1)
                    Rectangle()
                        .fill(Color.white.opacity(0.10))
                        .frame(height: 1)
                    transcriptColumn
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .frame(height: 188)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        primary
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        if content == .answer, let lead = account.currentTopic {
                            standingStrip(lead)
                        }
                    }
                    .padding(.trailing, 22)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                    Rectangle()
                        .fill(Color.white.opacity(0.10))
                        .frame(width: 1)
                    transcriptColumn
                        .padding(.leading, 18)
                        .frame(width: 236)
                        .frame(maxHeight: .infinity, alignment: .topLeading)
                        .transition(.opacity)
                }
                panelFooter(hint: nil)
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
        .onAppear { zenState.note(account.currentTopic) }
        .onChange(of: account.currentTopic) { _, topic in zenState.note(topic) }
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

    private var primary: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let warning = callVPN.warning {
                Text(warning)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(NotchAccent.attention)
                    .lineLimit(2)
                    .help(warning)
            }
            Group {
                switch content {
                case .answer: answerBlock
                case .recap: accountBlock
                case .noAnswer: pendingBlock
                case .halfDeaf: halfDeafBlock
                case .listening: listeningBlock
                }
            }
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

    /// The latest point stays prominent; the full running account scrolls here.
    private var accountBlock: some View {
        let account = account
        let earlier = account.earlier
        let open = Array(copilot.openQuestions.prefix(2))

        return ScrollView(.vertical, showsIndicators: true) {
          VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                CallaEyebrow(surface == "question" ? "No answer yet · where it stands" : "Where it stands",
                             tint: CallaCallInk.summary)
                Spacer(minLength: 4)
                if catchingUp {
                    HStack(spacing: 6) {
                        CallaWaveBars(tint: CallaCallInk.summary)
                        Text("catching up")
                            .font(.system(size: 11))
                            .foregroundStyle(NotchInk.tertiary)
                    }
                    .transition(.opacity)
                }
            }
            .frame(height: 22)

            if let lead = account.currentTopic {
                Text(lead)
                    .font(.system(size: compact ? 16 : 18, weight: .medium))
                    .tracking(-0.15)
                    .lineSpacing(3)
                    .foregroundStyle(.white.opacity(0.96))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .help(lead)
                    .id(lead)
                    .transition(.opacity)
            }

            if !earlier.isEmpty || !open.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Rectangle().fill(Color.white.opacity(0.10)).frame(height: 1)
                        .padding(.bottom, 12)
                    HStack(alignment: .top, spacing: 18) {
                        if !earlier.isEmpty {
                            accountColumn("Earlier", symbol: "checkmark", tint: CallaCallInk.summary,
                                          lines: earlier, ink: .white.opacity(0.75))
                        }
                        if !open.isEmpty {
                            accountColumn("Still open", symbol: "circle", tint: CallaCallInk.answer,
                                          lines: open, ink: .white.opacity(0.92))
                        }
                    }
                }
            }
          }
          .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxHeight: .infinity)
    }

    private func accountColumn(_ title: String, symbol: String, tint: Color,
                               lines: [String], ink: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(tint)
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(notchCapsTracking)
                    .foregroundStyle(NotchInk.tertiary)
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 12))
                    .lineSpacing(1.5)
                    .foregroundStyle(ink)
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
                    .font(.system(size: 13))
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
        halfDeafPlain
    }

    /// Their side is missing, and the one press that fixes it.
    private var halfDeafBanner: some View {
        HStack(spacing: 14) {
            Image(systemName: "speaker.slash.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(CallaCallInk.problem)
            VStack(alignment: .leading, spacing: 3) {
                Text("Their side isn't coming through")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(NotchInk.primary)
                Text("Only your microphone is being captured. Grant Screen Recording so the other side is transcribed too.")
                    .font(.system(size: 12))
                    .lineSpacing(1)
                    .foregroundStyle(Color.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Text("Open settings")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(NotchAccent.onAccent)
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(CallaCallInk.problem))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open Screen Recording settings")
            .accessibilityLabel("Open Screen Recording settings")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(CallaCallInk.problem.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(CallaCallInk.problem.opacity(0.30), lineWidth: 1)
        )
    }

    // MARK: - Compact

    /// Being in the call: the points Calla is writing as they come in — the
    /// newest set large, the ones before it under it, what is still open —
    /// and End. No transcript: that is for the full panel. The state, the
    /// clock and the controls live in the band above.
    private var compactPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let warning = callVPN.warning {
                Text(warning)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(NotchAccent.attention)
                    .lineLimit(2)
                    .help(warning)
            }
            if mode == .halfDeaf {
                halfDeafPlain
            } else {
                pointsFeed
            }
            Spacer(minLength: 0)
            panelFooter(hint: mode == .halfDeaf ? nil
                        : "Points arrive as the call goes · the transcript is in full view")
        }
        .padding(.top, 4)
    }

    private var pinned: Bool { vm.isPinned || session.pinsNotchOpen }

    /// Every point so far, oldest first, as the account holds them.
    private var allPoints: [String] {
        (account.standing.isEmpty ? [] : [account.standing]) + account.points
    }

    private var pointsFeed: some View {
        let points = allPoints
        let earlier = Array(points.dropLast().suffix(3).reversed())
        let open = Array(copilot.openQuestions.prefix(max(0, 4 - earlier.count)).prefix(2))
        return VStack(alignment: .leading, spacing: 10) {
            if let newest = points.last {
                VStack(alignment: .leading, spacing: 5) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        HStack(spacing: 8) {
                            if zenState.isNew(at: context.date) {
                                Text("NEW")
                                    .font(.system(size: 10, weight: .bold))
                                    .tracking(notchCapsTracking)
                                    .foregroundStyle(CallaCallInk.summary)
                                    .transition(.opacity)
                            }
                            if catchingUp {
                                CallaWaveBars(tint: CallaCallInk.summary)
                                Text("catching up")
                                    .font(.system(size: 11))
                                    .foregroundStyle(NotchInk.tertiary)
                            }
                        }
                        .frame(height: 12)
                    }
                    Text(newest)
                        .font(.system(size: 16, weight: .semibold))
                        .tracking(-0.15)
                        .lineSpacing(2)
                        .foregroundStyle(.white)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .help(newest)
                        .id(newest)
                        .transition(.opacity)
                }
                if !earlier.isEmpty || !open.isEmpty {
                    Rectangle().fill(Color.white.opacity(0.10)).frame(height: 1)
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(earlier.enumerated()), id: \.offset) { index, point in
                            pointRow(point, mark: index == 0 ? .point : .settled)
                        }
                        ForEach(Array(open.enumerated()), id: \.offset) { _, question in
                            pointRow(question, mark: .open)
                        }
                    }
                }
            } else {
                // Before the first point: the meeting, and that both sides are
                // heard — the same words zen uses, so the two never disagree.
                let content = CallaZenReading.content(now: Date(), level: .brief)
                VStack(alignment: .leading, spacing: 6) {
                    if let main = content.main {
                        Text(main)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(2)
                    }
                    if let before = content.before {
                        Text(before)
                            .font(.system(size: 13))
                            .foregroundStyle(NotchInk.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
        .animation(.smooth(duration: 0.35), value: points)
    }

    private enum PointMark { case point, settled, open }

    private func pointRow(_ text: String, mark: PointMark) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Group {
                switch mark {
                case .settled:
                    Image(systemName: "checkmark")
                        .font(.system(size: 8.5, weight: .heavy))
                        .foregroundStyle(CallaCallInk.summary)
                case .point:
                    Circle().fill(Color.white.opacity(0.6)).frame(width: 5, height: 5)
                case .open:
                    Circle().strokeBorder(CallaCallInk.answer, lineWidth: 1.6).frame(width: 8, height: 8)
                }
            }
            .frame(width: 10)
            Text(mark == .open ? "Still open: \(text)" : text)
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(mark == .open ? 0.9 : 0.78))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(text)
        }
    }

    /// Their side is missing: what happened, the one press that fixes it,
    /// and the reassurance that the call is still being written down. Plain
    /// type on the panel, not a box inside it.
    private var halfDeafPlain: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Their side isn’t coming through")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(NotchInk.primary)
            Text("Only your microphone is being captured, so you are still being written down. Allow call audio so the other side is heard too.")
                .font(.system(size: 12.5))
                .lineSpacing(1.5)
                .foregroundStyle(NotchInk.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Text("Allow call audio")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(NotchAccent.onAccent)
                    .padding(.horizontal, 15)
                    .frame(height: 30)
                    .background(Capsule().fill(CallaCallInk.problem))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Open Screen Recording settings")
            .padding(.top, 2)
        }
    }

    /// One quiet line and End, at the foot of both layouts.
    private func panelFooter(hint: String?) -> some View {
        HStack(spacing: 10) {
            if let hint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(NotchInk.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            CallaEndPill(title: "End call") { engine.endCall(origin: compact ? "compactEnd" : "fullEnd") }
                .help("End the call")
                .accessibilityLabel("End call")
        }
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
                    .font(.system(size: 11))
                    .foregroundStyle(copilot.systemAudioActive ? NotchInk.tertiary : CallaCallInk.problem)
            }
            .frame(height: 22)

            if turns.isEmpty {
                Text(copilot.systemAudioActive
                     ? "Turns appear here as they are transcribed on this Mac."
                     : "Grant Screen Recording so the other side is transcribed too.")
                    .font(.system(size: 12))
                    .foregroundStyle(NotchInk.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            } else {
                let shown = Array(turns.suffix(6))
                VStack(alignment: .leading, spacing: 10) {
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

    /// The speaker and clock on one line, the words under them; the newest
    /// turn at full ink and the rest stepped back.
    private func turnRow(_ turn: CallaCallTurn, isNewest: Bool, isQuestion: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(turn.speakerLabel.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(notchCapsTracking)
                    .foregroundStyle(turn.isRemote ? CallaCallInk.summary : NotchInk.secondary)
                Text(turn.clock)
                    .font(.system(size: 10, design: .monospaced).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.45))
                if isQuestion {
                    CallaEyebrow("question", tint: CallaCallInk.answer)
                }
            }
            Text(turn.text)
                .font(.system(size: 12))
                .lineSpacing(1.5)
                .foregroundStyle(isNewest ? NotchInk.primary : .white.opacity(isQuestion ? 0.9 : 0.6))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
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
            .fill(active ? NotchAccent.call : NotchAccent.attention)
            .frame(width: 8, height: 8)
            .background(Circle().fill((active ? NotchAccent.call : NotchAccent.attention).opacity(0.22))
                .padding(-4)
                .scaleEffect(expanded ? 1.2 : 1))
            .opacity(expanded ? 0.8 : 1)
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

    private func takeScreenshot(displayID: UInt32?) {
        engine.takeScreenshot(displayID: displayID)
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
        HStack(spacing: 9) {
            LivePulse(active: copilot.running && copilot.systemAudioActive)
            if CallaCopilotLiveView.answersRetired {
                Text(workingLabel ?? (mode == .halfDeaf ? "Only you" : "Listening"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(mode == .halfDeaf ? CallaCallInk.problem : CallaCallInk.summary)
                    .lineLimit(1)
                    .fixedSize()
            } else {
                surfaceSwitch
            }
            if let elapsed = CallaCopilotPresentation.elapsed(since: copilot.startedAt, now: now) {
                Text(elapsed)
                    .font(.system(size: 12, design: .monospaced).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.80))
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

    /// Screenshot, the two capture states, float, pin and layout, in that
    /// order, in both layouts. End sits at the foot of the panel, away from the
    /// controls you press mid-sentence.
    private var trailing: some View {
        let pinned = vm.isPinned || session.pinsNotchOpen
        let full = session.layout == .full
        return HStack(spacing: 2) {
                // What is being shared becomes context: the words on it go to
                // the copilot, and the picture is filed with the call.
                CallaScreenshotControl(compact: false, count: copilot.screenshotCount,
                                       tint: shotNote == nil ? Color.white.opacity(0.70) : CallaCallInk.summary) { displayID in
                    takeScreenshot(displayID: displayID)
                }
                .scaleEffect(shutter ? 0.78 : 1)
                .opacity(shutter ? 0.4 : 1)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: copilot.screenshotCount)
                .notchTooltip(copilot.screenshotCount > 0
                              ? "Screenshot the shared screen · \(copilot.screenshotCount) so far"
                              : "Screenshot the shared screen",
                              symbol: "camera")
                .accessibilityLabel(copilot.screenshotCount > 0
                                    ? "Take a screenshot for context, \(copilot.screenshotCount) taken"
                                    : "Take a screenshot for context")

            CallaWingIndicator(symbol: copilot.micActive ? "mic" : "mic.slash",
                               tint: copilot.micActive ? Color.white.opacity(0.70) : NotchAccent.attention)
                .notchTooltip(copilot.micActive ? "Your microphone is being captured"
                                                : "Your microphone is not being captured",
                              symbol: copilot.micActive ? "mic.fill" : "mic.slash.fill")
                .accessibilityLabel(copilot.micActive ? "Your microphone is being captured"
                                                      : "Your microphone is not being captured")
            // Reports the setting rather than asserting a guarantee: hidden from
            // captures when "Hide from screen recording" is on, visible when off.
            CallaWingIndicator(symbol: hiddenFromCapture ? "eye.slash" : "eye",
                               tint: hiddenFromCapture ? Color.white.opacity(0.70) : NotchAccent.attention)
                .notchTooltip(hiddenFromCapture ? "Hidden from screen shares"
                                                : "Visible in screen shares — turn on Hide in Settings",
                              symbol: hiddenFromCapture ? "eye.slash.fill" : "eye.fill")
                .accessibilityLabel(hiddenFromCapture ? "Hidden from screen recording"
                                                      : "Visible in screen recording")

            if !CallaCopilotLiveView.answersRetired {
                CallaWingButton(symbol: "questionmark.bubble") {
                    NotificationCenter.default.post(name: .callaCallAskQuestion, object: nil)
                }
                .notchTooltip("Ask about what was just said", symbol: "questionmark.bubble",
                              shortcut: shortcutKeys(.sessionAsk))
                .accessibilityLabel("Ask about what was just said")
            }

            // Out of the notch into a window that floats over every app —
            // beside the video, on another display, over a full-screen call.
            CallaWingButton(symbol: "pip.exit") {
                session.spinOut()
            }
            .notchTooltip("Float on top of everything", symbol: "pip.exit",
                          shortcut: shortcutKeys(.copilotToggleFloat))
            .accessibilityLabel("Float the call panel on top of everything")

            // Pin belongs to the notch, while Call contributes a temporary
            // automatic hold. The same action is available system-wide.
            CallaWingButton(symbol: pinned ? "pin.fill" : "pin",
                            tint: pinned ? NotchAccent.call : Color.white.opacity(0.70)) {
                AppDelegate.shared?.toggleUniversalNotchPin(for: vm)
            }
            .notchTooltip(pinned ? "Unpin the notch" : "Pin the notch open",
                          symbol: pinned ? "pin.fill" : "pin")
            .accessibilityLabel(pinned ? "Unpin notch" : "Pin notch open")

            // Collapse to the compact panel and back.
            CallaWingButton(symbol: full ? "arrow.down.right.and.arrow.up.left"
                                         : "arrow.up.left.and.arrow.down.right") {
                session.toggleLayout()
            }
            .notchTooltip(full ? "Compact" : "Full, with the transcript",
                          symbol: full ? "arrow.down.right.and.arrow.up.left"
                                       : "arrow.up.left.and.arrow.down.right",
                          shortcut: shortcutKeys(.copilotToggleLayout))
            .accessibilityLabel(full ? "Compact view" : "Full view")
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
        case .active: return NotchAccent.call
        case .ready: return NotchAccent.call
        case .warning: return NotchAccent.attention
        }
    }
}

// MARK: - Ambient (zen)

/// Zen's shared clock for "New": when the newest point arrived, so the band
/// beside the camera and the island under it agree on it.
@MainActor
final class CallaZenState: ObservableObject {
    static let shared = CallaZenState()
    @Published private(set) var newUntil: Date?
    private var lastPoint: String?

    /// Called whenever the newest point may have changed. The first point of a
    /// call is news too; the same point seen again is not.
    func note(_ point: String?) {
        guard let point, !point.isEmpty, point != lastPoint else { return }
        let first = lastPoint == nil
        lastPoint = point
        // A panel opened mid-call has not "just" heard anything.
        guard !first || CallaEngineClient.shared.status.copilot.turnCount > 0 else { return }
        guard Defaults[.callaZenHighlight] else { return }
        newUntil = Date().addingTimeInterval(CallaZen.highlightSeconds)
    }

    func isNew(at now: Date) -> Bool { newUntil.map { now < $0 } ?? false }

    func reset() {
        lastPoint = nil
        newUntil = nil
    }
}

/// The zen rules, read from the live call. One place, so the band and the
/// island cannot disagree about what is happening.
@MainActor
enum CallaZenReading {
    static func content(now: Date, level: CallaZen.Level) -> CallaZen.Content {
        let copilot = CallaEngineClient.shared.status.copilot
        let account = CallaCallAccount(copilot.summary)
        let points = (account.standing.isEmpty ? [] : [account.standing]) + account.points
        let meeting = CalendarManager.shared.selectedCallMeeting
        let people = meeting.flatMap { event -> Int? in
            guard let title = copilot.meetingTitle, title == event.title else { return nil }
            return event.participants.count
        } ?? 0
        return CallaZen.content(
            level: level,
            halfDeaf: copilot.running && !copilot.systemAudioActive,
            catchingUp: copilot.summaryWorking || copilot.working == "summary",
            isNew: CallaZenState.shared.isNew(at: now),
            points: points,
            openQuestions: copilot.openQuestions,
            meetingTitle: copilot.meetingTitle,
            people: people,
            heardAnything: copilot.turnCount > 0)
    }
}

/// The band beside the notch while a call rests in zen: the dot and one word
/// on the left — "Listening", "New", "Only you" — and the clock on the right,
/// with the hardware cutout between them, so the band reads as the notch
/// itself carrying status. The word replaces the labels zen used to print.
struct CallaAmbientWings: View {
    @ObservedObject private var engine = CallaEngineClient.shared
    @ObservedObject private var zenState = CallaZenState.shared
    @EnvironmentObject private var vm: CallaViewModel
    @Default(.callaZenLevel) private var levelValue
    @State private var now = Date()
    private let clockTick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var copilot: CallaCopilotStatus { engine.status.copilot }

    var body: some View {
        let content = CallaZenReading.content(now: now, level: CallaZen.Level(stored: levelValue))
        let warning = content.tone == .warning
        let tint = warning ? CallaCallInk.problem : CallaCallInk.summary
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(tint)
                    .frame(width: 7, height: 7)
                    .background(Circle().fill(tint.opacity(0.22)).padding(-3))
                Text(content.word)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                    .contentTransition(.opacity)
                Spacer(minLength: 0)
            }
            .lineLimit(1)
            .padding(.leading, 20)
            .frame(maxWidth: .infinity)

            // The camera housing. Nothing may be drawn here.
            Color.clear.frame(width: vm.closedNotchSize.width)

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if copilot.screenshotCount > 0 {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.56))
                        .overlay(alignment: .topTrailing) {
                            CallaSuperscript(count: copilot.screenshotCount)
                                .offset(x: 8, y: -6)
                        }
                        .padding(.trailing, 6)
                        .accessibilityLabel("\(copilot.screenshotCount) screenshots")
                }
                CallaWaveBars(tint: tint, active: copilot.speaking != nil)
                if let elapsed = CallaCopilotPresentation.elapsed(since: copilot.startedAt, now: now) {
                    Text(elapsed)
                        .font(.system(size: 12, design: .monospaced).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.86))
                }
            }
            .lineLimit(1)
            .padding(.trailing, 20)
            .frame(maxWidth: .infinity)
        }
        .animation(.smooth(duration: 0.3), value: content.word)
        .onReceive(clockTick) { now = $0 }
    }
}

/// The call at rest: the notch grown into an island under the camera.
///
/// It always says something true — the newest point Calla has written and the
/// ones before it, or before there are any, the meeting and that both sides are
/// heard — and never the transcript, which belongs to the fully open panel.
/// No labels: the band's one word carries the state. A fresh answer, when
/// answers are on, takes the island for a while. Hovering opens the panel.
struct CallaCopilotAmbientView: View {
    @ObservedObject private var engine = CallaEngineClient.shared
    @ObservedObject private var session = CopilotLiveSession.shared
    @ObservedObject private var zenState = CallaZenState.shared
    @EnvironmentObject private var vm: CallaViewModel
    @Default(.callaZenLevel) private var levelValue
    @State private var answer: HeldAnswer?
    @State private var answerTask: Task<Void, Never>?
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    struct HeldAnswer: Equatable {
        let question: String?
        let headline: String
        let angles: [String]
        let shownAt: Date
    }

    /// How long a fresh answer holds the island before the account returns.
    static let answerSeconds: Double = 25
    /// Upper bound for the island: five lines and the band, so on a laptop it
    /// stays above the faces in the call.
    static let maximumHeight: CGFloat = 300

    private var copilot: CallaCopilotStatus { engine.status.copilot }
    private var account: CallaCallAccount { CallaCallAccount(copilot.summary) }
    private var content: CallaZen.Content {
        CallaZenReading.content(now: now, level: CallaZen.Level(stored: levelValue))
    }

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
            } else if !content.isEmpty {
                zenView(content)
                    .transition(.opacity)
            }
            // Just the dot: nothing below the notch.
        }
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.top, 8)
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
                : min(Self.maximumHeight, max(84, band + content + 24))
            guard abs(wanted - session.ambientHeight) > 1 else { return }
            session.ambientHeight = wanted
            NotificationCenter.default.post(name: .copilotLiveDidChange, object: nil)
        }
        // Movement only to mark an update.
        .animation(.smooth(duration: 0.45), value: content)
        .animation(.smooth(duration: 0.45), value: answer)
        .onReceive(tick) { now = $0 }
        .onAppear { zenState.note(account.currentTopic) }
        .onChange(of: account.currentTopic) { _, topic in zenState.note(topic) }
        .onChange(of: copilot.suggestionAfterSeq) { _, _ in
            guard !CallaCopilotLiveView.answersRetired else { return }
            showLatestAnswer()
        }
        .onDisappear { answerTask?.cancel() }
    }

    /// The newest point at full ink, up to two lines; what came before on one
    /// line; at More, what is still open. Before the first point, the meeting
    /// in quieter ink.
    private func zenView(_ content: CallaZen.Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let main = content.main {
                Text(main)
                    .font(.system(size: 15, weight: .medium))
                    .lineSpacing(2.5)
                    .foregroundStyle(.white.opacity(content.mainIsQuiet ? 0.78 : 0.96))
                    .lineLimit(2)
                    .help(main)
                    .id(main)
                    .transition(.opacity)
            }
            if content.needsFix {
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Text("Allow call audio")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(NotchAccent.onAccent)
                        .padding(.horizontal, 14)
                        .frame(height: 28)
                        .background(Capsule().fill(CallaCallInk.problem))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Open Screen Recording settings so Calla can hear the other side")
                .padding(.top, 2)
            }
            if let before = content.before {
                Text(before)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(before)
            }
            if let open = content.open {
                Text("Still open: \(open)")
                    .font(.system(size: 12.5))
                    .foregroundStyle(CallaCallInk.answer.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(open)
            }
        }
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
/// it is read: mint is the running account, sun is what is still open, orange
/// is something wrong with capture. Nothing else in a call is tinted.
enum CallaCallInk {
    static let answer = NotchAccent.focus
    static let summary = NotchAccent.call
    static let problem = NotchAccent.attention
    static let ended = Color.white.opacity(0.55)
    /// Text on the coral wash an End control wears.
    static let endInk = Color(notchHex: 0xFF8A8A)
}

enum CallaCallType {
    static let eyebrow = Font.system(size: 11, weight: .bold)
    static let figure = Font.system(size: 11, weight: .regular, design: .monospaced).monospacedDigit()
    static let question = Font.system(size: 13)
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
            .tracking(notchCapsTracking)
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
            .font(.system(size: 10, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 6).fill(tint.opacity(NotchAccent.fill)))
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

    /// The newest point reflects the current topic; standing is older context.
    var currentTopic: String? { points.last ?? (standing.isEmpty ? nil : standing) }

    /// Everything before the current point, in reading order.
    var earlier: [String] {
        guard !points.isEmpty else { return [] }
        return (standing.isEmpty ? [] : [standing]) + Array(points.dropLast())
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
            .font(.system(size: 10, weight: .bold, design: .rounded).monospacedDigit())
            .foregroundStyle(NotchAccent.onAccent)
            .padding(.horizontal, 3)
            .frame(minWidth: 13, minHeight: 13)
            .background(Capsule().fill(NotchAccent.call))
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

/// A control big enough to hit mid-sentence without looking: 46pt tall, the
/// glyph and its name, and a press you can feel. End wears a coral wash.
struct CallaLargeButton: View {
    let title: String
    let symbol: String
    var selected = false
    var role: ButtonRole?
    /// A count in a mint pill after the title — screenshots taken.
    var count: Int = 0
    var height: CGFloat = 46
    let action: () -> Void

    @State private var hovering = false

    private var destructive: Bool { role == .destructive }

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: destructive ? .bold : .semibold))
                    .lineLimit(1)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                        .foregroundStyle(NotchAccent.call)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(NotchAccent.call.opacity(0.20)))
                }
            }
            .foregroundStyle(destructive ? CallaCallInk.endInk : selected ? NotchAccent.call : NotchInk.primary)
            .padding(.leading, destructive ? 16 : 15)
            .padding(.trailing, destructive ? 20 : 18)
            .frame(height: height)
            .background {
                RoundedRectangle(cornerRadius: height > 40 ? 14 : 12, style: .continuous)
                    .fill(fill)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(CallaPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(title)
        .accessibilityLabel(count > 0 ? "\(title), \(count)" : title)
    }

    private var fill: Color {
        if destructive { return NotchAccent.stop.opacity(hovering ? 0.26 : 0.16) }
        if selected { return NotchAccent.call.opacity(hovering ? 0.26 : NotchAccent.fill) }
        return Color.white.opacity(hovering ? 0.14 : 0.08)
    }
}

/// A direct shot on one display; with multiple displays, each menu button
/// captures the named display immediately.
struct CallaScreenshotControl: View {
    let compact: Bool
    let count: Int
    var tint: Color = Color.white.opacity(0.70)
    let action: (UInt32?) -> Void

    private struct Display: Identifiable {
        let id: UInt32
        let title: String
    }

    private var displays: [Display] {
        NSScreen.screens.enumerated().compactMap { index, screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return nil }
            return Display(id: number.uint32Value,
                           title: "Display \(index + 1) · \(screen.localizedName)")
        }
    }

    var body: some View {
        let choices = displays
        Group {
            if choices.count > 1 {
                Menu {
                    ForEach(choices) { display in
                        Button(display.title, systemImage: "display") { action(display.id) }
                    }
                } label: {
                    label(showsChoice: true)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
            } else {
                Button { action(choices.first?.id) } label: {
                    label(showsChoice: false)
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityLabel(choices.count > 1 ? "Choose display for screenshot" : "Take screenshot")
    }

    @ViewBuilder private func label(showsChoice: Bool) -> some View {
        if compact {
            HStack(spacing: 9) {
                Image(systemName: "camera")
                    .font(.system(size: 13, weight: .semibold))
                Text("Screenshot")
                    .font(.system(size: 13, weight: .semibold))
                if showsChoice {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                        .foregroundStyle(NotchAccent.call)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(NotchAccent.call.opacity(0.20)))
                }
            }
            .foregroundStyle(NotchInk.primary)
            .padding(.horizontal, 15)
            .frame(height: 46)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.08)))
        } else {
            Image(systemName: showsChoice ? "camera.badge.ellipsis" : "camera")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
                .overlay(alignment: .topTrailing) {
                    if count > 0 { CallaSuperscript(count: count) }
                }
        }
    }
}

/// A 28pt glyph button in the live band beside the housing.
struct CallaWingButton: View {
    let symbol: String
    var tint: Color = Color.white.opacity(0.70)
    var badge: Int = 0
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hovering && tint == Color.white.opacity(0.70) ? NotchInk.primary : tint)
                .frame(width: 28, height: 28)
                .background(Circle().fill(hovering ? Color.white.opacity(0.10) : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if badge > 0 {
                CallaSuperscript(count: badge)
                    .offset(x: 0, y: 1)
                    .allowsHitTesting(false)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .onHover { hovering = $0 }
    }
}

/// A state in the band that is not a control — the mic, capture hiding — drawn
/// at a wing button's size so the row keeps one rhythm.
struct CallaWingIndicator: View {
    let symbol: String
    var tint: Color = Color.white.opacity(0.70)

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
    }
}

/// The coral End pill at the end of a live band.
struct CallaEndPill: View {
    var title = "End"
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "stop.fill").font(.system(size: 9, weight: .bold))
                Text(title).font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(CallaCallInk.endInk)
            .padding(.leading, 10)
            .padding(.trailing, 12)
            .frame(height: 26)
            .background(Capsule().fill(NotchAccent.stop.opacity(hovering ? 0.26 : 0.16)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.leading, 6)
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
            // The strip is far wider than the notch. It hangs in an overlay so
            // its width never reaches the layout: as a child it became the
            // panel's ideal width and stretched the notch across the screen.
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 38)
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
            .padding(.horizontal, 14)
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.05)))
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
                .font(.system(size: 13))
                .foregroundStyle(NotchInk.tertiary)
        } else {
            HStack(spacing: 18) {
                ForEach(Array(shown.enumerated()), id: \.element.seq) { index, turn in
                    HStack(spacing: 10) {
                        Text(turn.speakerLabel.uppercased())
                            .font(.system(size: 10, weight: .bold))
                            .tracking(notchCapsTracking)
                            .foregroundStyle(turn.isRemote ? CallaCallInk.summary : NotchInk.tertiary)
                        Text(turn.text)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(index == shown.count - 1 ? 0.90 : 0.6))
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

// MARK: - Stacked

private struct CallaPanelStackedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The live panel is in the floating window, so it stacks into one column.
    var callaPanelStacked: Bool {
        get { self[CallaPanelStackedKey.self] }
        set { self[CallaPanelStackedKey.self] = newValue }
    }
}
