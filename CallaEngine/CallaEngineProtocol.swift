import Foundation

@objc protocol CallaEngineStatusObserver {
    /// Versioned status snapshot pushed after an engine-observed change.
    func callaEngineStatusDidChange(_ data: Data)
}

@objc protocol CallaEngineCallObserver {
    /// Typed v3 Call event. Status/file recovery remains fallback after reconnect.
    func callaEngineCallEvent(_ data: Data)
}

@objc protocol CallaEngineCodingObserver {
    /// Ordered Code event. Status is recovery state and never reconstructs this feed.
    func callaEngineCodingEvent(_ data: Data)
}

@objc protocol CallaEngineProtocol {
    func migrateBranding(_ includePreferences: Bool, with reply: @escaping (Data) -> Void)
    func privateSetup(_ request: Data, with reply: @escaping (Data) -> Void)
    func start(with reply: @escaping (Data) -> Void)
    func stop(with reply: @escaping (Data) -> Void)
    func applyPreferences(_ preferences: Data, with reply: @escaping (Data) -> Void)
    func status(with reply: @escaping (Data) -> Void)
    /// Retained weakly. Client keeps its regular status poll as reconnect fallback.
    func subscribeStatus(_ observer: CallaEngineStatusObserver, with reply: @escaping (Data) -> Void)
    func subscribeCallEvents(_ observer: CallaEngineCallObserver, with reply: @escaping (Data) -> Void)
    func requestGatewayUpdate(with reply: @escaping (Data) -> Void)
    /// Owner UI starts, stops, or re-targets the live call copilot. The engine
    /// validates the command, then drives the unsandboxed capture host that
    /// owns the microphone and screen-recording grants.
    func copilotControl(_ command: Data, with reply: @escaping (Data) -> Void)
    /// Opens a call's folder in ~/Documents/Calls, or the root for an empty id.
    func revealCallFolder(_ callID: String, with reply: @escaping (Data) -> Void)
    /// Writes the app's settings snapshot to Downloads, for carrying to another Mac.
    func saveSettingsSnapshot(_ data: Data, with reply: @escaping (Data) -> Void)
    /// Writes a folder for every past call that lacks one.
    func exportPastCalls(with reply: @escaping (Data) -> Void)
    /// Call archive backend: sync now, sign in again, restore, dismiss a notice.
    func backendControl(_ command: Data, with reply: @escaping (Data) -> Void)
    /// Turns of the current call newer than `seq`; -1 asks for the whole tail.
    ///
    /// One of the few methods here that does not reply with `Status`. A
    /// transcript is far too large to ride the two-second status poll, and the
    /// notch app is sandboxed, so it cannot read the capture host's files
    /// itself — this is the only way that text reaches the UI. The cursor keeps
    /// the live panel's sub-second poll cheap: past the first read it almost
    /// always returns an empty array.
    func copilotTranscript(since seq: Int, with reply: @escaping (Data) -> Void)
    /// Every call this Mac has archived, newest first. Replies with
    /// `[CallSummary]`, not `Status`.
    func copilotCalls(with reply: @escaping (Data) -> Void)
    /// One archived call's full transcript. Replies with `[CallTurn]`.
    func copilotCallTranscript(_ callID: String, with reply: @escaping (Data) -> Void)
    /// What the copilot returned during that call.
    func copilotCallSuggestions(_ callID: String, with reply: @escaping (Data) -> Void)
    /// The prompts the copilot would actually send, as `[path: text]`.
    ///
    /// Replies with a JSON dictionary, not `Status`. The app used to carry its
    /// own copy of the default wording so the Prompts pane could show something,
    /// and the two drifted until the pane was previewing a JSON contract the host
    /// had not used in months. There is one source now, and this is how the
    /// sandboxed app reaches it.
    func copilotPrompts(with reply: @escaping (Data) -> Void)
    /// Read one separately persisted reviewed-recap draft.
    func copilotRecapDraft(_ callID: String, with reply: @escaping (Data) -> Void)
    /// Approve, reject, or delete a recap draft. Approval is only path to knowledge.
    func copilotRecapControl(_ command: Data, with reply: @escaping (Data) -> Void)
    /// List, name, confirm or merge a call's speakers, or forget remembered
    /// voices. Replies with the call's speakers and every remembered voice.
    func copilotSpeakerControl(_ command: Data, with reply: @escaping (Data) -> Void)
    /// Runs the capture host's `permissions` subcommand so the microphone and
    /// screen-recording prompts are attributed to the host's own signature.
    ///
    /// Asking from inside this service would prompt for — and grant to — the
    /// engine, which is not the process that captures anything. Same shape as
    /// the fix already applied to the Tutor host.
    func requestCopilotPermissions(with reply: @escaping (Data) -> Void)
    func submitAgyToken(_ token: String, with reply: @escaping (Data) -> Void)
    /// Create, edit, delete or list knowledge notes.
    ///
    /// The store lives on this side of the sandbox line, so every edit the app
    /// makes is one of these rather than a file write.
    func knowledgeControl(_ command: Data, with reply: @escaping (Data) -> Void)
    /// Calls recorded against a calendar event, or its whole recurring series.
    func copilotCallsForEvent(_ query: Data, with reply: @escaping (Data) -> Void)
    /// Screen Quiz v1. Capture stays in CallaCallHost; Engine owns authority,
    /// encrypted history, worker pool, and sanitized state.
    func listQuizWindows(with reply: @escaping (Data) -> Void)
    func listQuizModels(with reply: @escaping (Data) -> Void)
    func requestQuizPermissions(with reply: @escaping (Data) -> Void)
    /// Brings the Quiz council up before Start is pressed. Grants nothing: no
    /// target, no session, no capture authority — only a council to spawn.
    func warmQuiz(_ request: Data, with reply: @escaping (Bool) -> Void)
    func cancelQuizWarm(with reply: @escaping (Bool) -> Void)
    func startQuiz(_ configuration: Data, with reply: @escaping (Data) -> Void)
    func sendQuizCommand(_ command: Data, with reply: @escaping (Data) -> Void)
    func quizStatus(with reply: @escaping (Data) -> Void)
    func quizHistory(with reply: @escaping (Data) -> Void)
    func revealQuizCapture(_ captureID: String, with reply: @escaping (Data) -> Void)
    func gradeQuizAnswer(_ answerID: String, grade: Int, with reply: @escaping (Data) -> Void)
    func deleteQuizSession(_ sessionID: String, with reply: @escaping (Data) -> Void)
    func deleteAllQuizHistory(with reply: @escaping (Data) -> Void)
    func prepareWave(_ data: Data, with reply: @escaping (Data) -> Void)
    func registerCodingFolder(_ bookmark: Data, with reply: @escaping (Data) -> Void)
    func startCoding(_ configuration: Data, with reply: @escaping (Data) -> Void)
    func codingControl(_ command: Data, with reply: @escaping (Data) -> Void)
    func codingStatus(with reply: @escaping (Data) -> Void)
    func codingEvents(since sequence: Int, with reply: @escaping (Data) -> Void)
    func codingSessions(with reply: @escaping (Data) -> Void)
    func subscribeCodingEvents(_ observer: CallaEngineCodingObserver, with reply: @escaping (Data) -> Void)
}
