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

    // MARK: - Mode A — files in hand, choose a meeting

    /// Left: what was dropped. Right: which meeting it is for.
    private var pickerColumns: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                fileCard
                Spacer(minLength: 8)
                doneButton
            }
            .frame(width: 176)
            .frame(maxHeight: .infinity, alignment: .topLeading)

            VStack(alignment: .leading, spacing: 4) {
                Text("Which meeting is this for?")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(NotchInk.primary)
                    .padding(.bottom, 4)
                ScrollView(.vertical) {
                    VStack(spacing: 4) {
                        ForEach(attach.targets) { target in
                            Button {
                                Task { await attach.commitPending(to: target) }
                            } label: {
                                targetRow(target)
                            }
                            .buttonStyle(.plain)
                            .help("Attach to \(target.title)")
                        }
                        if attach.targets.count <= 1 {
                            hint("No meetings in the next day and a half. It can still go to every call, or to any meeting from Settings.")
                        }
                    }
                }
                .scrollIndicators(.never)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .disabled(attach.isWorking)
        .overlay { if attach.isWorking { working } }
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
                Text(statusLine?.text ?? "Ready to attach")
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
