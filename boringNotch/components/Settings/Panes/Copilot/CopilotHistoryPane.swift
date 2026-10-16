import AppKit
import CallaContracts
import Defaults
import SwiftUI
import UniformTypeIdentifiers

/// Calls that already happened.
///
/// Every call has been archived to disk since the copilot shipped and nothing ever
/// showed them. The app is sandboxed and cannot read the capture host's files, so
/// all of this arrives through the engine.
///
/// Structured around one selected call, because that is the question people bring
/// here: what happened on *that* call — what was said, what the copilot said back,
/// and whether the better model has been over it since.
struct CopilotHistoryPane: View {
    @Environment(\.settingsRouter) private var router

    @ObservedObject private var engine = CallaEngineClient.shared

    @State private var calls: [CallaCallSummary] = []
    @State private var loading = false
    /// Calls waiting their turn for the large model.
    @State private var queued: [String] = []
    /// Which archive this pane is showing.
    ///
    /// This was bound to `Defaults[.callaCopilotMode]` — the same key the notch's
    /// Call|Quiz selector uses — so opening quiz history in Settings silently
    /// re-armed the notch into Quiz mode, and starting a quiz from a calendar
    /// event retargeted this pane. One key cannot do both jobs.
    @State private var historyMode = "call"
    @State private var quizSessions: [QuizHistorySession] = []
    @State private var captureImage: NSImage?
    @State private var showsCapture = false
    @State private var confirmsDeleteAllQuiz = false
    @State private var quizLoading = false
    /// Grades applied this visit, so a row reflects the press before the archive
    /// is read back.
    @State private var grades: [String: QuizAnswerGrade] = [:]


    var body: some View {
        SettingsPane(SettingsPage.copilotHistory) {
            Picker("History", selection: $historyMode) {
                Text("Call").tag("call")
                Text("Quiz").tag("quiz")
            }
            .pickerStyle(.segmented).frame(width: 200)
            if historyMode == "quiz" {
                quizCard
            } else {
                pendingRetranscribeCard
                callsCard
            }
        }
        .task { await load() }
        // The badge and the counts only change when a run finishes, so the list is
        // re-read then rather than left stale until the pane is reopened.
        .onChange(of: retranscribingID) { previous, current in
            guard previous != nil, current == nil else { return }
            Task { await load() }
            startNextRetranscribe()
        }
        .sheet(isPresented: $showsCapture) {
            VStack(spacing: 12) {
                if let captureImage {
                    Image(nsImage: captureImage).resizable().scaledToFit()
                } else {
                    Text("Capture unavailable")
                }
                Button("Close") { showsCapture = false }.keyboardShortcut(.cancelAction)
            }
            .padding().frame(minWidth: 640, minHeight: 420)
        }
        .confirmationDialog("Delete all Quiz history?", isPresented: $confirmsDeleteAllQuiz) {
            Button("Delete All Quiz History", role: .destructive) {
                engine.deleteAllQuizHistory { quizSessions = [] }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Encrypted captures, answers, and records are removed. Quiz encryption key rotates.")
        }
    }

    // MARK: - Re-transcribing

    /// Calls with audio still on disk that the large model has not been over.
    private var pending: [CallaCallSummary] {
        calls.filter { $0.hasAudio && !$0.retranscribed }
    }

    private var retranscribingID: String? { engine.status.copilot.retranscribingCallID }

    @ViewBuilder
    private var pendingRetranscribeCard: some View {
        if !pending.isEmpty || retranscribingID != nil {
            SettingCard(
                "Better transcripts",
                detail: "The large model is slower and more accurate. It runs on the saved audio, after the fact.",
                tint: retranscribingID != nil ? NotchTint.active : nil
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    if let active = retranscribingID {
                        SettingRow(
                            "Re-transcribing now",
                            detail: "\(active) — this takes a few minutes per call."
                        ) {
                            ProgressView().controlSize(.small)
                        }
                    }
                    if !pending.isEmpty {
                        SettingRow(
                            "\(pending.count) call\(pending.count == 1 ? "" : "s") not re-transcribed",
                            detail: "Runs one at a time; the next starts when the current one finishes."
                        ) {
                            Button(pending.count == 1 ? "Re-transcribe" : "Re-transcribe all") {
                                queued = pending.map(\.id)
                                startNextRetranscribe()
                            }
                            .controlSize(.small)
                            .disabled(retranscribingID != nil)
                        }
                    }
                    if let result = engine.status.copilot.lastResult,
                       result.lowercased().contains("transcrib") {
                        Text(result)
                            .font(NotchType.rowDetail)
                            .foregroundStyle(result.lowercased().contains("fail") ? NotchTint.attention : .secondary)
                    }
                }
            }
        }
    }

    /// Sequential, because the engine refuses a second concurrent run — and because
    /// two large-model passes at once would fight over the same cores.
    private func startNextRetranscribe() {
        guard retranscribingID == nil, let next = queued.first else { return }
        queued.removeFirst()
        engine.retranscribe(callID: next)
    }

    /// Was this answer right?
    ///
    /// This is the only place correctness is recorded, and confidence calibration
    /// is built from it — without any graded answers the percentage shown in the
    /// notch is only the model's opinion of itself.
    @ViewBuilder
    private func gradeControls(_ answer: QuizFinalAnswer) -> some View {
        let current = grades[answer.id] ?? .ungraded
        HStack(spacing: 2) {
            Button {
                apply(current == .correct ? .ungraded : .correct, to: answer)
            } label: {
                Image(systemName: current == .correct ? "hand.thumbsup.fill" : "hand.thumbsup")
            }
            .buttonStyle(.plain)
            .foregroundStyle(current == .correct ? NotchTint.healthy : .secondary)
            .help("This answer was right")
            .accessibilityLabel("Mark answer correct")

            Button {
                apply(current == .incorrect ? .ungraded : .incorrect, to: answer)
            } label: {
                Image(systemName: current == .incorrect ? "hand.thumbsdown.fill" : "hand.thumbsdown")
            }
            .buttonStyle(.plain)
            .foregroundStyle(current == .incorrect ? NotchTint.stuck : .secondary)
            .help("This answer was wrong")
            .accessibilityLabel("Mark answer incorrect")
        }
    }

    private func apply(_ grade: QuizAnswerGrade, to answer: QuizFinalAnswer) {
        grades[answer.id] = grade
        engine.gradeQuizAnswer(answer.id, grade: grade)
    }

    // MARK: - Calls

    private var quizCard: some View {
        SettingCard("Quiz History", detail: "Answers and encrypted captures. Marking answers right or wrong is what teaches the confidence figure what it is worth. Worker research stays backend-only.") {
            VStack(spacing: NotchSpace.snug) {
                if quizLoading {
                    Text("Reading the archive…").font(NotchType.rowDetail).foregroundStyle(.secondary)
                } else if quizSessions.isEmpty {
                    Text("No Quiz sessions yet").font(NotchType.rowDetail).foregroundStyle(.secondary)
                }
                ForEach(quizSessions) { quiz in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(quiz.startedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(NotchType.rowTitle)
                                Text([quiz.eventLabel ?? "No event", quiz.targetApplication,
                                      quiz.targetWindow].joined(separator: " · "))
                                    .font(NotchType.rowDetail).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            // A session with several viewports had every capture
                            // but the first hidden with nothing saying so.
                            if quiz.captureIDs.count > 1 {
                                Menu("Reveal capture") {
                                    ForEach(Array(quiz.captureIDs.enumerated()), id: \.element) { item in
                                        Button("Capture \(item.offset + 1)") { reveal(item.element) }
                                    }
                                }
                                .controlSize(.small).fixedSize()
                            } else if let captureID = quiz.captureIDs.first {
                                Button("Reveal capture") { reveal(captureID) }.controlSize(.small)
                            }
                            Button("Delete Session", role: .destructive) {
                                engine.deleteQuizSession(quiz.id) { loadQuiz() }
                            }
                            .controlSize(.small)
                        }
                        ForEach(quiz.answers) { answer in
                            HStack(alignment: .firstTextBaseline, spacing: NotchSpace.tight) {
                                VStack(alignment: .leading, spacing: NotchSpace.hair) {
                                    if let summary = answer.summary, !summary.isEmpty {
                                        Text(summary)
                                            .font(NotchType.rowDetail)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Text(answer.answer).lineLimit(3).textSelection(.enabled)
                                    if let rationale = answer.rationale, !rationale.isEmpty {
                                        Label {
                                            Text(rationale)
                                                .font(NotchType.rowDetail)
                                                .foregroundStyle(.secondary)
                                                .fixedSize(horizontal: false, vertical: true)
                                        } icon: {
                                            Image(systemName: "wand.and.stars")
                                                .foregroundStyle(NotchTint.healthy)
                                        }
                                    }
                                }
                                Spacer(minLength: 8)
                                if answer.verified {
                                    SettingBadge("\(answer.confidence)%", tint: NotchTint.healthy)
                                } else {
                                    SettingBadge("No answer", tint: NotchTint.attention)
                                }
                                if answer.verified { gradeControls(answer) }
                            }
                            .font(NotchType.rowDetail)
                        }
                    }
                    if quiz.id != quizSessions.last?.id { Divider() }
                }
                HStack {
                    Spacer()
                    Button("Delete All Quiz History", role: .destructive) {
                        confirmsDeleteAllQuiz = true
                    }
                    .controlSize(.small).disabled(quizSessions.isEmpty)
                }
            }
        }
    }

    @ViewBuilder
    private var callsCard: some View {
        if calls.isEmpty {
            SettingCard {
                VStack(alignment: .leading, spacing: 3) {
                    Text(loading ? "Reading the archive…" : "No calls yet")
                        .font(NotchType.rowTitle)
                    Text("A call appears here as soon as one finishes.")
                        .font(NotchType.rowDetail)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            SettingCard("Calls", detail: "Newest first.") { callList(calls) }
        }
    }

    private func callList(_ rows: [CallaCallSummary]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, call in
                callRow(call)
                if index < rows.count - 1 {
                    Divider().padding(.vertical, 2)
                }
            }
        }
    }

    private func callRow(_ call: CallaCallSummary) -> some View {
        HStack(spacing: 10) {
            SettingGlyph(symbol: "waveform", tint: NotchTint.active, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(call.startedAt?.formatted(date: .abbreviated, time: .shortened) ?? call.id)
                    .font(NotchType.rowTitle)
                Text(subtitle(for: call))
                    .font(NotchType.rowDetail)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            // Whether the large model has been over this call. Previously
            // indistinguishable from a call that was never re-transcribed.
            if call.retranscribed {
                SettingBadge("Re-transcribed", tint: NotchTint.healthy)
            }
            if call.wasInterrupted {
                SettingBadge("Interrupted", tint: NotchTint.attention)
            }
            // Zero advice against a full transcript is the case worth surfacing: the
            // copilot was running and never answered.
            if call.suggestionCount == 0, call.turnCount > 0 {
                SettingBadge("No advice", tint: NotchTint.attention)
            }
            SettingBadge(CallaCopilotPersona.title(call.persona))
            Image(systemName: "chevron.forward")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        // A call opens on its own page. It used to expand in place, which pushed
        // the list you were choosing from off the screen with the thing you had
        // chosen.
        .onTapGesture { router?.push(.copilotCallDetail(id: call.id)) }
    }

    // MARK: - Overview


    // MARK: - Detail












    // MARK: - Data


    private func load() async {
        loading = true
        engine.fetchCalls { fetched in
            calls = fetched
            loading = false
        }
        loadQuiz()
    }

    private func loadQuiz() {
        quizLoading = true
        engine.quizHistory { sessions in
            quizSessions = sessions
            quizLoading = false
        }
    }

    private func reveal(_ captureID: String) {
        engine.revealQuizCapture(captureID) { data in
            captureImage = data.flatMap(NSImage.init(data:))
            showsCapture = true
        }
    }


    private func subtitle(for call: CallaCallSummary) -> String {
        var parts: [String] = []
        if call.wasInterrupted { parts.append("Interrupted") }
        if let duration = call.duration { parts.append(callClock(duration)) }
        parts.append("\(call.turnCount) turn\(call.turnCount == 1 ? "" : "s")")
        if call.suggestionCount > 0 { parts.append("\(call.suggestionCount) suggested") }
        if call.hasAudio { parts.append("audio kept") }
        return parts.joined(separator: " · ")
    }

}
