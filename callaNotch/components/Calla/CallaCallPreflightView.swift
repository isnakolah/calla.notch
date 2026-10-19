//
//  CallaCallPreflightView.swift
//  callaNotch
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
            state: copilot.running ? "In a call" : (blocker == .none ? "Ready" : "Not ready"),
            live: copilot.running,
            tint: copilot.running || blocker == .none ? NotchAccent.call : NotchAccent.attention,
            figure: copilot.running
                ? CallaCopilotPresentation.elapsed(since: copilot.startedAt, now: now)
                : nil,
            mode: $selectedMode,
            switcherEnabled: !copilot.running && !engine.status.quiz.active,
            includesQuiz: quizEnabled,
            headline: headline,
            headlineTint: NotchInk.primary,
            detail: detail,
            checks: checks,
            note: nextMeeting,
            context: { personaChip },
            controls: { callControls },
            utility: {
                CallaHeaderGlyphButton(symbol: "clock.arrow.circlepath",
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
            CallaCheck("Answers", symbol: "sparkles",
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

    private var brainState: (value: String, state: CallaCheck.State) {
        guard provider == "local" else {
            return engine.status.gatewayReachable
                ? ("gateway reachable", .ready) : ("gateway unreachable", .blocking)
        }
        guard copilot.agyAvailable else { return ("agy is not installed", .blocking) }
        return copilot.agyLoggedIn ? ("Gemini, signed in", .ready) : ("signed out of Gemini", .blocking)
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
            return copilot.lastResult ?? "Reinstall Calla to restore the copilot."
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
        provider == "local" ? "Gemini" : "the gateway"
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
            CallaPrimaryButton(title: "End call", symbol: "stop.fill", tint: NotchAccent.stop) {
                engine.endCall()
            }
        case (false, .microphone), (false, .screen):
            CallaPrimaryButton(title: blocker == .microphone ? "Allow microphone" : "Allow screen recording",
                               symbol: blocker == .microphone ? "mic.fill" : "rectangle.inset.filled.and.person.filled",
                               tint: NotchAccent.attention) {
                engine.requestCopilotPermissions()
            }
            CallaSecondaryButton(title: "Start anyway") { start() }
        case (false, .signIn):
            CallaPrimaryButton(title: "Sign in to Gemini", symbol: "person.badge.key.fill",
                               tint: NotchAccent.attention) {
                engine.loginAgy()
            }
        case (false, .model):
            CallaPrimaryButton(title: "Fetching model…", symbol: "arrow.down.circle",
                               tint: NotchAccent.call, enabled: false) {}
        case (false, .none):
            CallaPrimaryButton(title: "Start listening", symbol: "waveform",
                               enabled: copilot.available) { start() }
                .keyboardShortcut(.defaultAction)
            contextChip
        }
    }

    /// The next meeting today, so the reader knows what this call is for.
    private var nextMeeting: String? {
        if let title = copilot.meetingTitle, !title.isEmpty { return "For \(title)" }
        let now = Date()
        let horizon = now.addingTimeInterval(8 * 3600)
        let next = CalendarManager.shared.events
            .filter { event in
                guard case .event = event.type, !event.isAllDay else { return false }
                return event.end > now && event.start < horizon
            }
            .min { $0.start < $1.start }
        guard let next else { return nil }
        let time = next.start <= now ? "now" : next.start.formatted(date: .omitted, time: .shortened)
        return "Next: \(next.title), \(time)"
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
        CallaMenuIconButton(symbol: "paperclip", count: selectedKnowledgeNoteIDs.count) {
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
