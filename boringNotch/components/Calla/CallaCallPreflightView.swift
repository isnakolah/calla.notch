//
//  CallaCallPreflightView.swift
//  boringNotch
//
//  The plain listening call, at rest.
//
//  A pre-flight check rather than a settings page, because that is the question
//  people bring to it thirty seconds before a call: *will this work?* A copilot
//  that starts and then silently hears only one side is worse than one that
//  refuses to start, so the panel shows what is armed before it offers to begin,
//  and the primary control names whatever is missing instead of always saying
//  "start".
//
//  Any persona, with the user's selected knowledge and no required project.
//  Calls started here have no synthetic interview meeting context.
//

import AppKit
import Defaults
import SwiftUI

struct CallaCallPreflightView: View {
    @ObservedObject private var engine = CallaEngineClient.shared
    @ObservedObject private var library = CallaKnowledgeLibrary.shared
    @Default(.callaCopilotPersona) private var persona
    @Default(.callaCopilotLiveModel) private var liveModel
    @Default(.callaIntelligenceProvider) private var provider
    @Default(.callaCopilotCustomPersonas) private var customPersonas
    @Default(.callaQuizEnabled) private var quizEnabled
    @Default(.callaCopilotMode) private var selectedMode

    /// Drives only the elapsed-time label; the rest arrives on the engine poll.
    @State private var now = Date()
    @State private var selectedKnowledgeNoteIDs = Set<String>()
    @State private var callPackCustomized = false
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var copilot: CallaCopilotStatus { engine.status.copilot }

    var body: some View {
        card
            .task {
                engine.start()
                engine.startMonitoring()
                await library.load()
                if !callPackCustomized { selectedKnowledgeNoteIDs = Set(applicableKnowledge.map(\.id)) }
            }
            .onChange(of: persona) { _, _ in
                if !callPackCustomized { selectedKnowledgeNoteIDs = Set(applicableKnowledge.map(\.id)) }
            }
            .onReceive(tick) { value in
                if copilot.running { now = value }
            }
    }

    // MARK: - The card

    private var card: some View {
        CallaPreflightCard(
            state: copilot.running ? "In a call" : "Ready",
            live: copilot.running,
            tint: copilot.running ? NotchTint.healthy : .effectiveAccent,
            figure: copilot.running
                ? CallaCopilotPresentation.elapsed(since: copilot.startedAt, now: now)
                : nil,
            mode: $selectedMode,
            switcherEnabled: !copilot.running && !engine.status.quiz.active
                && !CopilotLiveSession.shared.isCoding,
            includesQuiz: quizEnabled,
            includesPlainCall: true,
            headline: headline,
            headlineTint: blocker == .none || copilot.running ? NotchInk.primary : NotchTint.attention,
            detail: detail,
            checks: checks,
            context: { personaChip },
            controls: { callControls },
            utility: {
                NotchGlyphButton(symbol: "clock.arrow.circlepath",
                                 help: "Past calls, their transcripts, and what the copilot said") {
                    SettingsWindowController.shared.showCopilotWindow(tab: "CopilotHistory")
                }
            })
    }

    /// Which profile shapes this call. It sits in the header's context slot
    /// rather than on the control rail: it is what the call *is*, in the same
    /// place the interview names its meeting.
    private var personaChip: some View {
        CallaContextChip(title: CallaCopilotPersona.title(persona), symbol: "person.crop.circle") {
            ForEach(CallaCopilotPersona.grouped(including: Array(customPersonas.keys)), id: \.title) { group in
                Section(group.title) {
                    ForEach(group.ids, id: \.self) { value in
                        Button(CallaCopilotPersona.title(value)) {
                            persona = value
                            engine.setCallPersona(value)
                        }
                    }
                }
            }
        }
        .help("Choose call profile")
    }

    // MARK: - Readiness

    /// The four things a call needs, as four glyphs.
    private var checks: [CallaCheck] {
        [
            CallaCheck("Microphone", symbol: copilot.hostMicGranted ? "mic.fill" : "mic.slash.fill",
                       value: micState.value, state: micState.state),
            CallaCheck("Other side", symbol: "speaker.wave.2.fill",
                       value: screenState.value, state: screenState.state),
            CallaCheck(brainLabel, symbol: "sparkles",
                       value: brainState.value, state: brainState.state),
            CallaCheck("Speech model", symbol: "waveform",
                       value: modelState.value, state: modelState.state)
        ]
    }

    private var micState: (value: String, state: CallaCheck.State) {
        guard copilot.hostPermissionsKnown else { return ("not checked yet", .unknown) }
        return copilot.hostMicGranted ? ("allowed", .ready) : ("not allowed", .blocking)
    }

    private var screenState: (value: String, state: CallaCheck.State) {
        guard copilot.hostPermissionsKnown else { return ("not checked yet", .unknown) }
        return copilot.hostScreenGranted ? ("captured", .ready) : ("not captured", .blocking)
    }

    /// Short enough for a tooltip's first word. Which remote is behind agy is in
    /// the detail line, which has the width for it.
    private var brainLabel: String { provider == "local" ? "Agy" : "Gateway" }

    private var brainState: (value: String, state: CallaCheck.State) {
        guard provider == "local" else {
            return engine.status.gatewayReachable
                ? ("reachable", .ready) : ("unreachable", .blocking)
        }
        guard copilot.agyAvailable else { return ("unavailable", .blocking) }
        return copilot.agyLoggedIn ? ("signed in", .ready) : ("signed out", .blocking)
    }

    private var modelState: (value: String, state: CallaCheck.State) {
        guard let download = copilot.modelDownload else { return (shortModelName, .ready) }
        if download.state == "failed" { return ("download failed", .blocking) }
        if download.isActive { return ("downloading, \(Int(download.fraction * 100))%", .working) }
        return (shortModelName, .ready)
    }

    private var shortModelName: String {
        liveModel.replacingOccurrences(of: "whisper-", with: "")
            .replacingOccurrences(of: "-en", with: "")
    }

    // MARK: - Copy

    private var headline: String {
        guard copilot.available else { return "Call host is not installed" }
        if copilot.running {
            return copilot.systemAudioActive ? "Listening to both sides" : "Hearing only you"
        }
        switch blocker {
        case .microphone: return "Nothing would be heard"
        case .screen: return "Only your side would be heard"
        case .signIn: return "Sign in to use this Mac's copilot"
        case .model: return "Fetching the transcription model"
        case .none: return "Ready to listen"
        }
    }

    /// One line, and it has to *be* one line.
    private var detail: String {
        guard copilot.available else {
            return copilot.lastResult ?? "Reinstall Boring to restore the copilot."
        }
        if copilot.running {
            return "\(copilot.turnCount) turn\(copilot.turnCount == 1 ? "" : "s") · answers via \(brainSentenceName)"
        }
        switch blocker {
        case .microphone: return "Your own voice is half the conversation."
        case .screen: return "Screen Recording transcribes the other side."
        case .signIn: return "Sign in to agy for Google-backed answers."
        case .model: return modelDetail
        case .none: return "Audio stays on this Mac · answers via \(brainSentenceName)"
        }
    }

    private var brainSentenceName: String {
        provider == "local" ? "agy (Google)" : "Gateway"
    }

    private var modelDetail: String {
        guard let download = copilot.modelDownload else { return "Downloading in the background." }
        if download.state == "failed" { return download.message ?? "The download did not finish." }
        return "\(Int(download.fraction * 100))% of \(download.model)"
    }

    // MARK: - Controls

    /// The blocking step, if there is one.
    private enum Blocker { case microphone, screen, signIn, model, none }

    private var blocker: Blocker {
        if copilot.hostPermissionsKnown, !copilot.hostMicGranted { return .microphone }
        if copilot.hostPermissionsKnown, !copilot.hostScreenGranted { return .screen }
        if provider == "local", copilot.agyAvailable, !copilot.agyLoggedIn { return .signIn }
        if let download = copilot.modelDownload, download.isActive { return .model }
        return .none
    }

    @ViewBuilder
    private var callControls: some View {
        switch (copilot.isRecording, blocker) {
        case (true, _):
            CallaPrimaryButton(title: "End call", symbol: "stop.fill", tint: NotchTint.stuck) {
                engine.endCall()
            }
        case (false, .microphone), (false, .screen):
            CallaPrimaryButton(title: "Allow recording", symbol: "checkmark.shield.fill",
                               tint: NotchTint.attention) {
                engine.requestCopilotPermissions()
            }
            NotchChip(action: { start() }) { Text("Start anyway") }
        case (false, .signIn):
            CallaPrimaryButton(title: "Sign in", symbol: "person.badge.key.fill",
                               tint: NotchTint.attention) {
                engine.loginAgy()
            }
        case (false, .model):
            CallaPrimaryButton(title: "Fetching model…", symbol: "arrow.down.circle",
                               tint: NotchTint.active, enabled: false) {}
        case (false, .none):
            contextChip
            CallaPrimaryButton(title: "Start", symbol: "waveform",
                               enabled: copilot.available) { start() }
        }
    }

    /// No meeting, deliberately — see the note at the top of this file.
    private func start() {
        engine.startCall(persona: persona, model: liveModel,
                         selectedKnowledgeNoteIDs: callPackSelection)
    }

    private var applicableKnowledge: [CallaKnowledgeNote] {
        library.notes.filter { note in
            note.scope == "always" || (note.scope == "persona" && note.scopeKey == persona)
        }
    }

    private var callPackSelection: [String]? {
        callPackCustomized ? selectedKnowledgeNoteIDs.sorted() : nil
    }

    private var contextChip: some View {
        CallaMenuChip(title: "Context", symbol: "paperclip") {
            if applicableKnowledge.isEmpty {
                Text("No matching notes")
            } else {
                ForEach(applicableKnowledge) { note in
                    Button {
                        callPackCustomized = true
                        if selectedKnowledgeNoteIDs.contains(note.id) {
                            selectedKnowledgeNoteIDs.remove(note.id)
                        } else {
                            selectedKnowledgeNoteIDs.insert(note.id)
                        }
                    } label: {
                        Label(note.title.isEmpty ? "Untitled note" : note.title,
                              systemImage: selectedKnowledgeNoteIDs.contains(note.id)
                                ? "checkmark" : note.symbol)
                    }
                }
            }
            Divider()
            Button("Add notes or files…") {
                SettingsWindowController.shared.showCopilotWindow(tab: "CopilotKnowledge")
            }
        }
        .help("Add context for this call")
        .accessibilityLabel("Context, \(selectedKnowledgeNoteIDs.count) selected")
    }
}
