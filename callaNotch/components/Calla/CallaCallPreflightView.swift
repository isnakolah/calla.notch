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
//  Calendar calls reuse the same readiness surface and carry the selected
//  event's context into capture only after the reader presses Start call.
//

import AppKit
import CallaContracts
import Combine
import Defaults
import SwiftUI

struct CallaCallPreflightView: View {
    @ObservedObject private var engine = CallaEngineClient.shared
    @ObservedObject private var library = CallaKnowledgeLibrary.shared
    @ObservedObject private var calendarManager = CalendarManager.shared
    @ObservedObject private var categories = MeetingCategoryStore.shared
    @ObservedObject private var callVPN = CallVPNManager.shared
    @Default(.callaCopilotPersona) private var persona
    @Default(.callaCopilotLiveModel) private var liveModel
    @Default(.callaIntelligenceProvider) private var provider
    @Default(.callaCopilotCustomPersonas) private var customPersonas
    @Default(.callaQuizEnabled) private var quizEnabled
    @Default(.callaCopilotMode) private var selectedMode
    @Default(.calendarDefaultCallPersona) private var calendarDefaultPersona

    /// Drives only the elapsed-time label; the rest arrives on the engine poll.
    @State private var now = Date()
    @State private var selectedKnowledgeNoteIDs = Set<String>()
    @State private var callPackCustomized = false
    @State private var selectedPersona: String?
    @State private var joinFailure: String?
    @State private var choosingCategory = false
    @State private var vpnStarting = false
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
            .onChange(of: categories.revision) { _, _ in
                if meeting != nil { selectedPersona = nil }
                let matching = Set(applicableKnowledge.map(\.id))
                selectedKnowledgeNoteIDs = callPackCustomized
                    ? selectedKnowledgeNoteIDs.intersection(matching) : matching
            }
            .onReceive(tick) { value in
                now = value
            }
            .onChange(of: calendarManager.selectedCallMeeting?.id) { _, _ in
                selectedPersona = nil
                joinFailure = nil
                callPackCustomized = false
                selectedKnowledgeNoteIDs = Set(applicableKnowledge.map(\.id))
            }
            .confirmationDialog("Choose a call type", isPresented: $choosingCategory,
                                titleVisibility: .visible) {
                if let meeting, let suggestion = categories.suggestion(for: meeting) {
                    Button("Use suggested \(CallaCopilotPersona.title(suggestion))") {
                        selectedPersona = suggestion
                        categories.save(suggestion, for: meeting)
                        beginCall()
                    }
                }
                ForEach(CallaCopilotPersona.grouped(including: Array(customPersonas.keys)), id: \.title) { group in
                    ForEach(group.ids, id: \.self) { value in
                        Button(CallaCopilotPersona.title(value)) {
                            selectedPersona = value
                            if let meeting { categories.save(value, for: meeting) }
                            else { persona = value; engine.setCallPersona(value) }
                            beginCall()
                        }
                    }
                }
            } message: {
                if let meeting, let suggestion = categories.suggestion(for: meeting) {
                    Text("Suggested: \(CallaCopilotPersona.title(suggestion))")
                }
            }
    }

    // MARK: - The card

    private var card: some View {
        CallaPreflightCard(
            state: copilot.running ? "In a call" : (meeting != nil ? "Meeting" : (blocker == .none ? "Ready" : "Not ready")),
            live: copilot.running,
            tint: copilot.running || blocker == .none ? NotchAccent.call : NotchAccent.attention,
            figure: copilot.running
                ? CallaCopilotPresentation.elapsed(since: copilot.startedAt, now: now)
                : nil,
            mode: $selectedMode,
            switcherEnabled: !copilot.running && !engine.status.quiz.active,
            includesQuiz: quizEnabled,
            headline: headline,
            headlineTint: joinFailure == nil ? NotchInk.primary : NotchAccent.stop,
            detail: detail,
            checks: checks,
            note: callVPN.warning ?? nextMeeting,
            context: { personaChip },
            controls: { callControls },
            utility: {
                if !calendarManager.upcomingCallMeetings.isEmpty {
                    CallaMenuIconButton(symbol: "calendar", count: calendarManager.upcomingCallMeetings.count) {
                        ForEach(calendarManager.upcomingCallMeetings.prefix(5)) { event in
                            Button("\(event.title) · \(event.start.formatted(date: .abbreviated, time: .shortened)) · \(CallaCopilotPersona.title(categories.confirmed(for: event) ?? categories.suggestion(for: event) ?? calendarDefaultPersona))") {
                                SettingsWindowController.shared.show(route: SettingsRoute(page: .copilotKnowledgeDetail(.event(id: event.id))))
                            }
                        }
                        Button("All upcoming meetings…") {
                            SettingsWindowController.shared.show(route: SettingsRoute(page: .copilotKnowledge))
                        }
                        Divider()
                        if meeting != nil {
                            Button("Dismiss this meeting") { calendarManager.dismissCallMeeting() }
                        }
                    }
                    .help("Choose or dismiss a meeting")
                } else {
                    CallaHeaderGlyphButton(symbol: "clock.arrow.circlepath",
                                           help: "Past calls, their transcripts, and what the copilot said") {
                        SettingsWindowController.shared.showCopilotWindow(tab: "CopilotHistory")
                    }
                }
            })
    }

    /// Which profile shapes this call. It sits in the header's context slot
    /// rather than on the control rail: it is what the call *is*, in the same
    /// place the interview names its meeting.
    private var personaChip: some View {
        CallaContextChip(title: CallaCopilotPersona.title(callPersona), symbol: "person.crop.circle") {
            ForEach(CallaCopilotPersona.grouped(including: Array(customPersonas.keys)), id: \.title) { group in
                Section(group.title) {
                    ForEach(group.ids, id: \.self) { value in
                        Button(CallaCopilotPersona.title(value)) {
                            selectedPersona = value
                            if let meeting { categories.save(value, for: meeting) }
                            else {
                                persona = value
                                engine.setCallPersona(value)
                            }
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
        if let joinFailure { return joinFailure }
        guard copilot.available else { return "Call host is not installed" }
        if copilot.running {
            return copilot.systemAudioActive ? "Listening to both sides" : "Hearing only you"
        }
        if let meeting { return meeting.title.isEmpty ? "Calendar meeting" : meeting.title }
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
        if let meeting {
            let count = applicableKnowledge.count
            return "\(meeting.calendar.account) · \(count) context note\(count == 1 ? "" : "s")"
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
                engine.endCall(origin: "preflightEnd")
            }
        case (false, .microphone), (false, .screen):
            // The fix's full name when the notch has the width for it.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    permissionButton(blocker == .microphone ? "Allow microphone" : "Allow screen recording")
                    CallaSecondaryButton(title: "Start anyway") { start() }
                }
                HStack(spacing: 6) {
                    permissionButton(blocker == .microphone ? "Allow mic" : "Allow recording")
                    CallaSecondaryButton(title: "Start anyway") { start() }
                }
                HStack(spacing: 6) {
                    permissionButton("Allow")
                    CallaSecondaryButton(title: "Start anyway") { start() }
                }
            }
        case (false, .signIn):
            CallaPrimaryButton(title: "Sign in to Gemini", symbol: "person.badge.key.fill",
                               tint: NotchAccent.attention) {
                engine.loginAgy()
            }
        case (false, .model):
            CallaPrimaryButton(title: "Fetching model…", symbol: "arrow.down.circle",
                               tint: NotchAccent.call, enabled: false) {}
        case (false, .none):
            CallaPrimaryButton(title: vpnStarting ? "Preparing VPN…" : "Start call", symbol: "waveform",
                               badge: meeting.map { meetingTimer($0) },
                               enabled: copilot.available && !vpnStarting) { start() }
                .keyboardShortcut(.defaultAction)
            if callVPN.hasPendingRestore && !vpnStarting {
                CallaSecondaryButton(title: "Restore VPN") {
                    Task { await callVPN.restorePending() }
                }
            } else {
                contextChip
            }
        }
    }

    private func permissionButton(_ title: String) -> some View {
        CallaPrimaryButton(title: title,
                           symbol: blocker == .microphone ? "mic.fill" : "rectangle.inset.filled.and.person.filled",
                           tint: NotchAccent.attention) {
            engine.requestCopilotPermissions()
        }
        .help(blocker == .microphone ? "Allow microphone access" : "Allow screen recording")
    }

    /// The next meeting today, so the reader knows what this call is for.
    private var nextMeeting: String? {
        if let meeting {
            return meeting.start > now
                ? "Starts \(meeting.start.formatted(date: .omitted, time: .shortened))"
                : "Meeting in progress"
        }
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

    private func start() {
        if let meeting {
            guard categories.confirmed(for: meeting) != nil else {
                choosingCategory = true
                return
            }
        } else if selectedPersona == nil {
            choosingCategory = true
            return
        }
        beginCall()
    }

    private func beginCall() {
        guard !vpnStarting else { return }
        let selectedMeeting = meeting
        let selectedCallPersona = callPersona
        let selectedCallModel = liveModel
        let selectedNotes = callPackSelection
        vpnStarting = true
        Task { @MainActor in
            await callVPN.prepareForCall()
            vpnStarting = false
            openAndStartCall(meeting: selectedMeeting, persona: selectedCallPersona,
                             model: selectedCallModel, notes: selectedNotes)
        }
    }

    private func openAndStartCall(meeting: EventModel?, persona: String, model: String, notes: [String]?) {
        if let meeting {
            guard let url = meeting.videoCallURL else {
                joinFailure = "Meeting link is no longer available"
                Task { await callVPN.restoreAfterCall() }
                return
            }
            let native = Defaults[.openMeetingsInApp] ? MeetingLinkResolver.nativeURL(for: url) : nil
            guard (native.map { NSWorkspace.shared.open($0) } ?? false) || NSWorkspace.shared.open(url) else {
                joinFailure = "Could not open meeting link"
                Task { await callVPN.restoreAfterCall() }
                return
            }
        }
        engine.startCall(persona: persona, model: model,
                         meeting: meeting.map(CallaMeeting.init),
                         selectedKnowledgeNoteIDs: notes)
    }

    private var meeting: EventModel? { calendarManager.selectedCallMeeting }

    private var callPersona: String {
        if let selectedPersona { return selectedPersona }
        guard let meeting else { return persona }
        if let chosen = categories.confirmed(for: meeting) { return chosen }
        if let suggestion = categories.suggestion(for: meeting) { return suggestion }
        let fallback = calendarDefaultPersona
        return CallaCopilotPersona.all(including: Array(customPersonas.keys)).contains(fallback)
            ? fallback : "generic"
    }

    private func meetingTimer(_ event: EventModel) -> String {
        let seconds = Int(abs(event.start.timeIntervalSince(now)))
        let clock = String(format: "%02d:%02d", seconds / 60, seconds % 60)
        return event.start > now ? "in \(clock)" : "+\(clock)"
    }

    private var applicableKnowledge: [CallaKnowledgeNote] {
        library.notes.filter { note in
            note.scope == "always" || (note.scope == "persona" && note.scopeKey == callPersona)
                || (note.scope == "event" && note.scopeKey == meeting?.id)
                || (note.scope == "series" && note.scopeKey == meeting?.seriesID)
        }
    }

    private var callPackSelection: [String]? {
        callPackCustomized
            ? selectedKnowledgeNoteIDs.intersection(Set(applicableKnowledge.map(\.id))).sorted()
            : nil
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
