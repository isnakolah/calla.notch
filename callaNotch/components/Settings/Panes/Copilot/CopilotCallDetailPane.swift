//
//  CopilotCallDetailPane.swift
//  callaNotch
//

import Defaults
import SwiftUI

/// One archived call, on a page of its own.
///
/// This used to expand in place above the list: opening a call pushed the list
/// down the pane, and the thing you were reading and the thing you were choosing
/// from competed for the same scroll. A call has a transcript, a timeline and
/// whatever the copilot said — that is a page, not a disclosure.
///
/// The Timeline / Transcript / Copilot control stays a segmented picker rather
/// than becoming three more destinations. It re-filters one dataset; it does not
/// swap unrelated content. That is the line between a control and navigation in
/// disguise, and it is worth not blurring the next time someone tidies this.
struct CopilotCallDetailPane: View {
    let callID: String

    @ObservedObject private var engine = CallaEngineClient.shared
    @ObservedObject private var categories = MeetingCategoryStore.shared
    @Default(.callaCopilotCustomPersonas) private var customPersonas
    @Environment(\.settingsRouter) private var router

    @State private var call: CallaCallSummary?
    @State private var turns: [CallaCallTurn] = []
    @State private var suggestions: [CallaCopilotArchivedSuggestion] = []
    @State private var recap: CallaRecapDraft?
    @State private var regeneratingRecap = false
    @State private var categoryScope = "series"
    @State private var speakers: CallaCallSpeakers?
    @State private var renaming: CallaCallSpeakers.Speaker?
    @State private var renameText = ""
    @State private var view: DetailView = .timeline
    @State private var loading = true

    /// The three ways a finished call is worth reading.
    private enum DetailView: String, CaseIterable, Identifiable {
        case timeline, transcript, advice
        var id: String { rawValue }

        var title: String {
            switch self {
            case .timeline: "Timeline"
            case .transcript: "Transcript"
            case .advice: "Copilot"
            }
        }
    }

    var body: some View {
        SettingsPane(page: .copilotCallDetail(id: callID), titleOverride: title) {
            if let call {
                overviewCard(for: call)
                speakersCard
                recapCard
                detailCard(for: call)
            } else if loading {
                SettingCard {
                    HStack(spacing: NotchSpace.snug) {
                        ProgressView().controlSize(.small)
                        Text("Reading the call\u{2026}").font(NotchType.rowDetail).foregroundStyle(.secondary)
                    }
                }
            } else {
                SettingsEmptyState(
                    symbol: "waveform.slash",
                    title: "This call is no longer in the archive",
                    detail: "It may have been exported and removed, or the archive was cleared.",
                    actionTitle: "Back to History",
                    action: { router?.pop() })
            }
        }
        .task { await load() }
        .alert("Name this speaker", isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let speaker = renaming { nameSpeaker(speaker, renameText) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text(Defaults[.callaRememberVoices]
                 ? "Every line from this voice takes the name, and later calls will recognise it."
                 : "Every line from this voice takes the name.")
        }
    }

    private var title: String {
        call?.startedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Call"
    }

    private func load() async {
        loading = true
        let summaries: [CallaCallSummary] = await withCheckedContinuation { continuation in
            engine.fetchCalls { continuation.resume(returning: $0) }
        }
        call = summaries.first { $0.id == callID }
        loading = false
        guard call != nil else { return }
        engine.fetchCallTranscript(callID: callID) { turns = $0 }
        engine.fetchCallSuggestions(callID) { suggestions = $0 }
        engine.fetchRecapDraft(callID: callID) { recap = $0 }
        engine.controlSpeakers(CallaSpeakerCommand(action: "list", callID: callID)) { speakers = $0 }
    }

    // MARK: - Speakers

    /// Who was on the call, once the post-call speaker pass has separated the
    /// remote voices. Hidden until then: before it runs there is only "Them".
    @ViewBuilder
    private var speakersCard: some View {
        if let speakers, !speakers.remote.isEmpty {
            SettingCard("Speakers", detail: speakersDetail(speakers)) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(speakers.remote) { speaker in
                        speakerRow(speaker, in: speakers)
                    }
                }
            }
        }
    }

    private func speakersDetail(_ speakers: CallaCallSpeakers) -> String {
        let count = speakers.remote.count
        let guesses = speakers.remote.filter(\.isGuess).count
        var text = "\(count) other voice\(count == 1 ? "" : "s") on this call."
        if guesses > 0 {
            text += " Names marked ? were guessed from the conversation — confirm or change them."
        }
        return text
    }

    private func speakerRow(_ speaker: CallaCallSpeakers.Speaker, in all: CallaCallSpeakers) -> some View {
        HStack(spacing: NotchSpace.snug) {
            Circle().fill(Self.tint(for: speaker.id)).frame(width: 8, height: 8)
            Text(speaker.name + (speaker.isGuess ? " ?" : ""))
                .font(NotchType.rowTitle)
            if speaker.nameSource == "voiceprint" {
                Image(systemName: "waveform.badge.checkmark")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help("Recognised from an earlier call")
            }
            Text(talkTime(speaker.speechSeconds))
                .font(NotchType.rowDetail)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if speaker.isGuess {
                Button("Confirm") { control("confirm", speaker) }
                    .controlSize(.small)
            }
            Menu {
                let taken = Set(all.remote.filter { $0.id != speaker.id && $0.isNamed }.map(\.name))
                let options = all.attendees.filter { !taken.contains($0) && $0 != speaker.name }
                if !options.isEmpty {
                    Section("Attendees") {
                        ForEach(options, id: \.self) { name in
                            Button(name) { nameSpeaker(speaker, name) }
                        }
                    }
                }
                Button("Rename\u{2026}") {
                    renameText = speaker.isNamed ? speaker.name : ""
                    renaming = speaker
                }
                let others = all.remote.filter { $0.id != speaker.id }
                if !others.isEmpty {
                    Menu("Same person as") {
                        ForEach(others) { other in
                            Button(other.name) { control("merge", speaker, into: other.id) }
                        }
                    }
                }
                if speaker.isNamed {
                    Divider()
                    Button("Clear name") { nameSpeaker(speaker, "") }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func nameSpeaker(_ speaker: CallaCallSpeakers.Speaker, _ name: String) {
        engine.controlSpeakers(CallaSpeakerCommand(action: "name", callID: callID, speakerID: speaker.id, name: name)) {
            applySpeakers($0)
        }
    }

    private func control(_ action: String, _ speaker: CallaCallSpeakers.Speaker, into: String? = nil) {
        engine.controlSpeakers(CallaSpeakerCommand(action: action, callID: callID, speakerID: speaker.id, into: into)) {
            applySpeakers($0)
        }
    }

    /// A rename or merge changes what every turn is labelled, so the transcript
    /// is re-read rather than patched.
    private func applySpeakers(_ updated: CallaCallSpeakers?) {
        if let updated { speakers = updated }
        engine.fetchCallTranscript(callID: callID) { turns = $0 }
    }

    private func talkTime(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return total < 60 ? "\(total)s" : "\(total / 60)m \(total % 60)s"
    }

    /// One steady colour per voice, so a speaker can be followed down the
    /// transcript without reading every name.
    static func tint(for speakerID: String?) -> Color {
        guard let speakerID, speakerID != "me" else { return .secondary }
        let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .yellow, .indigo]
        let index = Int(speakerID.dropFirst()) ?? 1
        return palette[(max(index, 1) - 1) % palette.count]
    }

    private func overviewCard(for call: CallaCallSummary) -> some View {
        SettingCard(call.startedAt?.formatted(date: .abbreviated, time: .shortened) ?? call.id) {
            VStack(alignment: .leading, spacing: 10) {
                SettingFact(title: "Call type", value: CallaCopilotPersona.title(
                    categories.confirmed(eventID: call.eventID, seriesID: call.seriesID) ?? call.persona))
                if let eventID = call.eventID {
                    if call.seriesID != nil {
                        Picker("Change type for", selection: $categoryScope) {
                            Text("Every repeat").tag("series")
                            Text("This occurrence").tag("event")
                        }
                        .frame(maxWidth: 330)
                    }
                    Menu("Change call type") {
                        ForEach(CallaCopilotPersona.grouped(including: Array(customPersonas.keys)), id: \.title) { group in
                            Section(group.title) {
                                ForEach(group.ids, id: \.self) { value in
                                    Button(CallaCopilotPersona.title(value)) {
                                        categories.save(value, eventID: eventID, seriesID: call.seriesID,
                                                        occurrenceOnly: categoryScope == "event")
                                    }
                                }
                            }
                        }
                    }
                }
                SettingFact(
                    title: "Ended",
                    value: call.wasInterrupted ? "Interrupted" : "Completed",
                    tint: call.wasInterrupted ? NotchTint.attention : NotchTint.healthy)
                if let duration = call.duration {
                    SettingFact(title: "Length", value: callClock(duration))
                }
                SettingFact(title: "Turns transcribed", value: "\(call.turnCount)")
                // The two numbers side by side are the point: a re-transcribed pass
                // that found more turns is visibly better than the live one.
                SettingFact(
                    title: "Re-transcribed",
                    value: call.retranscribed
                        ? "yes — \(call.archivedTurnCount) turns with the large model"
                        : "not yet",
                    tint: call.retranscribed ? NotchTint.healthy : nil
                )
                SettingFact(
                    title: "Copilot suggestions",
                    value: "\(call.suggestionCount)",
                    tint: call.suggestionCount == 0 ? NotchTint.attention : nil
                )
                SettingFact(title: "Audio", value: call.hasAudio ? "kept" : "discarded")

                HStack(spacing: 8) {
                    Button("Show folder") { CallaEngineClient.shared.revealCallFolder(callID: call.id) }
                        .controlSize(.small)
                    Button("Export…") { export(call) }
                        .controlSize(.small)
                        .disabled(turns.isEmpty)
                    if call.hasAudio {
                        Button(call.retranscribed
                               ? "Re-transcribe again"
                               : "Re-transcribe with the large model") {
                            engine.retranscribe(callID: call.id)
                        }
                        .controlSize(.small)
                        .help("Runs the archive model over the saved audio. Slower, and more accurate.")
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    @ViewBuilder
    private var recapCard: some View {
        if let recap {
            SettingCard("Review recap", detail: recapDetail(recap), tint: recap.reviewState == "pending" ? NotchTint.active : nil) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(recap.overview)
                        .font(NotchType.rowDetail)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(recap.items) { item in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.kind.replacingOccurrences(of: "_", with: " ").capitalized)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text(item.text)
                                .font(NotchType.rowDetail)
                                .textSelection(.enabled)
                            Text("Turns \(item.fromSeq)–\(item.toSeq)")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    if let failure = recap.failure, !failure.isEmpty {
                        Text(failure).font(NotchType.rowDetail).foregroundStyle(NotchTint.attention)
                        Button(regeneratingRecap ? "Regenerating…" : "Retry regeneration") {
                            regeneratingRecap = true
                            engine.regenerateCallRecap(callID) {
                                regeneratingRecap = false
                                engine.fetchRecapDraft(callID: callID) { self.recap = $0 }
                            }
                        }
                        .disabled(regeneratingRecap)
                    }
                    HStack {
                        if recap.reviewState == "pending" {
                            Button("Approve recap") { controlRecap("approve") }
                                .buttonStyle(.borderedProminent)
                                .disabled(recap.failure != nil)
                            Button("Reject") { controlRecap("reject") }
                        } else {
                            Text(recap.reviewState == "approved" ? "Approved knowledge" : "Rejected — kept in history")
                                .font(NotchType.rowDetail).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Delete", role: .destructive) { controlRecap("delete") }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private func recapDetail(_ recap: CallaRecapDraft) -> String {
        var values = [recap.provider, recap.model].compactMap { $0 }
        values.append(recap.reviewState == "pending" ? "Approval required" : recap.reviewState.capitalized)
        return values.joined(separator: " · ")
    }

    private func controlRecap(_ action: String) {
        engine.controlRecap(action, callID: callID) { recap = $0 }
    }

    private func detailCard(for call: CallaCallSummary) -> some View {
        SettingCard(detailTitle, detail: detailSubtitle(for: call)) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: $view) {
                    ForEach(DetailView.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        switch view {
                        case .timeline: timelineRows
                        case .transcript: transcriptRows
                        case .advice: adviceRows
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 340)
                .background(NotchSurface.sunken,
                            in: RoundedRectangle(cornerRadius: NotchRadius.control, style: .continuous))
            }
        }
    }

    private var detailTitle: String {
        switch view {
        case .timeline: "What happened"
        case .transcript: "Transcript"
        case .advice: "What the copilot said"
        }
    }

    private func detailSubtitle(for call: CallaCallSummary) -> String {
        switch view {
        case .timeline: "Turns and the copilot's advice, in the order they happened."
        case .transcript: "\(turns.count) turn\(turns.count == 1 ? "" : "s"), as transcribed on this Mac."
        case .advice:
            call.suggestionCount == 0
                ? "Nothing was returned during this call."
                : "\(call.suggestionCount) suggestion\(call.suggestionCount == 1 ? "" : "s")."
        }
    }

    /// Turns and advice interleaved.
    ///
    /// A suggestion answers a particular turn — that is what `after_seq` records —
    /// so showing them apart loses the only thing that makes the advice
    /// interpretable afterwards: what it was responding to.
    @ViewBuilder
    private var timelineRows: some View {
        if turns.isEmpty {
            emptyNote("This call has no saved turns.")
        } else {
            ForEach(turns) { turn in
                turnBubble(turn)
                ForEach(suggestions.filter { $0.afterSeq == turn.seq }) { suggestion in
                    adviceBlock(suggestion, showSeq: false)
                }
            }
            // Advice that answers a turn no longer in the transcript still belongs
            // somewhere, rather than being silently dropped.
            let orphans = suggestions.filter { suggestion in
                !turns.contains { $0.seq == suggestion.afterSeq }
            }
            ForEach(orphans) { adviceBlock($0, showSeq: true) }
        }
    }

    @ViewBuilder
    private var transcriptRows: some View {
        if turns.isEmpty {
            emptyNote("This call has no saved turns.")
        } else {
            ForEach(turns) { turnBubble($0) }
        }
    }

    @ViewBuilder
    private var adviceRows: some View {
        if suggestions.isEmpty {
            emptyNote("The copilot produced no advice — either it was not asked, or it could not answer.")
        } else {
            ForEach(suggestions) { adviceBlock($0, showSeq: true) }
        }
    }

    /// Them left, you right — the same split the live panel uses, so a transcript
    /// read afterwards looks like the one read during the call.
    ///
    /// Each bubble carries who said it and when. Left-versus-right is learnable
    /// during a call and ambiguous a week later; on a call with several people
    /// it says nothing at all about which of them spoke.
    private func turnBubble(_ turn: CallaCallTurn) -> some View {
        let tint = turn.isRemote ? (turn.speaker == nil ? Color.blue : Self.tint(for: turn.speaker)) : Color.secondary
        return HStack(alignment: .top, spacing: 6) {
            if !turn.isRemote { Spacer(minLength: 36) }
            VStack(alignment: turn.isRemote ? .leading : .trailing, spacing: 2) {
                HStack(spacing: 5) {
                    Text(turn.speakerLabel)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(tint)
                    Text(turn.clock)
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Text(turn.text)
                    .font(.system(size: 11))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        turn.isRemote ? tint.opacity(0.16) : Color.secondary.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            if turn.isRemote { Spacer(minLength: 36) }
        }
    }

    private func adviceBlock(_ suggestion: CallaCopilotArchivedSuggestion, showSeq: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 9))
                    .foregroundStyle(NotchTint.active)
                Text(showSeq ? "copilot · after turn \(suggestion.afterSeq)" : "copilot")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            if !suggestion.headline.isEmpty {
                Text(suggestion.headline)
                    .font(.system(size: 11, weight: .medium))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(suggestion.angles.enumerated()), id: \.offset) { _, angle in
                Text("• \(angle)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(suggestion.confirm.enumerated()), id: \.offset) { _, item in
                Text("check: \(item)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(NotchTint.attention)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NotchTint.active.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text)
            .font(NotchType.rowDetail)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }


    /// Writing to a location the user picked is the one file write the sandbox
    /// allows without an entitlement, which is why this is a save panel and not a
    /// Downloads folder drop.
    ///
    /// Exports the timeline rather than the transcript alone: the advice is half of
    /// what happened, and it is only interpretable next to the turn it answered.
    private func export(_ call: CallaCallSummary) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "call-\(call.startedAt.map { ISO8601DateFormatter().string(from: $0) } ?? call.id).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var lines: [String] = []
        for turn in turns {
            lines.append("[\(turn.clock)] \(turn.speakerLabel): \(turn.text)")
            for suggestion in suggestions where suggestion.afterSeq == turn.seq {
                if !suggestion.headline.isEmpty { lines.append("         COPILOT: \(suggestion.headline)") }
                for angle in suggestion.angles { lines.append("                  • \(angle)") }
                for item in suggestion.confirm { lines.append("                  check: \(item)") }
            }
        }

        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSSound.beep()
        }
    }
}
