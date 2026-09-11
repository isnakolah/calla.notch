import AppKit
import Defaults
import SwiftUI
import UniformTypeIdentifiers

/// One meeting's page: what it has, and how to give it more.
///
/// The whole editing surface lives here rather than in the list, which is what
/// lets the list stay scannable. Same three ways in as the notch — drag, choose,
/// type — because someone who learned it there should not have to learn it again.
struct CopilotKnowledgeDetailPane: View {
    let route: KnowledgeRoute

    @StateObject private var library = CallaKnowledgeLibrary.shared
    @ObservedObject private var attach = CallaKnowledgeAttach.shared
    @Default(.callaCopilotPersona) private var persona

    @StateObject private var codingSetups = CallaCodingSetupStore.shared
    @State private var scope: String = "series"
    @State private var codingDraft = CallaCodingSetup(scope: "always")
    @State private var codingDirty = false
    @State private var isTargeted = false
    @State private var draft = ""
    @State private var draftTitle = ""
    @State private var viewing: CallaKnowledgeNote?
    @State private var problem: String?

    private var event: EventModel? {
        guard case let .event(id) = route else { return nil }
        return library.events.first { $0.id == id }
    }

    private var notes: [CallaKnowledgeNote] {
        switch route {
        case .event:
            guard let event else { return [] }
            return library.notes(for: event).sorted { $0.updatedAt > $1.updatedAt }
        case .waveInterview:
            return library.notes.filter {
                $0.scope == "series" && $0.scopeKey == WaveInterview.seriesID
                    || $0.scope == "event" && $0.scopeKey == WaveInterview.eventID
            }.sorted { $0.updatedAt > $1.updatedAt }
        case .everyCall:
            return library.notes(scope: "always").sorted { $0.updatedAt > $1.updatedAt }
        case .byPersona:
            return library.notes(scope: "persona").sorted { $0.updatedAt > $1.updatedAt }
        case .orphaned:
            return library.orphanedNotes.sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    /// Where anything added on this page goes.
    private var target: KnowledgeTarget {
        switch route {
        case .event:
            guard let event else { return .everyCall }
            let choices = KnowledgeTarget.choices(for: event)
            return choices.first { $0.scope == scope } ?? choices.first ?? .everyCall
        case .waveInterview:
            return .waveInterview
        case .byPersona:
            return KnowledgeTarget(
                kind: .persona(id: persona),
                title: "Every \(CallaCopilotPersona.title(persona)) call",
                detail: "Only that persona")
        default:
            return .everyCall
        }
    }

    private var canAdd: Bool {
        switch route {
        // By-persona is addable now that it files under the persona scope it
        // claims. It is the answer to "the copilot should know my CV on every
        // interview but not on a support call".
        case .event, .waveInterview, .everyCall, .byPersona: true
        case .orphaned: false
        }
    }

    var body: some View {
        SettingsPane(SettingsPage.copilotKnowledgeDetail(route), titleOverride: title) {
            if let problem { problemCard(problem) }
            if case .event = route, event == nil {
                SettingCard {
                    Text("This meeting is no longer on your calendar. Anything attached to it is under “Not on your calendar any more”.")
                        .font(NotchType.rowDetail)
                        .foregroundStyle(.secondary)
                }
            }
            if canAdd { addCard }
            if CallaFeatureAvailability.liveCoding && showsCodingSetup { codingCard }
            contentsCard
            if let viewing { viewerCard(viewing) }
        }
        .task {
            if library.events.isEmpty { await library.load() }
            if let event, event.seriesID == nil || !event.hasRecurrenceRules { scope = "event" }
            loadCodingDraft()
        }
        .onChange(of: scope) { _, _ in loadCodingDraft() }
        .onReceive(NotificationCenter.default.publisher(for: .callaKnowledgeDidChange)) { _ in
            Task { await library.load() }
        }
    }

    // MARK: - Titles

    private var eyebrow: String {
        switch route {
        case .event: "Meeting"
        case .waveInterview: "Interview"
        case .everyCall, .byPersona: "Call copilot"
        case .orphaned: "Needs attention"
        }
    }

    private var title: String {
        switch route {
        case .event: event?.title ?? "This meeting"
        case .waveInterview: WaveInterview.title
        case .everyCall: "Every call"
        case .byPersona: "By kind of call"
        case .orphaned: "Not on your calendar any more"
        }
    }

    private var detail: String? {
        switch route {
        case .event:
            guard let event else { return nil }
            let when = event.start.formatted(date: .abbreviated, time: .shortened)
            let calls = library.callCount(for: event)
            var parts = [when]
            if event.hasRecurrenceRules { parts.append("repeats") }
            if calls > 0 { parts.append("\(calls) call\(calls == 1 ? "" : "s") recorded") }
            return parts.joined(separator: " · ")
        case .waveInterview:
            let when = WaveInterview.startsAt.formatted(date: .abbreviated, time: .shortened)
            return "\(when) · in front of the copilot in every session of it."
        case .everyCall:
            return "Read at the start of every call, whatever the meeting is about."
        case .byPersona:
            return "Applies when the copilot is set to that persona. Add these from the Prompts pane."
        case .orphaned:
            return "Still stored, and still applied if the meeting reappears."
        }
    }

    // MARK: - Adding

    private var addCard: some View {
        SettingCard("Add something") {
            VStack(alignment: .leading, spacing: 12) {
                if case .event = route, let event, event.hasRecurrenceRules, event.seriesID != nil {
                    Picker("", selection: $scope) {
                        Text("Every repeat").tag("series")
                        Text("Just this one").tag("event")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 260)
                }

                HStack(alignment: .top, spacing: 12) {
                    dropZone
                    VStack(alignment: .leading, spacing: 7) {
                        TextField("Title", text: $draftTitle)
                            .textFieldStyle(.roundedBorder)
                        PromptEditor(
                            text: $draft,
                            placeholder: "They churned on latency last quarter. Dana signs the renewal.",
                            minHeight: 74)
                        HStack {
                            Spacer(minLength: 0)
                            Button("Add note") { commitDraft() }
                                .controlSize(.small)
                                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }

                if let status = attach.status {
                    Label(status, systemImage: "checkmark.circle.fill")
                        .font(NotchType.rowDetail)
                        .foregroundStyle(NotchTint.healthy)
                }
            }
        }
    }

    private var dropZone: some View {
        VStack(spacing: 7) {
            Image(systemName: attach.isWorking ? "hourglass" : "doc.badge.plus")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
            Text(attach.isWorking ? "Reading…" : "Drop a file")
                .font(.system(size: 11.5, weight: .semibold))
            Text("PDF, Word, Pages export, plain text or a scan")
                .font(NotchType.rowDetail)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Choose…") { attach.attachChosenFiles(to: target) }
                .controlSize(.small)
                .disabled(attach.isWorking)
        }
        .padding(.horizontal, 12)
        .frame(width: 210)
        .frame(minHeight: 148)
        .background(
            RoundedRectangle(cornerRadius: NotchRadius.control, style: .continuous)
                .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.03)))
        .overlay(
            RoundedRectangle(cornerRadius: NotchRadius.control, style: .continuous)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.28),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            Task {
                guard await attach.accept(providers) else {
                    problem = "That is not a kind of file the copilot can read."
                    return
                }
                problem = nil
                await attach.commitPending(to: target)
                await library.load()
            }
            return true
        }
    }

    private func commitDraft() {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let heading = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""; draftTitle = ""
        Task {
            await attach.attach(text: body, title: heading.isEmpty ? target.title : heading, to: target)
            await library.load()
        }
    }

    // MARK: - Live Coding

    /// Live Coding's whole preflight, moved off the notch.
    ///
    /// The notch had been asking for the project folder and the interview brief
    /// thirty seconds before the call, through an `NSOpenPanel` and a text field
    /// on a surface with room for neither — so the Start button was drawn
    /// through the notch's lower curve. Both facts are known when the interview
    /// is booked, and this is where the rest of a meeting's preparation already
    /// lives, so they belong here. The notch then resolves what was prepared and
    /// offers one button.
    private var showsCodingSetup: Bool {
        switch route {
        case .event, .waveInterview, .everyCall: true
        case .byPersona, .orphaned: false
        }
    }

    /// Which scope this page writes a setup to. Event pages follow the same
    /// picker the notes use, so a briefing document and a project folder
    /// attached on the same visit land on the same meeting.
    private var codingScope: (scope: String, key: String?) {
        switch route {
        case .waveInterview:
            return (WaveInterview.setupScope, WaveInterview.setupScopeKey)
        case .event:
            guard let event else { return ("always", nil) }
            if scope == "series", let seriesID = event.seriesID, !seriesID.isEmpty {
                return ("series", seriesID)
            }
            return ("event", event.id)
        default:
            return ("always", nil)
        }
    }

    private var codingCard: some View {
        SettingCard(
            "Live Coding",
            detail: codingDraft.hasFolder
                ? "The notch resolves this and offers Start. Nothing is copied until you press it."
                : "Attach the project and the brief now, and Code becomes one button in the notch.",
            tint: codingDraft.hasFolder ? NotchTint.healthy : nil
        ) {
            VStack(alignment: .leading, spacing: 12) {
                folderRow
                WaveWindowPicker(target: $codingDraft.observationTarget)
                    .onChange(of: codingDraft.observationTarget) { _, _ in codingDirty = true }
                // No profile toggle. Every session is the Wave interview, and a
                // toggle that was off started the same session without its
                // context pack or its two-hour budget.
                WavePreparationControls(setup: codingDraft, save: { saveCodingDraft() })

                TextField("What the interview is — “Wave, part 2”",
                          text: $codingDraft.briefTitle)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: codingDraft.briefTitle) { _, _ in codingDirty = true }

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        briefList("What they are grading",
                                  placeholder: "Simple extensible design\nClean interfaces\nThoughtful edge cases",
                                  keyPath: \.rubric)
                        briefList("Task order",
                                  placeholder: "Cell references\nLiterals\nBinary operators",
                                  keyPath: \.taskOrdering)
                    }
                    GridRow {
                        briefList("Provided for you",
                                  placeholder: "Provided parser\nRange interfaces",
                                  keyPath: \.suppliedInterfaces)
                        briefList("Not worth the time",
                                  placeholder: "Date operations\nSecondary functions",
                                  keyPath: \.depriorities)
                    }
                }

                briefList("Constraints", placeholder: "No third-party packages", keyPath: \.constraints)

                Text("One per line. The brief is frozen when the session starts, so a note added mid-interview is not smuggled in behind the interviewer.")
                    .font(NotchType.rowDetail)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    if codingSetups.setup(scope: codingScope.scope, scopeKey: codingScope.key) != nil {
                        Button("Remove setup", role: .destructive) {
                            codingSetups.remove(scope: codingScope.scope, scopeKey: codingScope.key)
                            loadCodingDraft()
                        }
                        .controlSize(.small)
                    }
                    Spacer(minLength: 0)
                    if codingDirty {
                        Text("Not saved")
                            .font(NotchType.rowDetail)
                            .foregroundStyle(NotchTint.attention)
                    }
                    Button("Save setup") { saveCodingDraft() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!codingDirty)
                }
            }
        }
    }

    private var folderRow: some View {
        HStack(spacing: 10) {
            Image(systemName: codingDraft.hasFolder ? "folder.fill" : "folder.badge.plus")
                .font(.system(size: 14))
                .foregroundStyle(codingDraft.hasFolder ? Color.accentColor : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(codingDraft.hasFolder ? codingDraft.folderName : "No project folder")
                    .font(NotchType.rowTitle)
                    .lineLimit(1)
                Text(codingDraft.hasFolder
                     ? codingDraft.folderSummary
                     : "The folder the interview is written in. Boring works on a shadow copy; your own files are never edited.")
                    .font(NotchType.rowDetail)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if codingDraft.hasFolder {
                Button("Change…") { chooseFolder() }.controlSize(.small)
                Button {
                    codingDraft.folderBookmark = nil
                    codingDraft.folderName = ""
                    codingDraft.folderPath = ""
                    codingDirty = true
                } label: {
                    Image(systemName: "trash")
                }
                .controlSize(.small)
                .help("Forget this folder")
            } else {
                Button("Choose…") { chooseFolder() }.controlSize(.small)
            }
        }
    }

    private func briefList(_ title: String, placeholder: String,
                           keyPath: WritableKeyPath<CallaCodingSetup, [String]>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(NotchType.rowDetail).foregroundStyle(.secondary)
            PromptEditor(
                text: Binding(
                    get: { codingDraft[keyPath: keyPath].joined(separator: "\n") },
                    set: { value in
                        codingDraft[keyPath: keyPath] = value
                            .split(separator: "\n", omittingEmptySubsequences: true)
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        codingDirty = true
                    }),
                placeholder: placeholder,
                minHeight: 62)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use for Live Coding"
        // Same default as the Live Coding pane: open where the work is.
        let expected = WaveInterview.defaultProjectFolder
        if FileManager.default.fileExists(atPath: expected.path) {
            panel.directoryURL = expected
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bookmark = codingSetups.bookmark(for: url) else {
            problem = "That folder could not be kept for later. Try one inside your home folder."
            return
        }
        codingDraft.folderBookmark = bookmark
        codingDraft.folderName = url.lastPathComponent
        codingDraft.folderPath = url.path
        codingDirty = true
    }

    private func loadCodingDraft() {
        guard CallaFeatureAvailability.liveCoding else { return }
        let target = codingScope
        codingDraft = codingSetups.setup(scope: target.scope, scopeKey: target.key)
            ?? CallaCodingSetup(scope: target.scope, scopeKey: target.key)
        // A setup read back from a different scope still carries that scope, and
        // saving it would then move the row rather than write this page's.
        codingDraft.scope = target.scope
        codingDraft.scopeKey = target.key
        codingDirty = false
    }

    private func saveCodingDraft() {
        let target = codingScope
        codingDraft.scope = target.scope
        codingDraft.scopeKey = target.key
        codingSetups.save(codingDraft)
        codingDirty = false
    }

    // MARK: - Contents

    private var contentsCard: some View {
        SettingCard(
            "What it has",
            detail: notes.isEmpty ? nil : "Files are searched when a question needs them. Notes are in front of the copilot the whole call."
        ) {
            if notes.isEmpty {
                Text(canAdd
                     ? "Nothing yet."
                     : "Nothing here.")
                    .font(NotchType.rowDetail)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(notes.enumerated()), id: \.element.id) { index, note in
                        noteRow(note)
                        if index < notes.count - 1 { Divider().padding(.leading, 32) }
                    }
                }
            }
        }
    }

    private func noteRow(_ note: CallaKnowledgeNote) -> some View {
        HStack(spacing: 10) {
            Image(systemName: note.symbol)
                .font(.system(size: 14))
                .foregroundStyle(note.isDocument ? Color.accentColor : .secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(note.title.isEmpty ? "Untitled" : note.title)
                    .font(NotchType.rowTitle)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(note.subtitle)
                    Text("·")
                    Text(note.scopeLabel)
                    if note.isAlwaysInView {
                        Text("·")
                        Text("always in view").foregroundStyle(NotchTint.healthy)
                    }
                }
                .font(NotchType.rowDetail)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button(note.isEditable ? "Edit" : "View") { viewing = note }
                .controlSize(.small)
            Button {
                CallaEngineClient.shared.deleteKnowledge(id: note.id) { _ in
                    Task { await library.load() }
                    CallaKnowledgeFocus.shared.refresh()
                }
            } label: {
                Image(systemName: "trash")
            }
            .controlSize(.small)
            .help("Remove")
        }
        .padding(.vertical, 7)
    }

    // MARK: - Viewer

    private func viewerCard(_ note: CallaKnowledgeNote) -> some View {
        SettingCard(
            note.title.isEmpty ? "Note" : note.title,
            detail: note.isEditable
                ? nil
                : "What the copilot reads. Rebuilt from its source, so edits here would not stick.",
            tint: NotchTint.active
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if note.isEditable {
                    TextField("Title", text: bind(note, \.title))
                        .textFieldStyle(.roundedBorder)
                }
                PromptEditor(
                    text: bind(note, \.body),
                    placeholder: "",
                    minHeight: note.isEditable ? 150 : 240,
                    monospaced: !note.isEditable)
                    .disabled(!note.isEditable)
                HStack {
                    Text(note.subtitle).font(NotchType.rowDetail).foregroundStyle(.tertiary)
                    Spacer(minLength: 8)
                    Button("Close") { viewing = nil }
                        .controlSize(.small)
                    if note.isEditable {
                        Button("Save") {
                            guard let edited = viewing else { return }
                            CallaEngineClient.shared.saveKnowledge(edited) { _ in
                                viewing = nil
                                Task { await library.load() }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private func bind<T>(
        _ note: CallaKnowledgeNote,
        _ path: WritableKeyPath<CallaKnowledgeNote, T>
    ) -> Binding<T> {
        Binding(
            get: { viewing?[keyPath: path] ?? note[keyPath: path] },
            set: { viewing?[keyPath: path] = $0 })
    }

    private func problemCard(_ text: String) -> some View {
        SettingCard(tint: NotchTint.attention) {
            HStack(spacing: 10) {
                SettingStatusIcon(ok: false)
                Text(text).font(NotchType.rowDetail).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Dismiss") { problem = nil }.controlSize(.small)
            }
        }
    }
}
