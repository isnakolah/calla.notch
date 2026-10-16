import ApplicationServices
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import DistributionCore
import ImageIO
import UniformTypeIdentifiers
import CallaContracts
import IntelligenceCore
import IntelligenceProviders
import IntelligenceStore

private struct Preferences: Codable, Equatable {
    let quizEnabled: Bool?
    /// Write each finished call to ~/Documents/Calls. Absent means on.
    let callFoldersEnabled: Bool?
    let callFoldersAudio: Bool?
}

private struct Status: Codable {
    var running = false
    var gatewayReachable = false
    var releaseVersion: String? = nil
    var previousGatewayRelease: String? = nil
    var lastGatewayUpdate: String? = nil
    var lastGatewayUpdateAt: Date? = nil
    var lastResult = "Engine not started"
    var diagnostics: [String] = []
    var copilot: CopilotStatus = CopilotStatus()
    var quiz: QuizSessionSnapshot = QuizSessionSnapshot()
}

/// Live-call state, folded into the same `Status` the notch already polls every
/// two seconds. A second polling loop for the copilot would double the XPC
/// traffic to report a feature that is idle most of the time.
private struct CopilotStatus: Codable {
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
    var summary: String? = nil
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
    /// this is true, which is the claim the pre-roll card makes to the user.
    var prewarming = false
    /// A host process exists and is still paying its fixed costs.
    ///
    /// Distinct from `running`, which was only ever true once the whole of the
    /// host's `start()` had finished — so the notch had nothing to show for the
    /// first seconds of every call and the button read as dead.
    var starting = false
    /// Which fixed cost the host is on: `launching`, `permissions`, `model`,
    /// `capture`, `listening`. Optional so an older host decodes.
    var startupStage: String? = nil
    var modelLoaded = false
    /// The local brain has both lanes open and can answer at conversation speed.
    var brainWarm = false
    /// Nil when the gateway is not part of this call at all.
    var gatewayWarm: Bool? = nil
    /// The meeting this call was armed for, so the card has something to name.
    var meetingTitle: String? = nil
    var meetingStartsAt: Date? = nil
    /// Which brain answered: "local" or "gateway". The notch shows this, because
    /// an automatic failover the user cannot see is indistinguishable from a
    /// broken copilot.
    var activeProvider: String? = nil
    /// The model that answered, or why the local brain stood down.
    var providerDetail: String? = nil
    /// Whether the local Antigravity CLI is installed, so Settings can say
    /// "not installed" instead of a call failing the moment someone speaks.
    var agyAvailable = false
    var agyVersion: String? = nil
    /// Whether `agy` has valid OAuth credentials on disk.
    var agyLoggedIn = false
    /// Where the sign-in has got to: `starting`, `opening_browser`,
    /// `awaiting_code`, `exchanging`, `signed_in`, `failed`.
    ///
    /// A stage rather than a sentence, so the UI can show progress as steps
    /// instead of pattern-matching a status message that anything else can
    /// overwrite.
    /// The call currently being re-transcribed, if any.
    ///
    /// Re-transcription used to report only into `lastResult`, which History never
    /// showed — so pressing the button looked like it did nothing for the minutes it
    /// takes, and the row's badge stayed stale afterwards.
    var retranscribingCallID: String? = nil
    /// Whether a previous credential is set aside and can be put back.
    var agyBackupAvailable = false
    var agyLoginStage: String? = nil
    /// The Google sign-in URL, while a sign-in is running. The pane shows it so
    /// the user is not dependent on a browser having opened by itself.
    var agyLoginURL: String? = nil
    /// True exactly while agy is at its "paste the authorization code" prompt, so
    /// the paste field appears on a fact rather than on matching a status string.
    var agyAwaitingCode = false
    /// The Google account `agy` is authenticated as.
    var agyAccount: String? = nil
    var lastResult: String? = nil
    /// What the *capture host* was granted, read back from the file it writes.
    /// Preflighting here would report this service's own TCC state, which is
    /// not the state that decides whether anything gets recorded.
    var hostMicGranted = false
    var hostScreenGranted = false
    /// False until the host has reported once. Distinguishing this from a
    /// denial is the point: the two look identical in a bare Bool, and showing
    /// "not granted" against a host that holds both is exactly the wrong answer
    /// this path exists to stop giving.
    var hostPermissionsKnown = false
    var modelDownload: ModelDownloadFile? = nil
    /// Where the host is in its own lifecycle: `capturing`, `stopping`,
    /// `processingRecap`, `finished`. The host has published this since v2 and
    /// nothing forwarded it, so the app could see a call start and could see it
    /// vanish, and knew nothing about the seconds in between — which is exactly
    /// the window where End call looked like it had done nothing.
    var lifecycleState: String? = nil
    /// 0…1 while the recap is being written; nil otherwise.
    var recapProgress: Double? = nil
    /// The call has stopped capturing and is writing itself up. Exclusive with
    /// `running` and `starting`, on the same principle those two follow: three
    /// different things are happening and one Bool cannot say which.
    var finishing = false
}

/// Mirrors `permissions.json`, written by CallaCallHost about itself.
private struct CopilotPermissionsFile: Codable {
    var micGranted: Bool
    var screenGranted: Bool
    var checkedAt: Date?

    enum CodingKeys: String, CodingKey {
        case micGranted = "mic_granted"
        case screenGranted = "screen_granted"
        case checkedAt = "checked_at"
    }
}

/// Mirrors `model-download.json`, written by the host while it fetches a model.
private struct ModelDownloadFile: Codable {
    var model: String
    var receivedBytes: Int64
    var totalBytes: Int64
    var state: String
    var message: String?

    enum CodingKeys: String, CodingKey {
        case model, state, message
        case receivedBytes = "received_bytes"
        case totalBytes = "total_bytes"
    }
}

/// Just enough of a `CallTurn` to count and order them.
///
/// Deliberately not the whole shape: this decodes every line of an archive on a
/// list refresh, and the text is the expensive part nobody is reading yet.
private struct ArchivedTurn: Codable {
    var seq: Int
}

/// A transcript turn on its way to the notch.
///
/// Only needed since the store became the source: the JSONL path replies with the
/// host's own lines verbatim, which already carry these keys. Mirrors
/// `CallaCallTurn` in the app.
private struct ArchivedTurnOut: Codable {
    var id: UUID
    var seq: Int
    var source: String
    var t0: Double
    var t1: Double
    var text: String
    var confidence: Double?
    /// `me`, `S1`, `S2`, … once the post-call speaker pass has run.
    var speaker: String?
    /// What to call that speaker: a name, "You", or "Speaker N".
    var speakerName: String?

    enum CodingKeys: String, CodingKey {
        case id, seq, source, t0, t1, text, confidence, speaker
        case speakerName = "speaker_name"
    }
}

/// A speaker command from the History pane.
///
/// `name` with an empty `name` clears a name; `merge` folds `speaker_id` into
/// `into`. `remember` says whether this person's voice may be kept for future
/// calls — the app's "Remember voices" setting — and governs every action that
/// would enroll one.
private struct CopilotSpeakerCommand: Codable {
    let action: String
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

/// The speakers of one call plus every remembered voice, as the app shows them.
private struct CopilotSpeakersOut: Codable {
    struct Speaker: Codable {
        var id: String
        var name: String
        var nameSource: String
        var confidence: Double?
        var speechSeconds: Double

        enum CodingKeys: String, CodingKey {
            case id, name, confidence
            case nameSource = "name_source"
            case speechSeconds = "speech_seconds"
        }
    }

    struct Voice: Codable {
        var personID: String
        var name: String
        var updatedAt: Date

        enum CodingKeys: String, CodingKey {
            case name
            case personID = "person_id"
            case updatedAt = "updated_at"
        }
    }

    var speakers: [Speaker]
    var attendees: [String]
    var voices: [Voice]
}

/// The interview's occurrence ids, mirrored from the app's `WaveInterview`.
///
/// Hand-mirrored because the engine is a separate process with its own module
/// graph and does not link the app. Only the two ids are needed here: the app
/// owns everything else about the meeting.
enum CallaWaveIdentity {
    static let seriesID = "wave-interview"
    static let rehearsalEventID = "wave-interview-rehearsal"
}

/// One archived call, as listed for the History pane.
private struct CallSummaryFile: Codable {
    var id: String
    var startedAt: Date?
    var endedAt: Date?
    var endReason: String?
    var turnCount: Int
    var persona: String
    var hasAudio: Bool
    /// Whether `transcript-archive.jsonl` exists — the large model has been over
    /// this call. Without it, History could not tell a call that was re-transcribed
    /// from one that never was.
    var retranscribed: Bool = false
    /// Turns in the re-transcribed pass, so a better transcript is visibly better.
    var archivedTurnCount: Int = 0
    /// How many suggestions the copilot returned during the call. Zero on a call
    /// that transcribed fine and never answered is the signal worth seeing.
    var suggestionCount: Int = 0
    /// Which meeting the call belonged to. History groups on these, and a call
    /// recorded before the app pinned a meeting has neither.
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
}

/// Mirrors `ActiveCallStatus` written by CallaCallHost.
private struct CopilotHostStatus: Codable {
    var callID: String
    var persona: String
    var startedAt: Date
    var turnCount: Int
    var gatewayConnected: Bool
    var micActive: Bool
    var systemAudioActive: Bool
    /// Optional: a status file written by an older host has neither, and a
    /// missing key must not throw away the whole status.
    var provider: String?
    var providerDetail: String?
    var speaking: String?
    var thinking: Bool?
    var working: String?
    var questionWorking: Bool?
    var summaryWorking: Bool?
    var answering: Bool?
    var prewarming: Bool?
    var meetingTitle: String?
    var meetingStartsAt: Date?
    var lifecycle: CopilotLifecycleFile?

    enum CodingKeys: String, CodingKey {
        case callID = "call_id"
        case persona
        case prewarming
        case meetingTitle = "meeting_title"
        case meetingStartsAt = "meeting_starts_at"
        case startedAt = "started_at"
        case turnCount = "turn_count"
        case gatewayConnected = "gateway_connected"
        case micActive = "mic_active"
        case systemAudioActive = "system_audio_active"
        case provider, speaking, thinking, answering, working
        case questionWorking = "question_working"
        case summaryWorking = "summary_working"
        case providerDetail = "provider_detail"
        case lifecycle
    }
}

/// Small, forward-compatible projection of v2 lifecycle. Keep engine status
/// sanitized: no transcript, prompt, capture path, or raw provider output.
private struct CopilotLifecycleFile: Codable {
    var contractVersion: Int
    var generation: Int
    var state: String
    /// 0…1 while the host is writing the recap. Optional for the same reason
    /// every other field here is: a host older than it must still decode.
    var recapProgress: Double?
    /// Absent once the call is up, and absent entirely from a host older than
    /// the startup checklist.
    var startup: CopilotStartupFile?

    enum CodingKeys: String, CodingKey {
        case contractVersion = "contractVersion"
        case generation, state, startup, recapProgress
    }
}

/// Mirrors `CallStartupProgress`. Every field optional: this is read from a file
/// another executable writes, and one renamed key must not cost the whole status.
private struct CopilotStartupFile: Codable {
    var stage: String?
    var modelLoaded: Bool?
    var brainWarm: Bool?
    var gatewayWarm: Bool?
}

/// Mirrors the gateway's `suggestion` frame as persisted by the host.
private struct CopilotSuggestionFile: Codable {
    var callID: String
    var afterSeq: Int
    var headline: String
    var angles: [String]
    var confirm: [String]
    var question: String? = nil
    var citations: [String]?
    var grounding: String? = nil
    var latencyMs: Int?
    var summary: String?
    var openQuestions: [String]?

    enum CodingKeys: String, CodingKey {
        case callID = "call_id"
        case afterSeq = "after_seq"
        case headline
        case angles
        case confirm
        case question
        case citations
        case grounding
        case latencyMs = "latency_ms"
        case summary
        case openQuestions = "open_questions"
    }
}

/// Typed copilot command from the owner UI.
private struct CopilotCommand: Codable {
    var action: String
    var persona: String?
    var model: String?
    var callID: String?
    var question: String?
    var profile: CopilotProfile?
    /// "local" or "gateway". Absent means leave the stored preference alone.
    var provider: String?
    /// Live model tier for the local brain: fast | balanced | deep.
    var tier: String?
    /// Exact model for the end-of-call pass.
    var summaryModel: String?
    /// Whether the gateway may answer when the local brain cannot.
    var fallback: Bool?
    /// When the gateway socket opens: off | on-failure | warm.
    var gatewayStandby: String?
    /// The calendar event this call belongs to. The app sends the identity and
    /// the event's own fields; the knowledge itself is composed here, because the
    /// app is sandboxed and cannot open the store.
    var meeting: CopilotMeeting?
    var selectedKnowledgeNoteIDs: [String]?

    enum CodingKeys: String, CodingKey {
        case action, persona, model, profile, provider, tier, fallback, meeting, question
        case selectedKnowledgeNoteIDs = "selected_knowledge_note_ids"
        case summaryModel = "summary_model"
        case gatewayStandby = "gateway_standby"
        case callID = "call_id"
    }
}

private struct CopilotRecapCommand: Codable {
    let action: String
    let callID: String

    enum CodingKeys: String, CodingKey { case action; case callID = "call_id" }
}

/// The calendar event a call is for, as the app sends it.
private struct CopilotMeeting: Codable {
    var eventID: String?
    var seriesID: String?
    var title: String?
    var startsAt: Double?
    var endsAt: Double?
    var location: String?
    var attendees: [String]?
    var notes: String?

    enum CodingKeys: String, CodingKey {
        case title, location, attendees, notes
        case eventID = "event_id"
        case seriesID = "series_id"
        case startsAt = "starts_at"
        case endsAt = "ends_at"
    }
}

/// The user's prompt text, on its way to the gateway.
///
/// Free text, unlike every other field a command carries — which is why it is
/// kept in its own type and handed to the host on stdin. Nothing in here is ever
/// allowed to become a process argument.
private struct CopilotProfile: Codable {
    var about: String?
    var personaGuidance: String?
    var baseGuidance: String?

    enum CodingKeys: String, CodingKey {
        case about
        case personaGuidance = "persona_guidance"
        case baseGuidance = "base_guidance"
    }
}

extension JSONEncoder {
    /// ISO-8601 dates, matching the decoder the app already uses for every other
    /// reply this service sends.
    static var calla: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

/// A mutable cell for handing one value back out of a detached task.
///
/// `@unchecked Sendable` is accurate rather than lazy here: exactly one task
/// writes it, and the reader only runs after that task has signalled a semaphore,
/// which is a full barrier.
private final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}

/// A knowledge note crossing the XPC boundary in either direction.
///
/// The app owns the editing UI and the store lives on this side of the sandbox
/// line, so every create, edit and delete is one of these.
private struct KnowledgeCommand: Codable {
    /// `upsert`, `delete`, or `list`.
    var action: String
    var id: String?
    var title: String?
    var body: String?
    var scope: String?
    var scopeKey: String?
    /// For `list`: restrict to one event and its series.
    var eventID: String?
    var seriesID: String?
    /// `manual` or `document`. A document is a file the app read on its own side
    /// of the sandbox line; only the text it extracted ever reaches this process.
    var source: String?
    var originName: String?
    var originKind: String?
    var byteSize: Int?
    var pageCount: Int?

    enum CodingKeys: String, CodingKey {
        case action, id, title, body, scope, source
        case scopeKey = "scope_key"
        case eventID = "event_id"
        case seriesID = "series_id"
        case originName = "origin_name"
        case originKind = "origin_kind"
        case byteSize = "byte_size"
        case pageCount = "page_count"
    }
}

/// Boring keeps a bounded local summary of each private Gateway transaction so
/// Settings can show result after the XPC process restarts. Gateway remains
/// authoritative for full receipts under its release root.
private struct GatewayUpdateRecord: Codable {
    let currentRelease: String?
    let previousRelease: String?
    let summary: String
    let completedAt: Date

    enum CodingKeys: String, CodingKey {
        case currentRelease = "current_release"
        case previousRelease = "previous_release"
        case summary
        case completedAt = "completed_at"
    }
}

/// Persistent reader for CallHost's owner-only event socket. One bounded,
/// length-prefixed v3 event per frame; reconnects while exact call generation
/// remains active. Files remain recovery fallback.
private final class CallEventSocketClient: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    private var descriptor: Int32 = -1

    func start(path: URL, receive: @escaping @Sendable (CallEvent) -> Void) {
        stop()
        lock.withLock { active = true }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.run(path: path, receive: receive)
        }
    }

    func stop() {
        let fd = lock.withLock { () -> Int32 in
            active = false
            let fd = descriptor
            descriptor = -1
            return fd
        }
        if fd >= 0 { shutdown(fd, SHUT_RDWR); Darwin.close(fd) }
    }

    private var isActive: Bool { lock.withLock { active } }

    private func run(path: URL, receive: @escaping @Sendable (CallEvent) -> Void) {
        while isActive {
            guard let fd = Self.connect(path: path) else {
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            lock.withLock {
                if active { descriptor = fd }
                else { Darwin.close(fd) }
            }
            guard isActive else { return }
            readFrames(from: fd, receive: receive)
            lock.withLock {
                if descriptor == fd { descriptor = -1 }
            }
            Darwin.close(fd)
        }
    }

    private func readFrames(from fd: Int32, receive: @escaping @Sendable (CallEvent) -> Void) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        while isActive {
            guard let header = Self.read(count: 4, from: fd) else { return }
            let length = header.withUnsafeBytes { raw -> UInt32 in
                raw.loadUnaligned(as: UInt32.self).bigEndian
            }
            guard length > 0, length <= 256 * 1_024,
                  let payload = Self.read(count: Int(length), from: fd),
                  let event = try? decoder.decode(CallEvent.self, from: payload)
            else { return }
            receive(event)
        }
    }

    private static func connect(path: URL) -> Int32? {
        guard path.path.utf8.count < MemoryLayout<sockaddr_un>.size - 3 else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let maximum = MemoryLayout.size(ofValue: address.sun_path) - 1
        _ = path.path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { destination in
                strncpy(UnsafeMutableRawPointer(destination).assumingMemoryBound(to: CChar.self), source, maximum)
            }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { Darwin.close(fd); return nil }
        return fd
    }

    private static func read(count: Int, from fd: Int32) -> Data? {
        var data = Data(count: count)
        let completed = data.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            var offset = 0
            while offset < count {
                let result = recv(fd, base.advanced(by: offset), count - offset, 0)
                if result > 0 { offset += result; continue }
                if result < 0, errno == EINTR { continue }
                return false
            }
            return true
        }
        return completed ? data : nil
    }
}

/// Privileged call engine. Preferences arrive as complete snapshots from
/// Boring UI; this process never reads Boring or legacy Calla preferences.
final class BoringCallaEngine: NSObject, BoringCallaEngineProtocol, @unchecked Sendable {
    // A test can stop only its own call, never a later user-started meeting.
    private let queue = DispatchQueue(label: "theboringteam.boringnotch.calla-engine")
    private let fileManager = FileManager.default
    private var preferences: Preferences?
    private var isRunning = false
    private var lastResult = "Engine not started"
    private var copilotProcess: Process?
    private var copilotEventClient: CallEventSocketClient?
    private var copilotEventSequence = -1
    private var copilotEventQuestion: CallQuestion?
    private var copilotEventAnswer: CallAnswer?
    /// Live Call host inherited from an earlier Engine instance. Kept only after
    /// PID file, executable command, status call ID and generation all agree.
    private var adoptedCopilotPID: pid_t?
    private var adoptedCopilotCallID: String?
    /// Generation for which owner UI explicitly requested End. CallHost drains
    /// SIGTERM too, so process exit alone cannot distinguish user completion
    /// from external termination.
    private var copilotStopRequestedGeneration: Int?
    /// Monotonic per-engine call epoch. A host from an earlier run can finish
    /// after a restart; its file/event must not replace current call state.
    private var copilotGeneration = 0
    private var copilotPersona = "generic"
    private var copilotModel = "whisper-small-en"
    /// Which brain the next call starts on. Local by default, so a call still
    /// gets suggestions when `nomonhomelab` is unreachable.
    private var copilotProvider = "local"
    /// Which tier the next call answers on before the app has told us. Fast,
    /// for the same reason the app defaults to it: ~1.9s against ~5.2s.
    private var copilotTier = "fast"
    private var copilotSummaryModel = "gemini-3.1-pro-high"
    private var copilotFallback = true
    /// When the gateway socket opens on a call the local brain is answering.
    /// Warm matches what every host did before this was a setting.
    private var copilotGatewayStandby: GatewayStandby = .warm
    /// Mirrors the notch's "Answers only" toggle.
    private var retranscribingCallID: String?
    private var copilotResult: String?
    /// `agy --version`, probed once. Cached because it costs a process and the
    /// status poll runs every two seconds.
    private var privateSetupTestCallID: String?
    private let setupSessionHost = SetupSessionHost()
    private var agyProbe: (available: Bool, version: String?)?
    private var agyAuthCache: (loggedIn: Bool, account: String?)?
    /// Existence, size and modification date of the credential file, so a change
    /// to it invalidates the cached answer.
    private var agyAuthCacheFingerprint: String?
    /// The pty master: both where the TUI's screen is read from and where a pasted
    /// code is written to.
    private var agyLoginInput: FileHandle?
    private var agyLoginChoseMethod = false
    private var agyLoginStage: String?
    private var agyLoginFailure: String?
    /// Set only for a rehearsal, and the thing that keeps it away from the real
    /// credential.
    private var agyLoginRehearsalHome: URL?
    /// Set by `sign_out`, so the auto-repair that protects a failed
    /// re-authentication does not quietly sign the user back in.
    private var agyExplicitSignOut = false
    private var agyLoginLogURL: URL {
        copilotRoot.appendingPathComponent("agy-login.log")
    }
    private var agyLoginProcess: Process?
    /// Tail of the pty stream, kept so a failure can be explained in the words
    /// agy used rather than an exit code.
    private var agyLoginBuffer = ""
    private var agyLoginURL: String?
    private var agyLoginAwaitingCode = false
    /// One-shot channel for the prompt profile, held only between building the
    /// process and writing to it.
    private var copilotProfilePipe: Pipe?
    private var copilotPendingProfile: Data?
    /// Knowledge and call history.
    ///
    /// This process opens it because the app cannot: the app is sandboxed, the
    /// store lives in the unsandboxed runtime directory, and every read the
    /// Settings panes do comes through XPC. Opened lazily so a broken file costs
    /// the knowledge features rather than the whole engine.
    private lazy var store: CallaStore? = {
        do {
            return try CallaStore(path: copilotRoot.appendingPathComponent("calla.sqlite"))
        } catch {
            NSLog("[CallaEngine] knowledge store unavailable: %@", error.localizedDescription)
            return nil
        }
    }()
    private var archiveProcess: Process?
    private var modelProcess: Process?
    private var permissionProcess: Process?
    private var hostPermissionCheckStarted = false
    /// The host writes ISO-8601 dates; the default decoder would reject them.
    private lazy var jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
    private var gatewayUpdate: Process?
    private var gatewayReachable = false
    private var gatewayMonitor: DispatchSourceTimer?
    private var diagnostics: [String] = []
    // XPC observer arguments are proxies. The subscription must retain them
    // until this connection shuts down; a weak table loses the push channel.
    private let statusObservers = NSHashTable<AnyObject>(options: .strongMemory)
    private let callObservers = NSHashTable<AnyObject>(options: .strongMemory)
    private let codingObservers = NSHashTable<AnyObject>(options: .strongMemory)
    private var codingObserverSequence = -1
    private var statusMonitor: DispatchSourceTimer?
    // Call folders — see the extension at the end of this file.
    fileprivate var lastCallFolder: String?
    fileprivate var lastSeenCallID: String?
    fileprivate var exportingCallIDs = Set<String>()
    fileprivate var callFolderTimer: DispatchSourceTimer?
    fileprivate let callFolderQueue = DispatchQueue(label: "theboringteam.boringnotch.call-folders", qos: .utility)
    private lazy var quizController = QuizEngineController(
        root: root.appendingPathComponent("quiz", isDirectory: true),
        hostExecutable: { [weak self] in self?.copilotExecutable })
    private lazy var codingController = CodingSessionController(
        root: root.appendingPathComponent("coding", isDirectory: true),
        hostExecutable: { [weak self] in self?.copilotExecutable },
        askCall: { [weak self] callID, generation, questionID, prompt, evidence in
            guard let self else { return false }
            return await withCheckedContinuation { continuation in
                self.queue.async {
                    guard self.copilotGeneration == generation,
                          self.currentCopilotStatus().callID == callID else {
                        continuation.resume(returning: false); return
                    }
                    let event = self.requestHostControl(.answer, callID: callID, text: prompt, questionID: questionID, codingEvidence: evidence)
                    continuation.resume(returning: event?.kind == .answer)
                }
            }
        })

    private var root: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("boringNotch/Calla", isDirectory: true)
    }

    /// Receipt from builds that ran the removed Tutor host; reclaimed once.
    private var retiredRuntimePIDURL: URL { root.appendingPathComponent("runtime.pid") }
    /// Migration-only PID receipt from builds that embedded a local OpenClaw
    /// node. New builds never create it or launch OpenClaw on this Mac.
    private var retiredNodePIDURL: URL { root.appendingPathComponent("node.pid") }

    func start(with reply: @escaping (Data) -> Void) {
        queue.async {
            NSLog("[CallaEngine] start requested")
            do {
                try self.prepareRuntimeDirectories()
                self.restorePreferences()
                self.reclaimStaleOwnedChildren()
                let liveCallID = self.reconcileOwnedCopilotAtStartup()
                self.importArchivesOnce(preservingLiveCallID: liveCallID)
                self.isRunning = true
                self.lastResult = "Engine ready"
                self.startCallFolderSweep()
                self.startGatewayMonitor()
                NSLog("[CallaEngine] runtime launched")
            } catch {
                self.isRunning = false
                self.lastResult = "Engine startup failed: \(error.localizedDescription)"
                NSLog("[CallaEngine] startup failed: %@", error.localizedDescription)
            }
            reply(self.encodedStatus())
        }
    }

    /// Everything this service started, brought down.
    ///
    /// Called both by `stop()` and when the app's XPC connection drops — a force
    /// quit or a crash must not leave a call host holding the microphone, or a
    /// resident `agy` language server holding ~190MB, with nothing driving either.
    func shutdownEverything() {
        setupSessionHost.cancel()
        queue.async {
            self.statusMonitor?.cancel(); self.statusMonitor = nil
            self.statusObservers.removeAllObjects(); self.callObservers.removeAllObjects(); self.codingObservers.removeAllObjects()
        }
        _ = awaitOnQueue { [quizController] in await quizController.shutdown(); return true }
        _ = awaitOnQueue { [codingController] in await codingController.shutdown(); return true }
        stopGatewayMonitor()
        callFolderTimer?.cancel(); callFolderTimer = nil
        let interruptedCallID = currentOwnedCopilotCallID()
        if let interruptedCallID { markCallInterrupted(interruptedCallID) }
        if let copilot = copilotProcess, copilot.isRunning {
            // SIGINT first: the host drains the trailing utterance on it.
            kill(copilot.processIdentifier, SIGINT)
            terminateProcessTree(copilot.processIdentifier)
        } else if let adoptedCopilotPID, isOwnedCopilotProcess(adoptedCopilotPID) {
            kill(adoptedCopilotPID, SIGINT)
            terminateProcessTree(adoptedCopilotPID)
        }
        copilotProcess = nil
        copilotEventClient?.stop()
        copilotEventClient = nil
        copilotEventSequence = -1
        copilotEventQuestion = nil
        copilotEventAnswer = nil
        adoptedCopilotPID = nil
        adoptedCopilotCallID = nil
        copilotStopRequestedGeneration = nil
        clearOwnedPID(at: copilotPIDURL)
        try? fileManager.removeItem(at: copilotStatusURL)
        if let login = agyLoginProcess, login.isRunning {
            terminateProcessTree(login.processIdentifier)
        }
        agyLoginProcess = nil
        agyLoginInput = nil
        terminateStrayAgyHosts()
        gatewayReachable = false
        isRunning = false
    }

    /// Kills `agy` hosts that are ours but no longer anyone's child.
    ///
    /// A host orphaned by an earlier crash has been reparented to launchd, so no
    /// tree walk reaches it. They are identifiable because every host is launched
    /// with `--log-file` inside this app's runtime directory — the user's own `agy`
    /// in a terminal has nothing to do with that path and is never matched.
    ///
    /// `orphansOnly` limits the sweep to hosts whose wrapper has already been
    /// reparented to launchd. Startup uses it: a call host adopted across an
    /// Engine restart still owns its `agy`, and that one must be left alone.
    /// Orphans are killed outright if asking does not work, because `agy`
    /// ignores SIGTERM and nothing else will ever reap them.
    private func terminateStrayAgyHosts(orphansOnly: Bool = false) {
        let marker = copilotRoot.appendingPathComponent("agy").path
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,command="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var parents: [pid_t: pid_t] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard line.contains(marker), line.contains("agy") else { continue }
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count >= 2, let pid = pid_t(fields[0]), let parent = pid_t(fields[1]), pid > 1 else { continue }
            parents[pid] = parent
        }
        // A host's tree is `script` -> `agy`; its root is the one whose parent
        // is not itself part of a host.
        func isOrphaned(_ pid: pid_t) -> Bool {
            var current = pid
            while let parent = parents[current] { current = parent }
            return current == 1
        }
        let orphans = parents.keys.filter(isOrphaned)
        let targets = orphansOnly ? orphans : Array(parents.keys)
        guard !targets.isEmpty else { return }
        for pid in targets { Darwin.kill(pid, SIGTERM) }
        guard !orphans.isEmpty else { return }
        usleep(300_000)
        for pid in orphans where Darwin.kill(pid, 0) == 0 { Darwin.kill(pid, SIGKILL) }
        NSLog("[CallaEngine] reaped %d orphaned agy process(es)", orphans.count)
    }

    func stop(with reply: @escaping (Data) -> Void) {
        queue.async {
            // The call host holds the microphone, so it goes down with everything
            // else rather than leaving a recording indicator lit.
            self.shutdownEverything()
            self.lastResult = "Engine stopped"
            reply(self.encodedStatus())
        }
    }

    func applyPreferences(_ data: Data, with reply: @escaping (Data) -> Void) {
        queue.async {
            guard let decoded = try? JSONDecoder().decode(Preferences.self, from: data) else {
                self.lastResult = "Rejected invalid preference snapshot"
                reply(self.encodedStatus())
                return
            }
            self.preferences = decoded
            do {
                try self.writePreferences(decoded)
            } catch {
                self.lastResult = "Could not persist preference snapshot: \(error.localizedDescription)"
                reply(self.encodedStatus())
                return
            }
            self.lastResult = self.isRunning ? "Live preference snapshot applied" : "Preferences saved for engine start"
            reply(self.encodedStatus())
        }
    }

    func status(with reply: @escaping (Data) -> Void) {
        queue.async { reply(self.encodedStatus()) }
    }

    // MARK: - Screen Quiz

    func listQuizWindows(with reply: @escaping (Data) -> Void) {
        queue.async {
            Task { [weak self] in
                guard let self else { return }
                let windows = (try? await self.quizController.listWindows()) ?? []
                let data = (try? JSONEncoder.calla.encode(windows)) ?? Data("[]".utf8)
                self.queue.async { reply(data) }
            }
        }
    }

    func listQuizModels(with reply: @escaping (Data) -> Void) {
        queue.async {
            Task { [weak self] in
                guard let self else { return }
                let models = (try? await self.quizController.listModels()) ?? []
                let data = (try? JSONEncoder.calla.encode(models)) ?? Data("[]".utf8)
                self.queue.async { reply(data) }
            }
        }
    }

    func requestQuizPermissions(with reply: @escaping (Data) -> Void) {
        queue.async {
            Task { [weak self] in
                guard let self else { return }
                let readiness = await self.quizController.requestPermissions()
                let data = (try? JSONEncoder.calla.encode(readiness)) ?? Data()
                self.queue.async { reply(data) }
            }
        }
    }

    func warmQuiz(_ data: Data, with reply: @escaping (Bool) -> Void) {
        queue.async {
            guard self.preferences?.quizEnabled == true else { reply(false); return }
            guard data.count <= 16 * 1_024,
                  let request = try? self.jsonDecoder.decode(QuizWarmRequest.self, from: data)
            else { reply(false); return }
            guard self.copilotProcess?.isRunning != true,
                  !self.currentCopilotStatus().running else { reply(false); return }
            Task { [weak self] in
                guard let self else { return }
                await self.quizController.warm(request)
                self.queue.async { reply(true) }
            }
        }
    }

    func cancelQuizWarm(with reply: @escaping (Bool) -> Void) {
        queue.async {
            Task { [weak self] in
                guard let self else { return }
                await self.quizController.cancelWarm()
                self.queue.async { reply(true) }
            }
        }
    }

    func startQuiz(_ data: Data, with reply: @escaping (Data) -> Void) {
        queue.async {
            guard self.preferences?.quizEnabled == true else {
                self.lastResult = "Quiz is disabled by runtime feature gate"
                reply(self.encodedQuizSnapshot(.init(state: .failed, failure: self.lastResult))); return
            }
            guard data.count <= 512 * 1_024,
                  let configuration = try? self.jsonDecoder.decode(QuizSessionConfiguration.self, from: data) else {
                self.lastResult = "Rejected invalid Quiz configuration"
                reply(self.encodedQuizSnapshot(.init(state: .failed, failure: self.lastResult))); return
            }
            guard self.copilotProcess?.isRunning != true,
                  !self.currentCopilotStatus().running else {
                self.lastResult = "End Call before starting Quiz"
                reply(self.encodedQuizSnapshot(.init(state: .failed, failure: self.lastResult))); return
            }
            Task { [weak self] in
                guard let self else { return }
                let result: Result<QuizSessionSnapshot, Error>
                do { result = .success(try await self.quizController.start(configuration)) }
                catch { result = .failure(error) }
                let snapshot: QuizSessionSnapshot
                switch result {
                case .success(let value): snapshot = value
                case .failure(let error):
                    let current = await self.quizController.snapshot()
                    snapshot = QuizSessionSnapshot(
                        state: .failed,
                        target: configuration.target,
                        screenRecordingReady: current.screenRecordingReady,
                        accessibilityReady: current.accessibilityReady,
                        agyAuthenticated: current.agyAuthenticated,
                        modelsReady: current.modelsReady,
                        workersReady: false,
                        failure: error.localizedDescription)
                }
                let data = self.encodedQuizSnapshot(snapshot)
                self.queue.async {
                    switch result {
                    case .success:
                        self.lastResult = "Quiz watching selected window"
                    case .failure(let error):
                        self.lastResult = "Quiz start failed: \(error.localizedDescription)"
                    }
                    reply(data)
                }
            }
        }
    }

    func sendQuizCommand(_ data: Data, with reply: @escaping (Data) -> Void) {
        queue.async {
            guard data.count <= 32 * 1_024,
                  let command = try? self.jsonDecoder.decode(QuizCommand.self, from: data) else {
                self.lastResult = "Rejected invalid Quiz command"
                reply(self.encodedQuizSnapshot(.init(state: .failed, failure: self.lastResult))); return
            }
            Task { [weak self] in
                guard let self else { return }
                let result: Result<QuizSessionSnapshot, Error>
                do { result = .success(try await self.quizController.send(command)) }
                catch { result = .failure(error) }
                let snapshot: QuizSessionSnapshot
                switch result {
                case .success(let value): snapshot = value
                case .failure: snapshot = await self.quizController.snapshot()
                }
                let data = self.encodedQuizSnapshot(snapshot)
                self.queue.async {
                    if case .failure(let error) = result {
                        self.lastResult = "Quiz command failed: \(error.localizedDescription)"
                    }
                    reply(data)
                }
            }
        }
    }

    func quizStatus(with reply: @escaping (Data) -> Void) {
        queue.async {
            let value = self.awaitOnQueue { await self.quizController.snapshot() } ?? QuizSessionSnapshot()
            reply((try? JSONEncoder.calla.encode(value)) ?? Data())
        }
    }

    func quizHistory(with reply: @escaping (Data) -> Void) {
        queue.async {
            let value = self.awaitOnQueue { await self.quizController.history() } ?? []
            reply((try? JSONEncoder.calla.encode(value)) ?? Data("[]".utf8))
        }
    }

    func revealQuizCapture(_ captureID: String, with reply: @escaping (Data) -> Void) {
        queue.async {
            guard captureID.range(of: "^[A-Za-z0-9._-]{8,160}$", options: .regularExpression) != nil else {
                reply(Data()); return
            }
            reply(self.awaitOnQueue { await self.quizController.reveal(captureID: captureID) } ?? Data())
        }
    }

    func gradeQuizAnswer(_ answerID: String, grade: Int, with reply: @escaping (Data) -> Void) {
        queue.async {
            guard answerID.range(of: "^[A-Za-z0-9._-]{8,160}$", options: .regularExpression) != nil,
                  let value = QuizAnswerGrade(rawValue: grade) else {
                reply(self.encodedStatus()); return
            }
            _ = self.awaitOnQueue {
                try? await self.quizController.grade(answerID: answerID, grade: value)
                return true
            }
            reply(self.encodedStatus())
        }
    }

    func deleteQuizSession(_ sessionID: String, with reply: @escaping (Data) -> Void) {
        queue.async {
            guard sessionID.range(of: "^[A-Za-z0-9._-]{8,160}$", options: .regularExpression) != nil else {
                reply(self.encodedStatus()); return
            }
            _ = self.awaitOnQueue { try? await self.quizController.delete(sessionID: sessionID); return true }
            reply(self.encodedStatus())
        }
    }

    func deleteAllQuizHistory(with reply: @escaping (Data) -> Void) {
        queue.async {
            _ = self.awaitOnQueue { try? await self.quizController.deleteAll(); return true }
            reply(self.encodedStatus())
        }
    }

    // MARK: - Live Coding

    func prepareWave(_ data: Data, with reply: @escaping (Data) -> Void) {
        guard data.count <= 512 * 1024,
              let request = try? jsonDecoder.decode(WavePreparationRequest.self, from: data) else {
            reply(Data()); return
        }
        Task {
            let result = await codingController.prepareWave(request)
            reply((try? JSONEncoder.calla.encode(result)) ?? Data())
        }
    }

    func registerCodingFolder(_ bookmark: Data, with reply: @escaping (Data) -> Void) {
        queue.async {
            guard !bookmark.isEmpty, bookmark.count <= 256 * 1_024 else { reply(Data()); return }
            Task { [weak self] in
                guard let self else { return }
                let value = try? await self.codingController.registerFolder(bookmark: bookmark)
                let data = value.flatMap { try? JSONEncoder.calla.encode($0) } ?? Data()
                self.queue.async { reply(data) }
            }
        }
    }

    func startCoding(_ data: Data, with reply: @escaping (Data) -> Void) {
        queue.async {
            guard data.count <= 512 * 1_024,
                  let configuration = try? self.jsonDecoder.decode(CodingSessionConfiguration.self, from: data)
            else { reply(Data()); return }
            let call = self.currentCopilotStatus()
            let matchesLiveCall = call.running && call.callID == configuration.callID
                && configuration.generation == self.copilotGeneration
            let reservesNextCall = !call.running && !call.starting && !call.finishing
                && configuration.generation == self.copilotGeneration + 1
            guard matchesLiveCall || reservesNextCall else {
                let failed = CodingSessionSnapshot(
                    sessionID: configuration.sessionID, callID: configuration.callID,
                    generation: configuration.generation, lifecycle: .failed,
                    failure: .init(code: "call_not_active",
                                   message: "Start Live Coding capture before creating its shadow.",
                                   recovery: "Start the call, then try Code again."))
                reply((try? JSONEncoder.calla.encode(failed)) ?? Data()); return
            }
            let quiz = self.awaitOnQueue { await self.quizController.snapshot() } ?? .init()
            guard !quiz.active else { reply(Data()); return }
            self.codingObserverSequence = -1
            Task { [weak self] in
                guard let self else { return }
                // Report why, rather than replying with nothing.
                //
                // `try?` here cost two debugging sessions: a bookmark that would
                // not resolve and a date the decoder rejected both arrived as an
                // empty reply, which the notch could only render as a 45-second
                // timeout naming neither. A start that fails now says so.
                var snapshot: CodingSessionSnapshot?
                do {
                    snapshot = try await self.codingController.start(configuration)
                } catch {
                    snapshot = CodingSessionSnapshot(
                        sessionID: configuration.sessionID, callID: configuration.callID,
                        generation: configuration.generation, lifecycle: .failed,
                        failure: .init(code: "coding_start_failed",
                                       message: error.localizedDescription,
                                       recovery: "Check the project folder and AGY sign-in, then try again."))
                }
                let encoded = snapshot.flatMap { try? JSONEncoder.calla.encode($0) } ?? Data()
                self.queue.async { reply(encoded) }
                if snapshot?.lifecycle == .ready {
                    self.queue.async { self.startStatusMonitorIfNeeded() }
                    Task { [weak self] in
                        try? await Task.sleep(for: .seconds(35))
                        self?.queue.async { [weak self] in
                            guard let self else { return }
                            let call = self.currentCopilotStatus()
                            let sameCall = call.callID == configuration.callID
                                && self.copilotGeneration == configuration.generation
                            if sameCall, call.running {
                                _ = self.awaitOnQueue { await self.codingController.markCapturing(); return true }
                            } else if !(sameCall && (call.starting || call.finishing)) {
                                Task {
                                    await self.codingController.interruptIfStillAwaitingCall(
                                        sessionID: configuration.sessionID, generation: configuration.generation)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func codingControl(_ data: Data, with reply: @escaping (Data) -> Void) {
        queue.async {
            guard data.count <= 256 * 1_024,
                  let command = try? self.jsonDecoder.decode(CodingCommand.self, from: data)
            else { reply(Data()); return }
            if command.kind == .resume { self.codingObserverSequence = -1 }
            Task { [weak self] in
                guard let self else { return }
                let snapshot = try? await self.codingController.send(command)
                let encoded = snapshot.flatMap { try? JSONEncoder.calla.encode($0) } ?? Data()
                self.queue.async { reply(encoded) }
            }
        }
    }

    func codingStatus(with reply: @escaping (Data) -> Void) {
        queue.async {
            let value = self.awaitOnQueue { await self.codingController.snapshot() } ?? .init()
            reply((try? JSONEncoder.calla.encode(value)) ?? Data())
        }
    }

    func codingEvents(since sequence: Int, with reply: @escaping (Data) -> Void) {
        queue.async {
            let value = self.awaitOnQueue { await self.codingController.replay(since: sequence) } ?? []
            reply((try? JSONEncoder.calla.encode(value)) ?? Data("[]".utf8))
        }
    }

    func codingSessions(with reply: @escaping (Data) -> Void) {
        queue.async {
            let value = self.awaitOnQueue { await self.codingController.retainedSessions() } ?? []
            reply((try? JSONEncoder.calla.encode(value)) ?? Data("[]".utf8))
        }
    }

    func subscribeStatus(_ observer: BoringCallaEngineStatusObserver, with reply: @escaping (Data) -> Void) {
        queue.async {
            self.statusObservers.add(observer)
            self.startStatusMonitorIfNeeded()
            reply(self.encodedStatus())
        }
    }

    func subscribeCallEvents(_ observer: BoringCallaEngineCallObserver, with reply: @escaping (Data) -> Void) {
        queue.async {
            self.callObservers.add(observer)
            reply(self.encodedStatus())
        }
    }

    func subscribeCodingEvents(_ observer: BoringCallaEngineCodingObserver, with reply: @escaping (Data) -> Void) {
        queue.async {
            self.codingObservers.add(observer)
            self.startStatusMonitorIfNeeded()
            reply((try? JSONEncoder.calla.encode(
                self.awaitOnQueue { await self.codingController.snapshot() } ?? .init())) ?? Data())
        }
    }

    private func startStatusMonitorIfNeeded() {
        guard statusMonitor == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(400), repeating: .milliseconds(400))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if !self.statusObservers.allObjects.isEmpty { _ = self.encodedStatus() }
            let codingSnapshot = self.awaitOnQueue { await self.codingController.snapshot() } ?? .init()
            let call = self.currentCopilotStatus()
            if codingSnapshot.lifecycle == .ready, call.running,
               codingSnapshot.callID == call.callID,
               codingSnapshot.generation == self.copilotGeneration {
                _ = self.awaitOnQueue { await self.codingController.markCapturing(); return true }
            } else if codingSnapshot.lifecycle == .capturing,
                      !call.running, !call.starting, !call.finishing {
                let interrupted = self.copilotStopRequestedGeneration != codingSnapshot.generation
                _ = self.awaitOnQueue { await self.codingController.finishAfterCall(interrupted: interrupted); return true }
            }
            guard !self.codingObservers.allObjects.isEmpty else { return }
            let updates = self.awaitOnQueue {
                await self.codingController.replay(since: self.codingObserverSequence)
            } ?? []
            for event in updates {
                guard let data = try? JSONEncoder.calla.encode(event) else { continue }
                self.codingObserverSequence = max(self.codingObserverSequence, event.sequence)
                for object in self.codingObservers.allObjects {
                    (object as? BoringCallaEngineCodingObserver)?.callaEngineCodingEvent(data)
                }
            }
        }
        timer.resume()
        statusMonitor = timer
    }

    func requestGatewayUpdate(with reply: @escaping (Data) -> Void) {
        queue.async {
            guard self.isInstalledBoringApp else {
                self.lastResult = "Debug Gateway updates stage from Xcode build"
                reply(self.encodedStatus())
                return
            }
            self.requestGatewayUpdate(trigger: "manual retry")
            reply(self.encodedStatus())
        }
    }

    // MARK: - Live call copilot

    /// The capture host's own directory, written by CallaCallHost and read here.
    private var copilotRoot: URL { root.appendingPathComponent("copilot", isDirectory: true) }
    private var copilotStatusURL: URL { copilotRoot.appendingPathComponent("active-call.json") }
    private var copilotControlSocketURL: URL { copilotRoot.appendingPathComponent("call-host.sock") }
    private var copilotEventSocketURL: URL { copilotRoot.appendingPathComponent("call-events.sock") }
    private var copilotSuggestionURL: URL { copilotRoot.appendingPathComponent("latest-suggestion.json") }
    private var copilotPermissionsURL: URL { copilotRoot.appendingPathComponent("permissions.json") }
    private var copilotModelDownloadURL: URL { copilotRoot.appendingPathComponent("model-download.json") }
    private var copilotCallsRoot: URL { copilotRoot.appendingPathComponent("calls", isDirectory: true) }
    private var copilotPIDURL: URL { root.appendingPathComponent("callhost.pid") }

    /// The gateway route the copilot streams to. Fixed, like `probeGateway`'s
    /// URL — a transcript must not be steerable to another host.
    private static let copilotGateway = "wss://nomonhomelab.tailec0dca.ts.net/call-copilot/stream"

    private var copilotExecutable: URL? {
        let embedded = Bundle.main.resourceURL?
            .appendingPathComponent("CallaRuntime/CallaCallHost.app/Contents/MacOS/CallaCallHost")
        if let embedded, fileManager.isExecutableFile(atPath: embedded.path) { return embedded }
        // Development fallback: the standalone bundle installed by
        // scripts/calla/build-callhost.sh, so the feature is testable before a
        // full app deployment.
        let standalone = URL(fileURLWithPath: "/Applications/CallaCallHost.app/Contents/MacOS/CallaCallHost")
        return fileManager.isExecutableFile(atPath: standalone.path) ? standalone : nil
    }

    func copilotControl(_ data: Data, with reply: @escaping (Data) -> Void) {
        queue.async {
            guard let command = try? JSONDecoder().decode(CopilotCommand.self, from: data),
                  let action = CallaCopilotCommandValidation.action(command.action) else {
                self.lastResult = "Rejected invalid copilot command"
                self.copilotResult = "Rejected invalid copilot command"
                reply(self.encodedStatus()); return
            }
            switch action {
            case "start": self.startCopilot(command)
            case "stop": self.stopCopilot()
            case "answer": self.answerSelectedText(command.question)
            case "screenshot": self.captureScreenshot()
            case "archive": self.retranscribeCall(command)
            case "fetch_model": self.fetchModel(command)
            case "set_provider":
                guard let provider = CallaCopilotCommandValidation.provider(command.provider) else {
                    self.copilotResult = "Rejected unknown intelligence provider"; break
                }
                self.copilotProvider = provider
                if let tier = CallaCopilotCommandValidation.tier(command.tier) { self.copilotTier = tier }
                if let summary = CallaCopilotCommandValidation.summaryModel(command.summaryModel) {
                    self.copilotSummaryModel = summary
                }
                if let fallback = command.fallback { self.copilotFallback = fallback }
                if let standby = CallaCopilotCommandValidation.gatewayStandby(command.gatewayStandby),
                   let mode = GatewayStandby.named(standby) {
                    self.copilotGatewayStandby = mode
                }
                // Like persona: the host binds its provider at launch, so a
                // change mid-call would be a lie. Automatic fallback is the only
                // thing that switches brains during a call.
                self.copilotResult = self.copilotIsRunning
                    ? "Intelligence set to \(provider); applies to the next call"
                    : "Intelligence set to \(provider)"
            case "set_persona":
                guard let persona = CallaCopilotCommandValidation.persona(command.persona) else {
                    self.copilotResult = "Rejected unknown persona"; break
                }
                self.copilotPersona = persona
                // Persona is fixed for the life of a call; the gateway binds it
                // at call_start. Changing it takes effect on the next call.
                self.copilotResult = self.copilotIsRunning
                    ? "Persona set to \(persona); applies to the next call"
                    : "Persona set to \(persona)"
            case "login":
                self.loginAgy(force: command.fallback == true)
            case "test_login":
                self.testLoginFlow()
            case "sign_out":
                self.signOutAgy()
            case "restore_login":
                self.restoreAgyCredentials()
            default: break
            }
            reply(self.encodedStatus())
        }
    }

    private func startCopilot(_ command: CopilotCommand) {
        let quiz = awaitOnQueue { await self.quizController.snapshot() }
        guard quiz?.active != true else {
            copilotResult = "End Quiz before starting Call"
            return
        }
        if copilotIsRunning {
            copilotResult = "Call already running"
            return
        }
        adoptedCopilotPID = nil
        adoptedCopilotCallID = nil
        copilotStopRequestedGeneration = nil
        guard let executable = copilotExecutable else {
            copilotResult = "Call host is not installed"; return
        }
        if let persona = CallaCopilotCommandValidation.persona(command.persona) { copilotPersona = persona }
        if let model = CallaCopilotCommandValidation.liveModel(command.model) { copilotModel = model }
        if let provider = CallaCopilotCommandValidation.provider(command.provider) { copilotProvider = provider }
        if let tier = CallaCopilotCommandValidation.tier(command.tier) { copilotTier = tier }
        if let summary = CallaCopilotCommandValidation.summaryModel(command.summaryModel) { copilotSummaryModel = summary }
        if let fallback = command.fallback { copilotFallback = fallback }
        if let standby = CallaCopilotCommandValidation.gatewayStandby(command.gatewayStandby),
           let mode = GatewayStandby.named(standby) {
            copilotGatewayStandby = mode
        }
        guard let gateway = CallaCopilotCommandValidation.gatewayURL(Self.copilotGateway) else {
            copilotResult = "Copilot gateway route is not valid"; return
        }

        // Screen Recording is what captures the other party. Without it the
        // call still runs, but only our own side is transcribed — which makes
        // the suggestions close to useless, so say so rather than fail quietly.
        //
        // Asked of the *host's* own report, not of this process: this used to
        // call `CGPreflightScreenCaptureAccess()` here, which answers for the
        // engine's signature and so could say "granted" while the host that
        // does the recording had nothing. Same bug already fixed for the Tutor
        // host.
        // Only warn on a definite no. Unknown resolves itself a moment later
        // when the host writes its own status, and `serve` reports both grants
        // as it starts anyway.
        if hostPermissions()?.screenGranted == false {
            copilotResult = "Grant Screen Recording to capture the other party"
        }

        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = executable.deletingLastPathComponent()
        copilotGeneration &+= 1
        let generation = copilotGeneration
        copilotEventSequence = -1
        copilotEventQuestion = nil
        copilotEventAnswer = nil
        var arguments = [
            "serve",
            "--gateway", gateway.absoluteString,
            "--persona", copilotPersona,
            "--model", copilotModel,
            "--provider", copilotProvider,
            "--tier", copilotTier,
            "--generation", String(generation),
        ]
        if let requestedCallID = CallaCopilotCommandValidation.callID(command.callID) {
            arguments += ["--call-id", requestedCallID]
        }
        // Every value here came back from an allowlist above, so nothing the UI
        // sent can widen this command line.
        if let summaryModel = CallaCopilotCommandValidation.summaryModel(copilotSummaryModel) {
            arguments += ["--summary-model", summaryModel]
        }
        if !copilotFallback { arguments.append("--no-fallback") }
        // Validated to a known mode before it reaches argv, like every other
        // value here — nothing the UI sends can widen this command line.
        arguments += ["--gateway-standby", copilotGatewayStandby.argument]
        process.arguments = arguments
        // The user's prompt text goes in over stdin rather than as arguments.
        // It is the only free-text field this service accepts, and an argument
        // list is exactly where free text stops being only a prompt.
        let meeting = command.meeting.flatMap { incoming in
            CallaCopilotCommandValidation.meeting(
                eventID: incoming.eventID, seriesID: incoming.seriesID, title: incoming.title,
                startsAt: incoming.startsAt, endsAt: incoming.endsAt, location: incoming.location,
                attendees: incoming.attendees, notes: incoming.notes)
        }
        if command.meeting != nil, meeting == nil {
            copilotResult = "The meeting details were rejected; the call was not started"
            return
        }
        // Composed here rather than sent by the app. The app cannot open the
        // store — it is sandboxed and the file is not in its container — so the
        // only process that sees both the meeting the app names and the notes the
        // user wrote is this one.
        let selectedKnowledgeNoteIDs = CallaCopilotCommandValidation.knowledgeNoteIDs(command.selectedKnowledgeNoteIDs)
        if command.selectedKnowledgeNoteIDs != nil, selectedKnowledgeNoteIDs == nil {
            copilotResult = "Call pack selection was rejected"
            return
        }
        // Call-pack content is copied into an immutable snapshot by CallHost and
        // retrieved passage-by-passage. Never bootstrap a model conversation
        // with whole notes or document bodies. Meeting metadata remains in its
        // typed field; selected ids remain scope, not prompt text.
        if selectedKnowledgeNoteIDs != nil, store == nil {
            copilotResult = "Call pack store is unavailable"
            return
        }

        // A ceremony starts knowing where the last few of its kind left off —
        // a short, bounded digest. Everything older is reached by retrieval.
        let previousMeetings = CallaPersonaCatalog.isCeremony(copilotPersona)
            ? previousMeetingsDigest(persona: copilotPersona) : nil
        if let profile = CallaCopilotCommandValidation.profile(
            about: command.profile?.about,
            personaGuidance: command.profile?.personaGuidance,
            baseGuidance: command.profile?.baseGuidance,
            knowledge: previousMeetings,
            meeting: meeting,
            selectedKnowledgeNoteIDs: selectedKnowledgeNoteIDs),
           let payload = try? JSONEncoder().encode(profile) {
            let pipe = Pipe()
            process.standardInput = pipe
            copilotProfilePipe = pipe
            copilotPendingProfile = payload
        } else if command.profile != nil || meeting != nil || previousMeetings != nil {
            // A profile that fails validation must not silently become "no
            // profile" — the call would run with different guidance than the
            // settings pane shows.
            copilotResult = "Prompt settings were rejected; fix them in Settings › Prompts"
            return
        }
        var environment = ProcessInfo.processInfo.environment
        environment["AGY_CLI_DISABLE_AUTO_UPDATE"] = "1"
        environment["CALLA_RUNTIME_ROOT"] = root.path
        process.environment = environment
        let pidFile = copilotPIDURL
        process.terminationHandler = { [weak self] child in
            self?.queue.async {
                guard self?.copilotGeneration == generation else { return }
                self?.copilotEventClient?.stop()
                self?.copilotEventClient = nil
                // The host has finished its recap and closed the call; file it.
                if let self, let finished = self.currentOwnedCopilotCallID() ?? self.lastSeenCallID {
                    self.scheduleCallFolderExport(finished, after: 1)
                }
                if let self, let callID = self.currentOwnedCopilotCallID(),
                   CallaCallTerminationPolicy.shouldForceInterrupted(
                    exitingGeneration: generation,
                    explicitlyEndedGeneration: self.copilotStopRequestedGeneration) {
                    self.forceCallInterrupted(callID)
                }
                self?.clearOwnedPID(at: pidFile, matching: child.processIdentifier)
                self?.copilotProcess = nil
                self?.adoptedCopilotCallID = nil
                self?.copilotStopRequestedGeneration = nil
                if child.terminationStatus != 0 {
                    self?.copilotResult = "Call host stopped (status \(child.terminationStatus))"
                }
                // The host removes its own status file on a clean exit; clear it
                // here too so a crash cannot leave the notch showing a live call.
                try? FileManager.default.removeItem(at: self?.copilotStatusURL ?? pidFile)
            }
        }
        do {
            try fileManager.createDirectory(at: copilotRoot, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            try process.run()
            copilotProcess = process
            let eventClient = CallEventSocketClient()
            copilotEventClient = eventClient
            eventClient.start(path: copilotEventSocketURL) { [weak self] event in
                guard let engine = self else { return }
                engine.queue.async { engine.acceptCallEvent(event) }
            }
            try? writeOwnedPID(process.processIdentifier, to: copilotPIDURL)
            // Written after the child exists, and closed straight away so the
            // host sees EOF and starts rather than blocking on a read.
            if let payload = copilotPendingProfile, let pipe = copilotProfilePipe {
                pipe.fileHandleForWriting.write(payload)
                pipe.fileHandleForWriting.write(Data("\n".utf8))
                try? pipe.fileHandleForWriting.close()
            }
            copilotPendingProfile = nil
            copilotProfilePipe = nil
            if copilotResult == nil {
                copilotResult = "Call started"
            }
        } catch {
            copilotPendingProfile = nil
            copilotProfilePipe = nil
            copilotResult = "Could not start call host: \(error.localizedDescription)"
        }
    }

    /// Copies calls recorded before the store existed into it, once.
    ///
    /// Detached rather than on the engine queue: it walks every call directory and
    /// parses every transcript this Mac has ever recorded, and the engine queue
    /// also serves the status poll the notch is waiting on. Nothing depends on it
    /// having finished — every reader falls back to the files until it has.
    private func importArchivesOnce(preservingLiveCallID: String?) {
        guard let store else { return }
        let directory = copilotCallsRoot
        Task.detached(priority: .utility) {
            let imported = await store.importArchives(from: directory)
            let reconciled = (try? await store.reconcileCallHistory(
                from: directory, preservingLiveCallID: preservingLiveCallID)) ?? 0
            if imported > 0 {
                NSLog("[CallaEngine] imported %d archived call(s) into the store", imported)
            }
            if reconciled > 0 {
                NSLog("[CallaEngine] reconciled %d call history row(s)", reconciled)
            }
            // Loads the embedding backend and vectors anything that has none.
            //
            // The host does this too, but only when a call starts — which left a
            // note written in Settings lexically searchable and nothing more until
            // the next meeting. Ordered after the import on purpose, so the pass
            // that follows covers the calls that just arrived as well.
            await store.prepare()
        }
    }

    // MARK: - Knowledge

    /// The app's only way to touch the knowledge base.
    ///
    /// Replies with the resulting note list in every case, including deletes, so
    /// the Settings pane never has to guess what the store now holds — the app
    /// cannot read the file to check.
    func knowledgeControl(_ data: Data, with reply: @escaping (Data) -> Void) {
        queue.async {
            guard let command = try? JSONDecoder().decode(KnowledgeCommand.self, from: data),
                  let store = self.store else {
                reply(Data("[]".utf8)); return
            }

            switch command.action {
            case "upsert":
                // Bounded and control-character-checked on exactly the same rules
                // as the rest of the prompt payload. This text goes straight into
                // a model prompt, so it is no more trusted for having been typed
                // in Settings than for having arrived in a calendar invite.
                //
                // A document gets a far larger ceiling than a typed note, because
                // it is never packed into a prompt whole — it is chunked and
                // searched, and the thing being bounded is how much of a file the
                // store will hold rather than how much of it a model will read.
                let isDocument = command.source == "document"
                let bodyLimit = isDocument
                    ? CallaCopilotCommandValidation.documentLimit
                    : CallaCopilotCommandValidation.knowledgeLimit
                guard case .accepted(let title) = CallaCopilotCommandValidation.promptText(
                        command.title, limit: CallaCopilotCommandValidation.meetingTitleLimit),
                      case .accepted(let body) = CallaCopilotCommandValidation.promptText(
                        command.body, limit: bodyLimit),
                      case .accepted(let originName) = CallaCopilotCommandValidation.promptText(
                        command.originName, limit: CallaCopilotCommandValidation.meetingTitleLimit),
                      let scope = self.scope(command.scope, key: command.scopeKey),
                      title != nil || body != nil
                else { break }
                var note = KnowledgeNote(
                    title: title ?? "", body: body ?? "",
                    source: isDocument ? .document : .manual,
                    scope: scope,
                    originName: originName,
                    originKind: CallaCopilotCommandValidation.documentKind(command.originKind),
                    byteSize: max(0, command.byteSize ?? 0),
                    pageCount: max(0, command.pageCount ?? 0))
                if let id = command.id, !id.isEmpty { note.id = id }
                _ = self.awaitOnQueue { try? await store.upsert(note) }
            case "delete":
                guard let id = command.id, !id.isEmpty else { break }
                _ = self.awaitOnQueue { try? await store.deleteNote(id: id) }
            default:
                break
            }

            let notes = self.awaitOnQueue { () -> [KnowledgeNote] in
                // A listing for one event carries everything that would actually
                // reach a call there — the always-on notes and the persona's
                // included — because "what will the copilot know in this meeting"
                // is the only question the pane is really asking.
                if command.eventID != nil || command.seriesID != nil {
                    let context = MeetingContext(eventID: command.eventID, seriesID: command.seriesID)
                    return (try? await store.notes(for: context, persona: self.copilotPersona)) ?? []
                }
                return (try? await store.notes()) ?? []
            } ?? []
            reply((try? JSONEncoder.calla.encode(notes)) ?? Data("[]".utf8))
        }
    }

    func copilotCallsForEvent(_ data: Data, with reply: @escaping (Data) -> Void) {
        queue.async {
            guard let query = try? JSONDecoder().decode(KnowledgeCommand.self, from: data),
                  let store = self.store else {
                reply(Data("[]".utf8)); return
            }
            let calls = self.awaitOnQueue { () -> [CallRecord] in
                // No event named means "every call that knows which meeting it
                // was", which is what the Knowledge pane asks for to put a name
                // on each group. Filtering to a single meeting is the other case.
                if query.eventID == nil, query.seriesID == nil {
                    return (try? await store.calls(limit: 500)) ?? []
                }
                return (try? await store.calls(forEvent: query.eventID, seriesID: query.seriesID)) ?? []
            } ?? []
            reply((try? JSONEncoder.calla.encode(calls)) ?? Data("[]".utf8))
        }
    }

    private func scope(_ kind: String?, key: String?) -> KnowledgeScope? {
        switch kind {
        case "always", nil: .always
        case "event": CallaCopilotCommandValidation.eventIdentifier(key).map(KnowledgeScope.event)
        case "series": CallaCopilotCommandValidation.eventIdentifier(key).map(KnowledgeScope.series)
        case "persona": CallaCopilotCommandValidation.persona(key).map(KnowledgeScope.persona)
        default: nil
        }
    }

    /// Every note that applies to this meeting, as one block for the prompt.
    ///
    /// Synchronous on the engine's own queue, which is a deliberate trade: the
    /// store is an actor and this is the one call that must finish before the host
    /// is spawned, because the prompt blocks are bound at bootstrap and a lane
    /// that opened without them stays without them for the whole call. It is a
    /// handful of indexed reads on a local file.
    ///
    /// Ordered general to specific, so the note about *this* meeting is the last
    /// thing read. Truncated to the validator's ceiling rather than refused: a
    /// knowledge base that grew past the limit should cost its oldest notes, not
    /// the call.
    private func composedKnowledge(
        for meeting: CallaCopilotCommandValidation.MeetingFields
    ) -> String? {
        guard let store else { return nil }
        let context = MeetingContext(
            eventID: meeting.eventID,
            seriesID: meeting.seriesID,
            title: meeting.title,
            startsAt: meeting.startsAt.map(Date.init(timeIntervalSince1970:)),
            endsAt: meeting.endsAt.map(Date.init(timeIntervalSince1970:)),
            location: meeting.location,
            attendees: meeting.attendees,
            notes: meeting.notes)

        // The packing policy lives with the data rather than here: which notes go
        // in whole and which only get a line naming themselves is a fact about
        // what a note *is*, and it is unit-tested next to the store.
        let limit = CallaCopilotCommandValidation.knowledgeLimit
        return awaitOnQueue {
            (try? await store.promptBlock(
                for: context, persona: self.copilotPersona, limit: limit)) ?? nil
        } ?? nil
    }

    /// Runs an async store call to completion from the engine's serial queue.
    ///
    /// The engine is callback-based `@objc` XPC code with no async context of its
    /// own, and the store is an actor. A semaphore is the honest bridge; it is
    /// never taken on the actor's executor, so it cannot deadlock against the very
    /// task it is waiting for.
    private func awaitOnQueue<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task.detached {
            box.value = await body()
            semaphore.signal()
        }
        // A store query is milliseconds. The timeout exists so a pathological
        // lock cannot wedge the engine's only queue and take the notch with it.
        guard semaphore.wait(timeout: .now() + 5) == .success else {
            NSLog("[CallaEngine] store call timed out")
            return nil
        }
        return box.value
    }

    /// Re-runs the archive model over a finished call's saved audio.
    private func retranscribeCall(_ command: CopilotCommand) {
        guard let callID = CallaCopilotCommandValidation.callID(command.callID) else {
            copilotResult = "Rejected invalid call id"; return
        }
        guard archiveProcess?.isRunning != true else {
            copilotResult = "A re-transcribe is already running"; return
        }
        guard let executable = copilotExecutable else {
            copilotResult = "Call host is not installed"; return
        }
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = executable.deletingLastPathComponent()
        process.arguments = ["retranscribe", "--call", callID]
        var environment = ProcessInfo.processInfo.environment
        environment["AGY_CLI_DISABLE_AUTO_UPDATE"] = "1"
        environment["CALLA_RUNTIME_ROOT"] = root.path
        process.environment = environment
        process.terminationHandler = { [weak self] child in
            self?.queue.async {
                self?.archiveProcess = nil
                self?.retranscribingCallID = nil
                self?.copilotResult = child.terminationStatus == 0
                    ? "Re-transcribed \(callID)"
                    : "Re-transcribe failed (status \(child.terminationStatus))"
            }
        }
        do {
            try process.run()
            archiveProcess = process
            retranscribingCallID = callID
            copilotResult = "Re-transcribing \(callID)…"
        } catch {
            copilotResult = "Could not re-transcribe: \(error.localizedDescription)"
        }
    }

    /// Downloads a transcription model ahead of a call.
    ///
    /// Same work the first call would do anyway, moved to a moment where a
    /// several-minute wait is not sitting between the user and a meeting.
    private func fetchModel(_ command: CopilotCommand) {
        guard let model = CallaCopilotCommandValidation.liveModel(command.model) else {
            copilotResult = "Rejected unknown model"; return
        }
        guard modelProcess?.isRunning != true else {
            copilotResult = "A model download is already running"; return
        }
        guard let executable = copilotExecutable else {
            copilotResult = "Call host is not installed"; return
        }
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = executable.deletingLastPathComponent()
        process.arguments = ["models", "--fetch", model]
        var environment = ProcessInfo.processInfo.environment
        environment["AGY_CLI_DISABLE_AUTO_UPDATE"] = "1"
        environment["CALLA_RUNTIME_ROOT"] = root.path
        process.environment = environment
        process.terminationHandler = { [weak self] child in
            self?.queue.async {
                self?.modelProcess = nil
                if child.terminationStatus != 0 {
                    self?.copilotResult = "Model download failed (status \(child.terminationStatus))"
                }
            }
        }
        do {
            try process.run()
            modelProcess = process
            copilotResult = "Downloading \(model)…"
        } catch {
            copilotResult = "Could not download model: \(error.localizedDescription)"
        }
    }

    /// Runs the host's own permission request, so the prompts are attributed to
    /// the signature that captures.
    func requestCopilotPermissions(with reply: @escaping (Data) -> Void) {
        queue.async {
            guard let executable = self.copilotExecutable else {
                self.copilotResult = "Call host is not installed"
                reply(self.encodedStatus()); return
            }
            guard self.permissionProcess?.isRunning != true else {
                reply(self.encodedStatus()); return
            }
            let process = Process()
            process.executableURL = executable
            process.currentDirectoryURL = executable.deletingLastPathComponent()
            process.arguments = ["permissions"]
            var environment = ProcessInfo.processInfo.environment
            environment["AGY_CLI_DISABLE_AUTO_UPDATE"] = "1"
            environment["CALLA_RUNTIME_ROOT"] = self.root.path
            process.environment = environment
            process.terminationHandler = { [weak self] _ in
                self?.queue.async { self?.permissionProcess = nil }
            }
            do {
                try process.run()
                self.permissionProcess = process
                self.copilotResult = "Requesting microphone and screen recording…"
            } catch {
                self.copilotResult = "Could not request permissions: \(error.localizedDescription)"
            }
            reply(self.encodedStatus())
        }
    }

    /// What the host last reported about its own grants.
    ///
    /// Absent means *unknown*, not denied — after a fresh install nothing has
    /// written the file yet, and reporting "not granted" against a host that
    /// holds both is the same wrong answer this whole path was fixing. A
    /// prompt-free `permissions --check` fills it in once per engine lifetime.
    private func hostPermissions() -> (micGranted: Bool, screenGranted: Bool)? {
        guard let data = try? Data(contentsOf: copilotPermissionsURL),
              let file = try? jsonDecoder.decode(CopilotPermissionsFile.self, from: data) else {
            refreshHostPermissionsOnce()
            return nil
        }
        return (file.micGranted, file.screenGranted)
    }

    /// Asks the host to report its grants without prompting for them.
    ///
    /// `--check` never raises a dialog, so this is safe to fire on a status
    /// poll; the answer lands on the next one.
    private func refreshHostPermissionsOnce() {
        guard !hostPermissionCheckStarted, permissionProcess?.isRunning != true,
              let executable = copilotExecutable else { return }
        hostPermissionCheckStarted = true

        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = executable.deletingLastPathComponent()
        process.arguments = ["permissions", "--check"]
        var environment = ProcessInfo.processInfo.environment
        environment["AGY_CLI_DISABLE_AUTO_UPDATE"] = "1"
        environment["CALLA_RUNTIME_ROOT"] = root.path
        process.environment = environment
        process.terminationHandler = { [weak self] _ in
            self?.queue.async { self?.permissionProcess = nil }
        }
        if (try? process.run()) != nil { permissionProcess = process }
    }

    private func stopCopilot() {
        guard copilotIsRunning else {
            copilotResult = "No call running"
            try? fileManager.removeItem(at: copilotStatusURL)
            return
        }
        copilotStopRequestedGeneration = copilotGeneration
        if let callID = currentCopilotStatus().callID,
           let event = requestHostControl(.stop, callID: callID),
           event.kind == .finished {
            copilotResult = "Ending call…"
            return
        }
        // SIGINT rather than terminate(): the host flushes its endpointers,
        // drains the transcription queue and closes the WAVs on it, so a
        // trailing sentence is not lost.
        if let process = copilotProcess, process.isRunning {
            kill(process.processIdentifier, SIGINT)
        } else if let adoptedCopilotPID, isOwnedCopilotProcess(adoptedCopilotPID) {
            kill(adoptedCopilotPID, SIGINT)
        }
        copilotResult = "Ending call…"
    }

    private func answerSelectedText(_ text: String?) {
        guard let callID = currentCopilotStatus().callID else {
            copilotResult = "No call running"
            return
        }
        guard case .accepted(let prompt?) = CallaCopilotCommandValidation.promptText(
            text, limit: CallaCopilotCommandValidation.manualQuestionLimit
        ) else {
            copilotResult = "Select up to \(CallaCopilotCommandValidation.manualQuestionLimit) characters"
            return
        }
        guard let event = requestHostControl(.answer, callID: callID, text: prompt),
              event.kind == .answer else {
            copilotResult = "Copilot unavailable; try again"
            return
        }
        copilotResult = "Answering selected text…"
    }

    /// Asks the host for a screenshot. Off the engine queue: capturing and
    /// reading a large display can take a few seconds, and the status poll
    /// must not stall behind it.
    private func captureScreenshot() {
        guard let callID = currentCopilotStatus().callID else {
            copilotResult = "No call running"
            return
        }
        let generation = copilotGeneration
        copilotResult = "Taking a screenshot…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let event = self.requestHostControl(.capture, callID: callID, generation: generation, timeout: 20)
            self.queue.async {
                guard self.copilotGeneration == generation else { return }
                if let error = event?.snapshot.actionableError {
                    self.copilotResult = error
                } else {
                    self.copilotResult = event?.kind == .screenshot
                        ? "Screenshot added to the call" : "Screenshot unavailable; try again"
                }
            }
        }
    }

    /// One bounded JSON request/reply over the host's mode-0600 Unix socket.
    /// No transcript, prompt, coordinates, or raw provider output crosses it.
    private func requestHostControl(
        _ kind: CallHostCommandKind, callID: String, text: String? = nil, questionID: UUID? = nil, codingEvidence: CodingDialogueEvidence? = nil,
        generation explicitGeneration: Int? = nil, timeout seconds: Int = 3
    ) -> CallHostEvent? {
        guard fileManager.fileExists(atPath: copilotControlSocketURL.path) else { return nil }
        let generation = explicitGeneration ?? copilotGeneration
        var command = CallHostCommand(callID: callID, generation: generation, kind: kind, text: text, questionID: questionID)
        command.codingEvidence = codingEvidence
        guard let payload = try? JSONEncoder().encode(command) else { return nil }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let maximumPathLength = MemoryLayout.size(ofValue: address.sun_path) - 1
        copilotControlSocketURL.path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { destination in
                let destination = UnsafeMutableRawPointer(destination).assumingMemoryBound(to: CChar.self)
                strncpy(destination, source, maximumPathLength)
            }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }
        let sent = payload.withUnsafeBytes { send(descriptor, $0.baseAddress, payload.count, 0) }
        guard sent == payload.count else { return nil }
        _ = shutdown(descriptor, SHUT_WR)
        var reply = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while reply.count < 64 * 1024 {
            let count = recv(descriptor, &buffer, buffer.count, 0)
            if count > 0 { reply.append(buffer, count: Int(count)); continue }
            if count == 0 { break }
            if errno == EINTR { continue }
            return nil
        }
        guard let event = try? JSONDecoder().decode(CallHostEvent.self, from: reply),
              event.callID == callID, event.generation == generation,
              event.contractVersion == CallaContract.version else { return nil }
        return event
    }

    func copilotTranscript(since seq: Int, with reply: @escaping (Data) -> Void) {
        queue.async {
            reply(self.currentCopilotTranscript(since: seq))
        }
    }

    /// What the copilot returned during a finished call.
    ///
    /// The suggestions were already archived line by line; nothing could read them
    /// back, so a call's advice died with the call.
    func copilotCallSuggestions(_ callID: String, with reply: @escaping (Data) -> Void) {
        queue.async {
            guard let callID = CallaCopilotCommandValidation.callID(callID) else {
                reply(Data("[]".utf8)); return
            }
            // The store is the record now. The JSONL file is still written and is
            // still the fallback: a call recorded before the import ran, or one
            // whose store write failed, must not read as a call with no advice.
            if let store = self.store {
                let stored = self.awaitOnQueue {
                    (try? await store.suggestions(forCall: callID)) ?? []
                } ?? []
                if !stored.isEmpty {
                    let mapped = stored.map { entry in
                        CopilotSuggestionFile(
                            callID: callID, afterSeq: entry.afterSeq, headline: entry.headline,
                            angles: entry.angles, confirm: entry.confirm,
                            question: entry.question,
                            latencyMs: entry.latencyMs,
                            summary: entry.summary, openQuestions: entry.openQuestions)
                    }
                    reply((try? JSONEncoder().encode(mapped)) ?? Data("[]".utf8))
                    return
                }
            }
            let url = self.copilotCallsRoot
                .appendingPathComponent(callID, isDirectory: true)
                .appendingPathComponent("suggestions.jsonl")
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                reply(Data("[]".utf8)); return
            }
            let suggestions = text
                .split(separator: "\n", omittingEmptySubsequences: true)
                .compactMap { line -> CopilotSuggestionFile? in
                    guard let data = line.data(using: .utf8) else { return nil }
                    return try? self.jsonDecoder.decode(CopilotSuggestionFile.self, from: data)
                }
            reply((try? JSONEncoder().encode(suggestions)) ?? Data("[]".utf8))
        }
    }

    func copilotRecapDraft(_ callID: String, with reply: @escaping (Data) -> Void) {
        queue.async {
            guard let callID = CallaCopilotCommandValidation.callID(callID),
                  let store = self.store,
                  let draft = try? store.recapDraft(forCall: callID) else {
                reply(Data()); return
            }
            reply((try? JSONEncoder().encode(draft)) ?? Data())
        }
    }

    func copilotPrompts(with reply: @escaping (Data) -> Void) {
        queue.async {
            reply((try? JSONEncoder().encode(self.effectivePrompts())) ?? Data())
        }
    }

    /// The prompt files as they stand, exporting the defaults first if the user
    /// has never taken a copy.
    ///
    /// Reading files rather than asking the host over a pipe: the export is
    /// idempotent and never overwrites, so this costs one directory walk and
    /// cannot block the reply on a process that might not start. An empty result
    /// simply leaves the pane showing its own placeholders, which is what it did
    /// before this existed.
    private func effectivePrompts() -> [String: String] {
        let directory = root.appendingPathComponent("copilot/prompts", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            exportPromptDefaults()
        }
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil) else { return [:] }

        var prompts: [String: String] = [:]
        let base = directory.standardizedFileURL.path
        for case let url as URL in enumerator where url.pathExtension == "md" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base) else { continue }
            let relative = String(path.dropFirst(base.count)).trimmingCharacters(
                in: CharacterSet(charactersIn: "/"))
            prompts[relative] = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return prompts
    }

    /// Runs the host's own `prompts export`, which is the only thing that knows
    /// the bundled wording.
    private func exportPromptDefaults() {
        guard let executable = copilotExecutable else { return }
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = executable.deletingLastPathComponent()
        process.arguments = ["prompts", "export"]
        var environment = ProcessInfo.processInfo.environment
        environment["AGY_CLI_DISABLE_AUTO_UPDATE"] = "1"
        environment["CALLA_RUNTIME_ROOT"] = root.path
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // Not worth surfacing: the pane falls back to its own placeholders,
            // which is exactly what it did before this method existed.
            copilotResult = "Could not export prompts: \(error.localizedDescription)"
        }
    }

    func copilotRecapControl(_ payload: Data, with reply: @escaping (Data) -> Void) {
        queue.async {
            guard let command = try? JSONDecoder().decode(CopilotRecapCommand.self, from: payload),
                  ["approve", "reject", "delete"].contains(command.action),
                  let callID = CallaCopilotCommandValidation.callID(command.callID),
                  let store = self.store else {
                reply(Data()); return
            }
            switch command.action {
            case "approve":
                let record = try? store.call(id: callID)
                let meeting = record.map { row in
                    // A recap is filed at the narrowest scope its meeting has,
                    // and series beats event. Dropping the series on a rehearsal
                    // is what keeps a practice conclusion — reached against a
                    // scratch copy, or against an interviewer who was not there
                    // — from being retrieved during the interview itself. The
                    // rehearsal's own occurrence still gets it, so approving is
                    // not silently a no-op.
                    let rehearsal = row.eventID == CallaWaveIdentity.rehearsalEventID
                    return MeetingContext(eventID: row.eventID,
                                          seriesID: rehearsal ? nil : row.seriesID,
                                          title: row.eventTitle, startsAt: row.eventStart)
                }
                _ = self.awaitOnQueue { try? await store.approve(recapDraftFor: callID, meeting: meeting) }
            case "reject":
                try? store.reject(recapDraftFor: callID)
            case "delete":
                try? store.delete(recapDraftFor: callID)
            default: break
            }
            let draft = try? store.recapDraft(forCall: callID)
            reply((try? JSONEncoder().encode(draft)) ?? Data())
        }
    }

    func copilotSpeakerControl(_ payload: Data, with reply: @escaping (Data) -> Void) {
        queue.async {
            guard let command = try? JSONDecoder().decode(CopilotSpeakerCommand.self, from: payload),
                  let store = self.store else {
                reply(Data()); return
            }
            let callID = command.callID.flatMap(CallaCopilotCommandValidation.callID)
            let remember = command.remember ?? true
            _ = self.awaitOnQueue { () async -> Bool in
                switch command.action {
                case "name":
                    guard let callID, let speakerID = command.speakerID else { return false }
                    let named = try? await store.nameSpeaker(callID: callID, speakerID: speakerID,
                                                             name: command.name ?? "")
                    if remember, let named, named.speakerID != CallSpeaker.localID {
                        _ = try? await store.enroll(speaker: named)
                    }
                case "confirm":
                    // An auto-guessed name, accepted as is. Promotes it to a user
                    // name, which is what makes it safe to learn the voice from.
                    guard let callID, let speakerID = command.speakerID,
                          let speaker = try? await store.speakers(forCall: callID)
                            .first(where: { $0.speakerID == speakerID }),
                          let label = speaker.label else { return false }
                    let named = try? await store.nameSpeaker(callID: callID, speakerID: speakerID, name: label)
                    if remember, let named { _ = try? await store.enroll(speaker: named) }
                case "merge":
                    guard let callID, let speakerID = command.speakerID, let into = command.into else { return false }
                    try? await store.mergeSpeaker(callID: callID, from: speakerID, into: into)
                case "forget_voice":
                    guard let personID = command.personID else { return false }
                    try? await store.deleteVoiceprint(personID: personID)
                case "forget_voices":
                    try? await store.deleteAllVoiceprints()
                default:
                    break
                }
                return true
            }
            let out = self.awaitOnQueue { () async -> CopilotSpeakersOut in
                var speakers: [CallSpeaker] = []
                var attendees: [String] = []
                if let callID {
                    speakers = (try? await store.speakers(forCall: callID)) ?? []
                    attendees = (try? await store.attendees(forCall: callID)) ?? []
                }
                let voices = (try? await store.voiceprints()) ?? []
                return CopilotSpeakersOut(
                    speakers: speakers.map {
                        .init(id: $0.speakerID, name: $0.displayName, nameSource: $0.nameSource.rawValue,
                              confidence: $0.confidence, speechSeconds: $0.speechSeconds)
                    },
                    attendees: attendees,
                    voices: voices.map { .init(personID: $0.personID, name: $0.displayName, updatedAt: $0.updatedAt) })
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            reply((out.flatMap { try? encoder.encode($0) }) ?? Data())
        }
    }

    func copilotCalls(with reply: @escaping (Data) -> Void) {
        queue.async {
            reply(self.archivedCalls())
        }
    }

    func copilotCallTranscript(_ callID: String, with reply: @escaping (Data) -> Void) {
        queue.async {
            guard let validID = CallaCopilotCommandValidation.callID(callID) else {
                reply(Data("[]".utf8)); return
            }
            reply(self.transcriptData(forCall: validID, since: -1, limit: 5000))
        }
    }

    /// Reads the live call's `transcript.jsonl`, newest turns last.
    ///
    /// Bounded on purpose: an hour-long call is thousands of turns, and the
    /// panel only ever shows the tail. Reading the whole file into an XPC reply
    /// would stall the engine queue that also serves the status poll.
    ///
    /// `since` is what makes a sub-second poll affordable: past the first read
    /// the reply is almost always empty, because turns arrive at the pace of
    /// human speech and not at the pace of the poll.
    private func currentCopilotTranscript(since seq: Int, limit: Int = 400) -> Data {
        guard let callID = (try? Data(contentsOf: copilotStatusURL))
            .flatMap({ try? jsonDecoder.decode(CopilotHostStatus.self, from: $0) })?.callID,
            let validID = CallaCopilotCommandValidation.callID(callID) else {
            return Data("[]".utf8)
        }
        // The live pass, deliberately: this is the transcript the copilot is
        // reasoning over right now.
        return transcriptData(forCall: validID, since: seq, limit: limit, revision: 0)
    }

    /// `revision`: nil takes the best transcript available — the archive pass
    /// when it has run. The live panel passes `0` explicitly, because it is
    /// showing turns beside suggestions that were made from those exact words,
    /// and swapping in a better transcript mid-call would show advice next to
    /// text that never appeared on screen.
    private func transcriptData(
        forCall callID: String,
        since seq: Int,
        limit: Int,
        revision: Int? = nil
    ) -> Data {
        // Indexed on `(call_id, seq)`, so `since` is a range scan rather than a
        // whole-file read and filter. That matters here more than anywhere else:
        // the live panel polls this sub-second for the length of a call.
        if let store {
            let turns = awaitOnQueue {
                (try? await store.turns(forCall: callID, since: seq, revision: revision)) ?? []
            } ?? []
            if !turns.isEmpty {
                let names = turns.contains(where: { $0.speakerID != nil })
                    ? Dictionary(
                        (awaitOnQueue { (try? await store.speakers(forCall: callID)) ?? [] } ?? [])
                            .map { ($0.speakerID, $0.displayName) },
                        uniquingKeysWith: { first, _ in first })
                    : [:]
                let mapped = turns.suffix(limit).map { turn in
                    ArchivedTurnOut(
                        id: UUID(), seq: turn.seq, source: turn.source,
                        t0: turn.t0, t1: turn.t1, text: turn.text,
                        confidence: turn.confidence,
                        speaker: turn.speakerID,
                        speakerName: turn.speakerID.map { names[$0] ?? CallSpeaker.fallbackName(for: $0) })
                }
                return (try? JSONEncoder().encode(mapped)) ?? Data("[]".utf8)
            }
        }
        let file = copilotCallsRoot
            .appendingPathComponent(callID, isDirectory: true)
            .appendingPathComponent("transcript.jsonl")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return Data("[]".utf8) }
        var lines = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(limit)
            .map(String.init)
        if seq >= 0 {
            // Filtering on the decoded `seq` rather than on line position: the
            // file is appended to while this runs, and counting lines would
            // skip or repeat a turn depending on the timing.
            lines = lines.filter { line in
                guard let data = line.data(using: .utf8),
                      let turn = try? jsonDecoder.decode(ArchivedTurn.self, from: data) else { return false }
                return turn.seq > seq
            }
        }
        return Data(("[" + lines.joined(separator: ",") + "]").utf8)
    }

    /// Every call this Mac has recorded, newest first.
    ///
    /// The list, the times and the turn counts come from the store, which is one
    /// indexed query rather than parsing every transcript on disk — the old path
    /// read and decoded every line of every call to count them, which is why
    /// History took visibly longer the more you used it.
    ///
    /// Three fields still come from the filesystem, because only the filesystem
    /// knows them: whether the WAVs are still there, whether the large model has
    /// been over the call, and how many turns that pass produced.
    private func archivedCalls(limit: Int = 200) -> Data {
        guard let store else { return Data("[]".utf8) }
        let records = awaitOnQueue { (try? await store.calls(limit: limit)) ?? [] } ?? []
        let summaries = records.map { record -> CallSummaryFile in
            let facts = archiveFacts(forCall: record.id)
            return CallSummaryFile(
                id: record.id,
                startedAt: record.startedAt,
                endedAt: record.endedAt,
                endReason: record.endReason?.rawValue,
                turnCount: record.turnCount,
                persona: record.persona,
                hasAudio: facts.hasAudio,
                retranscribed: facts.archivedTurnCount > 0,
                archivedTurnCount: facts.archivedTurnCount,
                suggestionCount: facts.suggestionCount,
                eventID: record.eventID,
                seriesID: record.seriesID)
        }
        return (try? JSONEncoder().encode(summaries)) ?? Data("[]".utf8)
    }

    /// What only the call's directory can answer.
    ///
    /// Counted by scanning for newlines rather than decoding: these are line
    /// counts, and decoding every suggestion of every call to arrive at one
    /// integer is what made the old listing slow.
    private func archiveFacts(forCall callID: String) -> (hasAudio: Bool, archivedTurnCount: Int, suggestionCount: Int) {
        let directory = copilotCallsRoot.appendingPathComponent(callID, isDirectory: true)
        let contents = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        let hasAudio = contents.contains { $0.hasSuffix(".wav") }
        let archived = lineCount(directory.appendingPathComponent("transcript-archive.jsonl"))
        let suggestions = lineCount(directory.appendingPathComponent("suggestions.jsonl"))
        return (hasAudio, archived, suggestions)
    }

    private func lineCount(_ url: URL) -> Int {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: true).count
    }

    private func acceptCallEvent(_ incoming: CallEvent) {
        guard incoming.contractVersion == CallaContract.version,
              incoming.generation == copilotGeneration,
              incoming.sequence > copilotEventSequence else { return }
        if let current = adoptedCopilotCallID, current != incoming.callID { return }
        adoptedCopilotCallID = incoming.callID
        lastSeenCallID = incoming.callID
        copilotEventSequence = incoming.sequence
        if incoming.lifecycle?.state == .finished { scheduleCallFolderExport(incoming.callID, after: 1) }
        var accepted = incoming
        if let lifecycle = incoming.lifecycle {
            _ = awaitOnQueue { await self.codingController.reconcileCall(lifecycle); return true }
        }
        if let question = incoming.question { copilotEventQuestion = question }
        if var answer = incoming.answer {
            answer.timing.enginePublishedAt = Date()
            copilotEventAnswer = answer
            accepted.answer = answer
        }
        if incoming.kind == .failure, let message = incoming.message {
            copilotResult = message
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(accepted) {
            for object in callObservers.allObjects {
                (object as? BoringCallaEngineCallObserver)?.callaEngineCallEvent(data)
            }
        }
        // Same queue, immediately after event forwarding. Existing UI consumes
        // one status shape; this push replaces live polling without splitting
        // rendering logic. Recovery polls remain enabled at low frequency.
        _ = encodedStatus()
    }

    private func currentCopilotStatus() -> CopilotStatus {
        if let adoptedCopilotPID, !isOwnedCopilotProcess(adoptedCopilotPID) {
            if let adoptedCopilotCallID,
               CallaCallTerminationPolicy.shouldForceInterrupted(
                exitingGeneration: copilotGeneration,
                explicitlyEndedGeneration: copilotStopRequestedGeneration) {
                forceCallInterrupted(adoptedCopilotCallID)
            }
            self.adoptedCopilotPID = nil
            self.adoptedCopilotCallID = nil
            copilotStopRequestedGeneration = nil
            clearOwnedPID(at: copilotPIDURL)
            try? fileManager.removeItem(at: copilotStatusURL)
        }
        var status = CopilotStatus()
        status.generation = copilotGeneration
        status.available = copilotExecutable != nil
        status.persona = copilotPersona
        status.lastResult = copilotResult
        // Preference until a live call reports otherwise, so Settings and the
        // notch agree before the first suggestion lands.
        status.activeProvider = copilotProvider
        let agy = agyAvailability()
        status.agyAvailable = agy.available
        status.agyVersion = agy.version
        let auth = agyAuthStatus()
        status.agyLoggedIn = auth.loggedIn
        status.agyLoginURL = agyLoginURL
        status.agyAwaitingCode = agyLoginAwaitingCode
        status.agyLoginStage = agyLoginStage
        status.agyBackupAvailable = Self.credentialURLs.contains {
            fileManager.fileExists(atPath: Self.supersededURL(for: $0).path)
        }
        status.retranscribingCallID = archiveProcess?.isRunning == true ? retranscribingCallID : nil
        status.agyAccount = auth.account

        let permissions = hostPermissions()
        status.hostPermissionsKnown = permissions != nil
        status.hostMicGranted = permissions?.micGranted ?? false
        status.hostScreenGranted = permissions?.screenGranted ?? false
        status.modelDownload = (try? Data(contentsOf: copilotModelDownloadURL))
            .flatMap { try? jsonDecoder.decode(ModelDownloadFile.self, from: $0) }

        if let data = try? Data(contentsOf: copilotStatusURL),
           let host = try? jsonDecoder.decode(CopilotHostStatus.self, from: data),
           // V2 host reports generation. Refuse stale lifecycle state before it
           // can change notch UI; old archives have no lifecycle and remain
           // readable through history, never as active calls.
           host.lifecycle?.generation == copilotGeneration {
            adoptedCopilotCallID = host.callID
            let alive = copilotIsRunning
            // `starting` and `running` are deliberately exclusive. A host that is
            // still loading its model is not a call the notch should draw as live,
            // but it is emphatically not nothing either — that gap is what made
            // pressing Start look like it had failed.
            let booting = host.lifecycle?.state == CallLifecycleState.starting.rawValue
            status.lifecycleState = host.lifecycle?.state
            status.recapProgress = host.lifecycle?.recapProgress
            // Winding down is not capturing. A host writing its recap has both
            // microphones closed, so drawing it as a live call is the same lie
            // in the other direction — and it is what made the panel sit there
            // unchanged after End call until the process finally exited.
            let winding = host.lifecycle.map {
                $0.state == CallLifecycleState.stopping.rawValue
                    || $0.state == CallLifecycleState.processingRecap.rawValue
            } ?? false
            status.starting = alive && booting
            status.running = alive && !booting && !winding
            status.finishing = alive && winding
            if let startup = host.lifecycle?.startup {
                status.startupStage = startup.stage
                status.modelLoaded = startup.modelLoaded ?? false
                status.brainWarm = startup.brainWarm ?? false
                status.gatewayWarm = startup.gatewayWarm
            }
            status.callID = host.callID
            status.persona = host.persona
            status.startedAt = host.startedAt
            status.turnCount = host.turnCount
            status.gatewayConnected = host.gatewayConnected
            status.micActive = host.micActive
            status.systemAudioActive = host.systemAudioActive
            // The host is the authority once a call is live: it knows whether the
            // local brain actually answered or handed over to the gateway.
            status.activeProvider = host.provider ?? copilotProvider
            status.providerDetail = host.providerDetail
            status.speaking = host.speaking
            status.thinking = host.thinking ?? false
            status.working = host.working
            status.questionWorking = host.questionWorking ?? false
            status.summaryWorking = host.summaryWorking ?? false
            status.answering = host.answering ?? false
            status.prewarming = false
            status.meetingTitle = host.meetingTitle
            status.meetingStartsAt = host.meetingStartsAt

            if let suggestionData = try? Data(contentsOf: copilotSuggestionURL),
               let suggestion = try? jsonDecoder.decode(CopilotSuggestionFile.self, from: suggestionData),
               // A suggestion left over from an earlier call must never be
               // shown against the current one.
               suggestion.callID == host.callID {
                status.headline = suggestion.headline
                status.angles = suggestion.angles
                status.confirm = suggestion.confirm
                status.detectedQuestion = suggestion.question
                status.citationLabels = suggestion.citations ?? []
                status.grounding = suggestion.grounding
                status.answerLatencyMs = suggestion.latencyMs
                status.summary = suggestion.summary
                status.openQuestions = suggestion.openQuestions ?? []
                status.suggestionAfterSeq = suggestion.afterSeq
            }
            if let question = copilotEventQuestion,
               question.callID == host.callID,
               question.generation == copilotGeneration {
                status.detectedQuestion = question.prompt
            }
            if let answer = copilotEventAnswer,
               answer.callID == host.callID,
               answer.generation == copilotGeneration {
                status.headline = answer.main
                status.angles = answer.points
                status.confirm = answer.warning.map { [$0] } ?? []
                status.detectedQuestion = answer.question
                status.citationLabels = answer.citations.map { citation in
                    if let page = citation.page { return "\(citation.label) · p. \(page)" }
                    if let section = citation.section { return "\(citation.label) · \(section)" }
                    return citation.label
                }
                status.grounding = answer.grounding.rawValue
                status.answerLatencyMs = answer.timing.speechEndToPublishMilliseconds
                status.suggestionAfterSeq = answer.citations.compactMap(\.toSeq).max()
                    ?? copilotEventQuestion?.toSeq
                status.activeProvider = answer.provider
                status.providerDetail = answer.model
            }
        }
        if let id = status.callID {
            status.screenshotCount = lineCount(copilotCallsRoot
                .appendingPathComponent(id, isDirectory: true)
                .appendingPathComponent("captures/captures.jsonl"))
        }
        status.callFolder = lastCallFolder
        return status
    }

    /// Whether the local Antigravity CLI is installed, and its version.
    ///
    /// Looked up the same way the provider does — well-known install paths first,
    /// because a GUI app inherits a minimal `PATH` — and cached for the life of
    /// the service: the answer only changes when the user installs or removes
    /// `agy`, and this is read by a 2s poll.
    private func agyAvailability() -> (available: Bool, version: String?) {
        if let agyProbe { return agyProbe }
        guard let path = AgyLocator.locate() else {
            let probe = (available: false, version: String?.none)
            agyProbe = probe
            return probe
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        process.environment = AgyEnvironment.processEnvironment()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        var version: String?
        if (try? process.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            version = text.isEmpty ? nil : text
        }
        let probe = (available: true, version: version)
        agyProbe = probe
        return probe
    }

    /// Whether `agy` has OAuth credentials on disk, and which account.
    ///
    /// Same cache strategy as `agyAvailability`: looked up once and held for
    /// the life of the service. Cleared when a login command completes.
    /// The user's real home, whatever this process's sandbox says.
    ///
    /// `NSHomeDirectory()` is redirected to the container in a sandboxed process
    /// and not in an unsandboxed one, so using it here is how "Settings says
    /// signed in" could coexist with a call popping a fresh OAuth page: two
    /// processes were answering the same question from two different homes. The
    /// passwd database is not redirected, so everything agrees.
    private static let userHome: String = {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            let path = String(cString: dir)
            if !path.isEmpty { return path }
        }
        return NSHomeDirectory()
    }()

    private func agyAuthStatus() -> (loggedIn: Bool, account: String?) {
        // Keyed on the credential file itself, so the answer cannot go stale.
        //
        // This used to cache once per engine instance and only invalidate on
        // sign-in or sign-out — so an engine that happened to start while the
        // credential was absent reported "not signed in" forever, and one that
        // cached "signed in" never noticed it disappearing. Either way the call
        // path made the wrong decision and said nothing. A `stat` per poll is
        // cheap; the JSON is only re-read when the file actually changes.
        let fingerprint = credentialFingerprint()
        if let agyAuthCache, agyAuthCacheFingerprint == fingerprint { return agyAuthCache }
        agyAuthCacheFingerprint = fingerprint
        let result = (loggedIn: AgyLocator.hasCredentials(), account: AgyLocator.activeAccount())
        agyAuthCache = result
        return result
    }

    /// Runs `agy`'s own interactive sign-in and surfaces it to the UI.
    ///
    /// Driving the **TUI**, not print mode, and the difference is the whole reason
    /// sign-in used to fail:
    ///
    ///  * `agy -p` gives the flow a hard **60 seconds** and then kills it. That is
    ///    shorter than a human browser round-trip, so the paste field vanished
    ///    mid-sign-in — and pressing the button again minted a **new PKCE
    ///    challenge**, which is why a code from the earlier tab came back
    ///    "expired". The TUI has no such deadline (verified alive past 60s).
    ///  * The TUI first shows `Select login method` with `1. Google OAuth`
    ///    preselected, so a bare Return starts the flow.
    ///  * It then prints the accounts.google.com URL and accepts the pasted code
    ///    for as long as it is running.
    ///
    /// It needs a real terminal: with a pipe on stdin `agy` refuses outright, and
    /// its TUI opens `/dev/tty`, which needs a controlling terminal and therefore
    /// `setsid`. `/usr/bin/script` supplies both — and it sizes its inner pty from
    /// its own stdin, so handing it a **1000-column** pty is what keeps the
    /// 704-character URL on one line instead of wrapped beyond reassembly.
    /// A rehearsal of the sign-in against a throwaway `HOME`.
    ///
    /// Exists because the only other way to see this flow is to sign out, and
    /// signing out is what caused the damage this code now guards against. Every
    /// step is identical — menu, link, browser, code, error handling — but `agy`
    /// reads and writes credentials in a temporary directory, so the real one is
    /// untouched whatever happens.
    private func testLoginFlow() {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("calla-signin-rehearsal-\(UUID().uuidString.prefix(8))")
        try? fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        agyLoginRehearsalHome = scratch
        loginAgy(force: false, rehearsing: true)
    }

    private func loginAgy(force: Bool = false, rehearsing: Bool = false) {
        guard !copilotIsRunning else {
            copilotResult = "Cannot sign in while a call is running"; return
        }
        guard agyLoginProcess?.isRunning != true, agyLoginStage != "checking" else {
            copilotResult = "Sign-in already in progress"; return
        }
        guard let binary = agyBinaryPath() else {
            copilotResult = "agy is not installed"; return
        }

        let auth = agyAuthStatus()
        if auth.loggedIn, !force, !rehearsing {
            copilotResult = auth.account.map { "Already signed in as \($0)" } ?? "Already signed in"
            return
        }
        agyLoginStage = "checking"
        agyLoginURL = nil
        agyLoginAwaitingCode = false
        copilotResult = "Checking the connection to Google…"
        Task { [weak self] in
            guard let self else { return }
            let online = await AgyConnectivity.canReachGoogle()
            let check = online && force && auth.loggedIn && !rehearsing ? self.checkCredential() : nil
            self.queue.async {
                guard self.agyLoginStage == "checking" else { return }
                guard online else {
                    self.agyLoginStage = "failed"
                    self.copilotResult = "Offline or Google is unreachable. Connect to the internet, then press Retry. Your sign-in is unchanged."
                    return
                }
                if let check {
                    switch check {
                    case .valid:
                        self.agyLoginStage = nil
                        self.copilotResult = auth.account.map { "Already signed in as \($0)" } ?? "Already signed in and working"
                        return
                    case .unavailable:
                        self.agyLoginStage = "failed"
                        self.copilotResult = "Could not verify your account. Check the connection and retry; your sign-in is unchanged."
                        return
                    case .invalid:
                        // Only an explicit authentication rejection permits a
                        // replacement. Timeouts and quota failures preserve it.
                        for url in Self.credentialURLs where self.fileManager.fileExists(atPath: url.path) {
                            let superseded = Self.supersededURL(for: url)
                            try? self.fileManager.removeItem(at: superseded)
                            try? self.fileManager.moveItem(at: url, to: superseded)
                        }
                    }
                }
                self.startAgySignIn(binary: binary, rehearsing: rehearsing)
            }
        }
    }

    /// Spawns the TUI and starts watching it. Split out so the immediate path and
    /// the post-probe path cannot drift apart.
    private func startAgySignIn(binary: String, rehearsing: Bool) {
        agyAuthCache = nil
        agyProbe = nil
        agyLoginURL = nil
        agyLoginAwaitingCode = false
        agyLoginBuffer = ""
        agyLoginChoseMethod = false
        agyLoginStage = "starting"
        agyLoginFailure = nil

        // A pty of our own, wide enough that the sign-in URL is never wrapped.
        var master: Int32 = 0
        var slave: Int32 = 0
        var window = winsize(ws_row: 50, ws_col: 1000, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &window) == 0 else {
            copilotResult = "Could not allocate a terminal for sign-in"; return
        }
        let masterHandle = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: true)

        let process = Process()
        // Tethered so a killed engine does not leave a sign-in waiting forever.
        let launch = ProcessTether.tethered("/usr/bin/script", [
            "-q", "/dev/null", binary,
            "--log-file", agyLoginLogURL.path,
        ])
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.arguments
        var environment = ProcessInfo.processInfo.environment
        environment["AGY_CLI_DISABLE_AUTO_UPDATE"] = "1"
        // Only the app opens the published link, once per login. The CLI must
        // not launch another browser or retry it independently.
        environment["BROWSER"] = "/usr/bin/true"
        environment.removeValue(forKey: "AGY_CLI_NONINTERACTIVE_HEADLESS")
        environment["HOME"] = rehearsing ? (agyLoginRehearsalHome?.path ?? Self.userHome) : Self.userHome
        environment["TERM"] = "xterm-256color"
        process.environment = environment
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle

        masterHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let chunk = String(decoding: data, as: UTF8.self)
            self?.queue.async { self?.consumeLoginOutput(chunk) }
        }

        process.terminationHandler = { [weak self] child in
            masterHandle.readabilityHandler = nil
            self?.queue.async {
                guard let self else { return }
                self.agyLoginProcess = nil
                self.agyLoginInput = nil
                self.agyLoginAwaitingCode = false
                self.agyLoginURL = nil
                self.agyAuthCache = nil
                self.agyProbe = nil
                self.restoreSupersededCredentialIfNeeded()
                if let reason = self.agyLoginFailure {
                    self.agyLoginStage = "failed"
                    self.copilotResult = reason
                    self.agyLoginBuffer = ""
                    return
                }
                if let rehearsal = self.agyLoginRehearsalHome {
                    try? self.fileManager.removeItem(at: rehearsal)
                    self.agyLoginRehearsalHome = nil
                    self.agyLoginStage = "signed_in"
                    self.copilotResult = "Sign-in rehearsal finished — your real sign-in was untouched"
                    self.agyLoginBuffer = ""
                    return
                }
                if self.agyAuthStatus().loggedIn {
                    let account = self.agyAuthStatus().account
                    self.agyExplicitSignOut = false
                    self.agyLoginStage = "signed_in"
                    self.copilotResult = account.map { "Signed in as \($0)" } ?? "Signed in"
                } else {
                    self.agyLoginStage = "failed"
                    self.copilotResult = CallaAgyLoginParsing.failureMessage(
                        from: self.agyLoginBuffer,
                        status: child.terminationStatus)
                }
                self.agyLoginBuffer = ""
            }
        }

        do {
            try process.run()
            // The parent's copy must go, or reads never see EOF when agy exits.
            try? slaveHandle.close()
            agyLoginProcess = process
            agyLoginInput = masterHandle
            agyLoginStage = "starting"
            copilotResult = "Starting sign-in…"
            watchLoginForCompletion()
        } catch {
            try? slaveHandle.close()
            copilotResult = "Could not start sign-in: \(error.localizedDescription)"
        }
    }

    /// Reacts to the TUI: answer its menu, publish the URL, open the browser.
    private func consumeLoginOutput(_ chunk: String) {
        guard agyLoginFailure == nil, agyLoginProcess?.isRunning == true else { return }
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: agyLoginLogURL.path)
        agyLoginBuffer = String((agyLoginBuffer + chunk).suffix(16_000))

        if !agyLoginChoseMethod, CallaAgyLoginParsing.isAtLoginMethodMenu(agyLoginBuffer) {
            agyLoginChoseMethod = true
            // `1. Google OAuth` is already selected; Return accepts it.
            agyLoginInput?.write(Data("\r".utf8))
            agyLoginStage = "opening_browser"
            copilotResult = "Opening Google sign-in…"
        }

        if agyLoginURL == nil, let url = CallaAgyLoginParsing.signInURL(in: agyLoginBuffer) {
            agyLoginURL = url
            // The TUI accepts the pasted code from the moment the link is shown,
            // so this is the honest point to offer the field.
            agyLoginAwaitingCode = true
            agyLoginStage = "awaiting_code"
            copilotResult = "Approve in your browser, then paste the code. Use Open if the browser does not appear."
        }

        if CallaAgyLoginParsing.hasError(agyLoginBuffer) {
            stopAgyLogin(reason: CallaAgyLoginParsing.failureMessage(from: agyLoginBuffer, status: 0))
        }
    }

    /// Credentials on disk are the authority on success, not the screen.
    ///
    /// Polls until they appear, then shuts the TUI down. Also the long stop: a
    /// sign-in nobody finishes must not leave a terminal running forever.
    private func watchLoginForCompletion(deadline: Date = Date().addingTimeInterval(600),
                                        nextConnectionCheck: Date = Date().addingTimeInterval(10)) {
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, let process = self.agyLoginProcess, process.isRunning else { return }
            self.agyAuthCache = nil
            if self.agyAuthStatus().loggedIn {
                self.stopAgyLogin(reason: nil)
                return
            }
            if Date() >= deadline {
                self.stopAgyLogin(reason: "Sign-in timed out — start it again")
                return
            }
            if Date() >= nextConnectionCheck {
                Task { [weak self] in
                    let online = await AgyConnectivity.canReachGoogle()
                    self?.queue.async {
                        guard let self, self.agyLoginProcess === process, process.isRunning else { return }
                        guard online else {
                            self.stopAgyLogin(reason: "Connection lost. Reconnect, then press Retry. Your sign-in is unchanged.")
                            return
                        }
                        self.watchLoginForCompletion(deadline: deadline, nextConnectionCheck: Date().addingTimeInterval(10))
                    }
                }
            } else {
                self.watchLoginForCompletion(deadline: deadline, nextConnectionCheck: nextConnectionCheck)
            }
        }
    }

    /// Ends a sign-in, killing the whole tree.
    ///
    /// `terminate()` reaches `script`; the `agy` underneath it is a separate
    /// process and would otherwise be left holding a terminal.
    private func stopAgyLogin(reason: String?) {
        if let process = agyLoginProcess, process.isRunning {
            terminateProcessTree(process.processIdentifier)
        }
        if let reason {
            agyLoginFailure = reason
            agyLoginStage = "failed"
            agyLoginURL = nil
            agyLoginAwaitingCode = false
            copilotResult = reason
        }
    }

    static func childPIDs(of pid: Int32) -> [Int32] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-P", String(pid)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: { $0.isWhitespace })
            .compactMap { Int32($0) }
    }

    func submitAgyToken(_ token: String, with reply: @escaping (Data) -> Void) {
        queue.async {
            let code = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !code.isEmpty else {
                self.copilotResult = "Paste the code from the browser first"
                reply(self.encodedStatus()); return
            }
            guard let input = self.agyLoginInput, self.agyLoginProcess?.isRunning == true else {
                self.copilotResult = "No sign-in is waiting for a code — press Sign in again"
                reply(self.encodedStatus()); return
            }
            // Return, because the TUI is reading a line.
            input.write(Data((code + "\r").utf8))
            self.agyLoginStage = "exchanging"
            self.copilotResult = "Exchanging the code…"
            reply(self.encodedStatus())
        }
    }

    /// Clears the stored Google credential so the next sign-in starts fresh.
    ///
    /// Kept as a backup rather than deleted, and *not* auto-restored the way a
    /// failed re-authentication is — signing out is a decision, so undoing it is
    /// the user's call too (`restore_login`).
    private func signOutAgy() {
        guard !copilotIsRunning else {
            copilotResult = "Cannot sign out while a call is running"; return
        }
        if let login = agyLoginProcess, login.isRunning {
            terminateProcessTree(login.processIdentifier)
            agyLoginProcess = nil
            agyLoginInput = nil
        }
        let present = Self.credentialURLs.filter { fileManager.fileExists(atPath: $0.path) }
        guard !present.isEmpty else {
            copilotResult = "Not signed in"; return
        }
        for url in present {
            let superseded = Self.supersededURL(for: url)
            try? fileManager.removeItem(at: superseded)
            try? fileManager.moveItem(at: url, to: superseded)
        }
        // The account file only records which account was active; a fresh sign-in
        // rewrites it, and leaving it behind makes the UI claim an account that no
        // longer has a credential.
        try? fileManager.removeItem(at: Self.accountsBackupURL)
        try? fileManager.moveItem(at: Self.accountsURL, to: Self.accountsBackupURL)
        // Resident hosts hold a language server authenticated as the old account.
        terminateStrayAgyHosts()
        agyExplicitSignOut = true
        agyAuthCache = nil
        agyProbe = nil
        agyLoginStage = nil
        agyLoginURL = nil
        agyLoginAwaitingCode = false
        copilotResult = "Signed out — press Sign in to authenticate again"
    }

    /// Puts back what `sign_out` set aside.
    private func restoreAgyCredentials() {
        let setAside = Self.credentialURLs.filter {
            fileManager.fileExists(atPath: Self.supersededURL(for: $0).path)
        }
        guard !setAside.isEmpty else {
            copilotResult = "No previous sign-in to restore"; return
        }
        for url in setAside {
            try? fileManager.removeItem(at: url)
            try? fileManager.moveItem(at: Self.supersededURL(for: url), to: url)
        }
        if fileManager.fileExists(atPath: Self.accountsBackupURL.path) {
            try? fileManager.removeItem(at: Self.accountsURL)
            try? fileManager.moveItem(at: Self.accountsBackupURL, to: Self.accountsURL)
        }
        agyExplicitSignOut = false
        agyAuthCache = nil
        agyProbe = nil
        let auth = agyAuthStatus()
        copilotResult = auth.account.map { "Restored sign-in for \($0)" } ?? "Restored the previous sign-in"
    }

    static var accountsURL: URL {
        URL(fileURLWithPath: userHome).appendingPathComponent(".gemini/google_accounts.json")
    }

    static var accountsBackupURL: URL {
        accountsURL.appendingPathExtension("superseded")
    }

    private func credentialFingerprint() -> String {
        Self.credentialURLs.map { url -> String in
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
                return "absent"
            }
            let size = (attributes[.size] as? NSNumber)?.intValue ?? -1
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            return "\(size)-\(modified)"
        }.joined(separator: "|")
    }

    /// Every place AGY may keep the credential this engine signs in and out of.
    ///
    /// AGY 1.1.x writes `antigravity-cli/antigravity-oauth-token`; older builds
    /// wrote `oauth_creds.json`. This engine only ever knew the second one, and
    /// on a 1.1.x install that made a *successful* sign-in invisible: `agy`
    /// authenticated through the keyring, wrote the new file, and the completion
    /// watcher went on polling the old path until its ten-minute timeout — with
    /// the TUI still running behind a panel that said "signing in".
    ///
    /// `AgyLocator.hasCredentials` already knew both. The duplicate here is what
    /// drifted, so the engine now defers to it rather than keeping a second
    /// opinion.
    static var credentialURLs: [URL] { AgyEnvironment.credentialLocations }

    static var credentialURL: URL { AgyEnvironment.credentialsFile }

    static func supersededURL(for url: URL) -> URL {
        url.appendingPathExtension("superseded")
    }

    static var supersededCredentialURL: URL { supersededURL(for: credentialURL) }

    /// Whether the stored credential can actually reach the model.
    ///
    /// The file existing only proves a sign-in happened once; it can be revoked or
    /// expired. This is the difference between "signed in" and "working", and it is
    /// the question a re-authentication actually turns on. Costs one tiny model
    /// call, which is the right price for not destroying a good credential.
    private enum CredentialCheck { case valid, invalid, unavailable }
    private func checkCredential() -> CredentialCheck {
        guard let binary = agyBinaryPath() else { return .unavailable }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["-p", "ok", "--output-format", "json", "--print-timeout", "25s"]
        process.environment = AgyEnvironment.processEnvironment()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return .unavailable }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        if process.terminationStatus == 0,
           let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           result["status"] as? String == "SUCCESS" { return .valid }
        let lowered = output.lowercased()
        let transient = ["no such host", "network is", "connection refused", "connection reset", "dial tcp", "i/o timeout", "deadline exceeded", "timed out", "tls handshake", "429", "quota", "503", "502", "504"]
        if transient.contains(where: lowered.contains) { return .unavailable }
        let invalid = ["invalid_grant", "credentials revoked", "invalid credentials", "authentication required", "not logged in", "unauthenticated"]
        return invalid.contains(where: lowered.contains) ? .invalid : .unavailable
    }

    /// Puts a superseded credential back when a sign-in did not replace it.
    ///
    /// Without this, an abandoned or failed re-authentication leaves the user with
    /// no credential at all — worse off than before they pressed the button.
    private func restoreSupersededCredentialIfNeeded() {
        // A deliberate sign-out is not an accident to be repaired.
        guard !agyExplicitSignOut else { return }
        let setAside = Self.credentialURLs.filter {
            fileManager.fileExists(atPath: Self.supersededURL(for: $0).path)
        }
        guard !setAside.isEmpty else { return }
        if AgyLocator.hasCredentials() {
            // A new credential arrived; the old ones are genuinely superseded.
            for url in setAside { try? fileManager.removeItem(at: Self.supersededURL(for: url)) }
            return
        }
        for url in setAside {
            try? fileManager.moveItem(at: Self.supersededURL(for: url), to: url)
        }
        agyAuthCache = nil
    }


    private func agyBinaryPath() -> String? {
        AgyLocator.locate()
    }

    private func appendDiagnostic(_ line: String) {
        diagnostics.append(String(line.prefix(160)))
        diagnostics = Array(diagnostics.suffix(12))
    }

    private func prepareRuntimeDirectories() throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for name in ["catalogue", "courses", "learning", "overlay", "logs", "cache"] {
            try fileManager.createDirectory(at: root.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }

    /// Child processes inherit the XPC service's stdio, which goes nowhere.
    /// Give each child its own owner-only file under the private runtime root.
    private func childLogHandle(_ name: String) -> FileHandle? {
        let file = root.appendingPathComponent("logs/\(name).log")
        if !fileManager.fileExists(atPath: file.path) {
            fileManager.createFile(atPath: file.path, contents: nil,
                                   attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: file) else { return nil }
        // Append: a restart must not truncate the evidence of why the last run died.
        _ = try? handle.seekToEnd()
        return handle
    }

    private func writePreferences(_ preferences: Preferences) throws {
        let destination = root.appendingPathComponent("engine-preferences.json")
        let temporary = root.appendingPathComponent(".engine-preferences-\(UUID().uuidString)")
        let data = try JSONEncoder().encode(preferences)
        try data.write(to: temporary, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary, backupItemName: nil, options: [])
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }

    /// XPC may restart before Boring redraws Settings. Restore only the
    /// engine's own last complete Boring snapshot, never legacy Calla data.
    private func restorePreferences() {
        let file = root.appendingPathComponent("engine-preferences.json")
        guard let data = try? Data(contentsOf: file),
              let stored = try? JSONDecoder().decode(Preferences.self, from: data) else { return }
        preferences = stored
    }

    private func appCallaResources() -> URL? {
        // XPC bundle lives at App/Contents/XPCServices/Engine.xpc. Production
        // and Debug both place immutable plugin resources at App/Contents/Resources/Calla.
        let xpc = Bundle.main.bundleURL
        return xpc.deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Calla", isDirectory: true)
    }

    /// Clean receipts left by builds that embedded a local OpenClaw node.
    /// Only Boring-recorded PID is reclaimed; unrelated processes stay outside
    /// this app's authority.
    private func removeRetiredLocalNodeState() {
        reclaimOwnedProcess(at: retiredNodePIDURL)
        guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else { return }
        for name in names where name.hasPrefix("node-openclaw-") && name.hasSuffix(".json") {
            try? fileManager.removeItem(at: root.appendingPathComponent(name))
        }
    }

    /// launchd can reclaim an XPC instance before its descendants. Reclaim
    /// only Boring-recorded PIDs; never scan or kill generic OpenClaw work.
    private func reclaimStaleOwnedChildren() {
        // A Tutor host left by an earlier build is Boring's own child; end it.
        reclaimOwnedProcess(at: retiredRuntimePIDURL)
        try? fileManager.removeItem(at: root.appendingPathComponent("tutor-host.sock"))
        removeRetiredLocalNodeState()
        // Left behind by a host that was killed or crashed; nothing else reaps them.
        terminateStrayAgyHosts(orphansOnly: true)
        if copilotProcess?.isRunning != true {
            copilotProcess = nil
        }
    }

    /// Adopts a verified recording host across Engine restart. Legacy prewarm is
    /// sole Call host stopped during upgrade; unrelated and unverified processes
    /// are never touched.
    @discardableResult
    private func reconcileOwnedCopilotAtStartup() -> String? {
        guard let pid = ownedPID(at: copilotPIDURL) else {
            clearOwnedPID(at: copilotPIDURL)
            try? fileManager.removeItem(at: copilotStatusURL)
            return nil
        }
        guard let command = ownedCopilotCommand(pid) else {
            clearOwnedPID(at: copilotPIDURL)
            try? fileManager.removeItem(at: copilotStatusURL)
            return nil
        }
        let arguments = command.split(whereSeparator: \.isWhitespace)
        if arguments.contains("--prewarm") {
            if let data = try? Data(contentsOf: copilotStatusURL),
               let host = try? jsonDecoder.decode(CopilotHostStatus.self, from: data) {
                markCallInterrupted(host.callID)
            }
            terminateProcessTree(pid)
            clearOwnedPID(at: copilotPIDURL, matching: pid)
            try? fileManager.removeItem(at: copilotStatusURL)
            copilotResult = "Removed legacy prewarmed Call host"
            return nil
        }
        guard let data = try? Data(contentsOf: copilotStatusURL),
              let host = try? jsonDecoder.decode(CopilotHostStatus.self, from: data),
              let lifecycle = host.lifecycle else {
            // PID is ours, but without matching call identity no history row can
            // safely be preserved or changed. Adopt only its PID so a second
            // host cannot start while recovery waits for valid status.
            adoptedCopilotPID = pid
            return nil
        }

        if host.prewarming == true || lifecycle.state == CallLifecycleState.prewarming.rawValue {
            markCallInterrupted(host.callID)
            terminateProcessTree(pid)
            clearOwnedPID(at: copilotPIDURL, matching: pid)
            try? fileManager.removeItem(at: copilotStatusURL)
            copilotResult = "Removed legacy prewarmed Call host"
            return nil
        }

        adoptedCopilotPID = pid
        adoptedCopilotCallID = host.callID
        copilotGeneration = lifecycle.generation
        return host.callID
    }

    private var copilotIsRunning: Bool {
        if copilotProcess?.isRunning == true { return true }
        guard let adoptedCopilotPID else { return false }
        return isOwnedCopilotProcess(adoptedCopilotPID)
    }

    private func currentOwnedCopilotCallID() -> String? {
        if let data = try? Data(contentsOf: copilotStatusURL),
           let host = try? jsonDecoder.decode(CopilotHostStatus.self, from: data),
           host.lifecycle?.generation == copilotGeneration {
            return host.callID
        }
        return adoptedCopilotCallID
    }

    private func markCallInterrupted(_ callID: String, at date: Date = Date()) {
        guard let store else { return }
        _ = awaitOnQueue { try? await store.interruptCall(id: callID, at: date) }
    }

    private func forceCallInterrupted(_ callID: String, at date: Date = Date()) {
        guard let store else { return }
        _ = awaitOnQueue {
            try? await store.reconcileEndState(id: callID, at: date, reason: .interrupted)
        }
    }

    private func ownedPID(at file: URL) -> pid_t? {
        guard let value = try? String(contentsOf: file, encoding: .utf8),
              let pid = pid_t(value.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1, pid != getpid() else { return nil }
        return pid
    }

    /// PID file alone is not authority. Exact CallHost executable suffix plus
    /// `serve` command prevents stale/reused PID from targeting another process.
    private func isOwnedCopilotProcess(_ pid: pid_t) -> Bool {
        ownedCopilotCommand(pid) != nil
    }

    private func ownedCopilotCommand(_ pid: pid_t) -> String? {
        guard pid > 1, Darwin.kill(pid, 0) == 0 else { return nil }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "command="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let command = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0
            && command.contains("/CallaCallHost.app/Contents/MacOS/CallaCallHost")
            && command.split(whereSeparator: \.isWhitespace).contains("serve") else { return nil }
        return command
    }

    private func reclaimOwnedProcess(at file: URL) {
        guard let value = try? String(contentsOf: file, encoding: .utf8),
              let pid = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1, pid != getpid() else {
            clearOwnedPID(at: file)
            return
        }
        terminateProcessTree(pid)
        clearOwnedPID(at: file)
    }

    private func writeOwnedPID(_ pid: pid_t, to file: URL) throws {
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent)-\(UUID().uuidString)")
        guard let data = "\(pid)\n".data(using: .utf8) else { return }
        try data.write(to: temporary, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if fileManager.fileExists(atPath: file.path) {
            _ = try fileManager.replaceItemAt(file, withItemAt: temporary, backupItemName: nil, options: [])
        } else {
            try fileManager.moveItem(at: temporary, to: file)
        }
    }

    private func clearOwnedPID(at file: URL, matching pid: pid_t? = nil) {
        if let pid,
           let value = try? String(contentsOf: file, encoding: .utf8),
           value.trimmingCharacters(in: .whitespacesAndNewlines) != "\(pid)" { return }
        try? fileManager.removeItem(at: file)
    }

    private func terminateProcessTree(_ pid: pid_t) {
        guard pid > 1, pid != getpid() else { return }
        for descendant in childProcesses(of: pid).reversed() { Darwin.kill(descendant, SIGTERM) }
        Darwin.kill(pid, SIGTERM)
    }

    private func childProcesses(of rootPID: pid_t) -> [pid_t] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid="]
        process.standardOutput = output
        guard (try? process.run()) != nil else { return [] }
        // Drain before waiting so a full pipe cannot deadlock this serial queue.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return [] }
        let parents = text.split(separator: "\n").reduce(into: [pid_t: [pid_t]]()) { result, line in
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 2, let pid = Int32(fields[0]), let parent = Int32(fields[1]) else { return }
            result[parent, default: []].append(pid)
        }
        func descendants(_ parent: pid_t) -> [pid_t] {
            let children = parents[parent, default: []]
            return children + children.flatMap(descendants)
        }
        return descendants(rootPID)
    }

    private func startGatewayMonitor() {
        guard privateGatewayAllowed else { gatewayReachable = false; return }
        guard gatewayMonitor == nil else { return }
        probeGateway()
        let monitor = DispatchSource.makeTimerSource(queue: queue)
        monitor.schedule(deadline: .now() + 15, repeating: 15)
        monitor.setEventHandler { [weak self] in self?.probeGateway() }
        monitor.resume()
        gatewayMonitor = monitor
    }

    private func stopGatewayMonitor() {
        gatewayMonitor?.cancel()
        gatewayMonitor = nil
    }

    /// Fixed private Tailscale Serve route. Capability receipt separately
    /// proves Tutor contract, while this tracks current route reachability.
    private func probeGateway() {
        guard privateGatewayAllowed else { gatewayReachable = false; return }
        guard let url = URL(string: "https://nomonhomelab.tailec0dca.ts.net/") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 8
        URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
            let reachable = (response as? HTTPURLResponse).map { (200..<400).contains($0.statusCode) } ?? false
            self?.queue.async { self?.gatewayReachable = reachable }
        }.resume()
    }

    private var isInstalledBoringApp: Bool {
        let app = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return app.path.hasPrefix("/Applications/")
    }

    /// Installed Boring owns one immutable Gateway artifact. Debug deployment
    /// is staged by Xcode instead. This merely requests private owner-SSH
    /// update; the Gateway manifest short-circuits unchanged digests.
    private func requestGatewayUpdate(trigger: String) {
        guard privateGatewayAllowed else { lastResult = "Gateway skipped; run setup to connect it"; return }
        guard gatewayUpdate?.isRunning != true else {
            lastResult = "Gateway update already running"
            return
        }
        guard let resources = appCallaResources() else {
            lastResult = "Gateway update unavailable: Calla resources missing"
            return
        }
        let script = resources.appendingPathComponent("scripts/gateway-update.sh")
        let artifact = resources.appendingPathComponent("Gateway/calla-gateway.tar.gz")
        guard fileManager.isExecutableFile(atPath: script.path), fileManager.fileExists(atPath: artifact.path) else {
            lastResult = "Gateway update unavailable: bundled release missing"
            return
        }
        let output = Pipe()
        let process = Process()
        process.executableURL = script
        process.arguments = ["--bundle", artifact.path]
        process.standardOutput = output
        process.standardError = output
        process.terminationHandler = { [weak self] child in
            let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self?.queue.async {
                self?.gatewayUpdate = nil
                self?.recordGatewayUpdate(output: text, succeeded: child.terminationStatus == 0,
                                          terminationStatus: child.terminationStatus)
            }
        }
        do {
            try process.run()
            gatewayUpdate = process
            lastResult = "Gateway update requested (\(trigger))"
        } catch {
            lastResult = "Gateway update could not start: \(error.localizedDescription)"
        }
    }

    private struct TutorGatewayReply { let message: String; let model: String? }

    private func recordGatewayUpdate(output: String, succeeded: Bool, terminationStatus: Int32) {
        let previous = currentGatewayUpdate()
        let marker = output.split(separator: "\n").last(where: { $0.hasPrefix("CALLA_GATEWAY_RESULT\t") })
        let fields = marker?.split(separator: "\t", omittingEmptySubsequences: false) ?? []
        let outcome = fields.count > 1 ? String(fields[1]) : ""
        let current = fields.count > 2 && !fields[2].isEmpty ? String(fields[2]) : previous?.currentRelease
        let prior = fields.count > 3 && !fields[3].isEmpty ? String(fields[3]) : previous?.previousRelease
        let fallback: String
        if succeeded, outcome == "unchanged" {
            fallback = "Gateway release unchanged"
        } else if succeeded {
            fallback = "Gateway update complete"
        } else {
            fallback = "Gateway update failed: exit \(terminationStatus)"
        }
        // Gateway stdout can include transport and tool detail. Boring keeps a
        // receipt state only, never raw Gateway output.
        let summary = fallback
        let record = GatewayUpdateRecord(currentRelease: current, previousRelease: prior,
                                         summary: summary, completedAt: Date())
        do {
            try writeGatewayUpdate(record)
            lastResult = summary
        } catch {
            lastResult = "\(summary) (could not persist receipt: \(error.localizedDescription))"
        }
    }

    private func currentGatewayUpdate() -> GatewayUpdateRecord? {
        let file = root.appendingPathComponent("gateway-update.json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(GatewayUpdateRecord.self, from: data)
    }

    private func writeGatewayUpdate(_ record: GatewayUpdateRecord) throws {
        let destination = root.appendingPathComponent("gateway-update.json")
        let temporary = root.appendingPathComponent(".gateway-update-\(UUID().uuidString)")
        let data = try JSONEncoder().encode(record)
        try data.write(to: temporary, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary, backupItemName: nil, options: [])
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }

    private func encodedStatus() -> Data {
        let gatewayUpdate = currentGatewayUpdate()
        let status = Status(
            running: isRunning,
            gatewayReachable: gatewayReachable,
            releaseVersion: gatewayUpdate?.currentRelease,
            previousGatewayRelease: gatewayUpdate?.previousRelease,
            lastGatewayUpdate: gatewayUpdate?.summary,
            lastGatewayUpdateAt: gatewayUpdate?.completedAt,
            lastResult: lastResult,
            diagnostics: diagnostics,
            copilot: currentCopilotStatus(),
            quiz: awaitOnQueue { [quizController] in await quizController.snapshot() } ?? QuizSessionSnapshot()
        )
        do {
            let data = try JSONEncoder().encode(status)
            for object in statusObservers.allObjects {
                (object as? BoringCallaEngineStatusObserver)?.callaEngineStatusDidChange(data)
            }
            return data
        } catch {
            // Empty Data decodes to nothing on the far side, which looked
            // exactly like a dropped reply. The client logs its half; this is
            // the other one.
            NSLog("[CallaEngine] could not encode status: %@", String(describing: error))
            return Data()
        }
    }

    private func encodedQuizSnapshot(_ snapshot: QuizSessionSnapshot) -> Data {
        (try? JSONEncoder.calla.encode(snapshot)) ?? Data()
    }

    private func decodeFile<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        let file = root.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

}

// MARK: - Private distribution setup

extension BoringCallaEngine {
    private var privateDistribution: Bool {
        let app = Bundle.main.bundleURL.deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return Bundle(url: app)?.object(forInfoDictionaryKey: "BoringPrivateDistribution") as? Bool == true
    }

    private var privateGatewayAllowed: Bool {
        guard privateDistribution else { return true }
        let file = root.appendingPathComponent("gateway-enabled.json")
        return (try? JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Bool])?["enabled"] == true
    }

    /// Requests are precreated by the setup CLI with a random session ID.
    /// URLs never carry tokens, prompts or arbitrary filesystem paths.
    func privateSetup(_ data: Data, with reply: @escaping (Data) -> Void) {
        if privateDistribution,
           let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           request["uiCommand"] != nil {
            let app = Bundle.main.bundleURL.deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let result = setupSessionHost.handle(request, app: app)
                reply((try? JSONSerialization.data(withJSONObject: result)) ?? Data())
            }
            return
        }
        queue.async {
            guard self.privateDistribution,
                  let call = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let session = call["session"] as? String, UUID(uuidString: session) != nil,
                  let action = call["action"] as? String else { reply(Data()); return }
            let directory = self.root.appendingPathComponent("Setup/sessions")
            let request = directory.appendingPathComponent(session + ".request.json")
            let response = directory.appendingPathComponent(session + ".response.json")
            let allowed: Set<String> = ["status", "configure", "login", "permissions", "permissions-check", "calendar", "calls-folder", "integrations", "test-start", "test-stop", "finish"]
            guard allowed.contains(action),
                  let attributes = try? self.fileManager.attributesOfItem(atPath: request.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                  let requestData = try? Data(contentsOf: request), requestData.count < 8192,
                  let payload = try? JSONSerialization.jsonObject(with: requestData) as? [String: Any],
                  payload["schema"] as? Int == 1, payload["session"] as? String == session,
                  payload["action"] as? String == action,
                  let created = payload["createdAt"] as? Double,
                  abs(Date().timeIntervalSince1970 - created) < 600 else { reply(Data()); return }
            let options = payload["options"] as? [String: Bool] ?? [:]
            var error: String?
            switch action {
            case "login":
                self.agyAuthCache = nil; self.agyProbe = nil
                AgyLocator.forgetInstallations()
                self.loginAgy(force: true)
            case "permissions": self.requestCopilotPermissions { _ in }
            case "calls-folder":
                if !self.prepareCallFoldersRoot() { error = "Allow Boring Notch to use the Documents folder in System Settings → Privacy & Security → Files and Folders, then retry." }
            case "permissions-check":
                self.hostPermissionCheckStarted = false
                self.refreshHostPermissionsOnce()
            case "configure":
                if let enabled = options["gateway"] {
                    let file = self.root.appendingPathComponent("gateway-enabled.json")
                    try? self.fileManager.createDirectory(at: self.root, withIntermediateDirectories: true,
                                                         attributes: [.posixPermissions: 0o700])
                    if let data = try? JSONSerialization.data(withJSONObject: ["enabled": enabled]) {
                        try? data.write(to: file, options: .atomic)
                        try? self.fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                    }
                    if enabled { self.startGatewayMonitor() }
                    else { self.stopGatewayMonitor(); self.gatewayReachable = false }
                }
            case "test-start":
                let current = self.currentCopilotStatus()
                if call["approved"] as? Bool != true { error = "Meeting test cancelled in the app." }
                else if current.running || current.starting || current.finishing || self.copilotIsRunning {
                    error = "End the existing call before running the setup test."
                } else {
                    let id = "call-setup-" + UUID().uuidString
                    self.privateSetupTestCallID = id
                    self.startCopilot(CopilotCommand(action: "start", persona: "generic", model: "whisper-small-en", callID: id, provider: "local", tier: "balanced", fallback: false, gatewayStandby: "off"))
                    self.queue.asyncAfter(deadline: .now() + 100) { [weak self] in
                        guard let self, self.privateSetupTestCallID == id,
                              self.currentCopilotStatus().callID == id else { return }
                        self.stopCopilot(); self.privateSetupTestCallID = nil
                    }
                }
            case "test-stop":
                if let id = self.privateSetupTestCallID, self.currentCopilotStatus().callID == id {
                    self.stopCopilot(); self.privateSetupTestCallID = nil
                }
            default: break
            }
            let failure = error
            // Permission checks are short-lived child processes. Wait for their
            // fresh receipt rather than returning the old on-disk permission.
            self.queue.asyncAfter(deadline: .now() + (action == "permissions-check" ? 1 : 0)) {
                let status = self.currentCopilotStatus()
                let ui = call["uiState"] as? [String: Bool] ?? [:]
                let turns = (try? JSONSerialization.jsonObject(with: self.currentCopilotTranscript(since: -1))) as? [[String: Any]] ?? []
                let sources = Set(turns.compactMap { $0["source"] as? String })
                var result: [String: Any] = [
                    "schema": 1, "session": session, "action": action, "options": options,
                    "engineReady": self.isRunning,
                    "busy": status.running || status.starting || status.finishing || self.copilotIsRunning,
                    "microphone": status.hostMicGranted, "systemAudio": status.hostScreenGranted,
                    "microphoneActive": status.micActive, "systemAudioActive": status.systemAudioActive,
                    "turnCount": status.turnCount, "signedIn": AgyLocator.hasCredentials(),
                    "microphoneTranscribed": sources.contains("me"), "systemAudioTranscribed": sources.contains("them"),
                    "gatewayEnabled": self.privateGatewayAllowed, "gatewayReachable": self.gatewayReachable,
                    "archiveEnabled": ui["archive"] ?? false, "launchAtLogin": ui["launchAtLogin"] ?? false,
                ]
                if let failure { result["error"] = failure }
                if let bytes = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
                    try? bytes.write(to: response, options: .atomic)
                    try? self.fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: response.path)
                    reply(bytes)
                } else { reply(Data()) }
            }
        }
    }
}

// MARK: - Call folders

/// Every finished call, as a folder a person can open: `~/Documents/Calls/
/// <Type>/<date time title>/` with the summary, transcript, copilot answers,
/// notes, screenshots and audio. A mirror — the store stays the record — and
/// the same pass files the call into retrieval so later calls can search it.
extension BoringCallaEngine {
    fileprivate var callFoldersRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Calls", isDirectory: true)
    }

    fileprivate var callFoldersEnabled: Bool { preferences?.callFoldersEnabled ?? true }

    fileprivate struct ExportRecord: Codable {
        var path: String
        var accurateTranscript: Bool
        var exportedAt: Date
        var audio: Bool
        /// What the folder was written from, so a sweep can refresh it once
        /// the call is closed out or its summary lands. Absent in early records.
        var ended: Bool?
        var hadRecap: Bool?
        /// Whether speaker names were in the transcript, so the folder is
        /// rewritten once the post-call speaker pass lands.
        var hadSpeakers: Bool?
    }

    fileprivate func exportRecordURL(_ callID: String) -> URL {
        copilotCallsRoot.appendingPathComponent(callID, isDirectory: true).appendingPathComponent("export.json")
    }

    fileprivate func exportRecord(_ callID: String) -> ExportRecord? {
        guard let data = try? Data(contentsOf: exportRecordURL(callID)) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ExportRecord.self, from: data)
    }

    /// Engine queue only. Idempotent: a call already exported with the
    /// transcript it has now is left alone.
    fileprivate func scheduleCallFolderExport(_ callID: String, after delay: Double = 0) {
        guard CallaCopilotCommandValidation.callID(callID) != nil else { return }
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.exportingCallIDs.contains(callID) else { return }
            self.exportingCallIDs.insert(callID)
            self.exportCallFolder(callID)
            self.exportingCallIDs.remove(callID)
        }
    }

    /// Catches what the event stream missed — a host that exited before its
    /// last event, a crash, the accurate transcript landing minutes later.
    fileprivate func startCallFolderSweep() {
        guard callFolderTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 20, repeating: 60)
        timer.setEventHandler { [weak self] in self?.sweepCallFolders() }
        timer.resume()
        callFolderTimer = timer
    }

    fileprivate func sweepCallFolders(window: TimeInterval = 6 * 3600) {
        guard callFoldersEnabled, let store else { return }
        let recent = awaitOnQueue { (try? await store.calls(limit: 30)) ?? [] } ?? []
        let live = currentCopilotStatus().callID
        for call in recent where call.id != live && call.endedAt != nil {
            guard let ended = call.endedAt, Date().timeIntervalSince(ended) < window else { continue }
            let hasArchive = fileManager.fileExists(atPath: copilotCallsRoot
                .appendingPathComponent(call.id).appendingPathComponent("transcript-archive.jsonl").path)
            let hasRecap = (awaitOnQueue { try? await store.recapDraft(forCall: call.id) } ?? nil) != nil
            let hasSpeakers = !(awaitOnQueue { (try? await store.speakers(forCall: call.id)) ?? [] } ?? []).isEmpty
            if let record = exportRecord(call.id),
               record.accurateTranscript || !hasArchive,
               record.ended == true,
               record.hadRecap == true || !hasRecap,
               record.hadSpeakers == true || !hasSpeakers { continue }
            scheduleCallFolderExport(call.id)
        }
    }

    /// Writes (or refreshes) one call's folder and indexes it. Engine queue.
    fileprivate func exportCallFolder(_ callID: String) {
        guard callFoldersEnabled, let store else { return }
        guard let call = awaitOnQueue({ try? await store.call(id: callID) }) ?? nil else { return }
        let directory = copilotCallsRoot.appendingPathComponent(callID, isDirectory: true)
        let recap = awaitOnQueue { try? await store.recapDraft(forCall: callID) } ?? nil

        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let meeting = (try? Data(contentsOf: directory.appendingPathComponent("meeting.json")))
            .flatMap { try? decoder.decode(MeetingContext.self, from: $0) }
        let archiveURL = directory.appendingPathComponent("transcript-archive.jsonl")
        let accurate = fileManager.fileExists(atPath: archiveURL.path)
        // The store numbers each revision exactly as its JSONL does, so the
        // speaker pass's labels line up with these turns by `seq`.
        let speakerNames: [Int: String] = awaitOnQueue { () async -> [Int: String] in
            let speakers = (try? await store.speakers(forCall: callID)) ?? []
            guard !speakers.isEmpty else { return [:] }
            let names = Dictionary(speakers.map { ($0.speakerID, $0.displayName) }, uniquingKeysWith: { a, _ in a })
            let revision = accurate ? StoredTurn.archiveRevision : StoredTurn.liveRevision
            let stored = (try? await store.turns(forCall: callID, revision: revision)) ?? []
            return Dictionary(stored.compactMap { turn in
                turn.speakerID.map { (turn.seq, names[$0] ?? CallSpeaker.fallbackName(for: $0)) }
            }, uniquingKeysWith: { a, _ in a })
        } ?? [:]
        let turns = Self.jsonLines(accurate ? archiveURL : directory.appendingPathComponent("transcript.jsonl"))
            .compactMap { line -> CallFolderExport.Turn? in
                guard let seq = line["seq"] as? Int, let text = line["text"] as? String else { return nil }
                let isMe = line["source"] as? String == "me"
                return .init(seq: seq, isMe: isMe,
                             t0: line["t0"] as? Double ?? 0, text: text,
                             speaker: isMe ? nil : speakerNames[seq])
            }
        let answers = Self.jsonLines(directory.appendingPathComponent("suggestions.jsonl"))
            .compactMap { line -> CallFolderExport.Answer? in
                guard let seq = line["after_seq"] as? Int else { return nil }
                return .init(afterSeq: seq, headline: line["headline"] as? String ?? "",
                             angles: line["angles"] as? [String] ?? [], confirm: line["confirm"] as? [String] ?? [])
            }
        let captures = Self.jsonLines(directory.appendingPathComponent("captures/captures.jsonl"))
            .compactMap { line -> CallFolderExport.Capture? in
                guard let file = line["file"] as? String, !file.contains("/") else { return nil }
                return .init(file: file, offset: line["offset"] as? Double ?? 0, text: line["text"] as? String ?? "")
            }
        let context = meeting ?? MeetingContext(eventID: call.eventID, seriesID: call.seriesID,
                                                title: call.eventTitle, startsAt: call.eventStart)
        let notes = (awaitOnQueue { (try? await store.notes(for: context, persona: call.persona)) ?? [] } ?? [])
            .filter { $0.source != .eventField }
            .map { CallFolderExport.Note(title: $0.originName ?? $0.title, body: $0.body) }

        let input = CallFolderExport.Input(
            callID: callID, persona: call.persona, startedAt: call.startedAt ?? Date(),
            endedAt: call.endedAt, interrupted: call.endReason == .interrupted,
            meeting: .init(title: meeting?.title ?? call.eventTitle, attendees: meeting?.attendees ?? [],
                           location: meeting?.location, notes: meeting?.notes),
            recap: recap, turns: turns, accurateTranscript: accurate, answers: answers,
            notes: notes, captures: captures)

        // Reuse the folder chosen the first time, so a refreshed transcript
        // never moves the call or leaves a twin behind.
        let previous = exportRecord(callID)
        let relative: String
        if let path = previous?.path, !path.contains("..") {
            relative = path
        } else {
            let proposed = CallFolderExport.folderPath(for: input)
            let parent = callFoldersRoot.appendingPathComponent((proposed as NSString).deletingLastPathComponent)
            let taken = Set((try? fileManager.contentsOfDirectory(atPath: parent.path)) ?? [])
            relative = (proposed as NSString).deletingLastPathComponent + "/"
                + CallFolderExport.unique((proposed as NSString).lastPathComponent, taken: taken)
        }
        let folder = callFoldersRoot.appendingPathComponent(relative, isDirectory: true)
        guard folder.standardizedFileURL.path.hasPrefix(callFoldersRoot.standardizedFileURL.path + "/") else { return }
        do {
            try fileManager.createDirectory(at: folder.appendingPathComponent("notes"), withIntermediateDirectories: true)
            for (name, text) in CallFolderExport.files(for: input) {
                let target = folder.appendingPathComponent(name)
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: target, options: .atomic)
            }
            if (try? fileManager.contentsOfDirectory(atPath: folder.appendingPathComponent("notes").path))?.isEmpty == true {
                try? fileManager.removeItem(at: folder.appendingPathComponent("notes"))
            }
            if !captures.isEmpty {
                let shots = folder.appendingPathComponent("screenshots", isDirectory: true)
                try fileManager.createDirectory(at: shots, withIntermediateDirectories: true)
                for capture in captures where !fileManager.fileExists(atPath: shots.appendingPathComponent(capture.file).path) {
                    try? fileManager.copyItem(at: directory.appendingPathComponent("captures/\(capture.file)"),
                                              to: shots.appendingPathComponent(capture.file))
                }
            }
            let meta: [String: Any] = ["call_id": callID, "persona": call.persona,
                                       "started_at": ISO8601DateFormatter().string(from: input.startedAt),
                                       "ended_at": call.endedAt.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(),
                                       "event_id": call.eventID ?? NSNull(), "series_id": call.seriesID ?? NSNull(),
                                       "title": CallFolderExport.title(for: input)]
            if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
                try data.write(to: folder.appendingPathComponent("call.json"), options: .atomic)
            }
        } catch {
            appendDiagnostic("Call folder for \(callID) not written: \(error.localizedDescription)")
            return
        }

        let audio = preferences?.callFoldersAudio ?? true
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let record = ExportRecord(path: relative, accurateTranscript: accurate, exportedAt: Date(), audio: audio,
                                  ended: call.endedAt != nil, hadRecap: recap != nil,
                                  hadSpeakers: !(awaitOnQueue { (try? await store.speakers(forCall: callID)) ?? [] } ?? []).isEmpty)
        if let data = try? encoder.encode(record) {
            try? data.write(to: exportRecordURL(callID), options: .atomic)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: exportRecordURL(callID).path)
        }
        lastCallFolder = relative

        // Retrieval: ceremonies are searched by kind — every standup is
        // context for the next — and anything else by its recurring meeting.
        let scope: KnowledgeScope = CallaPersonaCatalog.isCeremony(call.persona) || call.seriesID?.isEmpty != false
            ? .persona(call.persona) : .series(call.seriesID!)
        let title = CallFolderExport.title(for: input) + " — "
            + (call.startedAt.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? "")
        let files = CallFolderExport.files(for: input)
        let transcript = turns.sorted { $0.seq < $1.seq }
            .map { "\($0.isMe ? "Me" : ($0.speaker ?? "Them")): \($0.text)" }.joined(separator: "\n")
        _ = awaitOnQueue {
            try? await store.indexCallHistory(callID: callID, scope: scope, title: title,
                                              summary: files["summary.md"] ?? "", transcript: transcript,
                                              at: call.startedAt ?? Date())
            return true
        }

        if audio, previous?.audio != true || !fileManager.fileExists(atPath: folder.appendingPathComponent("audio").path) {
            let sources = [("mic.wav", "me.m4a"), ("system.wav", "them.m4a")]
            callFolderQueue.async {
                let target = folder.appendingPathComponent("audio", isDirectory: true)
                try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                for (source, name) in sources {
                    let original = directory.appendingPathComponent(source)
                    let output = target.appendingPathComponent(name)
                    guard FileManager.default.fileExists(atPath: original.path),
                          !FileManager.default.fileExists(atPath: output.path),
                          let input = Self.wavWithRepairedHeader(original) else { continue }
                    defer { if input != original { try? FileManager.default.removeItem(at: input) } }
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
                    process.arguments = ["-f", "m4af", "-d", "aac", "-b", "32000", input.path, output.path]
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    try? process.run(); process.waitUntilExit()
                    if process.terminationStatus != 0 { try? FileManager.default.removeItem(at: output) }
                }
                if (try? FileManager.default.contentsOfDirectory(atPath: target.path))?.isEmpty == true {
                    try? FileManager.default.removeItem(at: target)
                }
            }
        }
    }

    /// A recording cut off by a crash or force-quit keeps all its audio but
    /// never gets its final header, so it reads as zero seconds long. Returns
    /// the file itself when the header is right, or a private copy with the
    /// RIFF and data sizes taken from the file's real length.
    fileprivate static func wavWithRepairedHeader(_ url: URL) -> URL? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 4096), header.count >= 44,
              header.prefix(4) == Data("RIFF".utf8),
              let length = try? handle.seekToEnd(), length > 44,
              let dataTag = header.range(of: Data("data".utf8)) else { return nil }
        func uint32(_ offset: Int) -> UInt32 {
            header[header.startIndex + offset ..< header.startIndex + offset + 4]
                .enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) }
        }
        let dataSizeOffset = dataTag.upperBound - header.startIndex
        let dataStart = UInt64(dataSizeOffset + 4)
        let actual = UInt32(clamping: length - dataStart)
        guard uint32(dataSizeOffset) != actual else { return url }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        do {
            try FileManager.default.copyItem(at: url, to: copy)
            let writer = try FileHandle(forWritingTo: copy)
            defer { try? writer.close() }
            func write(_ value: UInt32, at offset: UInt64) throws {
                try writer.seek(toOffset: offset)
                try writer.write(contentsOf: withUnsafeBytes(of: value.littleEndian) { Data($0) })
            }
            try write(UInt32(clamping: length - 8), at: 4)
            try write(actual, at: UInt64(dataSizeOffset))
            return copy
        } catch {
            try? FileManager.default.removeItem(at: copy)
            return nil
        }
    }

    fileprivate static func jsonLines(_ url: URL) -> [[String: Any]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    // MARK: XPC

    func revealCallFolder(_ callID: String, with reply: @escaping (Data) -> Void) {
        queue.async {
            let root = self.callFoldersRoot
            var target = root
            if !callID.isEmpty, let path = self.exportRecord(callID)?.path {
                target = root.appendingPathComponent(path, isDirectory: true)
            }
            try? self.fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = [target.path]
            try? process.run()
            reply(self.encodedStatus())
        }
    }

    /// Writes a folder for every call in the store, oldest first, and indexes
    /// each for retrieval. Safe to repeat: finished exports are skipped.
    func exportPastCalls(with reply: @escaping (Data) -> Void) {
        queue.async {
            guard let store = self.store else { reply(self.encodedStatus()); return }
            let calls = self.awaitOnQueue { (try? await store.calls(limit: 5_000)) ?? [] } ?? []
            let pending = calls.reversed().filter { $0.endedAt != nil && self.exportRecord($0.id) == nil }
            self.copilotResult = pending.isEmpty ? "Every call already has a folder" : "Exporting \(pending.count) calls…"
            for (index, call) in pending.enumerated() {
                self.queue.async {
                    self.exportCallFolder(call.id)
                    self.copilotResult = index == pending.count - 1
                        ? "Exported \(pending.count) calls to Documents/Calls"
                        : "Exporting calls… \(index + 1) of \(pending.count)"
                }
            }
            reply(self.encodedStatus())
        }
    }

    /// The last few calls of one kind, newest first: what each concluded and
    /// what it left open. Capped well under the knowledge limit.
    fileprivate func previousMeetingsDigest(persona: String) -> String? {
        guard let store else { return nil }
        let entries = awaitOnQueue { (try? await store.recentRecaps(persona: persona, limit: 3)) ?? [] } ?? []
        return CallFolderExport.continuity(
            persona: persona, entries: entries.map { ($0.call.startedAt, $0.draft) },
            limit: min(1_500, CallaCopilotCommandValidation.knowledgeLimit))
    }

    /// Creates the folder once so macOS asks for Documents access during
    /// setup rather than at the end of the first real call.
    fileprivate func prepareCallFoldersRoot() -> Bool {
        (try? fileManager.createDirectory(at: callFoldersRoot, withIntermediateDirectories: true)) != nil
    }
}
