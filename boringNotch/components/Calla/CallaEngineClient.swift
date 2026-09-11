import Foundation
import Defaults
import CallaContracts

@objc protocol BoringCallaEngineStatusObserver {
    func callaEngineStatusDidChange(_ data: Data)
}

@objc protocol BoringCallaEngineCallObserver {
    func callaEngineCallEvent(_ data: Data)
}

@objc protocol BoringCallaEngineCodingObserver {
    func callaEngineCodingEvent(_ data: Data)
}

@objc protocol BoringCallaEngineObserver: BoringCallaEngineStatusObserver, BoringCallaEngineCallObserver, BoringCallaEngineCodingObserver {}

@objc protocol BoringCallaEngineProtocol {
    func start(with reply: @escaping (Data) -> Void)
    func stop(with reply: @escaping (Data) -> Void)
    func applyPreferences(_ preferences: Data, with reply: @escaping (Data) -> Void)
    func status(with reply: @escaping (Data) -> Void)
    func subscribeStatus(_ observer: BoringCallaEngineStatusObserver, with reply: @escaping (Data) -> Void)
    func subscribeCallEvents(_ observer: BoringCallaEngineCallObserver, with reply: @escaping (Data) -> Void)
    func requestGatewayUpdate(with reply: @escaping (Data) -> Void)
    func requestScreenRecording(with reply: @escaping (Data) -> Void)
    func requestAccessibility(with reply: @escaping (Data) -> Void)
    func startCourse(_ courseID: String, with reply: @escaping (Data) -> Void)
    func resumeCourse(with reply: @escaping (Data) -> Void)
    func stopLesson(with reply: @escaping (Data) -> Void)
    func ask(_ text: String, with reply: @escaping (Data) -> Void)
    func setTutorProvider(_ provider: String, with reply: @escaping (Data) -> Void)
    func tutorHistory(_ query: Data, with reply: @escaping (Data) -> Void)
    func tutorCapture(_ captureID: String, with reply: @escaping (Data) -> Void)
    func cancelTutorFeedback(_ feedbackID: String, generation: Int, with reply: @escaping (Data) -> Void)
    func courseControl(_ command: Data, with reply: @escaping (Data) -> Void)
    func copilotControl(_ command: Data, with reply: @escaping (Data) -> Void)
    /// Turns newer than `seq`. Pass -1 for the whole tail.
    func copilotTranscript(since seq: Int, with reply: @escaping (Data) -> Void)
    func copilotCalls(with reply: @escaping (Data) -> Void)
    func copilotCallTranscript(_ callID: String, with reply: @escaping (Data) -> Void)
    /// What the copilot returned during that call.
    func copilotCallSuggestions(_ callID: String, with reply: @escaping (Data) -> Void)
    func copilotRecapDraft(_ callID: String, with reply: @escaping (Data) -> Void)
    func copilotRecapControl(_ command: Data, with reply: @escaping (Data) -> Void)
    /// The prompts the copilot would actually send, as `[path: text]`.
    func copilotPrompts(with reply: @escaping (Data) -> Void)
    func requestCopilotPermissions(with reply: @escaping (Data) -> Void)
    func submitAgyToken(_ token: String, with reply: @escaping (Data) -> Void)
    /// Create, edit, delete or list knowledge notes. Replies with the resulting
    /// list every time, because this app is sandboxed and cannot read the store
    /// to check what happened.
    func knowledgeControl(_ command: Data, with reply: @escaping (Data) -> Void)
    /// Calls recorded against a calendar event, or its whole recurring series.
    func copilotCallsForEvent(_ query: Data, with reply: @escaping (Data) -> Void)
    func listQuizWindows(with reply: @escaping (Data) -> Void)
    func listQuizModels(with reply: @escaping (Data) -> Void)
    func requestQuizPermissions(with reply: @escaping (Data) -> Void)
    /// Spawns the Quiz council before Start. Carries a council and nothing else:
    /// no target, no session, no capture authority.
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
    func subscribeCodingEvents(_ observer: BoringCallaEngineCodingObserver, with reply: @escaping (Data) -> Void)
}

struct CallaEnginePreferences: Codable, Equatable {
    let captureEnabled: Bool
    let allowedBundleIDs: [String]
    let captureLongEdge: Int
    let tooltipWidth: Int
    let hideTooltipOnHover: Bool
    let cursorSize: Int
    let tooltipOpacity: Double
    let showStatusHUD: Bool
    let learnerID: String
    let hiddenCourseIDs: [String]
    let quizEnabled: Bool

    static var current: CallaEnginePreferences {
        let learnerID = learnerIdentifier()
        return CallaEnginePreferences(
            captureEnabled: Defaults[.callaCaptureEnabled],
            allowedBundleIDs: Defaults[.callaAllowedBundleIDs],
            captureLongEdge: Defaults[.callaCaptureLongEdge],
            tooltipWidth: Defaults[.callaTooltipWidth],
            hideTooltipOnHover: Defaults[.callaHideTooltipOnHover],
            cursorSize: Defaults[.callaCursorSize],
            tooltipOpacity: Defaults[.callaTooltipOpacity],
            showStatusHUD: Defaults[.callaShowStatusHUD],
            learnerID: learnerID,
            hiddenCourseIDs: Defaults[.callaHiddenCourseIDs],
            quizEnabled: Defaults[.callaQuizEnabled]
        )
    }

    private static func learnerIdentifier() -> String {
        let stored = Defaults[.callaLearnerID]
        if stored.range(of: "^[A-Za-z0-9-]{8,80}$", options: .regularExpression) != nil { return stored }
        let identifier = "learner-" + UUID().uuidString.lowercased()
        Defaults[.callaLearnerID] = identifier
        return identifier
    }
}

struct CallaEngineStatus: Codable, Equatable {
    var running = false
    /// Whether the Tutor host answers its socket, as opposed to whether the
    /// engine believes it started it.
    var hostReady = false
    var socketPath = ""
    var screenRecordingGranted = false
    var accessibilityGranted = false
    var gatewayReachable = false
    var releaseVersion: String? = nil
    var previousGatewayRelease: String? = nil
    var lastGatewayUpdate: String? = nil
    var lastGatewayUpdateAt: Date? = nil
    var lastResult = "Engine not started"
    var diagnostics: [String] = []
    var activeLesson: CallaActiveLesson? = nil
    var courses: [CallaCourseSnapshot] = []
    var tutorIntelligence: CallaTutorIntelligenceStatus? = nil
    var copilot = CallaCopilotStatus()
    var quiz = QuizSessionSnapshot()
}

struct CallaTutorIntelligenceStatus: Codable, Equatable {
    var selectedProvider = "local"
    var activeProvider: String? = nil
    var pendingFeedbackID: String? = nil
    var activeRunID: String? = nil
    var activeRevision: String? = nil
    var activeGeneration: Int? = nil
    var localAgyAvailable = false
    var localAgyVersion: String? = nil
    var localAgyAuthenticated = false
    var gatewayFeedbackAvailable = false
    var gatewayAuthoringAvailable = false
    var engineIngressHealthy = false
    var captureAvailable = false
    var lastProvider: String? = nil
    var lastModel: String? = nil
    var lastLatencyMilliseconds: Int? = nil
    var lastFallbackReason: String? = nil
    var lastDeterministicVerification: String? = nil
    var historyByteCount = 0
    var captureCount = 0
    var storageFailure: String? = nil
    var protocolVersion = 4
}

struct CallaTutorHistoryQuery: Codable { let cursor: String?; let query: String?; let pageSize: Int }
struct CallaTutorFeedback: Codable, Identifiable, Equatable {
    let id: String; let runID: String; let generation: Int; let question: String?; let context: String
    let state: String; let answer: String?; let selectedProvider: String?; let actualProvider: String?
    let model: String?; let latencyMilliseconds: Int?; let fallbackReason: String?; let errorCode: String?
    let captureID: String?; let createdAt: Date
    enum CodingKeys: String, CodingKey {
        case id, question, context, state, answer, model
        case runID = "runID", generation, selectedProvider = "selectedProvider", actualProvider = "actualProvider"
        case latencyMilliseconds = "latencyMilliseconds", fallbackReason = "fallbackReason", errorCode = "errorCode"
        case captureID = "captureID", createdAt = "createdAt"
    }
}
struct CallaTutorHistoryPage: Codable, Equatable { let entries: [CallaTutorFeedback]; let nextCursor: String? }

/// Live-call state, carried on the engine's existing status poll.
struct CallaCopilotStatus: Codable, Equatable {
    var available = false
    var running = false
    var callID: String? = nil
    var generation = 0
    var persona = "generic"
    var startedAt: Date? = nil
    var turnCount = 0
    var gatewayConnected = false
    var micActive = false
    var systemAudioActive = false
    var headline: String? = nil
    var angles: [String] = []
    var confirm: [String] = []
    var detectedQuestion: String? = nil
    var citationLabels: [String] = []
    var grounding: String? = nil
    var answerLatencyMs: Int? = nil
    /// Where the conversation has got to, refreshed on every reply. This is
    /// what the panel shows between questions.
    var summary: String? = nil
    /// Raised and unresolved, likeliest to come back to you first.
    var openQuestions: [String] = []
    var suggestionAfterSeq: Int? = nil
    /// Who is speaking right now: `me`, `them`, or nobody.
    var speaking: String? = nil
    /// A request is in flight.
    var thinking = false
    /// Which job is in flight: `answer` or `summary`.
    var working: String? = nil
    var questionWorking = false
    var summaryWorking = false
    /// The newest pointer answers a question, rather than remarking on a statement.
    var answering = false
    /// Warm and ready, but deliberately not recording — the pre-roll before a
    /// scheduled meeting. `micActive` and `systemAudioActive` are both false while
    /// this is true, which is exactly the claim the pre-roll card makes.
    var prewarming = false
    /// A host process exists and is still paying its fixed costs — loading the
    /// model, opening the microphone. Never true at the same time as `running`.
    ///
    /// Before this existed the notch had nothing between "no call" and "call
    /// live", and the ~2s the host takes to come up was drawn as the former: the
    /// Start button sat there unchanged and the press read as lost.
    var starting = false
    /// Which fixed cost the host is on: `launching`, `permissions`, `model`,
    /// `capture`, `listening`.
    var startupStage: String? = nil
    var modelLoaded = false
    /// Both local lanes are open, so the next question is answered at
    /// conversation speed rather than paying the bootstrap.
    var brainWarm = false
    /// Nil when the gateway is not part of this call at all — standby off, or a
    /// local call that has not failed over. False means "not connected yet".
    var gatewayWarm: Bool? = nil
    /// The meeting this call was armed for.
    var meetingTitle: String? = nil
    var meetingStartsAt: Date? = nil

    /// A call that is actually capturing.
    ///
    /// `running` means only that a host process exists, which is also true
    /// throughout the pre-roll — so anything that draws "you are in a call" must
    /// ask this instead, or the notch will claim to be listening while both
    /// microphones are stopped.
    var isRecording: Bool { running && !prewarming }

    /// The end-of-call work, as the host reports it — or as this app claimed it
    /// the moment the button was pressed, whichever came first.
    var isFinishing: Bool {
        finishing
            || lifecycleState == CallLifecycleStateName.stopping
            || lifecycleState == CallLifecycleStateName.processingRecap
    }
    /// Which brain answered this call: "local" or "gateway". Shown in the notch,
    /// because a failover the user cannot see looks exactly like a broken copilot.
    var activeProvider: String? = nil
    /// The model that answered, or why the local brain stood down.
    var providerDetail: String? = nil
    /// Whether the local Antigravity CLI is installed at all.
    var agyAvailable = false
    var agyVersion: String? = nil
    /// The call currently being re-transcribed, if any.
    var retranscribingCallID: String? = nil
    /// Whether a previous credential is set aside and can be put back.
    var agyBackupAvailable = false
    /// Where the sign-in has got to: `starting`, `opening_browser`,
    /// `awaiting_code`, `exchanging`, `signed_in`, `failed`.
    var agyLoginStage: String? = nil
    /// The Google sign-in URL while a sign-in is running.
    var agyLoginURL: String? = nil
    /// True exactly while agy is waiting for the authorization code.
    var agyAwaitingCode = false
    /// Whether `agy` has valid OAuth credentials on disk.
    var agyLoggedIn = false
    /// The Google account `agy` is authenticated as.
    var agyAccount: String? = nil
    var lastResult: String? = nil
    /// Reported by the capture host about itself. The engine used to preflight
    /// these in its own process, which answered a question nobody asked: TCC
    /// grants are keyed to the signature that captures, and that is the host.
    var hostMicGranted = false
    var hostScreenGranted = false
    /// False until the host has reported. Absent is not the same as denied —
    /// after a fresh install nothing has asked yet.
    var hostPermissionsKnown = false
    var modelDownload: CallaModelDownload? = nil
    /// Where the host is in its own lifecycle: `capturing`, `stopping`,
    /// `processingRecap`, `finished`.
    var lifecycleState: String? = nil
    /// 0…1 while the recap is being written.
    var recapProgress: Double? = nil
    /// Capture has stopped and the call is being written up. The seconds this
    /// covers used to be invisible: `running` stayed true until the process
    /// exited, so End call changed nothing on screen and then the panel
    /// disappeared without explanation.
    var finishing = false

    var hasSuggestion: Bool {
        guard let headline else { return false }
        return !headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A sign-in is on screen and waiting for the user.
    ///
    /// True from the moment the link exists, because that is the moment `agy`
    /// starts accepting the code — and the moment the notch should be showing a
    /// field to paste it into.
    var isSigningIn: Bool {
        switch agyLoginStage {
        case "checking", "starting", "opening_browser", "awaiting_code", "exchanging": true
        // `failed` stays on screen so the reason can be read and retried.
        case "failed": true
        default: agyLoginURL != nil || agyAwaitingCode
        }
    }

    /// Whether to offer the code field.
    ///
    /// From the moment a link exists, not from a narrower "awaiting" flag: `agy`
    /// accepts the pasted code as soon as it prints the URL, and a field that is
    /// missing while the user is holding a code is the whole complaint.
    var canAcceptCode: Bool {
        agyLoginURL != nil || agyAwaitingCode || agyLoginStage == "exchanging"
    }
}

/// The lifecycle values the host writes. Named rather than spelled inline: the
/// host, the engine and this app each hold their own copy of the vocabulary, and
/// a typo in a string literal fails silently in exactly the place nobody looks.
enum CallLifecycleStateName {
    static let capturing = "capturing"
    static let stopping = "stopping"
    static let processingRecap = "processingRecap"
    static let finished = "finished"
}

/// Progress of a transcription model fetch.
///
/// The first call on a new Mac blocks for minutes pulling ~487MB with no sign
/// that anything is happening; this is what makes that visible.
struct CallaModelDownload: Codable, Equatable {
    let model: String
    let receivedBytes: Int64
    let totalBytes: Int64
    /// `downloading`, `verifying`, `ready` or `failed`.
    let state: String
    let message: String?

    enum CodingKeys: String, CodingKey {
        case model, state, message
        case receivedBytes = "received_bytes"
        case totalBytes = "total_bytes"
    }

    var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(receivedBytes) / Double(totalBytes)))
    }

    var isActive: Bool { state == "downloading" || state == "verifying" }
}

/// One transcribed turn, tagged with the side of the call it came from.
///
/// `source` is what makes the copilot possible at all: the two capture legs are
/// never mixed, so "who said this" is known rather than inferred.
struct CallaCallTurn: Codable, Equatable, Identifiable {
    let id: UUID
    let seq: Int
    let source: String
    let t0: Double
    let t1: Double
    let text: String
    let confidence: Double?

    var isRemote: Bool { source == "them" }
}

/// One suggestion as it was archived during a call.
///
/// Mirrors the engine's `CopilotSuggestionFile`. Kept so a finished call can show
/// what the copilot actually said, not only what was said to it.
struct CallaCopilotArchivedSuggestion: Codable, Equatable, Identifiable {
    let callID: String
    let afterSeq: Int
    let headline: String
    let angles: [String]
    let confirm: [String]
    let question: String?
    let citations: [String]?
    let latencyMs: Int?
    let summary: String?
    let openQuestions: [String]?

    var id: Int { afterSeq }

    enum CodingKeys: String, CodingKey {
        case callID = "call_id"
        case afterSeq = "after_seq"
        case headline, angles, confirm, question, citations, summary
        case latencyMs = "latency_ms"
        case openQuestions = "open_questions"
    }
}

/// Typed copilot command. Mirrors the engine's own decoder; the engine
/// re-validates every field before anything is spawned.
struct CallaCopilotCommand: Codable {
    let action: String
    let persona: String?
    let model: String?
    let callID: String?
    let question: String?
    /// Prompt text the user edited. Never reaches a process argument — the
    /// engine hands it to the capture host on stdin.
    let profile: CallaCopilotProfile?
    /// "local" or "gateway". Absent leaves the engine's stored choice alone.
    let provider: String?
    /// Live model tier for the local brain: fast | balanced | deep.
    let tier: String?
    /// Exact model for the end-of-call pass.
    let summaryModel: String?
    /// Whether the gateway may answer when the local brain cannot.
    let fallback: Bool?
    /// When the gateway socket opens: off | on-failure | warm.
    let gatewayStandby: String?
    /// The calendar event this call is for.
    ///
    /// Only the identity and the event's own fields travel. The knowledge itself
    /// is composed by the engine, which is the only process that can open the
    /// store — this one is sandboxed and the file is not in its container.
    let meeting: CallaMeeting?
    /// Nil uses automatic scope matching; empty freezes explicit empty pack.
    let selectedKnowledgeNoteIDs: [String]?

    enum CodingKeys: String, CodingKey {
        case action, persona, model, profile, provider, tier, fallback, meeting, question
        case selectedKnowledgeNoteIDs = "selected_knowledge_note_ids"
        case summaryModel = "summary_model"
        case gatewayStandby = "gateway_standby"
        case callID = "call_id"
    }

    init(action: String,
         persona: String? = nil,
         model: String? = nil,
         callID: String? = nil,
         question: String? = nil,
         profile: CallaCopilotProfile? = nil,
         provider: String? = nil,
         tier: String? = nil,
         summaryModel: String? = nil,
         fallback: Bool? = nil,
         gatewayStandby: String? = nil,
         meeting: CallaMeeting? = nil,
         selectedKnowledgeNoteIDs: [String]? = nil) {
        self.action = action
        self.persona = persona
        self.model = model
        self.callID = callID
        self.question = question
        self.profile = profile
        self.provider = provider
        self.tier = tier
        self.summaryModel = summaryModel
        self.fallback = fallback
        self.gatewayStandby = gatewayStandby
        self.selectedKnowledgeNoteIDs = selectedKnowledgeNoteIDs
        self.meeting = meeting
    }
}

struct CallaRecapItem: Codable, Identifiable, Equatable {
    let id: String
    let kind: String
    let text: String
    let fromSeq: Int
    let toSeq: Int
    let resolved: Bool

    enum CodingKeys: String, CodingKey {
        case id, kind, text
        case fromSeq = "from_seq"
        case toSeq = "to_seq"
        case resolved
    }
}

struct CallaRecapDraft: Codable, Equatable {
    let callID: String
    let overview: String
    let items: [CallaRecapItem]
    let provider: String?
    let model: String?
    let failure: String?
    let reviewState: String

    enum CodingKeys: String, CodingKey {
        case overview, items, provider, model, failure
        case callID = "call_id"
        case reviewState = "review_state"
    }
}

private struct CallaRecapCommand: Codable {
    let action: String
    let callID: String
    enum CodingKeys: String, CodingKey { case action; case callID = "call_id" }
}

/// A calendar event, on its way to the copilot.
struct CallaMeeting: Codable, Equatable {
    var eventID: String?
    var seriesID: String?
    var title: String?
    var startsAt: Double?
    var endsAt: Double?
    var location: String?
    var attendees: [String]
    var notes: String?

    enum CodingKeys: String, CodingKey {
        case title, location, attendees, notes
        case eventID = "event_id"
        case seriesID = "series_id"
        case startsAt = "starts_at"
        case endsAt = "ends_at"
    }

    /// A meeting that did not come from the calendar.
    ///
    /// Declaring `init(_ event:)` below suppresses the memberwise init, and
    /// `WaveInterview` needs one: its meeting is a fixed identity in code, not
    /// an EventKit row.
    init(eventID: String?, seriesID: String?, title: String?,
         startsAt: Double?, endsAt: Double?, location: String?,
         attendees: [String], notes: String?) {
        self.eventID = eventID
        self.seriesID = seriesID
        self.title = title
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.location = location
        self.attendees = attendees
        self.notes = notes
    }

    /// Everything about an event that is worth telling a copilot, and nothing
    /// that is not. Attendee names rather than addresses where the calendar has
    /// them: a first name is what gets said out loud on the call.
    init(_ event: EventModel) {
        eventID = event.id
        seriesID = event.seriesID
        title = event.title
        startsAt = event.start.timeIntervalSince1970
        endsAt = event.end.timeIntervalSince1970
        location = event.location
        attendees = event.participants.map(\.name).filter { !$0.isEmpty }
        notes = event.notes
    }
}

extension WaveInterview {
    /// What every call start sends. No attendees: the calendar is not the
    /// source here, and inventing names would put unverified text in a prompt.
    ///
    /// Lives beside `CallaMeeting` rather than beside the identity so that the
    /// identity itself stays free of the engine client and can be tested on its
    /// own.
    static func meeting(for session: Session) -> CallaMeeting {
        CallaMeeting(eventID: session.eventID,
                     seriesID: seriesID,
                     title: session.chipTitle,
                     startsAt: startsAt.timeIntervalSince1970,
                     endsAt: endsAt.timeIntervalSince1970,
                     location: nil,
                     attendees: [],
                     notes: nil)
    }

    /// Whichever run the notch is currently armed for.
    static var session: Session { Session.stored(Defaults[.callaWaveSession]) }
    static var meeting: CallaMeeting { meeting(for: session) }
}

/// The user's own prompt text, carried to the gateway on `call_start`.
///
/// Every field is free text, which is exactly why it is fenced off into its own
/// type: it is a prompt payload and nothing else, and the engine's validator
/// refuses to let any of it name a process or become a command-line argument.
struct CallaCopilotProfile: Codable, Equatable {
    /// Who the user is — role, company, product. Injected into every call.
    let about: String?
    /// Replaces the gateway's own persona block for the persona in play.
    let personaGuidance: String?
    /// Replaces the gateway's base guidance. Empty means "use the gateway's".
    let baseGuidance: String?

    enum CodingKeys: String, CodingKey {
        case about
        case personaGuidance = "persona_guidance"
        case baseGuidance = "base_guidance"
    }

    var isEmpty: Bool {
        [about, personaGuidance, baseGuidance]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .allSatisfy(\.isEmpty)
    }

    /// Reads the current settings into a profile, or nil when nothing is set.
    @MainActor
    static var current: CallaCopilotProfile? {
        let settings = CallaCopilotSettings.current
        let persona = settings.persona
        let overrides = settings.personaOverrides
            .merging(settings.customPersonas) { override, _ in override }
        let profile = CallaCopilotProfile(
            about: nonEmpty(settings.aboutMe),
            personaGuidance: nonEmpty(overrides[persona] ?? ""),
            baseGuidance: nonEmpty(settings.baseGuidance))
        return profile.isEmpty ? nil : profile
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Single typed ownership boundary for Call Copilot preferences. Existing keys
/// remain storage during staged migration; callers use this snapshot, validate
/// it, then atomically apply it before telling engine about next-call settings.
@MainActor
struct CallaCopilotSettings: Codable, Equatable {
    static let schemaVersion = 5
    /// The spellings the engine's own validator accepts. Kept here so an imported
    /// settings file with a mode this build does not know is rejected at the
    /// boundary rather than silently resolving to the default in the host.
    static let gatewayStandbyModes: Set<String> = ["off", "on-failure", "warm"]

    var enabled: Bool
    var persona: String
    var liveModel: String
    var autoReveal: Bool
    var archiveRetranscribe: Bool
    var prerollEnabled: Bool
    var prerollLead: Double
    var panelSurface: String
    var aboutMe: String
    var personaOverrides: [String: String]
    var customPersonas: [String: String]
    var baseGuidance: String
    var provider: String
    var liveTier: String
    var summaryModel: String
    var fallback: Bool
    /// Optional so a settings file exported before this field existed still
    /// imports — the synthesized decoder demands every non-optional key, and one
    /// missing key would throw away the whole import.
    var gatewayStandby: String?

    static var current: Self {
        Self(enabled: Defaults[.callaCopilotEnabled], persona: Defaults[.callaCopilotPersona],
             liveModel: Defaults[.callaCopilotLiveModel], autoReveal: Defaults[.callaCopilotAutoReveal],
             archiveRetranscribe: Defaults[.callaCopilotArchiveRetranscribe],
             prerollEnabled: false, prerollLead: 120,
             panelSurface: Defaults[.callaCopilotPanelSurface], aboutMe: Defaults[.callaCopilotAboutMe],
             personaOverrides: Defaults[.callaCopilotPersonaOverrides], customPersonas: Defaults[.callaCopilotCustomPersonas],
             baseGuidance: Defaults[.callaCopilotBaseGuidance], provider: Defaults[.callaIntelligenceProvider],
             liveTier: Defaults[.callaIntelligenceLiveTier], summaryModel: Defaults[.callaIntelligenceSummaryModel],
             fallback: Defaults[.callaIntelligenceFallback],
             gatewayStandby: Defaults[.callaGatewayStandby])
    }

    static var defaults: Self {
        Self(enabled: true, persona: "generic", liveModel: "whisper-small-en", autoReveal: true,
             archiveRetranscribe: false, prerollEnabled: false, prerollLead: 120,
             panelSurface: "summary", aboutMe: "", personaOverrides: [:], customPersonas: [:],
             baseGuidance: "", provider: "local", liveTier: "fast",
             summaryModel: "gemini-3.1-pro-high", fallback: true, gatewayStandby: "warm")
    }

    static func exportData() throws -> Data { try JSONEncoder().encode(current) }

    static func importData(_ data: Data) throws {
        var value = try JSONDecoder().decode(Self.self, from: data)
        if value.panelSurface == "answers" { value.panelSurface = "question" }
        try apply(value)
        Defaults[.callaCopilotSettingsSchemaVersion] = schemaVersion
    }

    static func reset() { try? apply(defaults) }

    static func migrate() {
        // Retired automatic-start switches stay decode/storage compatible, but
        // every launch enforces manual-only policy even after an older build or
        // preferences restore wrote them back.
        Defaults[.callaCopilotAutoStartOnMeeting] = false
        Defaults[.callaCopilotPrerollEnabled] = false
        // Keep the stored mode and persona for future reuse. UI routing resolves
        // unavailable interview selections to Call without rewriting preferences.
        guard Defaults[.callaCopilotSettingsSchemaVersion] < schemaVersion else { return }
        var value = current
        if value.panelSurface == "answers" { value.panelSurface = "question" }
        if !["summary", "question"].contains(value.panelSurface) { value.panelSurface = "summary" }
        if !["local", "gateway"].contains(value.provider) { value.provider = "local" }
        if !["fast", "balanced", "deep"].contains(value.liveTier) { value.liveTier = "fast" }
        if !Self.gatewayStandbyModes.contains(value.gatewayStandby ?? "") { value.gatewayStandby = "warm" }
        if !["whisper-small-en", "whisper-base-en"].contains(value.liveModel) { value.liveModel = "whisper-small-en" }
        value.prerollEnabled = false
        try? apply(value)
        Defaults[.callaCopilotSettingsSchemaVersion] = schemaVersion
    }

    static func apply(_ value: Self) throws {
        guard ["summary", "question"].contains(value.panelSurface),
              ["local", "gateway"].contains(value.provider),
              ["fast", "balanced", "deep"].contains(value.liveTier),
              Self.gatewayStandbyModes.contains(value.gatewayStandby ?? "warm"),
              ["whisper-small-en", "whisper-base-en"].contains(value.liveModel) else {
            throw ValidationError.invalid
        }
        Defaults[.callaCopilotEnabled] = value.enabled
        Defaults[.callaCopilotPersona] = value.persona
        Defaults[.callaCopilotLiveModel] = value.liveModel
        Defaults[.callaCopilotAutoReveal] = value.autoReveal
        Defaults[.callaCopilotArchiveRetranscribe] = value.archiveRetranscribe
        // Legacy fields remain import/export compatible, but manual-only policy
        // cannot be changed by an older settings file.
        Defaults[.callaCopilotAutoStartOnMeeting] = false
        Defaults[.callaCopilotPrerollEnabled] = false
        Defaults[.callaCopilotPrerollLead] = 120
        Defaults[.callaCopilotPanelSurface] = value.panelSurface
        Defaults[.callaCopilotAboutMe] = value.aboutMe
        Defaults[.callaCopilotPersonaOverrides] = value.personaOverrides
        Defaults[.callaCopilotCustomPersonas] = value.customPersonas
        Defaults[.callaCopilotBaseGuidance] = value.baseGuidance
        Defaults[.callaIntelligenceProvider] = value.provider
        Defaults[.callaIntelligenceLiveTier] = value.liveTier
        Defaults[.callaIntelligenceSummaryModel] = value.summaryModel
        Defaults[.callaIntelligenceFallback] = value.fallback
        Defaults[.callaGatewayStandby] = value.gatewayStandby ?? "warm"
    }

    enum ValidationError: LocalizedError { case invalid
        var errorDescription: String? { "Copilot settings contain unsupported values" }
    }
}

/// One archived call, as listed in settings.
struct CallaCallSummary: Codable, Equatable, Identifiable {
    let id: String
    let startedAt: Date?
    let endedAt: Date?
    let endReason: String?
    let turnCount: Int
    let persona: String
    /// Whether raw audio is still on disk, which is what re-transcribing needs.
    let hasAudio: Bool
    /// Whether the large model has been over this call.
    var retranscribed: Bool = false
    /// Turns in that better pass, so the improvement is visible.
    var archivedTurnCount: Int = 0
    /// How many suggestions the copilot returned. Zero against a full transcript is
    /// the case worth noticing.
    var suggestionCount: Int = 0
    /// Which meeting this call belonged to. Absent on calls recorded before the
    /// app pinned one, which is why History cannot simply assume the interview.
    var eventID: String?
    var seriesID: String?

    /// Whether this call was a session of the Wave interview.
    var isWaveInterview: Bool {
        seriesID == WaveInterview.seriesID
            || eventID == WaveInterview.eventID
            || eventID == WaveInterview.rehearsalEventID
    }

    /// Whether it was a rehearsal rather than the sitting.
    var isWaveRehearsal: Bool { eventID == WaveInterview.rehearsalEventID }

    enum CodingKeys: String, CodingKey {
        case id, persona, retranscribed
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case endReason = "end_reason"
        case turnCount = "turn_count"
        case hasAudio = "has_audio"
        case archivedTurnCount = "archived_turn_count"
        case suggestionCount = "suggestion_count"
        case eventID = "event_id"
        case seriesID = "series_id"
    }

    var duration: TimeInterval? {
        guard let startedAt, let endedAt else { return nil }
        return max(0, endedAt.timeIntervalSince(startedAt))
    }

    var wasInterrupted: Bool { endReason == "interrupted" }
}

struct CallaActiveLesson: Codable, Equatable {
    let courseID: String
    let lessonID: String
    let lessonTitle: String
    let active: Bool

    enum CodingKeys: String, CodingKey { case courseID = "course_id", lessonID = "lesson_id", lessonTitle = "lesson_title", active }
}

struct CallaLessonSnapshot: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let stepCount: Int
    let completed: Bool
    let dueForReview: Bool

    enum CodingKeys: String, CodingKey { case id, title, completed; case stepCount = "step_count", dueForReview = "due_for_review" }
}

struct CallaCourseSnapshot: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let summary: String
    let icon: String
    let targetApp: String?
    let hidden: Bool
    let completedCount: Int
    let dueForReview: Bool
    let checkpointLessonID: String?
    let recentThread: [String]
    let lifecyclePhase: String?
    let lifecycleNote: String?
    let runtimeVersion: String?
    let runtimeBlocked: Bool
    let revision: String?
    let targetVersion: String?
    let authoredLessonCount: Int?
    let reviewWarnings: [String]
    let artifactDigest: String?
    let compilerVersion: String?
    let packContractVersion: Int?
    let validationReceipt: String?
    let preflightReceipt: String?
    let lessons: [CallaLessonSnapshot]

    enum CodingKeys: String, CodingKey {
        case id, title, summary, icon, hidden, lessons
        case targetApp = "target_app", completedCount = "completed_count", dueForReview = "due_for_review"
        case checkpointLessonID = "checkpoint_lesson_id", recentThread = "recent_thread"
        case lifecyclePhase = "lifecycle_phase", lifecycleNote = "lifecycle_note"
        case runtimeVersion = "runtime_version", runtimeBlocked = "runtime_blocked"
        case revision, targetVersion = "target_version", authoredLessonCount = "authored_lesson_count"
        case reviewWarnings = "review_warnings", artifactDigest = "artifact_digest", compilerVersion = "compiler_version"
        case packContractVersion = "pack_contract_version", validationReceipt = "validation_receipt", preflightReceipt = "preflight_receipt"
    }

    var lessonCount: Int { lessons.count }
    var nextLesson: CallaLessonSnapshot? { lessons.first { !$0.completed } ?? lessons.first { $0.id == checkpointLessonID } ?? lessons.first }
    /// Only published revisions cross from owner Course Settings into learner
    /// surfaces. Missing lifecycle fails closed.
    var isLearnerVisible: Bool { lifecyclePhase == "published" }
}

struct CallaCourseCommand: Codable {
    let action: String
    let courseID: String?
    let lessonID: String?
    let outline: String?
    let assetBundlePath: String?
    let targetApp: String?
    let targetVersion: String?

    init(action: String, courseID: String? = nil, lessonID: String? = nil, outline: String? = nil,
         assetBundlePath: String? = nil, targetApp: String? = nil, targetVersion: String? = nil) {
        self.action = action; self.courseID = courseID; self.lessonID = lessonID; self.outline = outline
        self.assetBundlePath = assetBundlePath; self.targetApp = targetApp; self.targetVersion = targetVersion
    }

    enum CodingKeys: String, CodingKey {
        case action
        case courseID = "course_id", lessonID = "lesson_id", outline
        case assetBundlePath = "asset_bundle_path", targetApp = "target_app", targetVersion = "target_version"
    }
}

extension Notification.Name {
    /// Posted the moment a lesson goes live, from wherever it was started —
    /// notch, Settings, or the calendar binding.
    static let callaLessonDidStart = Notification.Name("callaLessonDidStart")
    /// Posted when the gateway pushes a new answer pointer during a live call.
    static let callaCopilotSuggestion = Notification.Name("callaCopilotSuggestion")
}

@MainActor
final class CallaEngineClient: ObservableObject {
    static let shared = CallaEngineClient()

    @Published private(set) var status = CallaEngineStatus()
    /// When the last command reply set `status.quiz`, and to which session.
    ///
    /// `startQuiz` and `sendQuiz` write the snapshot their reply carries, but
    /// `apply(_:)` then replaces the whole status struct from a poll that may
    /// have been issued *before* the host registered the session. The panel then
    /// tore back to the preflight and flipped live again a tick later. A poll
    /// carrying an older view of the quiz is now ignored for a moment.
    private var quizCommandAppliedAt: Date?
    private var quizCommandSessionID: String?
    private static let quizCommandGrace: TimeInterval = 2

    @Published var pendingQuizMeeting: CallaMeeting?
    @Published private(set) var liveCallEvents: [CallEvent] = []
    @Published private(set) var coding = CodingSessionSnapshot()
    @Published private(set) var codingEvents: [CodingEvent] = []
    @Published var codingPreflight: CodingFolderPreflight?
    @Published private(set) var retainedCodingSessions: [CodingRetainedSession] = []
    @Published private(set) var codingTranscriptTail: [CallaCallTurn] = []
    private var codingEventSequence = -1
    private var codingTranscriptSequence = -1
    private var codingTranscriptFetchInFlight = false
    /// Session-only context exclusions belong to Quiz setup in Settings. The
    /// notch only starts the prepared session and never owns configuration UI.
    @Published var pendingQuizExcludedContextIDs = Set<String>()
    private var connection: NSXPCConnection?
    private var monitorTask: Task<Void, Never>?
    private lazy var statusObserver = StatusObserver(
        status: { [weak self] data in
            guard let self, let result = try? Self.decoder.decode(CallaEngineStatus.self, from: data) else { return }
            self.apply(result)
        },
        call: { [weak self] data in
            guard let self, let event = try? Self.decoder.decode(CallEvent.self, from: data),
                  event.callID == self.status.copilot.callID,
                  event.generation == self.status.copilot.generation else { return }
            self.liveCallEvents.removeAll { $0.callID != event.callID || $0.generation != event.generation }
            guard !self.liveCallEvents.contains(where: { $0.id == event.id }) else { return }
            self.liveCallEvents.append(event)
            if self.liveCallEvents.count > 2000 { self.liveCallEvents.removeFirst(self.liveCallEvents.count - 2000) }
        },
        coding: { [weak self] data in
            guard let event = try? Self.decoder.decode(CodingEvent.self, from: data) else { return }
            self?.applyCodingEvent(event)
        })

    private init() {}

    /// Which meeting the next session is being prepared for.
    ///
    /// Mode-neutral on purpose. Code resolves its project and brief from the
    /// same slot, and the version of this that also set `callaCopilotMode` threw
    /// a reader out of Code and into Quiz for choosing a meeting.
    func prepareMeeting(_ meeting: CallaMeeting?) {
        if pendingQuizMeeting?.eventID != meeting?.eventID {
            pendingQuizExcludedContextIDs.removeAll()
        }
        pendingQuizMeeting = meeting
    }

    /// Choose the meeting *and* go to Quiz. What the calendar's Quiz entry point
    /// means, and what it has always done.
    func prepareQuiz(for meeting: CallaMeeting?) {
        prepareMeeting(meeting)
        Defaults[.callaCopilotMode] = "quiz"
    }

    func togglePendingQuizContext(_ id: String) {
        if pendingQuizExcludedContextIDs.contains(id) {
            pendingQuizExcludedContextIDs.remove(id)
        } else {
            pendingQuizExcludedContextIDs.insert(id)
        }
    }

    func start() {
        invoke { $0.start(with: $1) }
    }

    /// A lesson can start without the notch being open, so status polling has
    /// to outlive the Tutor tab — otherwise nothing is watching to raise it.
    /// Status is read-only over XPC, so this never launches or mutates runtime.
    func startMonitoring() {
        guard monitorTask == nil else { return }
        monitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refresh()
                if self.coding.lifecycle.active {
                    self.fetchCodingEvents()
                    self.forwardCodingTranscript()
                }
                let teaching = self.status.activeLesson?.active == true
                // A sign-in is a handful of states that each last a second or two.
                // At the idle cadence the UI looks dead and a step can come and go
                // between polls, so it is worth the extra chatter while it lasts.
                let signingIn = self.status.copilot.isSigningIn
                // A live call is the one case where this poll *is* the latency. The
                // host answers a question in ~2s and writes it to a file; at the idle
                // cadence it then sat there for up to 4s more, which is longer than
                // the answer took and long enough for the moment to pass.
                let onACall = self.status.copilot.running || self.callIsFinishing
                    || self.status.quiz.active
                // A call on the way up is the other case where the poll *is* the
                // latency, and a tighter one: every startup step the host
                // publishes is a line the panel wants to draw, and at the idle
                // cadence the whole startup would land as one jump at the end.
                // A quiz working on a question is the same case, and a tighter
                // one still: the engine answers in a couple of seconds and the
                // panel can only learn of it here, so at the 0.6s call cadence a
                // finished answer sat unseen for a third of the time it took to
                // produce. The startup states are included for the same reason
                // the call's are — each one is a line the panel wants to draw.
                let quizWorking = [QuizSessionState.starting, .preparingWorkers,
                                   .collecting, .solving, .retrying, .arbitrating]
                    .contains(self.status.quiz.state) && self.status.quiz.active
                // A live coding session is the same case as a call coming up: the transcript
                // reaches the engine only from this loop, so the poll *is* the latency
                // for every question the interviewer asks.
                let comingUp = self.callIsComingUp || quizWorking || self.coding.lifecycle.active
                let interval: Double = comingUp
                    ? 0.25
                    : (signingIn ? 0.5 : (onACall ? 0.6 : (teaching ? 2 : 4)))
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    func stop() {
        invoke { $0.stop(with: $1) }
    }

    func applyCurrentPreferences() {
        guard let data = try? JSONEncoder().encode(Preferences.current) else { return }
        invoke { $0.applyPreferences(data, with: $1) }
    }

    /// Brings the engine and everything it started down, and waits for it.
    ///
    /// Called from `applicationWillTerminate`, where async is not good enough: the
    /// process is about to go away, and a fire-and-forget XPC message loses the race
    /// often enough to leave a call host holding the microphone. macOS allows a few
    /// seconds here, so a bounded wait is both safe and the point.
    func shutdownAndWait(timeout: TimeInterval = 2.5) {
        let done = DispatchSemaphore(value: 0)
        invoke { proxy, reply in
            proxy.stop(with: { data in
                reply(data)
                done.signal()
            })
        }
        _ = done.wait(timeout: .now() + timeout)
    }

    func refresh() {
        // Status is read-only. Settings opens this path, so it must never
        // launch a runtime or mutate Gateway state as a side effect.
        invoke { $0.status(with: $1) }
    }

    func requestGatewayUpdate() {
        invoke { $0.requestGatewayUpdate(with: $1) }
    }

    func requestScreenRecording() {
        invoke { $0.requestScreenRecording(with: $1) }
    }

    func requestAccessibility() {
        invoke { $0.requestAccessibility(with: $1) }
    }

    func startCourse(_ courseID: String, completion: ((CallaEngineStatus) -> Void)? = nil) {
        invoke({ $0.startCourse(courseID, with: $1) }, completion: completion)
    }

    func startLesson(courseID: String, lessonID: String) {
        courseControl(.init(action: "start_lesson", courseID: courseID, lessonID: lessonID))
    }

    func startAgain(courseID: String) { courseControl(.init(action: "start_again", courseID: courseID)) }

    func courseControl(_ command: CallaCourseCommand) {
        guard let data = try? JSONEncoder().encode(command) else { return }
        invoke { $0.courseControl(data, with: $1) }
    }

    func resumeCourse() {
        invoke { $0.resumeCourse(with: $1) }
    }

    func stopLesson() {
        invoke { $0.stopLesson(with: $1) }
    }

    func ask(_ text: String) {
        invoke { $0.ask(text, with: $1) }
    }

    func setTutorProvider(_ provider: String) {
        guard ["local", "gateway"].contains(provider) else { return }
        invoke { $0.setTutorProvider(provider, with: $1) }
    }

    func tutorHistory(query: String? = nil, cursor: String? = nil, completion: @escaping (CallaTutorHistoryPage?) -> Void) {
        let request = CallaTutorHistoryQuery(cursor: cursor, query: query, pageSize: 50)
        guard let data = try? JSONEncoder().encode(request) else { completion(nil); return }
        let connection = connection ?? makeConnection()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in completion(nil) }) as? BoringCallaEngineProtocol else { completion(nil); return }
        proxy.tutorHistory(data) { response in
            completion(try? Self.decoder.decode(CallaTutorHistoryPage.self, from: response))
        }
    }

    func tutorCapture(_ captureID: String, completion: @escaping (Data?) -> Void) {
        let connection = connection ?? makeConnection()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in completion(nil) }) as? BoringCallaEngineProtocol else { completion(nil); return }
        proxy.tutorCapture(captureID) { data in completion(data.isEmpty ? nil : data) }
    }

    func reportLocalFailure(_ message: String) {
        status.lastResult = message
    }

    private func invoke(_ call: @escaping (BoringCallaEngineProtocol, @escaping (Data) -> Void) -> Void,
                        completion: ((CallaEngineStatus) -> Void)? = nil) {
        let connection = connection ?? makeConnection()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
            NSLog("[CallaEngine] XPC unavailable: %@", error.localizedDescription)
            Task { @MainActor in
                self?.status.lastResult = "Engine unavailable: \(error.localizedDescription)"
                self?.status.running = false
            }
        }) as? BoringCallaEngineProtocol else { return }
        call(proxy) { [weak self] data in
            let result: CallaEngineStatus
            do {
                result = try JSONDecoder().decode(CallaEngineStatus.self, from: data)
            } catch {
                // This used to be `try?` with a bare `return`, so a status
                // struct that drifted from the engine's own copy dropped every
                // reply forever with no log and no visible change — the UI just
                // stayed on whatever it last showed. The two structs are still
                // hand-maintained in separate targets, so say so out loud.
                NSLog("[CallaEngine] undecodable status reply (%d bytes): %@",
                      data.count, String(describing: error))
                Task { @MainActor in
                    // Deliberately not clearing `running`: the engine may be
                    // perfectly healthy and only the encoding drifted, and
                    // asserting otherwise trades one wrong answer for another.
                    self?.status.lastResult = "Engine reply could not be read"
                }
                return
            }
            Task { @MainActor in
                self?.apply(result)
                completion?(result)
            }
        }
    }

    /// Every status path funnels through here so a lesson start is detected
    /// once, whether it arrived from polling or from a command's own reply.
    private func apply(_ result: CallaEngineStatus) {
        let previous = status.activeLesson
        let previousCopilot = status.copilot
        let previousQuizSession = status.quiz.sessionID
        let outgoingQuiz = status.quiz
        let heldQuiz = quizPollIsStale(result.quiz) ? status.quiz : nil
        status = result
        if let heldQuiz { status.quiz = heldQuiz }

        // A finished quiz must not leave its event pinned: the preflight chip
        // kept showing yesterday's meeting, and its notes were silently folded
        // into the next session's context.
        if previousQuizSession != nil, result.quiz.sessionID == nil {
            pendingQuizMeeting = nil
            pendingQuizExcludedContextIDs.removeAll()
            // Hand the finished session somewhere it can still be read; the panel
            // is about to be torn down with it.
            CopilotLiveSession.shared.noteQuizEnded(outgoingQuiz)
        }

        // The host has finished, or there is no host left to finish. Also
        // released on the timeout, so a host that died mid-recap cannot leave
        // the notch writing a recap forever.
        if endingCall {
            let done = !result.copilot.running && !result.copilot.isFinishing
                && !result.copilot.starting
            if done || result.copilot.lifecycleState == CallLifecycleStateName.finished {
                endEnding()
            } else if let deadline = endDeadline, Date() >= deadline {
                endEnding()
            }
        }

        if result.copilot.starting || result.copilot.running {
            endLaunch()
        } else if launchingCall,
                  result.copilot.lastResult != previousCopilot.lastResult,
                  CopilotStartFailure.classify(reason: result.copilot.lastResult,
                                               copilot: result.copilot).isTerminalRefusal {
            // The engine has refused outright — a host already alive, a runtime
            // that is not installed, settings that failed validation. Waiting for
            // the thirty-second deadline here meant half a minute of a progress
            // bar for a call that was never going to exist. Keyed on the result
            // having *changed*, so a stale message from an earlier command
            // cannot cancel a launch that is genuinely still coming up.
            endLaunch()
        } else if let deadline = launchDeadline, Date() >= deadline {
            endLaunch()
        }

        // A new pointer is the one copilot event worth interrupting for. Keyed
        // on the turn it answers, so a poll that re-reads the same suggestion
        // does not re-open the notch every two seconds.
        let copilot = result.copilot
        if copilot.running, copilot.hasSuggestion,
           copilot.suggestionAfterSeq != previousCopilot.suggestionAfterSeq
            || copilot.callID != previousCopilot.callID {
            NotificationCenter.default.post(name: .callaCopilotSuggestion, object: nil)
        }

        guard let current = result.activeLesson, current.active else { return }
        guard previous?.active != true || previous?.lessonID != current.lessonID else { return }
        NotificationCenter.default.post(name: .callaLessonDidStart, object: nil)
    }

    // MARK: - Live call copilot

    func startCall(persona: String, model: String, meeting: CallaMeeting? = nil,
                   callID: String? = nil,
                   selectedKnowledgeNoteIDs: [String]? = nil) {
        CopilotLiveSession.shared.prepareForSessionStart()
        // Starting a call on the local brain without credentials used to mean a
        // browser popping open mid-meeting with nowhere to put the code. Sign in
        // first, and let the notch show the field.
        if Defaults[.callaIntelligenceProvider] == "local",
           status.copilot.agyAvailable,
           !status.copilot.agyLoggedIn
        {
            loginAgy()
            return
        }
        // Set here rather than waited for.
        //
        // The engine cannot report a host that does not exist yet, and the poll
        // that would notice it is up to four seconds away. Claiming the launch
        // locally is what makes the button respond to the press; the host's own
        // status replaces this the moment it lands, and `launchDeadline` gives up
        // if it never does.
        beginLaunch()
        var command = callCommand("start", persona: persona, model: model, meeting: meeting)
        command = CallaCopilotCommand(
            action: command.action, persona: command.persona, model: command.model,
            callID: callID ?? command.callID, question: command.question, profile: command.profile,
            provider: command.provider, tier: command.tier, summaryModel: command.summaryModel,
            fallback: command.fallback, gatewayStandby: command.gatewayStandby,
            meeting: command.meeting, selectedKnowledgeNoteIDs: selectedKnowledgeNoteIDs)
        send(command)
    }

    /// A call this app has asked for and not yet seen come up.
    ///
    /// Cleared by the host reporting for itself — either `starting`, which means
    /// the process is alive and the claim is now the host's rather than ours, or
    /// `running`, which means it beat us to it.
    @Published private(set) var launchingCall = false
    private var launchDeadline: Date?
    /// Long enough to cover a cold model load and a TCC prompt, short enough that
    /// a host that died on launch does not leave the notch waiting forever.
    private static let launchTimeout: TimeInterval = 30

    private func beginLaunch() {
        launchingCall = true
        launchDeadline = Date().addingTimeInterval(Self.launchTimeout)
    }

    private func endLaunch() {
        launchingCall = false
        launchDeadline = nil
    }

    /// True while the user should be looking at a starting call — ours by claim,
    /// or the host's by report.
    var callIsComingUp: Bool { launchingCall || status.copilot.starting }

    private func callCommand(
        _ action: String, persona: String, model: String, meeting: CallaMeeting?
    ) -> CallaCopilotCommand {
        let settings = CallaCopilotSettings.current
        return CallaCopilotCommand(
            action: action,
            persona: persona,
            model: model,
            profile: CallaCopilotProfile.current,
            provider: settings.provider,
            tier: settings.liveTier,
            summaryModel: settings.summaryModel,
            fallback: settings.fallback,
            gatewayStandby: settings.gatewayStandby,
            meeting: meeting)
    }

    /// Changes which brain answers. Takes effect on the next call: the capture
    /// host binds its provider at launch, so switching mid-call would report a
    /// change that did not happen. Automatic fallback is the only thing that swaps
    /// brains during a call.
    func setIntelligence(
        provider: String,
        tier: String? = nil,
        summaryModel: String? = nil,
        fallback: Bool? = nil,
        gatewayStandby: String? = nil
    ) {
        send(CallaCopilotCommand(
            action: "set_provider",
            provider: provider,
            tier: tier,
            summaryModel: summaryModel,
            fallback: fallback,
            gatewayStandby: gatewayStandby))
    }

    func endCall() {
        CopilotLiveSession.shared.releaseEndedCall()
        // Claimed locally, for the same reason `startCall` claims its launch:
        // the host cannot report a stop it has not been told about yet, and the
        // poll that would notice is up to four seconds away. Pressing End used
        // to change nothing on screen for those four seconds and then, once the
        // recap pass began, still nothing — because `running` stayed true until
        // the process exited. The button now responds to the press and the
        // host's own progress replaces this the moment it lands.
        beginEnding()
        send(CallaCopilotCommand(action: "stop"))
    }

    /// A stop this app has asked for and not yet seen finish.
    @Published private(set) var endingCall = false
    private var endDeadline: Date?
    /// Long enough for the drain, the final chunk and the deep closing pass —
    /// which is ~8.5s on its own — and short enough that a host that died
    /// mid-recap does not leave the notch finishing forever.
    private static let endTimeout: TimeInterval = 60

    private func beginEnding() {
        endingCall = true
        endDeadline = Date().addingTimeInterval(Self.endTimeout)
    }

    private func endEnding() {
        endingCall = false
        endDeadline = nil
    }

    /// True while the user should be looking at a call being written up — ours
    /// by claim, or the host's by report.
    var callIsFinishing: Bool { endingCall || status.copilot.isFinishing }

    func answerSelectedText(_ text: String) {
        send(CallaCopilotCommand(action: "answer", question: text))
    }

    func setCallPersona(_ persona: String) {
        send(CallaCopilotCommand(action: "set_persona", persona: persona))
    }

    // MARK: - Screen Quiz

    func listQuizWindows(completion: @escaping ([QuizWindowTarget]) -> Void) {
        quizReply({ $0.listQuizWindows(with: $1) }, as: [QuizWindowTarget].self,
                  fallback: [], completion: completion)
    }

    func listQuizModels(completion: @escaping ([String]) -> Void) {
        quizReply({ $0.listQuizModels(with: $1) }, as: [String].self,
                  fallback: [], completion: completion)
    }

    func requestQuizPermissions(completion: @escaping (QuizPermissionReadiness?) -> Void) {
        quizOptionalReply({ $0.requestQuizPermissions(with: $1) },
                          as: QuizPermissionReadiness.self, completion: completion)
    }

    /// Asks the Engine to spawn the warm council now, while the reader is still
    /// looking at the preflight.
    ///
    /// Fire and forget in both directions: the Engine refuses quietly when
    /// anything is not ready, and nothing here waits on the answer. Start
    /// re-checks everything itself and works exactly the same when this did
    /// nothing at all.
    func warmQuiz(mode: QuizMode, profile: QuizModeProfile) {
        guard let data = try? Self.engineEncoder.encode(QuizWarmRequest(mode: mode, profile: profile))
        else { return }
        quizAcknowledged { $0.warmQuiz(data, with: $1) }
    }

    func cancelQuizWarm() {
        quizAcknowledged { $0.cancelQuizWarm(with: $1) }
    }

    private func quizAcknowledged(
        _ call: @escaping (BoringCallaEngineProtocol, @escaping (Bool) -> Void) -> Void
    ) {
        let connection = connection ?? makeConnection()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in })
                as? BoringCallaEngineProtocol else { return }
        call(proxy) { _ in }
    }

    func startQuiz(_ configuration: QuizSessionConfiguration,
                   completion: ((QuizSessionSnapshot?) -> Void)? = nil) {
        CopilotLiveSession.shared.prepareForSessionStart()
        guard let data = try? Self.engineEncoder.encode(configuration) else {
            completion?(nil); return
        }
        quizOptionalReply({ $0.startQuiz(data, with: $1) },
                          as: QuizSessionSnapshot.self) { [weak self] snapshot in
            if let snapshot { self?.applyQuizCommandResult(snapshot) }
            completion?(snapshot)
        }
    }

    func sendQuiz(_ command: QuizCommand,
                  completion: ((QuizSessionSnapshot?) -> Void)? = nil) {
        guard let data = try? Self.engineEncoder.encode(command) else {
            completion?(nil); return
        }
        quizOptionalReply({ $0.sendQuizCommand(data, with: $1) },
                          as: QuizSessionSnapshot.self) { [weak self] snapshot in
            if let snapshot { self?.applyQuizCommandResult(snapshot) }
            completion?(snapshot)
        }
    }

    private func applyQuizCommandResult(_ snapshot: QuizSessionSnapshot) {
        status.quiz = snapshot
        quizCommandAppliedAt = Date()
        quizCommandSessionID = snapshot.sessionID
    }

    /// Whether a polled snapshot is allowed to replace what a command just said.
    ///
    /// Only the disagreement that matters is guarded: a poll that has not yet
    /// caught up to the session the command established. Once it names the same
    /// session — or the grace window passes — the engine is authoritative again.
    private func quizPollIsStale(_ polled: QuizSessionSnapshot) -> Bool {
        guard let appliedAt = quizCommandAppliedAt,
              Date().timeIntervalSince(appliedAt) < Self.quizCommandGrace else { return false }
        return polled.sessionID != quizCommandSessionID
    }

    func quizHistory(completion: @escaping ([QuizHistorySession]) -> Void) {
        quizReply({ $0.quizHistory(with: $1) }, as: [QuizHistorySession].self,
                  fallback: [], completion: completion)
    }

    func revealQuizCapture(_ captureID: String, completion: @escaping (Data?) -> Void) {
        let connection = connection ?? makeConnection()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in completion(nil) })
                as? BoringCallaEngineProtocol else { completion(nil); return }
        proxy.revealQuizCapture(captureID) { data in
            Task { @MainActor in completion(data.isEmpty ? nil : data) }
        }
    }

    /// Records whether an answer was right. This is the ground truth confidence
    /// calibration is built from, so it also decides what future percentages mean.
    func gradeQuizAnswer(_ answerID: String, grade: QuizAnswerGrade,
                         completion: (() -> Void)? = nil) {
        let connection = connection ?? makeConnection()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            Task { @MainActor in completion?() }
        }) as? BoringCallaEngineProtocol else {
            completion?(); return
        }
        proxy.gradeQuizAnswer(answerID, grade: grade.rawValue) { _ in
            Task { @MainActor in completion?() }
        }
    }

    func deleteQuizSession(_ sessionID: String, completion: (() -> Void)? = nil) {
        let connection = connection ?? makeConnection()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in completion?() })
                as? BoringCallaEngineProtocol else { completion?(); return }
        proxy.deleteQuizSession(sessionID) { _ in Task { @MainActor in completion?() } }
    }

    func deleteAllQuizHistory(completion: (() -> Void)? = nil) {
        let connection = connection ?? makeConnection()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in completion?() })
                as? BoringCallaEngineProtocol else { completion?(); return }
        proxy.deleteAllQuizHistory { _ in Task { @MainActor in completion?() } }
    }

    // MARK: - Live Coding

    /// Starts the interview: the coding session, and the call underneath it.
    ///
    /// The call is where every spoken question is answered, so it has to know
    /// which meeting it is in. It did not: the meeting was resolved for the
    /// *setup* and then dropped here, which left the call retrieving only
    /// `always` and persona-scoped notes and left its History row with no
    /// event to group on. `WaveInterview.meeting` is now sent on every start,
    /// however the session was reached.
    func startCodingInterview(capabilityID: String, brief: InterviewBrief?,
                              speechModel: String, observationTarget: QuizWindowTarget? = nil,
                              onFailure: ((CodingSessionSnapshot?) -> Void)? = nil) {
        guard CallaFeatureAvailability.liveCoding else { onFailure?(nil); return }
        if status.copilot.running, let callID = status.copilot.callID,
           status.copilot.generation > 0 {
            var configuration = codingConfiguration(callID: callID,
                                                    generation: status.copilot.generation,
                                                    capabilityID: capabilityID, brief: brief)
            configuration.observationTarget = observationTarget
            startCoding(configuration) { snapshot in
                if snapshot?.failure != nil { onFailure?(snapshot) }
            }
            return
        }
        let callID = "call-\(UUID().uuidString.lowercased().prefix(16))"
        var configuration = codingConfiguration(callID: callID,
                                                generation: status.copilot.generation + 1,
                                                capabilityID: capabilityID, brief: brief)
        configuration.observationTarget = observationTarget
        startCoding(configuration) { [weak self] snapshot in
            guard snapshot?.lifecycle == .ready else { onFailure?(snapshot); return }
            self?.startWaveCall(callID: callID, speechModel: speechModel)
        }
    }

    /// Every coding session is the Wave interview, so the profile and the
    /// planned duration are not read from a setup row any more — a setup whose
    /// toggle happened to be off would have started the same interview without
    /// its context pack or its two-hour budget.
    private func codingConfiguration(callID: String, generation: Int,
                                     capabilityID: String,
                                     brief: InterviewBrief?) -> CodingSessionConfiguration {
        var configuration = CodingSessionConfiguration(
            sessionID: "code-\(UUID().uuidString.lowercased())", callID: callID,
            generation: generation,
            folderCapabilityID: capabilityID, brief: brief,
            model: Defaults[.callaCodingProfile].move.modelID,
            profile: Defaults[.callaCodingProfile])
        configuration.interviewProfile = WaveInterview.profileID
        configuration.plannedDurationMinutes = WaveInterview.plannedMinutes
        configuration.rehearsal = WaveInterview.session.isRehearsal
        return configuration
    }

    /// The one way a call is started. Persona and meeting are pinned rather
    /// than passed, so no caller can start the interview as a generic call.
    func startWaveCall(callID: String? = nil, speechModel: String) {
        guard CallaFeatureAvailability.liveCoding else { return }
        startCall(persona: WaveInterview.persona, model: speechModel,
                  meeting: WaveInterview.meeting, callID: callID)
    }

    /// Which run the next session is. Changing it mid-session would leave the
    /// running call filed under one occurrence and the next event under
    /// another, so it is refused while anything is live.
    var canChangeWaveSession: Bool {
        !status.copilot.running && !coding.lifecycle.active && !launchingCall
    }

    func setWaveSession(_ session: WaveInterview.Session) {
        guard canChangeWaveSession else { return }
        Defaults[.callaWaveSession] = session.rawValue
        objectWillChange.send()
    }

    func resumeCodingInterview(sessionID: String, speechModel: String) {
        guard CallaFeatureAvailability.liveCoding else { return }
        if status.copilot.running, let callID = status.copilot.callID,
           status.copilot.generation > 0 {
            sendCoding(.init(sessionID: sessionID, callID: callID,
                             generation: status.copilot.generation, kind: .resume))
        } else {
            let callID = "call-\(UUID().uuidString.lowercased().prefix(16))"
            sendCoding(.init(sessionID: sessionID, callID: callID,
                             generation: status.copilot.generation + 1, kind: .resume)) {
                [weak self] snapshot in
                guard snapshot?.lifecycle == .capturing || snapshot?.lifecycle == .ready else { return }
                // A resumed session is still a session of the same meeting.
                self?.startWaveCall(callID: callID, speechModel: speechModel)
            }
        }
    }

    func fetchRetainedCodingSessions() {
        codingOptionalReply({ $0.codingSessions(with: $1) }, as: [CodingRetainedSession].self) {
            [weak self] sessions in self?.retainedCodingSessions = sessions ?? []
        }
    }

    func deleteCodingSession(_ sessionID: String) {
        let command = CodingCommand(sessionID: sessionID, callID: "archive-delete",
                                    generation: 1, kind: .delete)
        sendCoding(command) { [weak self] _ in self?.fetchRetainedCodingSessions() }
    }

    func prepareWave(_ request: WavePreparationRequest, completion: @escaping (WavePreparationResult?) -> Void) {
        guard let data = try? JSONEncoder().encode(request) else { completion(nil); return }
        codingOptionalReply({ $0.prepareWave(data, with: $1) }, as: WavePreparationResult.self, completion: completion)
    }

    func registerCodingFolder(_ url: URL, completion: @escaping (CodingFolderPreflight?) -> Void) {
        guard let bookmark = try? url.bookmarkData(
            options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        else { completion(nil); return }
        codingOptionalReply({ $0.registerCodingFolder(bookmark, with: $1) },
                            as: CodingFolderPreflight.self) { [weak self] value in
            self?.codingPreflight = value; completion(value)
        }
    }

    func startCoding(_ configuration: CodingSessionConfiguration,
                     completion: ((CodingSessionSnapshot?) -> Void)? = nil) {
        guard CallaFeatureAvailability.liveCoding else { completion?(nil); return }
        guard let data = try? Self.engineEncoder.encode(configuration) else { completion?(nil); return }
        codingOptionalReply({ $0.startCoding(data, with: $1) }, as: CodingSessionSnapshot.self) {
            [weak self] snapshot in
            if let snapshot {
                self?.coding = snapshot; self?.codingEventSequence = -1
                self?.codingTranscriptSequence = -1
                self?.codingEvents.removeAll(); self?.codingTranscriptTail.removeAll()
                self?.fetchCodingEvents()
            }
            completion?(snapshot)
        }
    }

    func sendCoding(_ command: CodingCommand,
                    completion: ((CodingSessionSnapshot?) -> Void)? = nil) {
        guard let data = try? Self.engineEncoder.encode(command) else { completion?(nil); return }
        codingOptionalReply({ $0.codingControl(data, with: $1) }, as: CodingSessionSnapshot.self) {
            [weak self] snapshot in
            if let snapshot { self?.coding = snapshot }
            completion?(snapshot)
        }
    }

    func fetchCodingEvents() {
        guard CallaFeatureAvailability.liveCoding else { return }
        let connection = connection ?? makeConnection()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in })
                as? BoringCallaEngineProtocol else { return }
        proxy.codingEvents(since: codingEventSequence) { [weak self] data in
            let values = (try? Self.decoder.decode([CodingEvent].self, from: data)) ?? []
            Task { @MainActor in values.forEach { self?.applyCodingEvent($0) } }
        }
    }

    /// Bridges the Call host's typed, speaker-labelled turns into the Code
    /// coordinator.  The cursor is local and monotonic, so reconnect polling
    /// can replay the coding event stream without submitting a transcript turn
    /// twice. Cue classification receives Whisper's persisted confidence rather
    /// than promoting uncertain speech into execution authority.
    ///
    /// Turn timings go with it. A turn is one VAD utterance, not a thought, so
    /// the engine segments these into statements before anything can cost a
    /// model request — without `t0`/`t1` there is no silence to measure and
    /// every fragment looks complete.
    private func forwardCodingTranscript() {
        guard CallaFeatureAvailability.liveCoding, !codingTranscriptFetchInFlight,
              let sessionID = coding.sessionID, let callID = coding.callID else { return }
        codingTranscriptFetchInFlight = true
        fetchTranscript(since: codingTranscriptSequence) { [weak self] turns in
            guard let self else { return }
            self.codingTranscriptFetchInFlight = false
            for turn in turns.sorted(by: { $0.seq < $1.seq }) where turn.seq > self.codingTranscriptSequence {
                self.codingTranscriptSequence = turn.seq
                self.codingTranscriptTail.append(turn)
                if self.codingTranscriptTail.count > 12 {
                    self.codingTranscriptTail.removeFirst(self.codingTranscriptTail.count - 12)
                }
                self.sendCoding(.init(
                    sessionID: sessionID, callID: callID, generation: self.coding.generation,
                    kind: .requestMove, transcript: turn.text,
                    speaker: turn.isRemote ? .them : .me, confidence: turn.confidence ?? 0,
                    t0: turn.t0, t1: turn.t1, transcriptSequence: turn.seq))
            }
        }
    }

    private func applyCodingEvent(_ event: CodingEvent) {
        guard event.contractVersion == LiveCodingContract.version,
              event.sequence > codingEventSequence,
              coding.sessionID == nil || (event.sessionID == coding.sessionID
                && event.callID == coding.callID && event.generation == coding.generation) else { return }
        codingEventSequence = event.sequence
        codingEvents.append(event)
        if codingEvents.count > LiveCodingContract.maximumEvents {
            codingEvents.removeFirst(codingEvents.count - LiveCodingContract.maximumEvents)
        }
        coding.latestSequence = event.sequence
        if let lifecycle = event.lifecycle { coding.lifecycle = lifecycle }
        if let revision = event.sourceRevision { coding.sourceRevision = revision }
        if let move = event.move, move.status == .current { coding.activeMove = move; coding.pendingRun = move.check }
        if let failure = event.failure { coding.failure = failure }
    }

    private func codingOptionalReply<T: Decodable>(
        _ call: @escaping (BoringCallaEngineProtocol, @escaping (Data) -> Void) -> Void,
        as type: T.Type, completion: @escaping (T?) -> Void
    ) {
        let connection = connection ?? makeConnection()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            Task { @MainActor in completion(nil) }
        }) as? BoringCallaEngineProtocol else { completion(nil); return }
        call(proxy) { data in
            let value = try? Self.decoder.decode(T.self, from: data)
            Task { @MainActor in completion(value) }
        }
    }

    private func quizReply<T: Decodable>(
        _ call: @escaping (BoringCallaEngineProtocol, @escaping (Data) -> Void) -> Void,
        as type: T.Type, fallback: T, completion: @escaping (T) -> Void
    ) {
        quizOptionalReply(call, as: type) { completion($0 ?? fallback) }
    }

    private func quizOptionalReply<T: Decodable>(
        _ call: @escaping (BoringCallaEngineProtocol, @escaping (Data) -> Void) -> Void,
        as type: T.Type, completion: @escaping (T?) -> Void
    ) {
        let connection = connection ?? makeConnection()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            Task { @MainActor in completion(nil) }
        }) as? BoringCallaEngineProtocol else { completion(nil); return }
        call(proxy) { data in
            let value = try? Self.decoder.decode(type, from: data)
            Task { @MainActor in completion(value) }
        }
    }

    private func send(_ command: CallaCopilotCommand) {
        guard let data = try? JSONEncoder().encode(command) else { return }
        invoke { proxy, reply in proxy.copilotControl(data, with: reply) }
    }

    /// Fetches the live call's turns.
    ///
    /// Deliberately not on the status poll: the transcript is large, and only
    /// the live panel wants it. Pass the newest `seq` already held to get back
    /// just what arrived since — the live panel polls sub-second, and re-reading
    /// the whole call at that rate is what made the old window feel slow.
    func fetchTranscript(since seq: Int? = nil, completion: @escaping ([CallaCallTurn]) -> Void) {
        let connection = connection ?? makeConnection()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            NSLog("[CallaEngine] transcript unavailable: %@", error.localizedDescription)
            Task { @MainActor in completion([]) }
        }) as? BoringCallaEngineProtocol else { return }
        proxy.copilotTranscript(since: seq ?? -1) { data in
            let turns = (try? JSONDecoder().decode([CallaCallTurn].self, from: data)) ?? []
            Task { @MainActor in completion(turns) }
        }
    }

    // MARK: - Knowledge

    /// Everything the copilot has been told, or the subset that applies to one
    /// meeting.
    ///
    /// Every one of these round-trips to the engine. The store lives in the
    /// unsandboxed runtime directory and this app cannot open it, which is also
    /// why each mutation replies with the resulting list rather than a status —
    /// there is no second way to find out what the store now holds.
    func fetchKnowledge(
        eventID: String? = nil,
        seriesID: String? = nil,
        completion: @escaping ([CallaKnowledgeNote]) -> Void
    ) {
        knowledge(CallaKnowledgeCommand(action: "list", eventID: eventID, seriesID: seriesID),
                  completion: completion)
    }

    func saveKnowledge(_ note: CallaKnowledgeNote, completion: @escaping ([CallaKnowledgeNote]) -> Void) {
        knowledge(CallaKnowledgeCommand(
            action: "upsert", id: note.id, title: note.title, body: note.body,
            scope: note.scope, scopeKey: note.scopeKey,
            source: note.source,
            originName: note.originName, originKind: note.originKind,
            byteSize: note.byteSize, pageCount: note.pageCount), completion: completion)
    }

    func deleteKnowledge(id: String, completion: @escaping ([CallaKnowledgeNote]) -> Void) {
        knowledge(CallaKnowledgeCommand(action: "delete", id: id), completion: completion)
    }

    private func knowledge(
        _ command: CallaKnowledgeCommand,
        completion: @escaping ([CallaKnowledgeNote]) -> Void
    ) {
        guard let payload = try? JSONEncoder().encode(command) else {
            completion([]); return
        }
        let connection = connection ?? makeConnection()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            NSLog("[CallaEngine] knowledge unavailable: %@", error.localizedDescription)
            Task { @MainActor in completion([]) }
        }) as? BoringCallaEngineProtocol else { return }
        proxy.knowledgeControl(payload) { data in
            let notes = (try? Self.decoder.decode([CallaKnowledgeNote].self, from: data)) ?? []
            Task { @MainActor in completion(notes) }
        }
    }

    /// Previous calls for a meeting — the same series where there is one, so a
    /// recurring standup shows every instance rather than only today's.
    func fetchCalls(
        forEvent eventID: String?,
        seriesID: String?,
        completion: @escaping ([CallaCallRecord]) -> Void
    ) {
        let query = CallaKnowledgeCommand(action: "list", eventID: eventID, seriesID: seriesID)
        guard let payload = try? JSONEncoder().encode(query) else { completion([]); return }
        let connection = connection ?? makeConnection()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            NSLog("[CallaEngine] call list unavailable: %@", error.localizedDescription)
            Task { @MainActor in completion([]) }
        }) as? BoringCallaEngineProtocol else { return }
        proxy.copilotCallsForEvent(payload) { data in
            let calls = (try? Self.decoder.decode([CallaCallRecord].self, from: data)) ?? []
            Task { @MainActor in completion(calls) }
        }
    }

    /// The engine encodes dates as ISO-8601, matching every other reply it sends.
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// For payloads the engine reads with its ISO-8601 decoder.
    ///
    /// The engine has always replied in ISO-8601 and `decoder` above has always
    /// read it, but requests going the other way used a plain `JSONEncoder`,
    /// which writes a `Date` as a number. `JSONDecoder.dateDecodingStrategy =
    /// .iso8601` does not tolerate that — it throws — and the throw was
    /// swallowed by a `try?`, so `startCoding` replied with empty data and the
    /// notch waited out its 45-second timer reporting "Live Coding did not
    /// start in time".
    ///
    /// Only for the five payloads `BoringCallaEngine.jsonDecoder` handles. The
    /// engine reads everything else with a plain decoder, which expects the
    /// numeric form, so those call sites must keep using `JSONEncoder()`.
    private static let engineEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// Lists the calls this Mac has archived, newest first.
    func fetchCalls(completion: @escaping ([CallaCallSummary]) -> Void) {
        let connection = connection ?? makeConnection()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            NSLog("[CallaEngine] call list unavailable: %@", error.localizedDescription)
            Task { @MainActor in completion([]) }
        }) as? BoringCallaEngineProtocol else { return }
        proxy.copilotCalls { data in
            let calls = (try? JSONDecoder().decode([CallaCallSummary].self, from: data)) ?? []
            Task { @MainActor in completion(calls) }
        }
    }

    /// Reads one archived call's transcript in full.
    /// What the copilot returned during a finished call.
    func fetchCallSuggestions(_ callID: String, completion: @escaping ([CallaCopilotArchivedSuggestion]) -> Void) {
        invoke { proxy, reply in
            proxy.copilotCallSuggestions(callID, with: { data in
                reply(data)
                let decoded = (try? JSONDecoder().decode([CallaCopilotArchivedSuggestion].self, from: data)) ?? []
                DispatchQueue.main.async { completion(decoded) }
            })
        }
    }

    func fetchCallTranscript(callID: String, completion: @escaping ([CallaCallTurn]) -> Void) {
        let connection = connection ?? makeConnection()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            NSLog("[CallaEngine] archive unavailable: %@", error.localizedDescription)
            Task { @MainActor in completion([]) }
        }) as? BoringCallaEngineProtocol else { return }
        proxy.copilotCallTranscript(callID) { data in
            let turns = (try? JSONDecoder().decode([CallaCallTurn].self, from: data)) ?? []
            Task { @MainActor in completion(turns) }
        }
    }

    func fetchRecapDraft(callID: String, completion: @escaping (CallaRecapDraft?) -> Void) {
        let connection = connection ?? makeConnection()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            Task { @MainActor in completion(nil) }
        }) as? BoringCallaEngineProtocol else { return }
        proxy.copilotRecapDraft(callID) { data in
            let recap = try? Self.decoder.decode(CallaRecapDraft.self, from: data)
            Task { @MainActor in completion(recap) }
        }
    }

    /// The effective prompt pack, keyed by its path inside the pack.
    ///
    /// The Settings pane used to hold its own copy of the default wording, which
    /// drifted until it was previewing a JSON contract the host had stopped
    /// using. This asks the side of the sandbox line that actually sends them.
    func fetchPrompts(completion: @escaping ([String: String]) -> Void) {
        let connection = connection ?? makeConnection()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            Task { @MainActor in completion([:]) }
        }) as? BoringCallaEngineProtocol else { return }
        proxy.copilotPrompts { data in
            let prompts = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
            Task { @MainActor in completion(prompts) }
        }
    }

    func controlRecap(_ action: String, callID: String, completion: @escaping (CallaRecapDraft?) -> Void) {
        guard let payload = try? JSONEncoder().encode(CallaRecapCommand(action: action, callID: callID)) else {
            completion(nil); return
        }
        let connection = connection ?? makeConnection()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            Task { @MainActor in completion(nil) }
        }) as? BoringCallaEngineProtocol else { return }
        proxy.copilotRecapControl(payload) { data in
            let recap = try? Self.decoder.decode(CallaRecapDraft.self, from: data)
            Task { @MainActor in completion(recap) }
        }
    }

    /// Re-runs the large model over a finished call's saved audio.
    func retranscribe(callID: String) {
        send(CallaCopilotCommand(action: "archive", callID: callID))
    }

    /// Asks the capture host — not the engine — for microphone and screen
    /// recording. TCC keys a grant to the code signature that asks, so asking
    /// from here would prompt for the wrong process and grant nothing useful.
    func requestCopilotPermissions() {
        invoke { $0.requestCopilotPermissions(with: $1) }
    }

    /// Downloads a transcription model ahead of a call.
    func prefetchModel(_ model: String) {
        send(CallaCopilotCommand(action: "fetch_model", model: model))
    }

    /// Triggers the `agy` OAuth login flow through the engine.
    /// Starts `agy`'s Google sign-in.
    ///
    /// `force` replaces a credential that already exists — the case where Settings
    /// reports "signed in" but a call still cannot reach the model. Without it, a
    /// sign-in with valid-looking credentials on disk is a no-op, because running
    /// it anyway would spend a model call to learn what is already known.
    func loginAgy(force: Bool = false) {
        send(CallaCopilotCommand(action: "login", fallback: force))
    }

    /// Rehearses the sign-in against a throwaway `HOME`.
    ///
    /// While credentials are valid no real sign-in will start — correctly, since
    /// `agy` caches them — so this is the only way to watch the flow without
    /// signing out, and signing out is what broke things once already.
    func testSignInFlow() {
        send(CallaCopilotCommand(action: "test_login"))
    }

    /// Clears the stored Google credential so the next sign-in starts fresh.
    ///
    /// Kept as a backup, and deliberately not auto-restored — see `restoreSignIn()`.
    func signOutAgy() {
        send(CallaCopilotCommand(action: "sign_out"))
    }

    /// Puts back the credential that `signOutAgy()` set aside.
    func restoreSignIn() {
        send(CallaCopilotCommand(action: "restore_login"))
    }

    /// Submits a token to a running `agy` login flow.
    func submitAgyToken(_ token: String) {
        invoke { $0.submitAgyToken(token, with: $1) }
    }

    private func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(serviceName: "theboringteam.boringnotch.BoringCallaEngine")
        let remoteInterface = NSXPCInterface(with: BoringCallaEngineProtocol.self)
        remoteInterface.setInterface(
            NSXPCInterface(with: BoringCallaEngineStatusObserver.self),
            for: #selector(BoringCallaEngineProtocol.subscribeStatus(_:with:)), argumentIndex: 0, ofReply: false)
        remoteInterface.setInterface(
            NSXPCInterface(with: BoringCallaEngineCallObserver.self),
            for: #selector(BoringCallaEngineProtocol.subscribeCallEvents(_:with:)), argumentIndex: 0, ofReply: false)
        remoteInterface.setInterface(
            NSXPCInterface(with: BoringCallaEngineCodingObserver.self),
            for: #selector(BoringCallaEngineProtocol.subscribeCodingEvents(_:with:)), argumentIndex: 0, ofReply: false)
        connection.remoteObjectInterface = remoteInterface
        connection.exportedInterface = NSXPCInterface(with: BoringCallaEngineObserver.self)
        connection.exportedObject = statusObserver
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in
                self?.connection = nil
                self?.status.running = false
            }
        }
        connection.resume()
        self.connection = connection
        if let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in }) as? BoringCallaEngineProtocol {
            proxy.subscribeStatus(statusObserver) { [weak self] data in
                guard let self, let result = try? Self.decoder.decode(CallaEngineStatus.self, from: data) else { return }
                Task { @MainActor in self.apply(result) }
            }
            proxy.subscribeCallEvents(statusObserver) { _ in }
            proxy.subscribeCodingEvents(statusObserver) { [weak self] data in
                guard let self, let snapshot = try? Self.decoder.decode(CodingSessionSnapshot.self, from: data) else { return }
                Task { @MainActor in self.coding = snapshot; self.fetchCodingEvents() }
            }
        }
        return connection
    }
}

private final class StatusObserver: NSObject, BoringCallaEngineObserver {
    private let receiveStatus: (Data) -> Void
    private let receiveCoding: (Data) -> Void
    private let receiveCall: (Data) -> Void
    init(status: @escaping (Data) -> Void, call: @escaping (Data) -> Void, coding: @escaping (Data) -> Void) {
        receiveStatus = status; receiveCoding = coding; receiveCall = call
    }
    func callaEngineStatusDidChange(_ data: Data) {
        Task { @MainActor in receiveStatus(data) }
    }
    func callaEngineCallEvent(_ data: Data) {
        Task { @MainActor in receiveCall(data) }
    }
    func callaEngineCodingEvent(_ data: Data) {
        Task { @MainActor in receiveCoding(data) }
    }
}

private typealias Preferences = CallaEnginePreferences
