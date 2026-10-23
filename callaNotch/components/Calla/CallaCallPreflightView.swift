//
//  CallaCallPreflightView.swift
//  callaNotch
//
//  The plain listening call, at rest.
//
//  It answers two questions in order: what is this call, and will it work? Four
//  lines, because that is what the notch's normal 512×168 holds under the tab
//  row: the state word, what the call is, one line of why, and a rail of the
//  likely call types beside the one button.
//
//  The call type is in plain sight rather than behind a menu or a dialog. Every
//  type is ranked by how likely it is for this call (`CallTypeRanker`), the rail
//  shows the top few, and Start confirms what the reader can see. Start asks
//  only when Calla is not sure, and then in the same space: the picker and the
//  list of today's calls replace the tab rather than opening over it, so the
//  notch never grows and a system sheet never appears over the menu bar.
//
//  A copilot that starts and then silently hears only one side is worse than
//  one that refuses to start, so a missing permission takes the headline and
//  the button until it is fixed.
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
    @ObservedObject private var meetingWatch = MeetingApproachWatch.shared
    @Default(.callaCopilotPersona) private var persona
    @Default(.callaCopilotLiveModel) private var liveModel
    @Default(.callaIntelligenceProvider) private var provider
    /// Read so that adding or removing a type of your own re-ranks the rail.
    @Default(.callaCopilotCustomPersonas) private var customPersonas
    @Default(.callaQuizEnabled) private var quizEnabled
    @Default(.callaCopilotMode) private var selectedMode

    /// Drives the meeting countdown; the rest arrives on the engine poll.
    @State private var now = Date()
    @State private var selectedKnowledgeNoteIDs = Set<String>()
    @State private var callPackCustomized = false
    /// The type the reader picked here. Until they pick, the ranker's pick stands.
    @State private var chosenType: String?
    @State private var joinFailure: String?
    @State private var vpnStarting = false
    @State private var surface: Surface = .tab
    /// The type under the pointer, whose "listens for" borrows the detail line.
    @State private var hoveredType: String?
    @State private var query = ""
    /// For a repeating meeting: whether the type is kept for every occurrence.
    @State private var forEveryOccurrence = true
    @FocusState private var queryFocused: Bool
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private enum Surface: Equatable {
        case tab
        /// From Start, a pick starts the call; from More…, it only sets the type.
        case picker(startsCall: Bool)
        case today
    }

    /// The header's caps, a touch larger than the shared token: at 10pt on the
    /// black slab the state word was the hardest thing on the tab to read.
    private static let caps = Font.system(size: 10.5, weight: .bold)

    private var copilot: CallaCopilotStatus { engine.status.copilot }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(EdgeInsets(top: 2, leading: 0, bottom: 6, trailing: 0))
            .task {
                engine.start()
                engine.startMonitoring()
                await library.load()
                if !callPackCustomized { selectedKnowledgeNoteIDs = Set(applicableKnowledge.map(\.id)) }
            }
            .onChange(of: callType) { _, _ in
                if !callPackCustomized { selectedKnowledgeNoteIDs = Set(applicableKnowledge.map(\.id)) }
            }
            .onChange(of: categories.revision) { _, _ in
                let matching = Set(applicableKnowledge.map(\.id))
                selectedKnowledgeNoteIDs = callPackCustomized
                    ? selectedKnowledgeNoteIDs.intersection(matching) : matching
            }
            .onReceive(tick) { value in
                now = value
            }
            // "Join" pressed in the closed notch. Carried out here because this
            // panel owns starting a call: the call type, the VPN and the notes.
            // `onReceive` sees the current value on appearing, so a Join that
            // opened this panel is not missed.
            .onReceive(meetingWatch.$joinRequest) { id in
                guard let id, id == meeting?.id, !copilot.running, !vpnStarting else { return }
                meetingWatch.consumeJoin()
                start()
            }
            .onChange(of: calendarManager.selectedCallMeeting?.id) { _, _ in
                chosenType = nil
                joinFailure = nil
                callPackCustomized = false
                forEveryOccurrence = true
                selectedKnowledgeNoteIDs = Set(applicableKnowledge.map(\.id))
            }
            .onChange(of: copilot.running) { _, running in
                if running { close() }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch surface {
        case .tab: tab
        case .picker(let startsCall): picker(startsCall: startsCall)
        case .today: todayList
        }
    }

    // MARK: - Which type

    private var meeting: EventModel? { calendarManager.selectedCallMeeting }

    private var ranking: CallTypeRanker.Ranking { categories.ranking(for: meeting, now: now) }

    /// What Start would use. Nil only when Calla is not sure and the reader has
    /// not picked: then Start opens the picker instead of guessing.
    private var callType: String? { chosenType ?? ranking.pick }

    private func choose(_ id: String) {
        chosenType = id
        if meeting == nil {
            persona = id
            engine.setCallPersona(id)
        }
    }

    // MARK: - The tab

    private var tab: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Text(headline)
                .font(.system(size: 16, weight: .semibold))
                .tracking(-0.1)
                .foregroundStyle(joinFailure == nil ? NotchInk.primary : NotchAccent.stop)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.top, 5)
            Text(line)
                .font(.system(size: 12))
                .foregroundStyle(lineIsWarning ? NotchAccent.attention : Color.white.opacity(0.76))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.top, 1)
                .animation(.easeOut(duration: 0.12), value: hoveredType)
            Spacer(minLength: 0)
            rail
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(stateTint)
                .frame(width: 7, height: 7)
            Text(stateWord.uppercased())
                .font(Self.caps)
                .tracking(0.7)
                .foregroundStyle(stateTint == NotchAccent.attention ? NotchAccent.attention : Color.white.opacity(0.84))
                .lineLimit(1)
                .fixedSize()
            if copilot.running {
                Text(CallaCopilotPresentation.elapsed(since: copilot.startedAt, now: now))
                    .font(.system(size: 11.5, design: .rounded).monospacedDigit())
                    .foregroundStyle(NotchInk.secondary)
                    .fixedSize()
            }
            Spacer(minLength: 6)
            if !copilot.running, !calendarManager.upcomingCallMeetings.isEmpty {
                CallaHeaderTextButton(title: todayLabel, help: "Your calls coming up, and their types") {
                    open(.today)
                }
            }
            CallaModeSwitcher(selection: $selectedMode,
                              enabled: !copilot.running && !engine.status.quiz.active,
                              includesQuiz: quizEnabled)
            if calendarManager.upcomingCallMeetings.isEmpty {
                CallaHeaderGlyphButton(symbol: "clock.arrow.circlepath",
                                       help: "Past calls, their transcripts, and what the copilot said") {
                    SettingsWindowController.shared.showCopilotWindow(tab: "CopilotHistory")
                }
            }
        }
        .frame(height: 24)
    }

    private var stateWord: String {
        if copilot.running { return "In a call" }
        if !copilot.available || blocker != .none { return "Not ready" }
        if let meeting { return "Meeting · \(meetingTimer(meeting))" }
        return "Ready"
    }

    private var stateTint: Color {
        copilot.running || (copilot.available && blocker == .none) ? NotchAccent.call : NotchAccent.attention
    }

    private var todayLabel: String {
        let count = calendarManager.upcomingCallMeetings.filter { Calendar.current.isDateInToday($0.start) }.count
        return count > 0 ? "\(count) today" : "Upcoming"
    }

    // MARK: - Copy

    private var headline: String {
        if let joinFailure { return joinFailure }
        guard copilot.available else { return "Call host is not installed" }
        if copilot.running {
            return copilot.systemAudioActive ? "Listening to both sides" : "Hearing only you"
        }
        switch blocker {
        case .microphone: return "Nothing would be heard"
        case .screen: return "Only your side would be heard"
        case .signIn: return "Sign in to use this Mac's copilot"
        case .model: return "Fetching the transcription model"
        case .none: break
        }
        if let meeting { return meeting.title.isEmpty ? "Calendar meeting" : meeting.title }
        return "Start a call"
    }

    /// One line, and it has to *be* one line: the fourth band is the rail.
    private var line: String {
        if let hoveredType {
            return "\(CallaCopilotPersona.title(hoveredType)) · listens for \(CallaCopilotPersona.listensFor(hoveredType))"
        }
        guard copilot.available else {
            return copilot.lastResult ?? "Reinstall Calla to restore the copilot."
        }
        if copilot.running {
            let turns = "\(copilot.turnCount) turn\(copilot.turnCount == 1 ? "" : "s")"
            return callType.map { "\(turns) · \(CallaCopilotPersona.title($0))" } ?? turns
        }
        if let warning = callVPN.warning { return warning }
        switch blocker {
        case .microphone: return "Your own voice is half the conversation."
        case .screen: return "Calla needs Screen Recording to hear the other side."
        case .signIn: return "Sign in to agy for Google-backed answers."
        case .model: return modelDetail
        case .none: break
        }
        let when = meeting.map { "\($0.start.formatted(date: .omitted, time: .shortened)) · " } ?? ""
        guard let type = callType else {
            return when + "Not sure what kind of call this is. Pick one below."
        }
        let title = CallaCopilotPersona.title(type)
        if chosenType == nil, let reason = ranking.entry(type)?.reason {
            return when + "\(title) · \(reason)"
        }
        return when + "\(title) · listens for \(CallaCopilotPersona.listensFor(type))"
    }

    private var lineIsWarning: Bool {
        hoveredType == nil && !copilot.running
            && (!copilot.available || callVPN.warning != nil || [Blocker.microphone, .screen, .signIn].contains(blocker))
    }

    private var modelDetail: String {
        guard let download = copilot.modelDownload else { return "Downloading in the background." }
        if download.state == "failed" { return download.message ?? "The download did not finish." }
        return "\(Int(download.fraction * 100))% of \(download.model)"
    }

    // MARK: - Readiness

    /// The blocking step, if there is one.
    private enum Blocker { case microphone, screen, signIn, model, none }

    private var blocker: Blocker {
        if copilot.hostPermissionsKnown, !copilot.hostMicGranted { return .microphone }
        if copilot.hostPermissionsKnown, !copilot.hostScreenGranted { return .screen }
        if provider == "local", copilot.agyAvailable, !copilot.agyLoggedIn { return .signIn }
        if let download = copilot.modelDownload, download.isActive { return .model }
        return .none
    }

    // MARK: - The rail

    @ViewBuilder
    private var rail: some View {
        HStack(spacing: 6) {
            switch (copilot.isRecording, blocker) {
            case (true, _):
                Spacer(minLength: 0)
                CallaPrimaryButton(title: "End call", symbol: "stop.fill", tint: NotchAccent.stop) {
                    engine.endCall(origin: "preflightEnd")
                }
            case (false, .microphone), (false, .screen):
                currentTypeChip
                Spacer(minLength: 6)
                CallaSecondaryButton(title: "Start anyway") { start() }
                CallaPrimaryButton(title: blocker == .microphone ? "Allow microphone" : "Allow call audio",
                                   symbol: blocker == .microphone ? "mic.fill" : "speaker.wave.2.fill",
                                   tint: NotchAccent.attention) {
                    engine.requestCopilotPermissions()
                }
                .help(blocker == .microphone ? "Allow microphone access" : "Allow Screen Recording so Calla hears the other side")
            case (false, .signIn):
                currentTypeChip
                Spacer(minLength: 6)
                CallaPrimaryButton(title: "Sign in to Gemini", symbol: "person.badge.key.fill",
                                   tint: NotchAccent.attention) {
                    engine.loginAgy()
                }
            case (false, .model):
                typeChips
                Spacer(minLength: 6)
                CallaPrimaryButton(title: "Fetching model…", symbol: "arrow.down.circle",
                                   tint: NotchAccent.call, enabled: false) {}
            case (false, .none):
                typeChips
                Spacer(minLength: 6)
                if callVPN.hasPendingRestore && !vpnStarting {
                    CallaSecondaryButton(title: "Restore VPN") {
                        Task { await callVPN.restorePending() }
                    }
                }
                CallaPrimaryButton(title: vpnStarting ? "Preparing VPN…" : (meeting == nil ? "Start call" : "Join and listen"),
                                   symbol: "waveform",
                                   enabled: copilot.available && !vpnStarting) { start() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(height: 34)
    }

    /// The likely types, as many as the rail has room for, then More… and the
    /// notes. The chosen type is always among them, even when it ranks low.
    private var typeChips: some View {
        ViewThatFits(in: .horizontal) {
            chipRow(3)
            chipRow(2)
            chipRow(1)
        }
    }

    private func chipRow(_ count: Int) -> some View {
        HStack(spacing: 2) {
            ForEach(chipIDs(count), id: \.self) { id in
                CallTypeChip(title: CallaCopilotPersona.title(id),
                             selected: id == callType,
                             ring: ringTint(for: id),
                             action: { choose(id) },
                             hover: { inside in hover(id, inside) })
            }
            CallTypeChip(title: "More…", ink: NotchAccent.call, action: { open(.picker(startsCall: false)) })
            contextChip
                .padding(.leading, 2)
        }
        .padding(.leading, -11)
        .fixedSize()
    }

    private func chipIDs(_ count: Int) -> [String] {
        var ids = Array(ranking.ids.prefix(count))
        if let callType, !ids.contains(callType) {
            ids = [callType] + ids.prefix(max(count - 1, 0))
        }
        return ids
    }

    /// A ring marks the type Calla picked; a faint ring around every chip says
    /// "pick one" when it is not sure.
    private func ringTint(for id: String) -> Color? {
        if id == callType, chosenType == nil { return NotchAccent.call.opacity(0.75) }
        if callType == nil { return Color.white.opacity(0.2) }
        return nil
    }

    /// One chip for the type in use, which opens the picker. For a rail whose
    /// other end is a fix, where three chips would not fit.
    private var currentTypeChip: some View {
        CallTypeChip(title: callType.map(CallaCopilotPersona.title) ?? "Call type",
                     selected: callType != nil,
                     chevron: true,
                     action: { open(.picker(startsCall: false)) })
            .padding(.leading, -11)
    }

    private func hover(_ id: String, _ inside: Bool) {
        if inside { hoveredType = id } else if hoveredType == id { hoveredType = nil }
    }

    private func open(_ next: Surface) {
        hoveredType = nil
        query = ""
        withAnimation(.easeOut(duration: 0.14)) { surface = next }
    }

    private func close() {
        hoveredType = nil
        query = ""
        withAnimation(.easeOut(duration: 0.14)) { surface = .tab }
    }

    // MARK: - The picker

    private func picker(startsCall: Bool) -> some View {
        let entries = filteredEntries
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(NotchAccent.call)
                    .frame(width: 7, height: 7)
                Text((startsCall ? "Start as" : "Call type").uppercased())
                    .font(Self.caps)
                    .tracking(0.7)
                    .foregroundStyle(Color.white.opacity(0.84))
                    .fixedSize()
                TextField(meeting.map { "for \($0.title) · type to find" } ?? "Type to find one", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(NotchInk.primary)
                    .focused($queryFocused)
                    .onSubmit {
                        if let first = entries.first { pick(first.id, startsCall: startsCall) }
                    }
                if meetingRepeats, let meeting {
                    CallaHeaderTextButton(
                        title: forEveryOccurrence ? "Every \(meeting.title)" : "Just this one",
                        tint: NotchAccent.call,
                        symbol: "chevron.up.chevron.down",
                        help: "Keep this type for every occurrence of the meeting, or only this one"
                    ) {
                        forEveryOccurrence.toggle()
                    }
                    .frame(maxWidth: 160)
                }
                CallaHeaderTextButton(title: "esc", help: "Back") { close() }
                    .keyboardShortcut(.cancelAction)
            }
            .frame(height: 24)

            ScrollView(.vertical) {
                VStack(spacing: 2) {
                    ForEach(entries, id: \.id) { entry in
                        CallTypeRow(title: CallaCopilotPersona.title(entry.id),
                                    reason: rowReason(entry),
                                    band: entry.band.label,
                                    selected: entry.id == callType,
                                    picked: entry.id == ranking.pick,
                                    action: { pick(entry.id, startsCall: startsCall) },
                                    hover: { inside in hover(entry.id, inside) })
                    }
                    if entries.isEmpty {
                        Text("No call type is called that.")
                            .font(.system(size: 12))
                            .foregroundStyle(NotchInk.secondary)
                            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                            .padding(.horizontal, 10)
                    }
                }
            }
            .scrollIndicators(.automatic)
            .padding(.horizontal, -10)
        }
        .onAppear { queryFocused = true }
        .onExitCommand { close() }
    }

    private var filteredEntries: [CallTypeRanker.Entry] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return ranking.entries }
        return ranking.entries.filter { CallaCopilotPersona.title($0.id).localizedCaseInsensitiveContains(text) }
    }

    /// Why it ranks where it does; under the pointer, what it listens for.
    private func rowReason(_ entry: CallTypeRanker.Entry) -> String {
        if hoveredType == entry.id || entry.reason == nil {
            return "listens for \(CallaCopilotPersona.listensFor(entry.id))"
        }
        return entry.reason ?? ""
    }

    private func pick(_ id: String, startsCall: Bool) {
        choose(id)
        close()
        if startsCall { beginCall(id) }
    }

    private var meetingRepeats: Bool {
        guard let meeting, meeting.hasRecurrenceRules, let series = meeting.seriesID else { return false }
        return !series.isEmpty
    }

    // MARK: - Today's calls

    private var todayList: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(NotchAccent.call)
                    .frame(width: 7, height: 7)
                Text(todayLabel.uppercased())
                    .font(Self.caps)
                    .tracking(0.7)
                    .foregroundStyle(Color.white.opacity(0.84))
                    .fixedSize()
                Text("A ring is Calla's guess. Joining confirms it.")
                    .font(.system(size: 12))
                    .foregroundStyle(NotchInk.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                CallaHeaderTextButton(title: "esc", help: "Back") { close() }
                    .keyboardShortcut(.cancelAction)
            }
            .frame(height: 24)

            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(calendarManager.upcomingCallMeetings.prefix(10)) { event in
                        meetingRow(event)
                    }
                }
            }
            .padding(.horizontal, -10)
        }
        .onExitCommand { close() }
    }

    private func meetingRow(_ event: EventModel) -> some View {
        let selected = event.id == meeting?.id
        return HStack(spacing: 12) {
            Button {
                calendarManager.selectCallMeeting(event)
                close()
            } label: {
                HStack(spacing: 12) {
                    Text(Calendar.current.isDateInToday(event.start)
                         ? event.start.formatted(date: .omitted, time: .shortened)
                         : event.start.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                        .font(.system(size: 12.5, design: .rounded).monospacedDigit())
                        .foregroundStyle(selected ? NotchAccent.call : Color.white.opacity(0.76))
                        .frame(width: 70, alignment: .leading)
                    Text(event.title.isEmpty ? "Calendar meeting" : event.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(NotchInk.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Get ready for this call")
            MeetingTypeMenu(event: event, categories: categories)
            if selected {
                CallaHeaderGlyphButton(symbol: "xmark", help: "Not now: dismiss this meeting") {
                    calendarManager.dismissCallMeeting()
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.white.opacity(selected ? 0.07 : 0)))
    }

    // MARK: - Starting

    private func start() {
        guard let type = callType else {
            open(.picker(startsCall: true))
            return
        }
        beginCall(type)
    }

    private func beginCall(_ type: String) {
        guard !vpnStarting else { return }
        let selectedMeeting = meeting
        // Starting confirms the type that was on screen, so the next
        // occurrence of a repeating meeting starts the same way.
        if let selectedMeeting {
            categories.save(type, for: selectedMeeting, occurrenceOnly: !forEveryOccurrence)
        } else {
            persona = type
        }
        let selectedCallModel = liveModel
        let selectedNotes = callPackSelection
        vpnStarting = true
        Task { @MainActor in
            await callVPN.prepareForCall()
            vpnStarting = false
            openAndStartCall(meeting: selectedMeeting, persona: type,
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

    private func meetingTimer(_ event: EventModel) -> String {
        let seconds = Int(abs(event.start.timeIntervalSince(now)))
        let clock = String(format: "%02d:%02d", seconds / 60, seconds % 60)
        return event.start > now ? "in \(clock)" : "+\(clock)"
    }

    // MARK: - Notes

    private var applicableKnowledge: [CallaKnowledgeNote] {
        let type = callType ?? "generic"
        return library.notes.filter { note in
            note.scope == "always" || (note.scope == "persona" && note.scopeKey == type)
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
        .help("Notes Calla will use on this call")
        .accessibilityLabel("Notes, \(selectedKnowledgeNoteIDs.count) selected")
    }
}

// MARK: - Pieces

/// One call type on the rail: text on the slab, a lift when it is the one in use.
private struct CallTypeChip: View {
    let title: String
    var selected = false
    var ring: Color?
    var ink: Color?
    var chevron = false
    let action: () -> Void
    var hover: (Bool) -> Void = { _ in }

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
                if chevron {
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .heavy))
                }
            }
            .foregroundStyle(ink ?? (selected || hovering ? NotchInk.primary : Color.white.opacity(0.76)))
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(Capsule().fill(Color.white.opacity(selected ? 0.14 : (hovering ? 0.08 : 0))))
            .overlay {
                if let ring { Capsule().strokeBorder(ring, lineWidth: 1) }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovering = inside
            hover(inside)
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel(title)
    }
}

/// One row of the picker: the name, why it ranks there, and how likely it is.
private struct CallTypeRow: View {
    let title: String
    let reason: String
    let band: String?
    let selected: Bool
    /// Calla's pick: ringed, and its band in the accent.
    let picked: Bool
    let action: () -> Void
    let hover: (Bool) -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(NotchInk.primary)
                    .lineLimit(1)
                    .frame(width: 118, alignment: .leading)
                Text(reason)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let band {
                    Text(band)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(picked ? NotchAccent.call : Color.white.opacity(0.66))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(selected ? 0.14 : (hovering ? 0.08 : 0))))
            .overlay {
                if picked {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(NotchAccent.call.opacity(0.75), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovering = inside
            hover(inside)
        }
        .accessibilityLabel([title, band, reason].compactMap { $0 }.joined(separator: ", "))
    }
}

/// The type of one meeting in today's list, as a menu in ranked order.
private struct MeetingTypeMenu: View {
    let event: EventModel
    @ObservedObject var categories: MeetingCategoryStore

    @State private var hovering = false

    var body: some View {
        let ranking = categories.ranking(for: event)
        let confirmed = categories.confirmed(for: event)
        let current = confirmed ?? ranking.pick
        Menu {
            ForEach(ranking.entries, id: \.id) { entry in
                Button {
                    categories.save(entry.id, for: event)
                } label: {
                    let title = CallaCopilotPersona.title(entry.id)
                    if entry.id == current {
                        Label(title, systemImage: "checkmark")
                    } else {
                        Text(entry.band.label.map { "\(title) · \($0)" } ?? title)
                    }
                }
            }
        } label: {
            Text(current.map(CallaCopilotPersona.title) ?? "Choose…")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(current == nil ? NotchAccent.call : NotchInk.primary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        // Outside the label: a borderless menu draws its own chrome over it.
        .background(Capsule().fill(Color.white.opacity(hovering ? 0.12 : 0.06)))
        .overlay {
            if confirmed == nil, current != nil {
                Capsule().strokeBorder(NotchAccent.call.opacity(0.75), lineWidth: 1).allowsHitTesting(false)
            }
        }
        .onHover { hovering = $0 }
        .help("Call type for this meeting")
    }
}

/// A quiet one-line text button for a Calla header: "3 today", "esc", a scope.
struct CallaHeaderTextButton: View {
    let title: String
    var tint: Color = Color.white.opacity(0.76)
    var symbol: String?
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 8, weight: .heavy))
                }
            }
            .foregroundStyle(hovering ? NotchInk.primary : tint)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(Capsule().fill(Color.white.opacity(hovering ? 0.10 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(title)
    }
}
