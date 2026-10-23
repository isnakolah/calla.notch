import Foundation
import AppKit
import Defaults
import CallaContracts
import UserNotifications

@objc protocol CallaEngineStatusObserver {
    func callaEngineStatusDidChange(_ data: Data)
}

@objc protocol CallaEngineCallObserver {
    func callaEngineCallEvent(_ data: Data)
}

@objc protocol CallaEngineCodingObserver {
    func callaEngineCodingEvent(_ data: Data)
}

@objc protocol CallaEngineObserver: CallaEngineStatusObserver, CallaEngineCallObserver, CallaEngineCodingObserver {}

@objc protocol CallaEngineProtocol {
    func migrateBranding(_ includePreferences: Bool, with reply: @escaping (Data) -> Void)
    func privateSetup(_ request: Data, with reply: @escaping (Data) -> Void)
    func start(with reply: @escaping (Data) -> Void)
    func stop(with reply: @escaping (Data) -> Void)
    func applyPreferences(_ preferences: Data, with reply: @escaping (Data) -> Void)
    func status(with reply: @escaping (Data) -> Void)
    func subscribeStatus(_ observer: CallaEngineStatusObserver, with reply: @escaping (Data) -> Void)
    func subscribeCallEvents(_ observer: CallaEngineCallObserver, with reply: @escaping (Data) -> Void)
    func requestGatewayUpdate(with reply: @escaping (Data) -> Void)
    func copilotControl(_ command: Data, with reply: @escaping (Data) -> Void)
    /// Opens a call's folder in ~/Documents/Calls, or the root for an empty id.
    func revealCallFolder(_ callID: String, with reply: @escaping (Data) -> Void)
    /// Writes the app's settings snapshot to Downloads, for carrying to another Mac.
    func saveSettingsSnapshot(_ data: Data, with reply: @escaping (Data) -> Void)
    func exportDiagnostics(with reply: @escaping (Data) -> Void)
    /// Writes a folder for every past call that lacks one.
    func exportPastCalls(with reply: @escaping (Data) -> Void)
    /// Call archive backend: sync now, sign in again, restore, dismiss a notice.
    func backendControl(_ command: Data, with reply: @escaping (Data) -> Void)
    /// Turns newer than `seq`. Pass -1 for the whole tail.
    func copilotTranscript(since seq: Int, with reply: @escaping (Data) -> Void)
    func copilotCalls(with reply: @escaping (Data) -> Void)
    func copilotCallTranscript(_ callID: String, with reply: @escaping (Data) -> Void)
    /// What the copilot returned during that call.
    func copilotCallSuggestions(_ callID: String, with reply: @escaping (Data) -> Void)
    func copilotRecapDraft(_ callID: String, with reply: @escaping (Data) -> Void)
    func copilotRecapControl(_ command: Data, with reply: @escaping (Data) -> Void)
    func recategorizeMeeting(_ command: Data, with reply: @escaping (Data) -> Void)
    func regenerateCallRecap(_ callID: String, with reply: @escaping (Data) -> Void)
    func suggestMeetingCategory(_ details: String, with reply: @escaping (Data) -> Void)
    func copilotSpeakerControl(_ command: Data, with reply: @escaping (Data) -> Void)
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
    func subscribeCodingEvents(_ observer: CallaEngineCodingObserver, with reply: @escaping (Data) -> Void)
}

struct CallaEnginePreferences: Codable, Equatable {
    let quizEnabled: Bool
    let callFoldersEnabled: Bool
    let callFoldersAudio: Bool
    let backendSync: Bool

    static var current: CallaEnginePreferences {
        CallaEnginePreferences(quizEnabled: Defaults[.callaQuizEnabled],
                               callFoldersEnabled: Defaults[.callaCallFoldersEnabled],
                               callFoldersAudio: Defaults[.callaCallFoldersAudio],
                               backendSync: Defaults[.callaBackendSync])
    }
}

/// The call archive, as the engine reports it (CallaEngine/CallaBackendSync.swift).
struct CallaBackendState: Codable, Equatable {
    var enabled = true
    var signedIn = false
    var deviceName: String? = nil
    var url: String? = nil
    var syncing: String? = nil
    var pendingCalls = 0
    var syncedCalls = 0
    var lastSyncAt: Date? = nil
    var lastError: String? = nil
    var inboxConnected = false
    var notice: Notice? = nil
    var restore: String? = nil

    struct Notice: Codable, Equatable {
        var id: Int64
        var title: String
        var body: String?
    }
}

struct CallaEngineStatus: Codable, Equatable {
    var running = false
    var gatewayReachable = false
    var releaseVersion: String? = nil
    var previousGatewayRelease: String? = nil
    var lastGatewayUpdate: String? = nil
    var lastGatewayUpdateAt: Date? = nil
    var lastResult = "Engine not started"
    var diagnostics: [String] = []
    var copilot = CallaCopilotStatus()
    var quiz = QuizSessionSnapshot()
    /// Optional so a status from an engine that predates the archive decodes.
    var backend: CallaBackendState? = nil
}

/// Live-call state, carried on the engine's existing status poll.
struct CallaCopilotStatus: Codable, Equatable {
    var available = false
    var running = false
    /// Screenshots taken during the current call.
    var screenshotCount = 0
    /// Where the last finished call was filed, relative to ~/Documents/Calls.
    var callFolder: String? = nil
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
    /// `me`, `S1`, `S2`, … once the post-call speaker pass has run.
    var speaker: String? = nil
    /// A name, "You" or "Speaker N". Nil before the speaker pass.
    var speakerName: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, seq, source, t0, t1, text, confidence, speaker
        case speakerName = "speaker_name"
    }

    var isRemote: Bool { source == "them" }

    /// Who to credit the turn to: the diarized speaker when there is one, else
    /// the side of the call it was captured on.
    var speakerLabel: String { speakerName ?? (isRemote ? "Them" : "You") }

    /// "12:34" from the start of the call, or "1:02:03" past the hour.
    var clock: String {
        let seconds = Int(max(0, t0))
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// A call's speakers and every remembered voice, as the engine reports them.
struct CallaCallSpeakers: Codable, Equatable {
    struct Speaker: Codable, Equatable, Identifiable {
        let id: String
        let name: String
        /// `none`, `auto` (guessed, unconfirmed), `voiceprint` or `user`.
        let nameSource: String
        let confidence: Double?
        let speechSeconds: Double

        enum CodingKeys: String, CodingKey {
            case id, name, confidence
            case nameSource = "name_source"
            case speechSeconds = "speech_seconds"
        }

        var isLocal: Bool { id == "me" }
        var isGuess: Bool { nameSource == "auto" }
        var isNamed: Bool { nameSource != "none" }
    }

    struct Voice: Codable, Equatable, Identifiable {
        let personID: String
        let name: String
        let updatedAt: Date

        var id: String { personID }

        enum CodingKeys: String, CodingKey {
            case name
            case personID = "person_id"
            case updatedAt = "updated_at"
        }
    }

    let speakers: [Speaker]
    let attendees: [String]
    let voices: [Voice]

    var remote: [Speaker] { speakers.filter { !$0.isLocal } }
}

struct CallaSpeakerCommand: Codable {
    var action: String
    var callID: String?
    var speakerID: String?
    var name: String?
    var into: String?
    var personID: String?
    var remember: Bool?

    enum CodingKeys: String, CodingKey {
        case action, name, into, remember
        case callID = "call_id"
        case speakerID = "speaker_id"
        case personID = "person_id"
    }
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
    let displayID: UInt32?
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
    /// False leaves the last recaps of a repeating meeting out of the next call.
    /// Nil keeps the engine's default, which carries them.
    var carryRecaps: Bool?

    enum CodingKeys: String, CodingKey {
        case action, persona, model, profile, provider, tier, fallback, meeting, question
        case displayID = "display_id"
        case selectedKnowledgeNoteIDs = "selected_knowledge_note_ids"
        case carryRecaps = "carry_recaps"
        case summaryModel = "summary_model"
        case gatewayStandby = "gateway_standby"
        case callID = "call_id"
    }

    init(action: String,
         persona: String? = nil,
         model: String? = nil,
         callID: String? = nil,
         question: String? = nil,
         displayID: UInt32? = nil,
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
        self.displayID = displayID
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
        eventID = CalendarMeetingInput.identifier(event.id)
        seriesID = CalendarMeetingInput.identifier(event.seriesID)
        title = CalendarMeetingInput.text(event.title, limit: CalendarMeetingInput.titleLimit) ?? "Calendar meeting"
        startsAt = event.start.timeIntervalSince1970
        endsAt = event.end.timeIntervalSince1970
        location = CalendarMeetingInput.text(event.location, limit: CalendarMeetingInput.titleLimit)
        attendees = CalendarMeetingInput.attendees(event.participants.map(\.name))
        notes = CalendarMeetingInput.text(event.notes, limit: CalendarMeetingInput.notesLimit)
    }
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

extension Notification.Name {
    /// Posted when the gateway pushes a new answer pointer during a live call.
    static let callaCopilotSuggestion = Notification.Name("callaCopilotSuggestion")
}

@MainActor
final class CallaEngineClient: ObservableObject {
    private var automaticallyOpenedAgyURL: String?

    /// Survives sign-in view recreation and status polling. Manual Open is
    /// still available, but an OAuth challenge opens automatically only once.
    func openAgySignInPageOnce(_ value: String) {
        guard value != automaticallyOpenedAgyURL,
              status.copilot.agyLoginStage != "failed",
              let url = URL(string: value), url.scheme == "https",
              url.host == "accounts.google.com" else { return }
        automaticallyOpenedAgyURL = value
        NSWorkspace.shared.open(url)
    }
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
        // The engine still publishes coding events until its own side of Live
        // Coding is removed; the app no longer has anything to show for them.
        coding: { _ in })

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

    /// Polls engine status for the life of the app, so a call or quiz started
    /// from a shortcut is noticed without the notch open.
    /// Status is read-only over XPC, so this never launches or mutates runtime.
    func startMonitoring() {
        guard monitorTask == nil else { return }
        monitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refresh()
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
                let comingUp = self.callIsComingUp || quizWorking
                let interval: Double = comingUp
                    ? 0.25
                    : (signingIn ? 0.5 : (onACall ? 0.6 : 4))
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

    func reportLocalFailure(_ message: String) {
        status.lastResult = message
    }

    func performPrivateSetup(_ data: Data, completion: @escaping ([String: Any]) -> Void) {
        let connection = connection ?? makeConnection()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            Task { @MainActor in completion(["error": "Setup service unavailable: \(error.localizedDescription)"]) }
        }) as? CallaEngineProtocol else {
            completion(["error": "Setup service unavailable. Quit and reopen calla.notch."]); return
        }
        proxy.privateSetup(data) { response in
            guard let object = try? JSONSerialization.jsonObject(with: response) as? [String: Any] else {
                Task { @MainActor in completion(["error": "Setup service returned an incomplete response. Reopen the latest calla.notch app."]) }
                return
            }
            Task { @MainActor in completion(object) }
        }
    }

    private func invoke(_ call: @escaping (CallaEngineProtocol, @escaping (Data) -> Void) -> Void,
                        completion: ((CallaEngineStatus) -> Void)? = nil) {
        let connection = connection ?? makeConnection()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
            NSLog("[CallaEngine] XPC unavailable: %@", error.localizedDescription)
            Task { @MainActor in
                self?.status.lastResult = "Engine unavailable: \(error.localizedDescription)"
                self?.status.running = false
            }
        }) as? CallaEngineProtocol else { return }
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

    /// Every status path funnels through here, whether it arrived from polling
    /// or from a command's own reply.
    private func apply(_ result: CallaEngineStatus) {
        let previousCopilot = status.copilot
        let previousNotice = status.backend?.notice?.id
        let previousQuizSession = status.quiz.sessionID
        let outgoingQuiz = status.quiz
        let heldQuiz = quizPollIsStale(result.quiz) ? status.quiz : nil
        status = result
        CallVPNManager.shared.noteCallStatus(running: result.copilot.running,
                                             finishing: result.copilot.isFinishing,
                                             starting: result.copilot.starting)
        if let heldQuiz { status.quiz = heldQuiz }
        if let notice = result.backend?.notice, notice.id != previousNotice {
            postBackendNotice(notice)
        }

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

        updateCallPresentationProtection(for: result.copilot)

        // A new pointer is the one copilot event worth interrupting for. Keyed
        // on the turn it answers, so a poll that re-reads the same suggestion
        // does not re-open the notch every two seconds.
        let copilot = result.copilot
        if copilot.running, copilot.hasSuggestion,
           copilot.suggestionAfterSeq != previousCopilot.suggestionAfterSeq
            || copilot.callID != previousCopilot.callID {
            NotificationCenter.default.post(name: .callaCopilotSuggestion, object: nil)
        }
    }

    // MARK: - Live call copilot

    func startCall(persona: String, model: String, meeting: CallaMeeting? = nil,
                   callID: String? = nil,
                   selectedKnowledgeNoteIDs: [String]? = nil) {
        lastCallStart = (persona, model, meeting, selectedKnowledgeNoteIDs)
        CallTypeHistory.shared.record(persona)
        rememberCallNotes(persona: persona, meeting: meeting, selected: selectedKnowledgeNoteIDs)
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

    func recategorizeMeeting(eventID: String, seriesID: String?, persona: String,
                             occurrenceOnly: Bool, excluding eventIDs: [String] = []) {
        let payload: [String: Any] = ["eventID": eventID, "seriesID": seriesID as Any? ?? NSNull(),
                                      "persona": persona, "occurrenceOnly": occurrenceOnly,
                                      "excludedEventIDs": eventIDs]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let connection = connection ?? makeConnection()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            NSLog("[CallaEngine] recategorization unavailable: %@", error.localizedDescription)
        }) as? CallaEngineProtocol else { return }
        proxy.recategorizeMeeting(data) { _ in }
    }

    func regenerateCallRecap(_ callID: String, completion: @escaping () -> Void) {
        let connection = connection ?? makeConnection()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            Task { @MainActor in completion() }
        }) as? CallaEngineProtocol else { completion(); return }
        proxy.regenerateCallRecap(callID) { _ in
            Task { @MainActor in completion() }
        }
    }

    /// The model's reading of a meeting, best first. Nil when the request
    /// failed or nothing fit, which the caller treats as worth retrying.
    func suggestMeetingCategory(details: String, completion: @escaping ([String]?) -> Void) {
        let connection = connection ?? makeConnection()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            Task { @MainActor in completion(nil) }
        }) as? CallaEngineProtocol else { completion(nil); return }
        proxy.suggestMeetingCategory(details) { data in
            // A comma-separated list; an older engine replies with one id.
            let answer = String(data: data, encoding: .utf8) ?? ""
            let ranked = CallTypeRanker.parseModelReply(answer, known: CallaPersonaCatalog.builtIn)
            Task { @MainActor in completion(ranked.isEmpty ? nil : ranked) }
        }
    }

    private var lastCallStart: (persona: String, model: String, meeting: CallaMeeting?, noteIDs: [String]?)?

    func retryLastCall() {
        guard let lastCallStart else { return }
        startCall(persona: lastCallStart.persona, model: lastCallStart.model,
                  meeting: lastCallStart.meeting, selectedKnowledgeNoteIDs: lastCallStart.noteIDs)
    }

    func retryLastCallWithoutMeeting() {
        guard let lastCallStart else { return }
        startCall(persona: lastCallStart.persona, model: lastCallStart.model,
                  meeting: nil, selectedKnowledgeNoteIDs: lastCallStart.noteIDs)
    }

    /// A call this app has asked for and not yet seen come up.
    ///
    /// Cleared by the host reporting for itself — either `starting`, which means
    /// the process is alive and the claim is now the host's rather than ours, or
    /// `running`, which means it beat us to it.
    @Published private(set) var launchingCall = false
    /// A local claim that survives brief gaps in the engine's status stream.
    /// Calendar polling must not replace a call while its host is coming up.
    @Published private(set) var callPresentationProtected = false
    private var releaseCallPresentationTask: Task<Void, Never>?
    private var launchDeadline: Date?
    /// Long enough to cover a cold model load and a TCC prompt, short enough that
    /// a host that died on launch does not leave the notch waiting forever.
    private static let launchTimeout: TimeInterval = 30

    private func beginLaunch() {
        protectCallPresentation()
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

    private func protectCallPresentation() {
        releaseCallPresentationTask?.cancel()
        releaseCallPresentationTask = nil
        callPresentationProtected = true
    }

    private func updateCallPresentationProtection(for copilot: CallaCopilotStatus) {
        if launchingCall || endingCall || copilot.starting || copilot.running || copilot.isFinishing {
            protectCallPresentation()
        } else if callPresentationProtected, releaseCallPresentationTask == nil {
            releaseCallPresentationTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let self else { return }
                self.releaseCallPresentationTask = nil
                guard !self.launchingCall, !self.endingCall,
                      !self.status.copilot.starting, !self.status.copilot.running,
                      !self.status.copilot.isFinishing else { return }
                self.callPresentationProtected = false
            }
        }
    }

    private func callCommand(
        _ action: String, persona: String, model: String, meeting: CallaMeeting?
    ) -> CallaCopilotCommand {
        let settings = CallaCopilotSettings.current
        var command = CallaCopilotCommand(
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
        command.carryRecaps = Defaults[.callaCarryRecaps]
        return command
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

    func endCall(origin: String) {
        NSLog("[CallaCallControl] stop requested origin=%@ callID=%@ state=%@",
              origin, status.copilot.callID ?? "none", status.copilot.lifecycleState ?? "none")
        protectCallPresentation()
        Task { await CallVPNManager.shared.restoreAfterCall() }
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

    /// Screenshot of what is being shared, saved with the call and read into
    /// the copilot's context.
    // MARK: - This call's notes

    /// The notes this call was started with, as the host will have frozen them:
    /// the reader's own pick, or every note whose scope matches the call.
    @Published private(set) var callNotes: [CallaKnowledgeNote] = []
    /// Notes switched off for the rest of this call. Cleared when the next starts.
    @Published private(set) var excludedCallNoteIDs = Set<String>()

    private func rememberCallNotes(persona: String, meeting: CallaMeeting?, selected: [String]?) {
        excludedCallNoteIDs = []
        let notes = CallaKnowledgeLibrary.shared.notes
        if let selected {
            let ids = Set(selected)
            callNotes = notes.filter { ids.contains($0.id) }
            return
        }
        callNotes = notes.filter { note in
            note.scope == "always" || (note.scope == "persona" && note.scopeKey == persona)
                || (note.scope == "event" && meeting?.eventID != nil && note.scopeKey == meeting?.eventID)
                || (note.scope == "series" && meeting?.seriesID != nil && note.scopeKey == meeting?.seriesID)
        }
    }

    /// Switches one of this call's notes off, or back on, for the rest of it.
    /// The note itself is not changed; the next call uses it as before.
    func setCallNote(_ id: String, included: Bool) {
        guard status.copilot.running else { return }
        if included { excludedCallNoteIDs.remove(id) } else { excludedCallNoteIDs.insert(id) }
        send(CallaCopilotCommand(action: "exclude_knowledge",
                                 selectedKnowledgeNoteIDs: excludedCallNoteIDs.sorted()))
    }

    func takeScreenshot(displayID: UInt32? = nil) {
        send(CallaCopilotCommand(action: "screenshot", displayID: displayID))
    }

    /// Opens a call's folder in Documents/Calls, or the Calls folder itself.
    func revealCallFolder(callID: String? = nil) {
        invoke { $0.revealCallFolder(callID ?? "", with: $1) }
    }

    func exportPastCalls() {
        invoke { $0.exportPastCalls(with: $1) }
    }

    /// `sync`, `sign_in`, `restore` or `dismiss_notice`.
    func backendControl(_ action: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: ["action": action]) else { return }
        invoke { $0.backendControl(data, with: $1) }
    }

    /// A `notify` pushed by the backend: shown as a system notification, then
    /// cleared so it is shown once.
    private func postBackendNotice(_ notice: CallaBackendState.Notice) {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        if let body = notice.body { content.body = body }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "calla.backend.\(notice.id)", content: content, trigger: nil))
        backendControl("dismiss_notice")
    }

    /// Hands the settings snapshot to the engine, which writes it to Downloads.
    func saveSettingsSnapshot(_ data: Data) {
        invoke { $0.saveSettingsSnapshot(data, with: $1) }
    }

    func exportDiagnostics(completion: @escaping (String) -> Void) {
        let connection = connection ?? makeConnection()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            Task { @MainActor in completion("ERROR: \(error.localizedDescription)") }
        }) as? CallaEngineProtocol else {
            completion("ERROR: Calla engine is unavailable")
            return
        }
        proxy.exportDiagnostics { data in
            Task { @MainActor in
                completion(String(data: data, encoding: .utf8) ?? "ERROR: Invalid engine reply")
            }
        }
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
        _ call: @escaping (CallaEngineProtocol, @escaping (Bool) -> Void) -> Void
    ) {
        let connection = connection ?? makeConnection()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in })
                as? CallaEngineProtocol else { return }
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
                as? CallaEngineProtocol else { completion(nil); return }
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
        }) as? CallaEngineProtocol else {
            completion?(); return
        }
        proxy.gradeQuizAnswer(answerID, grade: grade.rawValue) { _ in
            Task { @MainActor in completion?() }
        }
    }

    func deleteQuizSession(_ sessionID: String, completion: (() -> Void)? = nil) {
        let connection = connection ?? makeConnection()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in completion?() })
                as? CallaEngineProtocol else { completion?(); return }
        proxy.deleteQuizSession(sessionID) { _ in Task { @MainActor in completion?() } }
    }

    func deleteAllQuizHistory(completion: (() -> Void)? = nil) {
        let connection = connection ?? makeConnection()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in completion?() })
                as? CallaEngineProtocol else { completion?(); return }
        proxy.deleteAllQuizHistory { _ in Task { @MainActor in completion?() } }
    }

    private func quizReply<T: Decodable>(
        _ call: @escaping (CallaEngineProtocol, @escaping (Data) -> Void) -> Void,
        as type: T.Type, fallback: T, completion: @escaping (T) -> Void
    ) {
        quizOptionalReply(call, as: type) { completion($0 ?? fallback) }
    }

    private func quizOptionalReply<T: Decodable>(
        _ call: @escaping (CallaEngineProtocol, @escaping (Data) -> Void) -> Void,
        as type: T.Type, completion: @escaping (T?) -> Void
    ) {
        let connection = connection ?? makeConnection()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            Task { @MainActor in completion(nil) }
        }) as? CallaEngineProtocol else { completion(nil); return }
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
        }) as? CallaEngineProtocol else { return }
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
        }) as? CallaEngineProtocol else { return }
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
        }) as? CallaEngineProtocol else { return }
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
    /// Only for the five payloads `CallaEngine.jsonDecoder` handles. The
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
        }) as? CallaEngineProtocol else { return }
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
        }) as? CallaEngineProtocol else { return }
        proxy.copilotCallTranscript(callID) { data in
            let turns = (try? JSONDecoder().decode([CallaCallTurn].self, from: data)) ?? []
            Task { @MainActor in completion(turns) }
        }
    }

    func fetchRecapDraft(callID: String, completion: @escaping (CallaRecapDraft?) -> Void) {
        let connection = connection ?? makeConnection()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            Task { @MainActor in completion(nil) }
        }) as? CallaEngineProtocol else { return }
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
        }) as? CallaEngineProtocol else { return }
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
        }) as? CallaEngineProtocol else { return }
        proxy.copilotRecapControl(payload) { data in
            let recap = try? Self.decoder.decode(CallaRecapDraft.self, from: data)
            Task { @MainActor in completion(recap) }
        }
    }

    /// Lists, names, confirms or merges a call's speakers, or forgets
    /// remembered voices. `remember` comes from the "Remember voices" setting
    /// unless the command already says.
    func controlSpeakers(_ command: CallaSpeakerCommand, completion: @escaping (CallaCallSpeakers?) -> Void) {
        var command = command
        if command.remember == nil { command.remember = Defaults[.callaRememberVoices] }
        guard let payload = try? JSONEncoder().encode(command) else { completion(nil); return }
        let connection = connection ?? makeConnection()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            Task { @MainActor in completion(nil) }
        }) as? CallaEngineProtocol else { return }
        proxy.copilotSpeakerControl(payload) { data in
            let speakers = try? Self.decoder.decode(CallaCallSpeakers.self, from: data)
            Task { @MainActor in completion(speakers) }
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
        let connection = NSXPCConnection(serviceName: CallaBrand.engineService)
        let remoteInterface = NSXPCInterface(with: CallaEngineProtocol.self)
        remoteInterface.setInterface(
            NSXPCInterface(with: CallaEngineStatusObserver.self),
            for: #selector(CallaEngineProtocol.subscribeStatus(_:with:)), argumentIndex: 0, ofReply: false)
        remoteInterface.setInterface(
            NSXPCInterface(with: CallaEngineCallObserver.self),
            for: #selector(CallaEngineProtocol.subscribeCallEvents(_:with:)), argumentIndex: 0, ofReply: false)
        remoteInterface.setInterface(
            NSXPCInterface(with: CallaEngineCodingObserver.self),
            for: #selector(CallaEngineProtocol.subscribeCodingEvents(_:with:)), argumentIndex: 0, ofReply: false)
        connection.remoteObjectInterface = remoteInterface
        connection.exportedInterface = NSXPCInterface(with: CallaEngineObserver.self)
        connection.exportedObject = statusObserver
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in
                self?.connection = nil
                self?.status.running = false
            }
        }
        connection.resume()
        self.connection = connection
        if let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in }) as? CallaEngineProtocol {
            proxy.subscribeStatus(statusObserver) { [weak self] data in
                guard let self, let result = try? Self.decoder.decode(CallaEngineStatus.self, from: data) else { return }
                Task { @MainActor in self.apply(result) }
            }
            proxy.subscribeCallEvents(statusObserver) { _ in }
        }
        return connection
    }
}

private final class StatusObserver: NSObject, CallaEngineObserver {
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

@MainActor
final class CallaDiagnostics: ObservableObject {
    static let shared = CallaDiagnostics()

    @Published private(set) var saving = false
    @Published private(set) var message: String?

    func save() {
        guard !saving else { return }
        saving = true
        message = nil
        CallaEngineClient.shared.exportDiagnostics { [weak self] result in
            guard let self else { return }
            self.saving = false
            if result.hasPrefix("ERROR:") {
                self.message = result
            } else {
                self.message = "Saved \((result as NSString).lastPathComponent) to Downloads"
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: result)])
            }
        }
    }
}
