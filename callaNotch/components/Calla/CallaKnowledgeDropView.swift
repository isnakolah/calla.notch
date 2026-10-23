import Defaults
import SwiftUI
import UniformTypeIdentifiers

/// One surface for giving the copilot something to read.
///
/// Two ways in and they meet here, which is the point — a drop onto the notch and
/// a right-click on a calendar event should not teach two different interfaces.
/// The only difference is which question is still open:
///
///  * dropped a file, no meeting chosen → ask which meeting;
///  * came from the calendar, meeting known → ask for the file.
///
/// Both are laid out the same way: the thing you brought on the left, the thing
/// you are choosing on the right. A notch is much wider than it is tall, so a
/// stack of full-width rows runs off the bottom while half the panel sits empty —
/// two columns is the shape the space actually is.
struct CallaKnowledgeDropView: View {
    @ObservedObject private var attach = CallaKnowledgeAttach.shared
    @EnvironmentObject var coordinator: CallaViewCoordinator
    @EnvironmentObject var vm: CallaViewModel

    @State private var isTargeted = false
    @State private var paneTargeted = false
    @State private var draft = ""
    /// Which answer to "when should Calla use this?" is picked; nil is the first.
    @State private var choiceID: String?
    /// A meeting chosen from "Another meeting…".
    @State private var otherTarget: KnowledgeTarget?

    var body: some View {
        Group {
            if let target = attach.presetTarget {
                attachColumns(target)
            } else {
                pickerColumns
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 2)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // In picker mode the only drop target was the one that appears once a
        // meeting is already chosen, so arriving here mid-drag — which is what
        // holding over Remember now does — left the file with nowhere to land.
        // The whole pane takes it, and the meeting is chosen afterwards.
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(paneTargeted ? NotchAccent.call.opacity(0.08) : Color.clear)
        )
        .onDrop(of: [.fileURL], isTargeted: $paneTargeted) { providers in
            guard attach.presetTarget == nil else { return false }
            Task {
                guard await attach.accept(providers) else {
                    attach.failure = "That is not a kind of file the copilot can read."
                    return
                }
            }
            return true
        }
    }

    // MARK: - Status

    /// What happened last — read, failed — or nil when there is nothing to say.
    private var statusLine: (text: String, tint: Color)? {
        if let failure = attach.failure { return (failure, NotchAccent.attention) }
        if let status = attach.status { return (status, NotchAccent.call) }
        return nil
    }

    private var fileSummary: String {
        let names = attach.pending.map(\.name)
        switch names.count {
        case 0: return "Nothing to add"
        case 1: return names[0]
        default: return "\(names[0]) and \(names.count - 1) more"
        }
    }

    /// What reading the dropped files found, before the reader has decided.
    private var readSummary: String {
        let files = attach.pending
        guard !files.isEmpty else { return "Ready to attach" }
        if let problem = files.compactMap(\.problem).first { return problem }
        guard attach.pendingRead else { return "Reading…" }
        if files.count == 1, let pages = files[0].pages, files[0].kind == "pdf" {
            return pages == 1 ? "Read the page. Calla can quote it now." : "Read all \(pages) pages. Calla can quote it now."
        }
        return "Read. Calla can quote it now."
    }

    /// Done means "finished filing", not "go away".
    private func done() {
        attach.cancelPending()
        coordinator.currentView = .home
        // Without the resize the notch keeps this pane's frame while showing a
        // shorter one, the pointer ends up outside it, and the hover watcher
        // closes the notch a tenth of a second later.
        withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) {
            vm.open()
        }
    }

    private var doneButton: some View {
        Button(action: done) {
            Text("Done")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.86))
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Capsule().fill(Color.white.opacity(0.08)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Done")
    }

    private func label(for target: KnowledgeTarget) -> String {
        switch target.kind {
        case .always: "Every call"
        case .series: "Every time it repeats"
        case .event: "Just this call"
        case let .persona(id): "Every \(CallaCopilotPersona.title(id)) call"
        }
    }

    // MARK: - Mode A — files in hand, one question

    /// The file, then one question: when should Calla use this?
    ///
    /// It used to be a list of every meeting in the next day and a half, which
    /// asked the reader to find the right row before they could finish a drop.
    /// Nearly every file is for the next meeting, the ones like it, or every
    /// call, so those are the three answers; any other meeting is one menu away.
    private var pickerColumns: some View {
        let choices = attach.dropChoices
        let chosen = choices.first { $0.id == choiceID } ?? otherTarget ?? choices.first
        return VStack(alignment: .leading, spacing: 12) {
            fileCard
            VStack(alignment: .leading, spacing: 4) {
                Text("When should Calla use this?")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(NotchInk.primary)
                    .padding(.bottom, 4)
                ForEach(choices) { target in
                    choiceRow(target, selected: target.id == chosen?.id) {
                        choiceID = target.id
                        otherTarget = nil
                    }
                }
                if let otherTarget, !choices.contains(otherTarget) {
                    choiceRow(otherTarget, selected: true) {}
                }
                otherMeetings(excluding: choices)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Text("Change it any time in Settings › Notes for Calla")
                    .font(.system(size: 11.5))
                    .foregroundStyle(NotchInk.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("Cancel", action: done)
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.82))
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .keyboardShortcut(.cancelAction)
                Button {
                    guard let chosen else { return }
                    Task { await attach.commitPending(to: chosen) }
                } label: {
                    Text(attach.pendingRead ? "Add" : "Reading…")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(NotchAccent.onAccent)
                        .padding(.horizontal, 18)
                        .frame(height: 32)
                        .background(Capsule().fill(NotchAccent.call.opacity(canAdd ? 1 : 0.4)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canAdd || chosen == nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 8)
        .disabled(attach.isWorking)
        .overlay { if attach.isWorking { working } }
    }

    private var canAdd: Bool {
        attach.pendingRead && attach.pending.contains { $0.problem == nil }
    }

    private func choiceRow(_ target: KnowledgeTarget, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? NotchAccent.call : NotchInk.tertiary)
                Text(choiceTitle(target))
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(NotchInk.primary)
                    .lineLimit(1)
                Text(choiceDetail(target))
                    .font(.system(size: 12))
                    .foregroundStyle(NotchInk.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Any other meeting in the next day and a half, for the file that is not
    /// about the next one.
    @ViewBuilder
    private func otherMeetings(excluding choices: [KnowledgeTarget]) -> some View {
        let others = attach.targets.filter { target in !choices.contains(target) && target.scope != "always" }
        if !others.isEmpty {
            Menu {
                ForEach(others) { target in
                    Button("\(target.title) · \(target.detail)") {
                        otherTarget = target
                        choiceID = nil
                    }
                }
            } label: {
                Text("Another meeting…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(NotchAccent.call)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.leading, 23)
        }
    }

    private func choiceTitle(_ target: KnowledgeTarget) -> String {
        switch target.kind {
        case .always: "Every call"
        case .series: "Every \(target.title)"
        case .event: target.id == attach.dropChoices.first?.id ? "Just the next call" : target.title
        case let .persona(id): "Every \(CallaCopilotPersona.title(id)) call"
        }
    }

    private func choiceDetail(_ target: KnowledgeTarget) -> String {
        switch target.kind {
        case .always: "Background, like how your team works"
        case .series: "It repeats"
        case .event:
            target.startsAt.map { "\(target.title), \($0.formatted(.dateTime.weekday(.abbreviated).hour().minute()))" }
                ?? target.title
        case .persona: "Every call of that type"
        }
    }

    /// The file, with its kind as a badge and what has happened to it.
    private var fileCard: some View {
        HStack(spacing: 10) {
            let ext = attach.pending.first.map { $0.url.pathExtension.uppercased() } ?? ""
            VStack {
                Spacer(minLength: 0)
                Text(ext.isEmpty ? "FILE" : String(ext.prefix(4)))
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(Color.black.opacity(0.86))
                    .padding(.horizontal, 3)
                    .background(RoundedRectangle(cornerRadius: 3).fill(NotchAccent.home))
                    .padding(.bottom, 6)
            }
            .frame(width: 36, height: 44)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.10)))
            VStack(alignment: .leading, spacing: 2) {
                Text(fileSummary)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(NotchInk.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(statusLine?.text ?? readSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(statusLine?.tint ?? NotchInk.tertiary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.06)))
    }

    private func targetRow(_ target: KnowledgeTarget) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol(for: target))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(NotchAccent.call)
                .frame(width: 14)
            Text(target.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(NotchInk.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let startsAt = target.startsAt {
                Text(startsAt, style: .time)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(NotchInk.tertiary)
            } else {
                Text(target.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(NotchInk.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.04)))
        .contentShape(Rectangle())
    }

    // MARK: - Mode B — meeting known, add files

    /// Left: the meeting and what is already attached. Right: bring a file in,
    /// or type a sentence.
    ///
    /// Dragging and choosing are the same intention — "this file" — so they are
    /// the same control rather than a target beside a button: the zone takes a
    /// drop and opens the picker on a click.
    private func attachColumns(_ target: KnowledgeTarget) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                meetingCard(target)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        NotchCaps("Attached")
                        Spacer(minLength: 0)
                        // "Every time it repeats" versus "just this one", when the
                        // meeting recurs.
                        if attach.targets.count > 1 { scopeMenu }
                    }
                    if attach.attached.isEmpty {
                        hint(statusLine?.text ?? "Nothing attached to this meeting yet.",
                             tint: statusLine?.tint)
                    } else {
                        attachedList
                    }
                }
            }
            .frame(width: 176)
            .frame(maxHeight: .infinity, alignment: .topLeading)

            VStack(alignment: .leading, spacing: 8) {
                dropZone(target)
                typeRow(target)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func meetingCard(_ target: KnowledgeTarget) -> some View {
        HStack(spacing: 10) {
            Rectangle().fill(NotchAccent.call).frame(width: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(target.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(NotchInk.primary)
                    .lineLimit(1)
                Text(target.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(NotchInk.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.trailing, 10)
        .frame(height: 50)
        .background(Color.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var scopeMenu: some View {
        Menu {
            ForEach(attach.targets) { choice in
                Button(label(for: choice)) { attach.retarget(choice) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(attach.presetTarget.map(label(for:)) ?? "Scope")
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .heavy))
            }
            .foregroundStyle(Color.white.opacity(0.86))
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Which meetings this is attached to")
    }

    private func dropZone(_ target: KnowledgeTarget) -> some View {
        HStack(spacing: 12) {
            Image(systemName: attach.isWorking ? "hourglass" : "doc.badge.plus")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(NotchAccent.call)
            VStack(alignment: .leading, spacing: 2) {
                Text(attach.isWorking ? "Reading…" : "Drop a file, or click to choose")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(NotchInk.primary)
                    .lineLimit(1)
                Text(attach.isWorking
                     ? "Scanned pages take a moment longer."
                     : "PDFs, docs, slides. Scans take a moment longer.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.65))
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(NotchAccent.call.opacity(isTargeted ? NotchAccent.fill : 0.06)))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(NotchAccent.call.opacity(isTargeted ? 0.9 : 0.45),
                              style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
        .contentShape(Rectangle())
        .onTapGesture { attach.attachChosenFiles(to: target) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Drop a file, or click to choose")
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            Task {
                guard await attach.accept(providers) else {
                    attach.failure = "That is not a kind of file the copilot can read."
                    return
                }
                await attach.commitPending(to: target)
            }
            return true
        }
    }

    private var attachedList: some View {
        ScrollView(.vertical) {
            VStack(spacing: 3) {
                ForEach(attach.attached) { note in
                    HStack(spacing: 7) {
                        Image(systemName: note.symbol)
                            .font(.system(size: 10))
                            .foregroundStyle(note.isDocument ? NotchAccent.call : NotchInk.tertiary)
                            .frame(width: 13)
                        Text(note.title.isEmpty ? "Untitled" : note.title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(NotchInk.primary)
                            .lineLimit(1)
                            .help(note.subtitle)
                        Spacer(minLength: 0)
                        Button { attach.remove(note) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(NotchInk.tertiary)
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Remove")
                        .accessibilityLabel("Remove \(note.title)")
                    }
                    .padding(.leading, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.white.opacity(0.04)))
                }
            }
        }
        .scrollIndicators(.never)
    }

    // MARK: - Typing

    private func typeRow(_ target: KnowledgeTarget) -> some View {
        let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(spacing: 6) {
            TextField("Or type something it should know", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(NotchInk.primary)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.05)))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                .onSubmit { commitDraft(target) }
                .accessibilityLabel("Note for the copilot")
                .overlay(alignment: .trailing) {
                    if !empty {
                        Button { commitDraft(target) } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(NotchAccent.call)
                                .frame(width: 30, height: 30)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Add this note")
                        .accessibilityLabel("Add this note")
                    }
                }
            doneButton
        }
    }

    private func commitDraft(_ target: KnowledgeTarget) {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        draft = ""
        Task { await attach.attach(text: body, title: target.title, to: target) }
    }

    // MARK: - Pieces

    private func hint(_ text: String, tint: Color? = nil) -> some View {
        Text(text)
            .font(.system(size: 11))
            .lineSpacing(1)
            .foregroundStyle(tint ?? NotchInk.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Reading is not instant for a scanned PDF — Vision runs page by page — so
    /// the wait is named rather than left as a spinner over a frozen list.
    private var working: some View {
        HStack(spacing: 9) {
            ProgressView().controlSize(.small)
            Text("Reading \(fileSummary)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(NotchInk.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.black.opacity(0.7)))
    }

    private func symbol(for target: KnowledgeTarget) -> String {
        switch target.kind {
        case .always: "globe"
        case .series: "repeat"
        case .event: "calendar"
        case .persona: "person.crop.rectangle"
        }
    }
}

// MARK: - What Calla is using, mid-call

/// The notes this call was started with, each with a switch.
///
/// A switch only affects this call: the note itself is untouched and the next
/// call uses it as before, which is what makes it safe to flip mid-sentence.
/// Grouped by why the note is here, so "why is Calla quoting the pricing
/// sheet?" is answered by the heading it sits under.
struct CallaCallNotesView: View {
    @ObservedObject private var engine = CallaEngineClient.shared
    @ObservedObject private var session = CopilotLiveSession.shared

    private struct NoteGroup: Identifiable {
        let id: String
        let title: String
        let notes: [CallaKnowledgeNote]
    }

    private var groups: [NoteGroup] {
        let notes = engine.callNotes
        let meeting = engine.status.copilot.meetingTitle.flatMap { $0.isEmpty ? nil : $0 }
        func pick(_ scope: String) -> [CallaKnowledgeNote] { notes.filter { $0.scope == scope } }
        var result: [NoteGroup] = []
        let event = pick("event"), series = pick("series"), persona = pick("persona"), always = pick("always")
        if !event.isEmpty { result.append(NoteGroup(id: "event", title: "This call", notes: event)) }
        if !series.isEmpty {
            result.append(NoteGroup(id: "series", title: meeting.map { "Every \($0)" } ?? "Every time it repeats", notes: series))
        }
        if !persona.isEmpty {
            let type = persona.first?.scopeKey.map(CallaCopilotPersona.title) ?? "call"
            result.append(NoteGroup(id: "persona", title: "Every \(type) call", notes: persona))
        }
        if !always.isEmpty { result.append(NoteGroup(id: "always", title: "Every call", notes: always)) }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("WHAT CALLA IS USING")
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(Color.white.opacity(0.84))
                Spacer(minLength: 8)
                Button("Back to the call") { session.toggleCallNotes() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(NotchAccent.call)
                    .keyboardShortcut(.cancelAction)
            }
            if groups.isEmpty {
                Text("No notes on this call. Drop a file on the notch and it is used from the next call.")
                    .font(.system(size: 13))
                    .foregroundStyle(NotchInk.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.title.uppercased())
                                    .font(.system(size: 10.5, weight: .bold))
                                    .tracking(0.7)
                                    .foregroundStyle(NotchInk.secondary)
                                    .lineLimit(1)
                                ForEach(group.notes) { note in row(note) }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("Switching a note off only affects this call. New notes are used from the next call.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(NotchInk.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private func row(_ note: CallaKnowledgeNote) -> some View {
        let included = !engine.excludedCallNoteIDs.contains(note.id)
        return HStack(spacing: 10) {
            Image(systemName: note.symbol)
                .font(.system(size: 12))
                .foregroundStyle(included ? NotchAccent.call : NotchInk.tertiary)
                .frame(width: 16)
            Text(note.title.isEmpty ? "Untitled note" : note.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(included ? NotchInk.primary : NotchInk.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if !included {
                Text("off for this call")
                    .font(.system(size: 11.5))
                    .foregroundStyle(NotchInk.tertiary)
            }
            Toggle("", isOn: Binding(
                get: { included },
                set: { engine.setCallNote(note.id, included: $0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .accessibilityLabel("Use \(note.title) on this call")
        }
        .frame(height: 30)
    }
}
