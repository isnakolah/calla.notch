import AppKit
import CallaContracts
import Defaults
import SwiftUI

/// Explicit Quiz preflight. Calendar entry points only seed this surface; they
/// never grant capture authority or start a worker.
struct CallaQuizPreflightView: View {
    @ObservedObject private var engine = CallaEngineClient.shared
    @ObservedObject private var library = CallaKnowledgeLibrary.shared
    @Default(.callaCopilotMode) private var mode
    @Default(.callaQuizVoterOneModel) private var voterOne
    @Default(.callaQuizVoterTwoModel) private var voterTwo
    @Default(.callaQuizVoterThreeModel) private var voterThree
    @Default(.callaQuizArbiterModel) private var arbiter
    @Default(.callaQuizCaptureResolution) private var captureResolution
    @Default(.callaQuizTargetWindowID) private var rememberedWindowID
    @Default(.callaQuizTargetBundleID) private var rememberedBundleID
    @Default(.callaQuizTargetWindowTitle) private var rememberedWindowTitle

    @State private var windows: [QuizWindowTarget] = []
    @State private var selectedWindowID: String?
    @State private var windowRefreshGeneration = 0
    @State private var preparing = false
    @State private var failure: String?

    private var meeting: CallaMeeting? { engine.pendingQuizMeeting }
    private var selectedWindow: QuizWindowTarget? {
        windows.first { $0.id == selectedWindowID }
    }
    /// The council for a question whose kind could not be determined, which is
    /// also what the legacy flat fields on the configuration are set from.
    private var fallbackProfile: QuizModeProfile {
        QuizProfileStore.profile(for: .fallback)
    }
    /// The council the Engine keeps resident for a session, and therefore the one
    /// worth spawning before Start rather than after it.
    private var warmProfile: QuizModeProfile {
        QuizProfileStore.profile(for: QuizProfileStore.warmMode)
    }

    private var canStart: Bool {
        selectedWindow != nil && !preparing && blockers.isEmpty
    }

    /// What would make Start fail, in the order worth fixing.
    ///
    /// The snapshot has carried `screenRecordingReady`, `accessibilityReady`,
    /// `agyAuthenticated` and `modelsReady` all along and the notch rendered
    /// none of them: a denied permission only ever surfaced as a generic failure
    /// string *after* the reader pressed Start. The panel has room for one line,
    /// so this reports the first thing standing in the way rather than a table.
    private var blockers: [String] {
        let quiz = engine.status.quiz
        var found: [String] = []
        if !quiz.screenRecordingReady { found.append("Screen Recording") }
        if !quiz.accessibilityReady { found.append("Accessibility") }
        if !quiz.agyAuthenticated { found.append("AGY sign-in") }
        if !quiz.modelsReady { found.append("Reasoner models") }
        return found
    }

    private var attachedNotes: [CallaKnowledgeNote] {
        guard let meeting else { return [] }
        return library.notes.filter { note in
            if note.scope == "event" { return note.scopeKey == meeting.eventID }
            if note.scope == "series" { return note.scopeKey == meeting.seriesID }
            return false
        }
    }

    var body: some View {
        CallaPreflightCard(
            state: preparing ? "Preparing" : "Ready",
            live: false,
            tint: .effectiveAccent,
            mode: $mode,
            switcherEnabled: !engine.status.copilot.running && !engine.status.quiz.active && !preparing,
            headline: headline,
            headlineTint: canStart ? NotchInk.primary : NotchTint.attention,
            detail: detail,
            checks: checks,
            context: { meetingChip },
            controls: {
                targetMenu
                NotchChip(tint: canStart ? .effectiveAccent : nil, action: { start() }) {
                    if preparing {
                        Image(systemName: "circle.dotted").font(NotchGlassType.glyphSmall)
                    }
                    Text(preparing ? "Preparing…" : "Start Quiz")
                }
                .opacity(canStart ? 1 : 0.45)
                .disabled(!canStart)
                // Return started nothing before, on a panel whose only primary
                // action is this button.
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel(preparing ? "Preparing Quiz" : "Start Quiz")
            },
            utility: {
                NotchGlyphButton(symbol: "gearshape", help: "Quiz settings") {
                    SettingsWindowController.shared.showCopilotWindow(tab: "Quiz")
                }
                .accessibilityLabel("Quiz settings")
            })
        .task { refresh() }
        // Holding ~190 MB per voter is worth it while the reader is deciding, and
        // not for a moment after they have gone somewhere else. The Engine also
        // drops the bench on its own timer, so a panel left open overnight is not
        // relying on this.
        .onDisappear { engine.cancelQuizWarm() }
    }

    /// Which meeting the questions are being asked in, in the header's context
    /// slot — the same place Call names its persona and Code names its project.
    private var meetingChip: some View {
        CallaContextChip(title: meeting?.title ?? "No event",
                         symbol: meeting == nil ? "calendar.badge.minus" : "calendar") {
            Button("No event") { engine.prepareQuiz(for: nil) }
        }
        .help(meeting == nil ? "No meeting context attached" : "Start without event context")
    }

    private var headline: String {
        if let failure, !failure.isEmpty { return failure }
        if let window = selectedWindow { return window.applicationName }
        return "Choose a window to watch"
    }

    private var detail: String {
        if failure != nil { return "Check Quiz settings, then try again." }
        guard let window = selectedWindow else {
            return "Quiz reads one window and answers what is on it."
        }
        var parts = [window.windowTitle]
        if !attachedNotes.isEmpty {
            parts.append("\(attachedNotes.count) note\(attachedNotes.count == 1 ? "" : "s") attached")
        }
        return parts.joined(separator: " · ")
    }

    /// The four things a quiz needs. The snapshot has carried all of them all
    /// along and the notch rendered none: a denied permission only ever
    /// surfaced as a generic failure string *after* the reader pressed Start.
    private var checks: [CallaCheck] {
        let quiz = engine.status.quiz
        return [
            CallaCheck("Screen Recording", symbol: "rectangle.inset.filled.and.person.filled",
                       ready: quiz.screenRecordingReady, yes: "allowed", no: "not allowed"),
            CallaCheck("Accessibility", symbol: "accessibility",
                       ready: quiz.accessibilityReady, yes: "allowed", no: "not allowed"),
            CallaCheck("Agy", symbol: "sparkles",
                       ready: quiz.agyAuthenticated, yes: "signed in", no: "signed out"),
            CallaCheck("Reasoners", symbol: "cpu",
                       ready: quiz.modelsReady, yes: "ready", no: "not ready")
        ]
    }

    private var targetMenu: some View {
        CallaWindowTargetMenu(target: selectedWindow, windows: windows,
            help: "Choose the window Quiz reads", refresh: refreshWindows) { window in
                if let window { select(window) }
            }
    }

    private func refresh() {
        refreshWindows()
        Task { await library.load() }
    }

    /// Starts the council spawning now.
    ///
    /// Every `agy` child spends seconds handshaking with Google before it can
    /// answer anything, and that used to begin when Start was pressed — while the
    /// reader waited. They have already chosen a window by this point, so the
    /// spawn happens during the part of this panel they were going to spend
    /// anyway. Nothing is granted by it: no target is sent and no session begins.
    private func warmIfReady() {
        guard selectedWindow != nil, blockers.isEmpty, failure == nil,
              !engine.status.quiz.active else { return }
        engine.warmQuiz(mode: QuizProfileStore.warmMode, profile: warmProfile)
    }

    private func refreshWindows() {
        windowRefreshGeneration += 1
        let generation = windowRefreshGeneration
        engine.listQuizWindows { values in
            guard generation == windowRefreshGeneration else { return }
            windows = values
            let restored = QuizWindowSelection.resolve(
                windows: values, currentID: selectedWindowID,
                rememberedID: rememberedWindowID,
                rememberedBundleID: rememberedBundleID,
                rememberedWindowTitle: rememberedWindowTitle)
            selectedWindowID = restored?.id
            if let restored {
                rememberedWindowID = restored.id
                warmIfReady()
            }
        }
    }

    private func select(_ window: QuizWindowTarget) {
        selectedWindowID = window.id
        rememberedWindowID = window.id
        rememberedBundleID = window.bundleID
        rememberedWindowTitle = window.windowTitle
        warmIfReady()
    }

    private func start() {
        guard let target = selectedWindow else { return }
        preparing = true
        failure = nil
        var context = attachedNotes.map { note in
            QuizContextReference(
                id: note.id,
                revision: ISO8601DateFormatter().string(from: note.updatedAt),
                title: note.title.isEmpty ? "Untitled note" : note.title,
                scope: note.scope == "series" ? .series : .event,
                kind: note.source,
                text: note.body)
        }
        if let text = meeting?.notes, !text.isEmpty {
            context.append(.init(id: "event-invite-notes", revision: "calendar-start",
                                 title: "Event notes", scope: .event,
                                 kind: "event_field", text: text))
        }
        let configuration = QuizSessionConfiguration(
            target: target, eventID: meeting?.eventID, eventLabel: meeting?.title,
            context: context,
            excludedContextIDs: Array(engine.pendingQuizExcludedContextIDs),
            voters: fallbackProfile.voters,
            arbiter: fallbackProfile.arbiter ?? .init(modelID: arbiter, effort: "high"),
            captureResolution: QuizCaptureResolution(rawValue: captureResolution)
                ?? QuizContract.defaultCaptureResolution,
            profiles: Defaults[.callaQuizProfiles],
            warmMode: QuizProfileStore.warmMode,
            speculative: Defaults[.callaQuizSpeculative])
        engine.startQuiz(configuration) { snapshot in
            preparing = false
            if snapshot?.active != true {
                let detail = snapshot?.failure ?? engine.status.lastResult
                failure = detail.isEmpty ? "Quiz could not start" : detail
            }
        }
        // A proxy that neither replies nor errors would otherwise leave the
        // button reading "Preparing…" for ever, with no way back. The call flow
        // guards its launch the same way.
        Task {
            try? await Task.sleep(for: .seconds(45))
            guard preparing, !engine.status.quiz.active else { return }
            preparing = false
            if failure == nil { failure = "Quiz did not start in time" }
        }
    }
}
