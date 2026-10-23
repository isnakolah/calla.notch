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


    /// The call open on the right.
    @State private var selectedID: String?
    @State private var filter = ""

    var body: some View {
        Group {
            if historyMode == "quiz" {
                SettingsPane(title: "Past calls") {
                    modePicker
                    quizCard
                }
            } else {
                HStack(spacing: 0) {
                    listColumn
                        .frame(width: 290)
                    Rectangle().fill(NotchSurface.hairline).frame(width: 1)
                    detailColumn
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(NotchSurface.base)
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
        .onAppear { takeFocus(router?.route.focus) }
        .onChange(of: router?.route.focus) { _, focus in takeFocus(focus) }
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

    /// A deep link to one call arrives as `call:<id>`.
    private func takeFocus(_ focus: String?) {
        guard let focus, focus.hasPrefix("call:") else { return }
        historyMode = "call"
        selectedID = String(focus.dropFirst("call:".count))
        router?.consumeFocus()
    }

    private var modePicker: some View {
        Picker("History", selection: $historyMode) {
            Text("Calls").tag("call")
            Text("Quiz").tag("quiz")
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize()
    }

    // MARK: - Split view

    private var listColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Past calls").font(NotchType.paneTitle)
                Spacer()
                modePicker.controlSize(.small)
            }
            .padding(.horizontal, 22)
            .padding(.top, 30)
            .padding(.bottom, 14)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
                TextField("Filter by persona or date", text: $filter)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .padding(.horizontal, 14)
            .padding(.bottom, 6)

            if calls.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text(loading ? "Reading the archive…" : "No calls yet").font(NotchType.rowTitle)
                    Text("A call appears here as soon as one finishes.")
                        .font(NotchType.rowDetail).foregroundStyle(.secondary)
                }
                .padding(22)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(days, id: \.title) { day in
                            Text(day.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 22)
                                .padding(.top, 10)
                                .padding(.bottom, 4)
                            ForEach(day.calls) { call in callRow(call) }
                        }
                    }
                    .padding(.bottom, 12)
                }
            }

            pendingFooter
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        if let selectedID, calls.contains(where: { $0.id == selectedID }) {
            CopilotCallDetailPane(callID: selectedID)
                .id(selectedID)
        } else {
            SettingsEmptyState(symbol: "waveform",
                               title: calls.isEmpty ? "Nothing to show yet" : "Choose a call",
                               detail: "Its recap, transcript and speakers open here.")
                .frame(maxHeight: .infinity)
        }
    }

    private struct Day { let title: String; let calls: [CallaCallSummary] }

    /// Newest first, grouped the way people remember calls: today, yesterday,
    /// then by date.
    private var days: [Day] {
        let calendar = Calendar.current
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        var order: [String] = []
        var grouped: [String: [CallaCallSummary]] = [:]
        for call in calls {
            let title: String
            if let date = call.startedAt {
                if calendar.isDateInToday(date) { title = "Today" }
                else if calendar.isDateInYesterday(date) { title = "Yesterday" }
                else { title = date.formatted(date: .abbreviated, time: .omitted) }
            } else {
                title = "Undated"
            }
            if !needle.isEmpty {
                let words = [CallaCopilotPersona.title(call.persona), title,
                             call.startedAt?.formatted(date: .long, time: .shortened) ?? ""]
                guard words.contains(where: { $0.lowercased().contains(needle) }) else { continue }
            }
            if grouped[title] == nil { order.append(title) }
            grouped[title, default: []].append(call)
        }
        return order.map { Day(title: $0, calls: grouped[$0] ?? []) }
    }

    @ViewBuilder
    private var pendingFooter: some View {
        if !pending.isEmpty || retranscribingID != nil {
            VStack(alignment: .leading, spacing: 6) {
                Rectangle().fill(NotchSurface.hairline).frame(height: 1)
                HStack(spacing: 8) {
                    if retranscribingID != nil {
                        ProgressView().controlSize(.small)
                        Text("Cleaning up a transcript…")
                    } else {
                        Text("\(pending.count) call\(pending.count == 1 ? "" : "s") can get a cleaner transcript")
                    }
                    Spacer(minLength: 4)
                    if retranscribingID == nil {
                        Button("Run") {
                            queued = pending.map(\.id)
                            startNextRetranscribe()
                        }
                        .controlSize(.small)
                    }
                }
                .font(NotchType.rowDetail)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
            }
        }
    }

    // MARK: - Re-transcribing

    /// Calls with audio still on disk that the large model has not been over.
    private var pending: [CallaCallSummary] {
        calls.filter { $0.hasAudio && !$0.retranscribed }
    }

    private var retranscribingID: String? { engine.status.copilot.retranscribingCallID }

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

    private func callRow(_ call: CallaCallSummary) -> some View {
        let selected = call.id == selectedID
        return Button { selectedID = call.id } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(CallaCopilotPersona.title(call.persona))
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 4)
                    if call.wasInterrupted {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(NotchTint.attention)
                            .help("Interrupted")
                    }
                    if call.suggestionCount == 0, call.turnCount > 0 {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 10))
                            .foregroundStyle(NotchTint.attention)
                            .help("The copilot never answered on this call")
                    }
                }
                Text(subtitle(for: call))
                    .font(NotchType.rowDetail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? NotchTint.active.opacity(0.24) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Overview


    // MARK: - Detail












    // MARK: - Data


    private func load() async {
        loading = true
        engine.fetchCalls { fetched in
            calls = fetched
            loading = false
            if selectedID == nil { selectedID = fetched.first?.id }
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
        if let start = call.startedAt { parts.append(start.formatted(date: .omitted, time: .shortened)) }
        if let duration = call.duration { parts.append(callClock(duration)) }
        parts.append("\(call.turnCount) turn\(call.turnCount == 1 ? "" : "s")")
        if call.suggestionCount > 0 { parts.append("\(call.suggestionCount) suggested") }
        if call.hasAudio { parts.append("audio kept") }
        return parts.joined(separator: " · ")
    }

}
