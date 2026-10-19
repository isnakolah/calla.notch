//
//  CallaCopilotEndingView.swift
//  callaNotch
//

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

    var body: some View {
        VStack(alignment: .leading, spacing: NotchGlassSpace.snug) {
            NotchCardHeader(state: "Finishing the call",
                            live: true,
                            tint: NotchTint.active,
                            figure: elapsed)

            Text(headline)
                .font(NotchGlassType.title)
                .foregroundStyle(NotchInk.primary)
                .lineLimit(1)

            CallaStepBar(total: Step.allCases.count,
                         completed: completedSteps,
                         tint: NotchTint.active)

            Text(footnote)
                .font(NotchGlassType.caption)
                .foregroundStyle(stalled ? NotchTint.attention : NotchInk.tertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            // No cancel. There is nothing safe to cancel into: the audio is
            // already closed and abandoning the recap loses the one artefact the
            // call was for. Leaving is allowed — the work finishes without the
            // panel — which is what this offers instead.
            HStack(spacing: NotchGlassSpace.tight) {
                NotchChip(action: { session.dismiss() }) { Text("Leave it running") }
                // Only once the wait has stopped being ordinary. Sending stop
                // again is what escalates: the engine retries the host's control
                // socket and falls through to SIGINT, which is the path that
                // gets a host that never answered to shut down.
                if stalled {
                    NotchChip(tint: NotchTint.attention, action: { engine.endCall() }) {
                        Text("Stop it again")
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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

/// A run of work, as one bar of segments.
///
/// Shared by the startup and the shutdown, which are the same shape: a known
/// number of real costs being paid in a known order. A determinate bar rather
/// than a spinner, because the reader can see which segment is taking the time;
/// the in-flight one breathes so a slow model pass does not look frozen.
struct CallaStepBar: View {
    let total: Int
    let completed: Int
    let tint: Color

    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<total, id: \.self) { index in
                Capsule()
                    .fill(index <= completed ? tint : NotchInk.tertiary.opacity(0.35))
                    .frame(height: 3)
                    .opacity(index == completed && pulsing ? 0.45 : 1)
            }
        }
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulsing)
        .onAppear { pulsing = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(min(completed + 1, total)) of \(total)")
    }
}
