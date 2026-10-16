import AppKit
import CallaContracts
import Combine
import Defaults
import SwiftUI

/// Owns "a call is happening right now" for the whole app.
///
/// Three things key off this and nothing else: the notch refuses to close, the
/// notch grows to `copilotNotchSize`, and the panel drops out of screen
/// recordings. Keeping them on one flag is deliberate — a live panel that is
/// visible in a share, or one that closes when the pointer drifts away, is
/// worse than no panel, and both failures come from the same state getting out
/// of sync.
@MainActor
final class CopilotLiveSession: ObservableObject {
    static let shared = CopilotLiveSession()

    enum Layout {
        /// The answer with the transcript beside it.
        case full
        /// The answer alone, at `copilotCompactNotchSize` — still listening,
        /// out of the way.
        case compact
    }

    /// Mirrors the engine's `copilot.running`, which is the only authority on
    /// whether a call exists. Never set this directly.
    @Published private(set) var isLive = false

    @Published private(set) var layout: Layout = .full
    /// The panel is resting as the ambient summary. Set by the notch, which
    /// owns hover; read here so the window keeps the collapsed size.
    @Published var ambientShowing = false
    /// The zen pane's height, measured from its text so nothing is cut off.
    @Published var ambientHeight: CGFloat = 118

    /// Where the reader is in the Quiz session's answers.
    ///
    /// This lives here rather than in the view because the global copy and
    /// step shortcuts have to act on the answer that is actually on screen. A
    /// `@State` in the panel would leave `sessionCopy` copying the newest
    /// answer while the reader looked at an older one.
    @Published private(set) var quizAnswerCursor = CallaQuizPresentation.Cursor.latest

    /// Bumped when the reader asks to scroll the answer they are looking at.
    ///
    /// The scroll shortcuts used to always scroll the *target window*, which put
    /// the session into `.collecting` — so pressing down while reading a long
    /// answer made Quiz go and fetch more of the question instead of moving the
    /// code. The panel is what the reader is looking at, so that is what the key
    /// moves; scrolling the target is what the key does only when Quiz has
    /// actually asked for it.
    @Published private(set) var quizAnswerScroll = QuizAnswerScrollRequest(tick: 0, lines: 0)

    struct QuizAnswerScrollRequest: Equatable {
        let tick: Int
        /// Negative is up.
        let lines: Int
    }

    /// The last Quiz session, kept after it ends so its answers and any failure
    /// survive long enough to be read.
    ///
    /// A finished or failed Quiz used to make `active` false, which dropped
    /// `isLive`, unpinned the notch and tore the panel down — taking the answer
    /// and the reason with it. The call flow has three dedicated surfaces for
    /// exactly this moment; Quiz had none.
    @Published private(set) var quizOutcome: QuizSessionSnapshot?

    /// Whether the session currently wants the notch held open. Cleared by
    /// `dismiss()` without ending the call.
    @Published private(set) var pinned = false
    @Published private(set) var endedByReader = false
    @Published private(set) var callEndReleases = 0

    func prepareForSessionStart() { endedByReader = false }

    /// End releases presentation immediately; audio drain and recap stay host-owned.
    func releaseEndedCall() {
        endedByReader = true
        pinned = false
        dismissedByReader = true
        clearStartupFailure()
        callEndReleases &+= 1
        NotificationCenter.default.post(name: .copilotLiveDidChange, object: nil)
    }

    /// The reader took the notch back — "Leave it running", a dismissed
    /// suggestion, a dismissed failure, or unpinning a live call.
    ///
    /// A dismissal is a decision about the *notch*, not about the call, and it
    /// has to outlive the event that follows it. Without this, the next status
    /// change after "Leave it running" either closed the notch under the reader
    /// or moved them to Home — the two things they had just declined by pressing
    /// the button. Cleared by anything that legitimately takes the notch again:
    /// a call starting, a sign-in, a failure worth reading.
    @Published private(set) var dismissedByReader = false

    /// A call has been asked for and has not come up yet.
    ///
    /// Its own state rather than a variant of `isLive`: nothing is being captured
    /// yet. It buys panel appearing on press instead of up to four seconds later,
    /// with host startup drawn inside it.
    @Published private(set) var starting = false

    /// The call has stopped capturing and is being written up.
    ///
    /// Holds the notch the way `starting` does, and for the same reason: this is
    /// a stretch of seconds where the user has just pressed something and is
    /// owed an answer about what it did. Previously the panel simply went on
    /// showing the live call — `running` stayed true until the host exited — and
    /// then disappeared without ever acknowledging the press.
    @Published private(set) var ending = false

    /// A start was asked for and ended without a call.
    ///
    /// Its own state because the alternative was silence. `starting` going false
    /// without `isLive` going true was treated as "nothing to show": the notch
    /// unpinned, the panel was replaced by the tab with its Start button back on
    /// it, and a start that failed became indistinguishable from one that was
    /// never pressed. The host had already said what went wrong — it just had
    /// nowhere to say it.
    ///
    /// So a failed start holds the notch exactly the way a starting one does,
    /// and the panel says which step it got to and offers the press again.
    @Published private(set) var startupFailed = false

    /// What the host said on the way down, kept because `lastResult` is
    /// overwritten by whatever the engine does next.
    @Published private(set) var startupFailure: String?

    /// The last step the host reported before it stopped reporting. The status
    /// clears `startupStage` when the host goes, which would otherwise leave the
    /// failure panel unable to say where it got to.
    @Published private(set) var lastStartupStage: String?

    /// A sign-in is waiting for the user, so the notch shows a field for the code
    /// instead of a call.
    ///
    /// Deliberately separate from `isLive`: this happens *before* a call exists —
    /// typically because someone started a meeting without being signed in — and it
    /// must hold the notch open on its own.
    @Published private(set) var signInActive = false

    /// An answer has arrived that the reader has not looked at.
    ///
    /// Lives here rather than in the panel because two views need it: the panel,
    /// which clears it when the answer is shown, and the notch's header band,
    /// which is where the cue is drawn — a dot beside the capture glyphs, so an
    /// answer landing while the recap is up is visible without the panel
    /// changing under the reader.
    @Published private(set) var unreadAnswer = false

    func markUnreadAnswer() { unreadAnswer = true }
    func clearUnreadAnswer() { unreadAnswer = false }

    /// The single question `BoringViewModel.close()` and the panel's sharing
    /// type both ask.
    var pinsNotchOpen: Bool {
        if endedByReader { return false }
        // A finished Quiz holds the notch so its answers can still be read — but
        // only until the reader lets it go, or the pin would be a control that
        // did nothing on that surface.
        if quizOutcome != nil { return !dismissedByReader }
        return (isLive || starting || ending || startupFailed || signInActive) && pinned
    }

    /// The size the notch should open to right now.
    var preferredOpenSize: CGSize {
        // A sign-in needs a line of text and a field, so it uses the compact size
        // whatever the call layout happens to be.
        // Filing a document outranks the rest: it is a two-column surface and at
        // a normal tab's height its own drop target falls off the bottom.
        if NotchDropRouter.shared.isChoosing { return dropChooserNotchSize }
        if CallaKnowledgeAttach.shared.isPresenting {
            // Only the drop needs the taller surface: it still has to show what
            // was dropped *and* the meetings it could go to. Arriving from the
            // calendar the meeting is already settled, so it is one column and
            // a line to type — a normal tab, like every other pane.
            return CallaKnowledgeAttach.shared.presetTarget == nil ? knowledgeNotchSize : openNotchSize
        }
        if endedByReader { return openNotchSize }
        if signInActive { return openNotchSize }
        // A starting call uses the full live size it is about to become, so the
        // notch does not resize under the reader the moment capture begins.
        // Compact, not the live slab.
        //
        // Startup has four short lines to show and a failure has three; the live
        // panel has a transcript beside an answer. Opening at the full size for
        // all of them meant the notch went straight to a mostly empty rectangle
        // and stayed there whether or not a call ever arrived. It grows into the
        // full size in `apply(running:)` — at the moment recording begins, which
        // is the moment the room starts carrying something.
        // Only while the session still holds the notch. After "Leave it
        // running" the panel belongs to whatever tab the reader went to, and
        // this was sizing every open — Home, Usage, the shelf — to the call's
        // compact height for the whole length of the write-up.
        if (starting || startupFailed || ending), !isLive, pinned { return CallaPanelSize.compact }
        guard isLive else { return openNotchSize }
        // Compact is genuinely smaller. Keeping the full slab for both layouts
        // meant collapsing bought nothing but empty card — the state and the
        // clock live in the header band either way, so the call is still
        // visibly running at the smaller size.
        // The user's own numbers, not the constants. Clamped on read.
        // The notch plus three short lines: an island, not a panel.
        // Wide enough for status beside the notch; as tall as its text needs.
        // Zen keeps compact's width: resting and hovering change only the height.
        if ambientShowing { return CGSize(width: CallaPanelSize.compact.width, height: ambientHeight) }
        return layout == .full ? CallaPanelSize.full : CallaPanelSize.compact
    }

    /// Hovering the ambient summary brings back the collapsed panel, whichever
    /// layout was last used.
    func collapseForHover() {
        guard layout != .compact else { return }
        withAnimation(.smooth(duration: 0.28)) { layout = .compact }
        NotificationCenter.default.post(name: .copilotLiveDidChange, object: nil)
    }

    /// Bumped whenever the panel-size settings change.
    ///
    /// The size itself is a computed property, so nothing can observe it. This
    /// is what `ContentView` watches to re-apply the size while a slider is
    /// being dragged — without it the setting reads as broken: you drag during a
    /// call, nothing moves, and the only way to see the result is to collapse
    /// the panel and open it again.
    @Published private(set) var panelSizeRevision = 0

    private var cancellables: Set<AnyCancellable> = []

    private init() {
        CallaEngineClient.shared.$status
            // Keep decode compatibility with older hosts, but only capture state
            // may open live panel.
            .map { $0.copilot.isRecording || $0.quiz.active }
            .removeDuplicates()
            .sink { [weak self] running in
                self?.apply(running: running)
            }
            .store(in: &cancellables)

        Defaults.publisher(
            keys: .callaPanelWidth, .callaPanelHeight,
            .callaCompactPanelWidth, .callaCompactPanelHeight
        )
        .sink { [weak self] in
            guard let self else { return }
            self.panelSizeRevision &+= 1
        }
        .store(in: &cancellables)

        CallaEngineClient.shared.$launchingCall
            .combineLatest(CallaEngineClient.shared.$status.map(\.copilot.starting))
            .map { $0 || $1 }
            .removeDuplicates()
            .sink { [weak self] starting in
                self?.apply(starting: starting)
            }
            .store(in: &cancellables)

        // Remembered while it is being reported, because the failure panel needs
        // it after the host has stopped reporting anything.
        CallaEngineClient.shared.$status
            .map(\.copilot.startupStage)
            .removeDuplicates()
            .sink { [weak self] stage in
                guard let stage else { return }
                self?.lastStartupStage = stage
            }
            .store(in: &cancellables)

        CallaEngineClient.shared.$endingCall
            .combineLatest(CallaEngineClient.shared.$status.map(\.copilot.isFinishing))
            .map { $0 || $1 }
            .removeDuplicates()
            .sink { [weak self] ending in
                self?.apply(ending: ending)
            }
            .store(in: &cancellables)

        CallaEngineClient.shared.$status
            .map(\.copilot.isSigningIn)
            .removeDuplicates()
            .sink { [weak self] signingIn in
                self?.apply(signingIn: signingIn)
            }
            .store(in: &cancellables)
    }

    private func apply(starting: Bool) {
        guard !endedByReader else { self.starting = false; return }
        guard starting != self.starting else { return }
        self.starting = starting

        // Only opens the notch. A call that comes up hands straight over to the
        // live panel — `apply(running:)` does that, and clears this — so
        // reaching here with `starting` false and nothing live means the start
        // ended without a call: the host died, was refused a permission, or the
        // client's thirty-second launch deadline expired.
        //
        // That used to unpin and let the notch close. It is the one moment in
        // the whole flow where the user is definitely looking at the notch and
        // definitely wants to be told something, so it holds instead.
        guard starting, Defaults[.callaCopilotEnabled] else {
            if !starting, !isLive {
                if Defaults[.callaCopilotEnabled] {
                    startupFailed = true
                    startupFailure = CallaEngineClient.shared.status.copilot.lastResult
                    layout = .compact
                    pin()
                } else {
                    pinned = false
                }
            }
            NotificationCenter.default.post(name: .copilotLiveDidChange, object: nil)
            return
        }
        clearStartupFailure()
        layout = .compact
        pin()
        reveal()
    }

    /// Forgets a failed start. Called when one succeeds, when the reader
    /// dismisses it, and when they press the button again.
    func clearStartupFailure() {
        guard startupFailed || startupFailure != nil else { return }
        startupFailed = false
        startupFailure = nil
    }

    /// Puts the notch back the way a dismissed call does: the panel goes, the
    /// call does not restart, and nothing else is disturbed.
    func dismissStartupFailure() {
        clearStartupFailure()
        lastStartupStage = nil
        pinned = false
        dismissedByReader = true
        NotificationCenter.default.post(name: .copilotLiveDidChange, object: nil)
    }

    private func apply(ending: Bool) {
        guard ending != self.ending else { return }
        self.ending = ending
        guard ending, Defaults[.callaCopilotEnabled] else {
            // The write-up is done. Nothing to hold the notch for any more, and
            // nothing to say — History has the recap.
            if !isLive { pinned = false }
            NotificationCenter.default.post(name: .copilotLiveDidChange, object: nil)
            return
        }
        // Recording has stopped, so the live panel's claim has stopped being
        // true. `apply(running:)` will clear `isLive` on the same status, but
        // the order of the two is not guaranteed and the panel must not be a
        // live call for even one frame after capture closed.
        isLive = false
        layout = .compact
        guard !endedByReader else {
            pinned = false
            NotificationCenter.default.post(name: .copilotLiveDidChange, object: nil)
            return
        }
        pin()
        reveal()
    }

    private func apply(signingIn: Bool) {
        guard signingIn != signInActive else { return }
        signInActive = signingIn

        if signingIn {
            guard Defaults[.callaCopilotEnabled] else { return }
            layout = .compact
            pin()
            reveal()
        } else {
            // A finished sign-in hands the notch back to whatever the call is
            // doing, rather than closing it out from under a call that started.
            if isLive { pin() } else { pinned = false }
            layout = isLive ? .full : .compact
            NotificationCenter.default.post(name: .copilotLiveDidChange, object: nil)
        }
    }

    private func apply(running: Bool) {
        // An in-flight capture status after End cannot reopen the presentation.
        // A fresh explicit launch resets this in prepareForSessionStart().
        if running, endedByReader { return }
        guard running != isLive else { return }
        isLive = running
        // A new session starts at its newest answer, and a finished one must not
        // leave a stale id pointing into the next session's history.
        quizAnswerCursor = .latest
        if running { quizOutcome = nil }

        if running {
            guard Defaults[.callaCopilotEnabled] else { return }
            starting = false
            ending = false
            clearStartupFailure()
            lastStartupStage = nil
            layout = .full
            pin()
            reveal()
        } else {
            pinned = false
            layout = .full
            NotificationCenter.default.post(name: .copilotLiveDidChange, object: nil)
        }
    }

    /// Brings the notch to the copilot tab and opens it at the live size.
    private func reveal() {
        let coordinator = BoringViewCoordinator.shared
        coordinator.currentView = .copilot
        NotificationCenter.default.post(name: .copilotLiveDidChange, object: nil)
    }

    /// Steps back through the session's answers. Stepping off the newest stops
    /// the panel following new arrivals until the reader returns to the end.
    func quizAnswerBack(history: [QuizFinalAnswer]) {
        quizAnswerCursor = CallaQuizPresentation.back(quizAnswerCursor, history: history)
    }

    func quizAnswerForward(history: [QuizFinalAnswer]) {
        quizAnswerCursor = CallaQuizPresentation.forward(quizAnswerCursor, history: history)
    }

    /// A Quiz session has ended. Worth holding the notch for only when there is
    /// something to report: an answer to read, or a reason it stopped.
    func noteQuizEnded(_ snapshot: QuizSessionSnapshot) {
        let hasSomethingToSay = !snapshot.answerHistory.isEmpty
            || (snapshot.failure?.isEmpty == false)
        guard hasSomethingToSay else { return }
        quizOutcome = snapshot
        quizAnswerCursor = .latest
    }

    func dismissQuizOutcome() {
        quizOutcome = nil
        NotificationCenter.default.post(name: .copilotLiveDidChange, object: nil)
    }

    func scrollQuizAnswer(by lines: Int) {
        quizAnswerScroll = QuizAnswerScrollRequest(tick: quizAnswerScroll.tick + 1, lines: lines)
    }

    func quizAnswerFollowLatest() {
        quizAnswerCursor = .latest
    }

    /// Drops a cursor whose answer has been trimmed out of the capped history.
    func reconcileQuizAnswerCursor(history: [QuizFinalAnswer]) {
        let reconciled = CallaQuizPresentation.reconcile(quizAnswerCursor, history: history)
        if reconciled != quizAnswerCursor { quizAnswerCursor = reconciled }
    }

    /// The answer the panel is showing, which is what the copy shortcut means.
    func quizDisplayedAnswer(history: [QuizFinalAnswer]) -> QuizFinalAnswer? {
        CallaQuizPresentation.position(quizAnswerCursor, history: history).answer
    }

    func toggleLayout() {
        // Nothing to toggle while a sign-in owns the panel.
        guard isLive, !signInActive else { return }
        // The same curve the notch resizes on, so the content and the window
        // move together instead of one snapping while the other glides.
        withAnimation(.smooth(duration: 0.28)) {
            layout = layout == .full ? .compact : .full
        }
        // A layout change is a size change, so the open notch has to be told.
        NotificationCenter.default.post(name: .copilotLiveDidChange, object: nil)
    }

    /// The session taking the notch. Always through here, so no path can pin
    /// the panel while still believing the reader wants it gone.
    private func pin() {
        pinned = true
        dismissedByReader = false
    }

    /// Sets the live layout outright.
    ///
    /// `toggleLayout` is the reader's own control; this is the resize editor
    /// putting the panel into the layout it is being asked to size. Without it,
    /// picking "Call · Compact" while a call is running sized the compact
    /// profile against the full layout's content.
    func setLayout(_ layout: Layout) {
        guard isLive, !signInActive, layout != self.layout else { return }
        self.layout = layout
        NotificationCenter.default.post(name: .copilotLiveDidChange, object: nil)
    }

    /// Lets the notch close while the call keeps running.
    ///
    /// Re-pins on the next suggestion, so dismissing is "not now", not "never
    /// again for this call".
    func dismiss() {
        pinned = false
        dismissedByReader = true
        // The notch is only ever told about a *pin* change by this notification.
        // Without it "Leave it running" left the call's panel parked open at the
        // call's size until some unrelated status change happened to fire.
        NotificationCenter.default.post(name: .copilotLiveDidChange, object: nil)
    }

    /// Changes whether a live call holds the notch open. Unpinning deliberately
    /// leaves the current panel on screen; normal notch close rules take over.
    /// Bumped when the reader explicitly lets the notch go.
    ///
    /// Releasing the pin cannot close the notch from here — the view model lives
    /// in the app, which is why `⌥⌘.` calls `dismiss()` *and* `vm.close()` itself.
    /// Dropping `pinned` alone therefore did nothing visible while a session was
    /// live: `syncCopilotLiveNotch` bails out for a live session, and with the
    /// pointer over another window there is no hover-out to trigger a close. So
    /// unpinning silently did nothing. This is the signal the notch acts on.
    @Published private(set) var notchReleases = 0

    func togglePin() {
        // A live session only. The key is global, so it fires with any app
        // focused — which is the point while a Quiz is running, but it must not
        // resurrect a *finished* one from whatever the reader is doing hours
        // later. The pin glyph on the ended panel still dismisses that surface.
        guard isLive, !signInActive else { return }
        if pinned {
            pinned = false
            dismissedByReader = true
            notchReleases += 1
        } else {
            pin()
            reveal()
        }
        NotificationCenter.default.post(name: .copilotLiveDidChange, object: nil)
    }

    /// Re-arms the pin — called when a fresh suggestion arrives after a dismiss.
    func repin() {
        guard isLive, !endedByReader else { return }
        pin()
    }
}

extension Notification.Name {
    /// Posted when the live session wants the notch opened or resized.
    static let copilotLiveDidChange = Notification.Name("copilotLiveDidChange")
}
