//
//  CallaCopilotEndingView.swift
//  callaNotch
//

import AppKit
import Defaults
import SwiftUI

/// The seconds between pressing End call and the call actually being finished.
///
/// The mirror of `CallaCopilotStartingView`, and it exists for the same reason.
/// Ending a call is not instant: the endpointers flush, the transcription queue
/// drains, the WAVs close, the last turns are folded into the account, and a
/// deep model writes the recap — which is ~8.5 seconds on its own. None of that
/// was on screen. `running` stayed true until the host process exited, so the
/// press changed nothing, the panel sat there unaltered, and then it vanished.
/// Pressing again did nothing either, so it read as a dead button twice over.
///
/// The host has published `stopping`, `processingRecap` and a 0…1 progress since
/// the v2 contract. Nothing forwarded it: the engine decoded the lifecycle file
/// without that field and never put the state on the status it sends. So this is
/// mostly a matter of drawing what was already being reported.
struct CallaCopilotEndingView: View {
    @ObservedObject private var engine = CallaEngineClient.shared
    @ObservedObject private var session = CopilotLiveSession.shared

    private var copilot: CallaCopilotStatus { engine.status.copilot }

    /// The ordered spine of the shutdown, and what each one is actually paying
    /// for. Two of these are bounded by how much audio is queued and two by a
    /// model, which is why this is a checklist and not a spinner.
    private enum Step: CaseIterable {
        case closing, transcript, account, recap

        var label: String {
            switch self {
            case .closing: "Closing the microphones"
            case .transcript: "Finishing the transcript"
            case .account: "Folding in the last turns"
            case .recap: "Writing the recap"
            }
        }
    }

    /// Where the host says it is.
    ///
    /// `recapProgress` is the host's own number and the steps are placed on it
    /// at the points it actually reports: 0.2 when the recap pass begins, 0.4
    /// once the account's tail is closed, 0.75 once the deep pass has answered.
    private var completedSteps: Int {
        guard copilot.lifecycleState != CallLifecycleStateName.stopping else { return 1 }
        guard let progress = copilot.recapProgress else { return 0 }
        if progress >= 0.75 { return 4 }
        if progress >= 0.4 { return 3 }
        if progress >= 0.2 { return 2 }
        return 1
    }

    /// Whether the host has told us anything at all since the press.
    ///
    /// This is the state `completedSteps == 0` means, and it was being drawn as
    /// "Closing the microphones" — which made that sentence the label for *no
    /// information*. Every stall before the host's first write rendered as the
    /// microphones being stuck, and the microphones are the one thing that is
    /// definitely not stuck: `CallSession.stop()` closes both legs before the
    /// drain, the account or the recap, so by the time any of the slow work
    /// starts they are already shut.
    private var awaitingHost: Bool {
        completedSteps == 0
            && copilot.lifecycleState != CallLifecycleStateName.processingRecap
    }

    /// Both capture legs reported closed. The host publishes these on every
    /// status write, so it is a fact rather than an inference.
    private var capturesClosed: Bool { !copilot.micActive && !copilot.systemAudioActive }

    private var headline: String {
        if awaitingHost {
            // Named for what is actually happening: the stop has been sent and
            // nothing has come back yet.
            return capturesClosed ? "Closing the microphones" : "Asking the call to stop"
        }
        guard completedSteps < Step.allCases.count else { return "Saved" }
        return Step.allCases[completedSteps].label
    }

    /// How long this has been on screen without the host advancing a step.
    ///
    /// The only way out of a stall used to be the engine client's 60-second
    /// timeout, with nothing on screen to say a stall was happening — so a stop
    /// that never landed looked identical to a recap being written.
    @State private var since = Date()
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private var stalledSeconds: Int { Int(now.timeIntervalSince(since)) }
    /// Past this, the wait stops being ordinary. The deep closing pass is ~8.5s
    /// and the transcript drain is bounded by the backlog, so a step that has
    /// not moved in twenty seconds is worth saying out loud.
    private var stalled: Bool { stalledSeconds >= 20 }

    private var saved: Bool { completedSteps >= Step.allCases.count }

    var body: some View {
        CallaLifecycleLayout(
            eyebrow: saved ? "Call saved"
                : "Finishing the call · step \(min(completedSteps + 1, Step.allCases.count)) of \(Step.allCases.count)",
            tint: saved ? NotchAccent.call : NotchInk.tertiary,
            live: false,
            headline: saved ? "Recap is ready" : headline,
            detail: footnote,
            detailTint: stalled ? NotchAccent.attention : NotchInk.secondary,
            steps: Step.allCases.map(\.label),
            completed: completedSteps,
            trailing: {
                if let elapsed {
                    Text(elapsed)
                        .font(.system(size: 12, design: .monospaced).monospacedDigit())
                        .foregroundStyle(NotchInk.tertiary)
                }
            },
            actions: {
                // No cancel. There is nothing safe to cancel into: the audio is
                // already closed and abandoning the recap loses the one artefact
                // the call was for. Leaving is allowed — the work finishes
                // without the panel — which is what this offers instead.
                CallaLifecycleButton(title: saved ? "Done" : "Leave it running",
                                     weight: saved ? .primary : .secondary) { session.dismiss() }
                // Only once the wait has stopped being ordinary. Sending stop
                // again is what escalates: the engine retries the host's control
                // socket and falls through to SIGINT, which is the path that
                // gets a host that never answered to shut down.
                if stalled && !saved {
                    CallaLifecycleButton(title: "Stop it again", weight: .primary,
                                         tint: NotchAccent.attention) { engine.endCall(origin: "recapRetry") }
                }
            })
        .animation(.smooth(duration: 0.2), value: completedSteps)
        .onReceive(tick) { now = $0 }
        .onChange(of: completedSteps) { _, _ in since = Date(); now = Date() }
    }

    private var elapsed: String? {
        guard let startedAt = copilot.startedAt else { return nil }
        let seconds = Int(Date().timeIntervalSince(startedAt))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// Says the one thing someone watching this actually wants to know: whether
    /// they can walk away.
    private var footnote: String {
        guard completedSteps < Step.allCases.count else {
            if let folder = copilot.callFolder, Defaults[.callaCallFoldersEnabled] {
                return "Saved to Documents › Calls › \(folder.replacingOccurrences(of: "/", with: " › "))."
            }
            return "The transcript and the recap are saved. You can find them under History."
        }
        if stalled {
            return awaitingHost
                ? "The call host has not answered in \(stalledSeconds)s. Stopping again sends it a signal directly."
                : "Still working after \(stalledSeconds)s. Recording has stopped either way."
        }
        return capturesClosed
            ? "Recording has stopped. This finishes on its own even if you close the notch."
            : "This finishes on its own even if you close the notch."
    }
}

/// A run of work, as one bar of segments with each step named under its own.
///
/// Shared by the startup and the shutdown, which are the same shape: a known
/// number of real costs being paid in a known order. A determinate bar rather
/// than a spinner, because the reader can see which segment is taking the time;
/// the in-flight one breathes so a slow model pass does not look frozen. A
/// failure fills its segment in coral and names it in coral.
struct CallaStepBar: View {
    let labels: [String]
    let completed: Int
    var tint: Color = NotchAccent.call
    var failed = false

    @State private var pulsing = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                let current = index == completed
                VStack(alignment: .leading, spacing: 7) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(NotchInk.hairline)
                            Capsule()
                                .fill(current && failed ? NotchAccent.stop : tint)
                                .frame(width: geo.size.width * fill(index))
                                .opacity(current && !failed && pulsing ? 0.55 : 1)
                        }
                    }
                    .frame(height: 6)
                    Text(label)
                        .font(.system(size: 11, weight: current ? .semibold : .medium))
                        .foregroundStyle(current ? (failed ? NotchAccent.stop : NotchInk.primary)
                                         : index < completed ? NotchInk.secondary : NotchInk.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulsing)
        .onAppear { pulsing = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(min(completed + 1, labels.count)) of \(labels.count)"
                            + (completed < labels.count ? ", \(labels[completed])" : ""))
    }

    private func fill(_ index: Int) -> CGFloat {
        if index < completed { return 1 }
        if index == completed { return failed ? 1 : 0.55 }
        return 0
    }
}

/// The frame a call's start and finish are drawn in: what stage this is, the
/// step in a 24pt headline, a sentence on what it means, then the step bar and
/// whatever can be pressed.
struct CallaLifecycleLayout<Trailing: View, Actions: View>: View {
    let eyebrow: String
    let tint: Color
    var live = true
    let headline: String
    let detail: String
    var detailTint: Color = NotchInk.secondary
    let steps: [String]
    let completed: Int
    var failed = false
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)
                    .background(Circle().fill(tint.opacity(live ? 0.22 : 0)).padding(-4))
                Text(eyebrow.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .tracking(notchCapsTracking)
                    .foregroundStyle(tint)
                    .lineLimit(1)
                Spacer(minLength: 8)
                trailing
            }
            .frame(height: 26)
            VStack(alignment: .leading, spacing: 6) {
                Text(headline)
                    .font(.system(size: 24, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(NotchInk.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(detailTint)
                    .lineSpacing(2)
                    .lineLimit(2)
                    .frame(maxWidth: 560, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 4)
            Spacer(minLength: 10)
            VStack(alignment: .leading, spacing: 12) {
                CallaStepBar(labels: steps, completed: completed, failed: failed)
                HStack(spacing: 8) { actions }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .padding(.bottom, 6)
    }
}

/// A 36pt pill for the lifecycle panels: filled, quiet, or bare text.
struct CallaLifecycleButton: View {
    enum Weight { case primary, secondary, plain }

    let title: String
    var weight: Weight = .secondary
    var tint: Color = NotchAccent.call
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: weight == .primary ? .bold : .semibold))
                .foregroundStyle(weight == .primary ? NotchAccent.onAccent
                                 : weight == .secondary ? Color.white.opacity(0.90) : NotchInk.secondary)
                .lineLimit(1)
                .padding(.horizontal, weight == .plain ? 14 : 17)
                .frame(height: 36)
                .background(Capsule().fill(weight == .primary ? tint
                                           : weight == .secondary ? Color.white.opacity(0.08) : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}

// MARK: - The recap

/// The call, written up: what was decided, what is still open, and what
/// someone has to do, in the notch once the write-up is done.
///
/// It replaces the moment the call used to simply vanish into Past calls. The
/// to-dos are the one part worth acting on before the next meeting starts, so
/// they can go straight to Reminders; the rest can become a follow-up email.
/// Everything here is the host's recap as written — nothing is inferred.
struct CallaRecapView: View {
    @ObservedObject private var session = CopilotLiveSession.shared

    /// To-dos the reader has unticked, so "Add to Reminders" leaves them out.
    @State private var skipped = Set<String>()
    @State private var note: (text: String, failed: Bool)?
    @State private var adding = false

    var body: some View {
        if let recap = session.recap {
            content(recap)
        }
    }

    private func content(_ recap: CallaRecapDraft) -> some View {
        let sections = CallaRecapPresentation.sections(recap.items.map {
            .init(kind: $0.kind, text: $0.text, resolved: $0.resolved)
        })
        let context = session.recapContext
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(NotchAccent.call).frame(width: 7, height: 7)
                Text("CALL ENDED · RECAP READY")
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(Color.white.opacity(0.84))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let length = CallaRecapPresentation.length(minutes: context.minutes) {
                    Text(length)
                        .font(.system(size: 12, design: .rounded).monospacedDigit())
                        .foregroundStyle(NotchInk.secondary)
                }
            }
            .frame(height: 24)

            VStack(alignment: .leading, spacing: 5) {
                Text(context.title?.isEmpty == false ? context.title! : "Your call")
                    .font(.system(size: 19, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(NotchInk.primary)
                    .lineLimit(1)
                if !recap.overview.isEmpty {
                    Text(recap.overview)
                        .font(.system(size: 13))
                        .foregroundStyle(NotchInk.reading)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 6)

            HStack(alignment: .top, spacing: 20) {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 6) {
                        if !sections.decided.isEmpty {
                            heading("Decided")
                            ForEach(sections.decided, id: \.self) { line($0) }
                        }
                        if !sections.open.isEmpty {
                            heading("Still open").padding(.top, sections.decided.isEmpty ? 0 : 8)
                            ForEach(sections.open, id: \.self) { line($0) }
                        }
                        if sections.decided.isEmpty && sections.open.isEmpty {
                            Text("Nothing was decided or left open.")
                                .font(.system(size: 12.5))
                                .foregroundStyle(NotchInk.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 6) {
                    heading("To do")
                    if sections.todo.isEmpty {
                        Text("No to-dos came out of this call.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(NotchInk.secondary)
                    } else {
                        ScrollView(.vertical) {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(sections.todo, id: \.self) { todo($0) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        let chosen = sections.todo.filter { !skipped.contains($0) }
                        Button {
                            addToReminders(chosen, title: context.title)
                        } label: {
                            Text(adding ? "Adding…" : chosen.count == sections.todo.count
                                 ? "Add all to Reminders" : "Add \(chosen.count) to Reminders")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(NotchAccent.call)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .disabled(chosen.isEmpty || adding)
                        .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 12)

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                CallaLifecycleButton(title: "Copy follow-up email", weight: .secondary) {
                    let email = CallaRecapPresentation.followUpEmail(
                        title: context.title, overview: recap.overview, sections: sections)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(email, forType: .string)
                    note = ("Copied. Paste it into an email and edit it.", false)
                }
                CallaLifecycleButton(title: "Open in Past calls", weight: .plain) {
                    SettingsWindowController.shared.show(route: SettingsRoute(page: .copilotCallDetail(id: recap.callID)))
                    session.dismissRecap()
                }
                if let note {
                    Text(note.text)
                        .font(.system(size: 12))
                        .foregroundStyle(note.failed ? NotchAccent.attention : NotchInk.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
                CallaLifecycleButton(title: "Done", weight: .primary) { session.dismissRecap() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .padding(.bottom, 6)
        .onExitCommand { session.dismissRecap() }
    }

    private func heading(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .bold))
            .tracking(0.7)
            .foregroundStyle(NotchInk.secondary)
    }

    private func line(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(Color.white.opacity(0.45)).frame(width: 4, height: 4).offset(y: -2)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(NotchInk.reading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func todo(_ text: String) -> some View {
        let on = !skipped.contains(text)
        return Button {
            if on { skipped.insert(text) } else { skipped.remove(text) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundStyle(on ? NotchAccent.call : NotchInk.tertiary)
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(on ? NotchInk.reading : NotchInk.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
        .help(on ? "Leave this out of Reminders" : "Include this in Reminders")
    }

    private func addToReminders(_ titles: [String], title: String?) {
        guard !titles.isEmpty else { return }
        adding = true
        Task { @MainActor in
            let saved = await CalendarService().addReminders(
                titles, notes: title.map { "From \($0), noted by Calla." } ?? "Noted by Calla.")
            adding = false
            note = saved > 0
                ? ("Added \(saved) to Reminders.", false)
                : ("Calla can't reach Reminders. Allow it in System Settings › Privacy › Reminders.", true)
        }
    }
}
