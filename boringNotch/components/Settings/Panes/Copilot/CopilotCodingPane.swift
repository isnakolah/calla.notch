//
//  CopilotCodingPane.swift
//  boringNotch
//

import AppKit
import CallaContracts
import Defaults
import SwiftUI

/// Live Coding's home.
///
/// The mode had no page at all: its whole preflight lived in the notch, on a
/// hundred-point surface that could not hold it, and was asked for thirty
/// seconds before the interview. Everything it needs is known when the
/// interview is booked, so it belongs here — and per-meeting, in Knowledge,
/// beside that meeting's notes.
///
/// This page owns the default: the project a Code session uses when it is not
/// tied to a meeting. It also lists what *is* tied to one, because a setup
/// nobody can see they made is a setup nobody trusts, and shows the sessions
/// the engine is still holding on disk.
struct CopilotCodingPane: View {
    @ObservedObject private var engine = CallaEngineClient.shared
    @ObservedObject private var library = CallaKnowledgeLibrary.shared
    @ObservedObject private var setups = CallaCodingSetupStore.shared
    @Environment(\.settingsRouter) private var router

    @Default(.callaCodingProfile) private var profile
    @State private var draft = CallaCodingSetup(scope: "always")
    @State private var dirty = false
    @State private var availableModels: [String] = []
    @State private var loadingModels = false
    @State private var modelCatalogError: String?
    @State private var problem: String?
    @State private var preparing = false
    @State private var preparationReport: String?

    private var coding: CodingSessionSnapshot { engine.coding }

    var body: some View {
        SettingsPane(.copilotCoding) {
            if let problem { problemCard(problem) }
            stateCard
            defaultCard
            perMeetingCard
            modelsCard
            retainedCard
            disclosureCard
        }
        .task {
            load()
            refreshModels()
            engine.fetchRetainedCodingSessions()
            if library.events.isEmpty { await library.load() }
        }
    }

    // MARK: - Models

    /// Which model answers each lane.
    ///
    /// Live Coding ran every lane on one hardcoded model while Quiz had per-role
    /// model and effort control. The three lanes want opposite things: the move
    /// lane is what the candidate waits on mid-sentence, and the edit lane is
    /// doing real work nobody is watching the clock on. One setting for both is
    /// how a copilot ends up either slow or careless.
    private var modelsCard: some View {
        SettingCard("Models") {
            VStack(alignment: .leading, spacing: NotchSpace.tight) {
                if let modelCatalogError { Text(modelCatalogError).font(.caption).foregroundStyle(.secondary) }
                laneRow(
                    "Move",
                    detail: "The next step, while you are still talking. Keep this fast.",
                    selection: profile.move) { profile.move = $0 }
                Divider()
                laneRow(
                    "Plan",
                    detail: "Reads the workspace and restates where the work stands.",
                    selection: profile.plan) { profile.plan = $0 }
                Divider()
                laneRow(
                    "Edit",
                    detail: "Writes in the shadow project. Slow is fine here.",
                    selection: profile.edit) { profile.edit = $0 }
                Divider()
                HStack {
                    Text("Named presets include their thinking level.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(loadingModels ? "Refreshing…" : "Refresh models") { refreshModels() }.disabled(loadingModels)
                    Button("Reset") { profile = .standard }
                        .disabled(profile == .standard)
                }
            }
        }
    }

    private func laneRow(_ title: String, detail: String,
                         selection: CodingModelSelection,
                         update: @escaping (CodingModelSelection) -> Void) -> some View {
        SettingRow(title, detail: detail) {
            HStack(spacing: 8) {
                Picker("", selection: Binding(
                    get: { selection.modelID },
                    set: { update(CodingModelSelection(modelID: $0, effort: selection.effort)) })) {
                    ForEach(modelChoices(including: selection.modelID), id: \.self) {
                        Text($0).tag($0)
                    }
                }
                .labelsHidden()
                .frame(width: 190)

                if selection.presetEffort == nil {
                Picker("", selection: Binding(
                    get: { selection.effort },
                    set: { update(CodingModelSelection(modelID: selection.modelID, effort: $0)) })) {
                    ForEach(["low", "medium", "high"], id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 90)
                }
            }
        }
    }

    /// The ids `agy` exposes, plus whatever is already selected so a model the
    /// catalogue has since dropped never silently disappears from the picker.
    private func modelChoices(including current: String) -> [String] {
        availableModels.contains(current) ? availableModels : [current] + availableModels
    }

    private func refreshModels() {
        guard !loadingModels else { return }
        loadingModels = true; modelCatalogError = nil
        engine.listQuizModels { models in
            loadingModels = false
            if models.isEmpty { modelCatalogError = "Model catalog unavailable. Your current selections are retained; refresh to retry." }
            else { availableModels = models }
        }
    }

    // MARK: - Right now

    private var stateCard: some View {
        SettingCard("Right now", tint: coding.lifecycle.active ? NotchTint.healthy : nil) {
            VStack(alignment: .leading, spacing: NotchSpace.tight) {
                SettingRow(stateTitle, detail: stateDetail) { EmptyView() }
                if let failure = coding.failure {
                    Text(failure.recovery ?? failure.message)
                        .font(NotchType.rowDetail)
                        .foregroundStyle(NotchTint.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var stateTitle: String {
        switch coding.lifecycle {
        case .preparing: "Preparing the shadow project"
        case .ready: "Ready, waiting for the call"
        case .capturing: "Interview running"
        case .stopping: "Stopping"
        case .interrupted: "Interrupted"
        case .failed: "Last session failed"
        case .finished: "Nothing running"
        }
    }

    private var stateDetail: String {
        guard coding.lifecycle.active else {
            return "Start a Code session from the notch. Nothing is copied until you do."
        }
        var parts: [String] = []
        if let revision = coding.sourceRevision { parts.append("revision \(revision.prefix(10))") }
        parts.append(coding.syncState.rawValue)
        if let model = coding.model { parts.append(model) }
        return parts.joined(separator: " · ")
    }

    // MARK: - The interview's project

    /// Reads the schedule from `WaveInterview` rather than repeating it. The
    /// literal "7 September, 12:00–14:00 Nairobi" used to live in this label,
    /// which is one more place to forget when the sitting moves.
    private var waveScheduleLabel: String {
        let day = WaveInterview.startsAt.formatted(.dateTime.weekday(.wide).day().month(.wide))
        var clock = Date.FormatStyle.dateTime.hour().minute()
        clock.timeZone = TimeZone(identifier: "Africa/Nairobi") ?? .gmt
        return "\(WaveInterview.title) · \(day), "
            + "\(WaveInterview.startsAt.formatted(clock))–\(WaveInterview.endsAt.formatted(clock)) Nairobi"
    }

    private var defaultCard: some View {
        SettingCard(
            waveScheduleLabel,
            detail: "The project a session runs against. Change it freely to try a scenario — every session is still a session of the same interview.",
            tint: draft.hasFolder ? NotchTint.healthy : nil
        ) {
            VStack(alignment: .leading, spacing: 12) {
                folderRow
                WaveWindowPicker(target: $draft.observationTarget)
                    .onChange(of: draft.observationTarget) { _, _ in dirty = true }
                Group {
                    Text("Put the supplied files in the project folder, then Prepare. It reads whatever is there.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button(preparing ? "Preparing…" : "Prepare") {
                            guard let bookmark = draft.folderBookmark else { return }
                            setups.save(draft); dirty = false; preparing = true
                            engine.prepareWave(.init(projectBookmark: bookmark)) { result in
                                preparing = false
                                problem = result?.failure ?? (result == nil ? "Preparation did not reply." : nil)
                                preparationReport = result?.report
                            }
                        }.disabled(preparing || !draft.hasFolder || coding.lifecycle.active)
                    }
                    if let preparationReport { Text(preparationReport).font(.caption).textSelection(.enabled) }
                    HStack {
                        Text("Wave transparency")
                        Slider(value: Binding(get: { Defaults[.waveGlassLevel] }, set: { Defaults[.waveGlassLevel] = $0 }), in: 0...1)
                        Button("Reset size") { NotchSizePreferences.reset(.wave) }
                    }
                }
                TextField("What the interview is — “Wave, part 2”", text: $draft.briefTitle)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: draft.briefTitle) { _, _ in dirty = true }

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        briefList("What they are grading",
                                  placeholder: "Simple extensible design\nClean interfaces",
                                  keyPath: \.rubric)
                        briefList("Task order",
                                  placeholder: "Cell references\nLiterals",
                                  keyPath: \.taskOrdering)
                    }
                    GridRow {
                        briefList("Provided for you",
                                  placeholder: "Provided parser\nRange interfaces",
                                  keyPath: \.suppliedInterfaces)
                        briefList("Not worth the time",
                                  placeholder: "Date operations",
                                  keyPath: \.depriorities)
                    }
                }
                briefList("Constraints", placeholder: "No third-party packages", keyPath: \.constraints)

                HStack(spacing: 8) {
                    if setups.fallback != nil {
                        Button("Remove default", role: .destructive) {
                            setups.remove(scope: "always", scopeKey: nil)
                            load()
                        }
                        .controlSize(.small)
                    }
                    Spacer(minLength: 0)
                    if dirty {
                        Text("Not saved")
                            .font(NotchType.rowDetail)
                            .foregroundStyle(NotchTint.attention)
                    }
                    Button("Save") {
                        draft.scope = "always"
                        draft.scopeKey = nil
                        setups.save(draft)
                        dirty = false
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!dirty)
                }
            }
        }
    }

    private var folderRow: some View {
        HStack(spacing: 10) {
            Image(systemName: draft.hasFolder ? "folder.fill" : "folder.badge.plus")
                .font(.system(size: 14))
                .foregroundStyle(draft.hasFolder ? Color.accentColor : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(draft.hasFolder ? draft.folderName : "No project folder")
                    .font(NotchType.rowTitle)
                    .lineLimit(1)
                Text(draft.hasFolder
                     ? draft.folderSummary
                     : "Choose \(WaveInterview.defaultProjectFolder.path). "
                        + "Boring works on a shadow copy; your own files are never edited.")
                    .font(NotchType.rowDetail)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(draft.hasFolder ? "Change…" : "Choose…") { chooseFolder() }
                .controlSize(.small)
            if draft.hasFolder {
                Button {
                    draft.folderBookmark = nil
                    draft.folderName = ""
                    draft.folderPath = ""
                    dirty = true
                } label: {
                    Image(systemName: "trash")
                }
                .controlSize(.small)
                .help("Forget this folder")
            }
        }
    }

    private func briefList(_ title: String, placeholder: String,
                           keyPath: WritableKeyPath<CallaCodingSetup, [String]>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(NotchType.rowDetail).foregroundStyle(.secondary)
            PromptEditor(
                text: Binding(
                    get: { draft[keyPath: keyPath].joined(separator: "\n") },
                    set: { value in
                        draft[keyPath: keyPath] = value
                            .split(separator: "\n", omittingEmptySubsequences: true)
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        dirty = true
                    }),
                placeholder: placeholder,
                minHeight: 62)
        }
    }

    // MARK: - Per meeting

    /// The setups filed against a meeting, and the way back to the page that
    /// made them. Editing happens there, beside that meeting's notes, so there
    /// is exactly one place a meeting's preparation lives.
    private var perMeetingCard: some View {
        let attached = setups.setups.filter { $0.scope != "always" }
        return SettingCard(
            "Prepared meetings",
            detail: attached.isEmpty
                ? "Attach a project to a meeting from Knowledge, and Code resolves it when that meeting comes round."
                : "Each of these wins over the default when its meeting is the one selected."
        ) {
            if attached.isEmpty {
                if let router {
                    Button("Open Knowledge") { router.push(.copilotKnowledge) }
                        .controlSize(.small)
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(attached.enumerated()), id: \.element.id) { index, setup in
                        meetingRow(setup)
                        if index < attached.count - 1 {
                            Divider().opacity(0.35).padding(.leading, 32)
                        }
                    }
                }
            }
        }
    }

    private func meetingRow(_ setup: CallaCodingSetup) -> some View {
        HStack(spacing: 10) {
            Image(systemName: setup.scope == "series" ? "repeat" : "calendar")
                .font(.system(size: 13))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(meetingTitle(setup)).font(NotchType.rowTitle).lineLimit(1)
                Text([setup.hasFolder ? setup.folderName : "no folder",
                      setup.briefTitle.isEmpty ? nil : setup.briefTitle,
                      setup.scopeLabel].compactMap { $0 }.joined(separator: " · "))
                    .font(NotchType.rowDetail)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let router, let route = knowledgeRoute(setup) {
                Button("Edit") { router.push(.copilotKnowledgeDetail(route)) }
                    .controlSize(.small)
            }
            Button {
                setups.remove(scope: setup.scope, scopeKey: setup.scopeKey)
            } label: {
                Image(systemName: "trash")
            }
            .controlSize(.small)
            .help("Remove this setup")
        }
        .padding(.vertical, 7)
    }

    /// The meeting's own name where the calendar still has it, and the id where
    /// it does not — a series whose occurrences have all passed still applies to
    /// the next one, so it is listed rather than hidden.
    private func meetingTitle(_ setup: CallaCodingSetup) -> String {
        guard let key = setup.scopeKey else { return "Any Code session" }
        if let event = library.events.first(where: {
            setup.scope == "series" ? $0.seriesID == key : $0.id == key
        }) { return event.title }
        return "Not on your calendar any more"
    }

    private func knowledgeRoute(_ setup: CallaCodingSetup) -> KnowledgeRoute? {
        guard let key = setup.scopeKey else { return .everyCall }
        if setup.scope == "event" { return .event(id: key) }
        guard let event = library.events.first(where: { $0.seriesID == key }) else { return nil }
        return .event(id: event.id)
    }

    // MARK: - Retained sessions

    private var retainedCard: some View {
        SettingCard(
            "Kept sessions",
            detail: "Each is an encrypted copy of the shadow project and everything the model said about it. They are kept until you delete them."
        ) {
            if engine.retainedCodingSessions.isEmpty {
                Text("Nothing kept.")
                    .font(NotchType.rowDetail)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(engine.retainedCodingSessions.enumerated()), id: \.element.id) { index, session in
                        retainedRow(session)
                        if index < engine.retainedCodingSessions.count - 1 {
                            Divider().opacity(0.35).padding(.leading, 32)
                        }
                    }
                }
            }
        }
    }

    private func retainedRow(_ session: CodingRetainedSession) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.folderName).font(NotchType.rowTitle).lineLimit(1)
                Text([session.startedAt.formatted(date: .abbreviated, time: .shortened),
                      "^[\(session.moveCount) move](inflect: true)",
                      session.lifecycle.rawValue].joined(separator: " · "))
                    .font(NotchType.rowDetail)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(role: .destructive) {
                engine.deleteCodingSession(session.sessionID)
            } label: {
                Image(systemName: "trash")
            }
            .controlSize(.small)
            .help("Delete this session and its shadow copy")
        }
        .padding(.vertical, 7)
    }

    // MARK: - What leaves the Mac

    /// Said once, here, rather than as three lines of small print on the notch.
    /// Live Coding sends more off the machine than any other mode, and the notch
    /// was the wrong place to explain that: nobody reads a disclosure thirty
    /// seconds before an interview.
    private var disclosureCard: some View {
        SettingCard("What leaves this Mac", tint: NotchTint.attention) {
            VStack(alignment: .leading, spacing: NotchSpace.tight) {
                SettingRow("Raw audio stays here", detail: "Only the transcript is used, and it is produced on this Mac.") { EmptyView() }
                SettingRow("Code, diffs and test output go to agy", detail: "Opened files, the diff against the shadow copy, and the output of any check you run are sent to the Google-backed model that answers.") { EmptyView() }
                SettingRow("Commands may reach the network", detail: "A check the model proposes runs inside the shadow copy, but a command that fetches packages can still transmit what it is building.") { EmptyView() }
            }
        }
    }

    private func problemCard(_ text: String) -> some View {
        SettingCard(tint: NotchTint.attention) {
            Text(text).font(NotchType.rowDetail).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Plumbing

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use for Live Coding"
        // Opens where the work is. The sandbox will not let the app attach a
        // folder on its own, so this is as close to a default as it gets: the
        // reader confirms the folder that is already selected.
        let expected = WaveInterview.defaultProjectFolder
        if FileManager.default.fileExists(atPath: expected.path) {
            panel.directoryURL = expected
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bookmark = setups.bookmark(for: url) else {
            problem = "That folder could not be kept for later. Try one inside your home folder."
            return
        }
        problem = nil
        draft.folderBookmark = bookmark
        draft.folderName = url.lastPathComponent
        draft.folderPath = url.path
        dirty = true
    }

    /// Loads the interview's own setup, and fills the brief in from the
    /// published spec the first time there is nothing in it.
    ///
    /// This card used to edit the `always` row — "what a Code session uses when
    /// it is not tied to a meeting". There is only one meeting now, so it edits
    /// that meeting's row, falling back to whatever was already prepared so a
    /// project set up before the change is still here.
    private func load() {
        draft = setups.setup(scope: WaveInterview.setupScope,
                             scopeKey: WaveInterview.setupScopeKey)
            ?? setups.fallback
            ?? CallaCodingSetup(scope: WaveInterview.setupScope,
                                scopeKey: WaveInterview.setupScopeKey)
        draft.scope = WaveInterview.setupScope
        draft.scopeKey = WaveInterview.setupScopeKey
        let before = draft
        draft.applyPublishedBriefIfEmpty()
        // Offered, not imposed: it is on screen as editable text and is only
        // written to disk when the reader saves, or when something else does.
        dirty = draft != before
    }
}
