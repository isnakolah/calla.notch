import Foundation

/// Versioned, bounded wire contract shared by Calla host, engine, and clients.
/// New fields must be optional or receive defaults until every shipped host has
/// crossed this version.
public enum CallaContract {
    public static let version = 3
}

public enum CallLifecycleState: String, Codable, Sendable, CaseIterable {
    /// The host process exists and is paying its fixed costs. Written before the
    /// model is loaded and before either microphone is open, so the notch can say
    /// "starting" the moment the process is alive rather than after everything is
    /// ready — the gap between those two used to look like a dead button.
    case starting
    case prewarming, ready, capturing, stopping, processingRecap, finished, failed
}

/// Which fixed cost the host is paying right now, for a UI that would otherwise
/// show an unmoving spinner.
///
/// Deliberately a closed enum rather than free text: it is drawn as a checklist,
/// and a stage the panel does not recognise would render as a blank row.
public enum CallStartupStage: String, Codable, Sendable, CaseIterable {
    case launching
    case permissions
    case model
    case capture
    /// Capture is live. The brain may still be warming; `CallStartupProgress`
    /// carries that separately because it never blocks recording.
    case listening
}

/// What the host has finished, for the live panel's startup checklist.
///
/// Every field is "has this landed", never "is this required" — a call runs with
/// a cold brain and no gateway, and the panel has to be able to say so without
/// implying something is broken.
public struct CallStartupProgress: Codable, Sendable, Equatable {
    public var stage: CallStartupStage
    public var modelLoaded: Bool
    public var brainWarm: Bool
    /// Nil when the gateway is not part of this call at all — standby off, or
    /// a purely local call that has not failed over.
    public var gatewayWarm: Bool?

    public init(
        stage: CallStartupStage = .launching,
        modelLoaded: Bool = false,
        brainWarm: Bool = false,
        gatewayWarm: Bool? = nil
    ) {
        self.stage = stage
        self.modelLoaded = modelLoaded
        self.brainWarm = brainWarm
        self.gatewayWarm = gatewayWarm
    }
}

public struct CallCaptureHealth: Codable, Sendable, Equatable {
    public var microphone: Bool
    public var systemAudio: Bool
    public var detail: String?

    public init(microphone: Bool, systemAudio: Bool, detail: String? = nil) {
        self.microphone = microphone
        self.systemAudio = systemAudio
        self.detail = detail
    }
}

public struct CallLifecycleSnapshot: Codable, Sendable, Equatable {
    public var contractVersion: Int
    public var callID: String
    public var generation: Int
    public var state: CallLifecycleState
    public var updatedAt: Date
    public var actionableError: String?
    public var capture: CallCaptureHealth
    public var provider: String?
    /// 0...1 while `processingRecap`; nil otherwise.
    public var recapProgress: Double?
    /// What the host is still paying for. Optional because it is only meaningful
    /// on the way up — a capturing call has nothing left to report — and because
    /// a host older than this field must still decode.
    public var startup: CallStartupProgress?

    public init(
        callID: String,
        generation: Int,
        state: CallLifecycleState,
        updatedAt: Date = Date(),
        actionableError: String? = nil,
        capture: CallCaptureHealth = .init(microphone: false, systemAudio: false),
        provider: String? = nil,
        recapProgress: Double? = nil,
        startup: CallStartupProgress? = nil,
        contractVersion: Int = CallaContract.version
    ) {
        self.contractVersion = contractVersion
        self.callID = callID
        self.generation = generation
        self.state = state
        self.updatedAt = updatedAt
        self.actionableError = actionableError
        self.capture = capture
        self.provider = provider
        self.recapProgress = recapProgress.map { min(1, max(0, $0)) }
        self.startup = startup
    }

    public func accepts(_ event: CallHostEvent) -> Bool {
        event.callID == callID && event.generation == generation && event.contractVersion == contractVersion
    }
}

public enum CallHostCommandKind: String, Codable, Sendable {
    case start, release, stop, snapshot, answer
}

public struct CallHostCommand: Codable, Sendable, Equatable {
    public var contractVersion: Int
    public var callID: String
    public var generation: Int
    public var kind: CallHostCommandKind
    /// Bounded selected transcript/manual text for `answer`; nil otherwise.
    public var text: String?
    /// Optional identity for coordinated requests and safe retries.
    public var questionID: UUID?
    public var codingEvidence: CodingDialogueEvidence?

    public init(callID: String, generation: Int, kind: CallHostCommandKind,
                text: String? = nil, questionID: UUID? = nil, contractVersion: Int = CallaContract.version) {
        self.contractVersion = contractVersion; self.callID = callID
        self.generation = generation; self.kind = kind; self.text = text
        self.questionID = questionID
    }
}

public enum CallHostEventKind: String, Codable, Sendable {
    case ready, captureState, answer, recapProgress, finished, fatal
}

public struct CallHostEvent: Codable, Sendable, Equatable {
    public var contractVersion: Int
    public var callID: String
    public var generation: Int
    public var kind: CallHostEventKind
    public var snapshot: CallLifecycleSnapshot

    public init(callID: String, generation: Int, kind: CallHostEventKind,
                snapshot: CallLifecycleSnapshot, contractVersion: Int = CallaContract.version) {
        self.contractVersion = contractVersion; self.callID = callID
        self.generation = generation; self.kind = kind; self.snapshot = snapshot
    }
}

public enum CallQuestionKind: String, Codable, Sendable { case direct, imperative, manual }
public enum CallQuestionState: String, Codable, Sendable {
    case detected, needsConfirmation, queued, answering, answered, superseded, failed, dismissed
}

public struct CallQuestion: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var fromSeq: Int
    public var toSeq: Int
    public var prompt: String
    public var kind: CallQuestionKind
    public var confidence: Double
    public var state: CallQuestionState
    public var answerID: String?
    public var supersessionReason: String?
    public var callID: String?
    public var generation: Int?
    public var utteranceID: String?
    public var detectedAt: Date
    public var speechEndedAt: Date?
    public var failure: String?

    public init(id: UUID = UUID(), fromSeq: Int, toSeq: Int, prompt: String, kind: CallQuestionKind,
                confidence: Double, state: CallQuestionState = .queued, answerID: String? = nil,
                supersessionReason: String? = nil, callID: String? = nil,
                generation: Int? = nil, utteranceID: String? = nil,
                detectedAt: Date = Date(), speechEndedAt: Date? = nil,
                failure: String? = nil) {
        self.id = id; self.fromSeq = fromSeq; self.toSeq = toSeq; self.prompt = prompt
        self.kind = kind; self.confidence = min(1, max(0, confidence)); self.state = state
        self.answerID = answerID; self.supersessionReason = supersessionReason
        self.callID = callID; self.generation = generation; self.utteranceID = utteranceID
        self.detectedAt = detectedAt; self.speechEndedAt = speechEndedAt; self.failure = failure
    }
}

/// Ordered queue. Only explicitly marked continuation turns may supersede an
/// unanswered question; unrelated questions always remain in order.
public struct CallQuestionQueue: Sendable, Equatable {
    public private(set) var questions: [CallQuestion] = []

    public init() {}

    public mutating func enqueue(_ question: CallQuestion, continuing: Bool = false) {
        if continuing, let index = questions.lastIndex(where: { $0.state == .queued }) {
            questions[index].state = .superseded
            questions[index].supersessionReason = "continued by \(question.id.uuidString)"
        }
        questions.append(question)
    }

    public mutating func beginNext() -> CallQuestion? {
        guard let index = questions.firstIndex(where: { $0.state == .queued }) else { return nil }
        questions[index].state = .answering
        return questions[index]
    }

    public mutating func answer(_ id: UUID, answerID: String) {
        guard let index = questions.firstIndex(where: { $0.id == id && $0.state == .answering }) else { return }
        questions[index].state = .answered; questions[index].answerID = answerID
    }

    public mutating func dismiss(_ id: UUID) {
        guard let index = questions.firstIndex(where: { $0.id == id && [.queued, .answering].contains($0.state) }) else { return }
        questions[index].state = .dismissed
    }

    public mutating func confirm(_ id: UUID, editedPrompt: String? = nil) {
        guard let index = questions.firstIndex(where: { $0.id == id && $0.state == .needsConfirmation }) else { return }
        if let editedPrompt {
            let value = editedPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { questions[index].prompt = String(value.prefix(1_200)) }
        }
        questions[index].state = .queued
    }

    public mutating func fail(_ id: UUID, reason: String) {
        guard let index = questions.firstIndex(where: { $0.id == id && [.queued, .answering].contains($0.state) }) else { return }
        questions[index].state = .failed
        questions[index].failure = String(reason.prefix(240))
    }
}

// MARK: - Live Call v3 answer and knowledge contract

public enum IntelligencePriority: Int, Codable, Sendable, Comparable, CaseIterable {
    case offline = 0, background = 1, high = 2, urgent = 3
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum IntelligenceQueuePolicy: String, Codable, Sendable {
    /// Keep every item in arrival order. Live questions use this.
    case fifo
    /// Keep only newest pending item for same session/task. Running summary uses this.
    case coalescing
}

public enum CallGrounding: String, Codable, Sendable {
    case transcript, callPack = "call_pack", mixed, generalKnowledge = "general_knowledge", refused
}

public enum KnowledgeCitationKind: String, Codable, Sendable {
    case transcript, document, note, generalKnowledge = "general_knowledge"
}

public struct KnowledgeCitation: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: KnowledgeCitationKind
    public var label: String
    public var sourceID: String?
    public var revision: String?
    public var page: Int?
    public var section: String?
    public var fromSeq: Int?
    public var toSeq: Int?

    public init(id: String, kind: KnowledgeCitationKind, label: String,
                sourceID: String? = nil, revision: String? = nil, page: Int? = nil,
                section: String? = nil, fromSeq: Int? = nil, toSeq: Int? = nil) {
        self.id = id; self.kind = kind; self.label = label; self.sourceID = sourceID
        self.revision = revision; self.page = page; self.section = section
        self.fromSeq = fromSeq; self.toSeq = toSeq
    }
}

public struct CallAnswerTiming: Codable, Sendable, Equatable {
    public var speechEndedAt: Date?
    public var questionDetectedAt: Date
    public var requestStartedAt: Date
    public var providerCompletedAt: Date
    public var enginePublishedAt: Date?
    public var renderedAt: Date?

    public init(speechEndedAt: Date? = nil, questionDetectedAt: Date = Date(),
                requestStartedAt: Date = Date(), providerCompletedAt: Date = Date(),
                enginePublishedAt: Date? = nil, renderedAt: Date? = nil) {
        self.speechEndedAt = speechEndedAt; self.questionDetectedAt = questionDetectedAt
        self.requestStartedAt = requestStartedAt; self.providerCompletedAt = providerCompletedAt
        self.enginePublishedAt = enginePublishedAt; self.renderedAt = renderedAt
    }

    public var speechEndToPublishMilliseconds: Int? {
        guard let speechEndedAt, let enginePublishedAt else { return nil }
        return max(0, Int((enginePublishedAt.timeIntervalSince(speechEndedAt) * 1_000).rounded()))
    }
}

public struct CallAnswer: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var callID: String
    public var generation: Int
    public var questionID: UUID
    public var question: String
    public var main: String
    public var points: [String]
    public var warning: String?
    public var grounding: CallGrounding
    public var citations: [KnowledgeCitation]
    public var provider: String
    public var model: String
    public var timing: CallAnswerTiming

    public init(id: String = "answer-" + UUID().uuidString.lowercased(), callID: String,
                generation: Int, questionID: UUID, question: String, main: String,
                points: [String] = [], warning: String? = nil,
                grounding: CallGrounding, citations: [KnowledgeCitation] = [],
                provider: String, model: String, timing: CallAnswerTiming = .init()) {
        self.id = id; self.callID = callID; self.generation = generation
        self.questionID = questionID; self.question = Self.words(question, limit: 160)
        self.main = Self.words(main, limit: 24)
        self.points = Array(points.prefix(3)).map { Self.words($0, limit: 10) }.filter { !$0.isEmpty }
        self.warning = warning.map { Self.words($0, limit: 24) }.flatMap { $0.isEmpty ? nil : $0 }
        self.grounding = grounding; self.citations = Self.validated(citations)
        self.provider = String(provider.prefix(80)); self.model = String(model.prefix(120)); self.timing = timing
    }

    /// One-release adapter. Archived `headline/angles/confirm` rows remain readable;
    /// storage is never rewritten.
    public init(legacyID: String, callID: String, afterSeq: Int, headline: String,
                angles: [String], confirm: [String], latencyMs: Int, at: Date) {
        let questionID = UUID()
        self.init(id: legacyID, callID: callID, generation: 0, questionID: questionID,
                  question: "Earlier answer after transcript turn \(afterSeq)", main: headline,
                  points: angles, warning: confirm.first, grounding: .transcript,
                  citations: [.init(id: "transcript-\(afterSeq)", kind: .transcript,
                                    label: "Transcript", toSeq: afterSeq)],
                  provider: "Legacy", model: "unknown",
                  timing: .init(questionDetectedAt: at.addingTimeInterval(-Double(latencyMs) / 1_000),
                                requestStartedAt: at.addingTimeInterval(-Double(latencyMs) / 1_000),
                                providerCompletedAt: at))
    }

    private static func words(_ value: String, limit: Int) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).prefix(limit).joined(separator: " ")
    }

    private static func validated(_ values: [KnowledgeCitation]) -> [KnowledgeCitation] {
        var seen = Set<String>()
        return values.prefix(8).filter { citation in
            guard !citation.id.isEmpty, !citation.label.isEmpty else { return false }
            return seen.insert(citation.id).inserted
        }
    }
}

public struct CallKnowledgeChunk: Codable, Sendable, Equatable, Identifiable {
    public var id: String { citation.id }
    public var citation: KnowledgeCitation
    public var text: String

    public init(citation: KnowledgeCitation, text: String) {
        self.citation = citation
        self.text = String(text.prefix(1_200))
    }
}

public struct CallKnowledgeSnapshot: Codable, Sendable, Equatable, Identifiable {
    public var id: String { callID }
    public var callID: String
    public var generation: Int
    public var createdAt: Date
    public var sourceRevisions: [String: String]
    public var chunks: [CallKnowledgeChunk]
    public var glossary: [String]

    public init(callID: String, generation: Int, createdAt: Date = Date(),
                sourceRevisions: [String: String], chunks: [CallKnowledgeChunk],
                glossary: [String] = []) {
        self.callID = callID; self.generation = generation; self.createdAt = createdAt
        self.sourceRevisions = sourceRevisions; self.chunks = chunks
        self.glossary = Array(glossary.map { String($0.prefix(80)) }.filter { !$0.isEmpty }.prefix(120))
    }
}

public enum CallEventKind: String, Codable, Sendable {
    case lifecycle, transcript, transcriptGap = "transcript_gap", question, answer, failure, replayComplete = "replay_complete"
}

public struct CallTranscriptEvent: Codable, Sendable, Equatable {
    public var utteranceID: String
    public var transcriptSequence: Int
    public var source: String
    public var startSeconds: Double
    public var endSeconds: Double
    public var text: String
    public var confidence: Double?

    public init(utteranceID: String, transcriptSequence: Int, source: String,
                startSeconds: Double, endSeconds: Double, text: String,
                confidence: Double? = nil) {
        self.utteranceID = String(utteranceID.prefix(80))
        self.transcriptSequence = transcriptSequence
        self.source = String(source.prefix(16))
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = String(text.prefix(1_600))
        self.confidence = confidence
    }
}

/// Bounded persistent-socket/XPC event. Payload fields stay typed and optional so
/// additive contract updates do not break older observers.
public struct CallEvent: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var contractVersion: Int
    public var callID: String
    public var generation: Int
    public var sequence: Int
    public var kind: CallEventKind
    public var at: Date
    public var lifecycle: CallLifecycleSnapshot?
    public var transcript: CallTranscriptEvent?
    public var question: CallQuestion?
    public var answer: CallAnswer?
    public var message: String?

    public init(id: String = UUID().uuidString, callID: String, generation: Int,
                sequence: Int, kind: CallEventKind, at: Date = Date(),
                lifecycle: CallLifecycleSnapshot? = nil, transcript: CallTranscriptEvent? = nil,
                question: CallQuestion? = nil,
                answer: CallAnswer? = nil, message: String? = nil,
                contractVersion: Int = CallaContract.version) {
        self.id = id; self.contractVersion = contractVersion; self.callID = callID
        self.generation = generation; self.sequence = sequence; self.kind = kind; self.at = at
        self.lifecycle = lifecycle; self.transcript = transcript
        self.question = question; self.answer = answer
        self.message = message.map { String($0.prefix(400)) }
    }
}

/// When the running account of a call is brought up to date.
///
/// It used to need three statements, or twenty seconds of silence, or a full
/// minute — and in an ordinary conversation none of those arrive quickly. One
/// person talking in a single long stretch is *one* statement, so the account
/// sat still until the sixty-second ceiling fired. The panel's summary was
/// routinely a minute behind what had just been said, which is the same as not
/// having one.
///
/// The unit that matters is a turn: somebody said a thing and stopped. That is
/// what `settleInterval` detects — a short pause after the last statement, long
/// enough that a sentence broken into two segments is still one chunk, short
/// enough that the account is current by the time anyone looks at it.
///
/// The other three rules stay as backstops for the cases a pause never comes:
/// a decision or commitment goes straight through, a talker who never stops for
/// breath is closed every `burstStatements`, and `maximumInterval` is the
/// ceiling nothing may exceed.
public struct CallSummaryTrigger: Sendable, Equatable {
    /// Nothing waits longer than this, whatever else is happening.
    public static let maximumInterval: TimeInterval = 60
    /// A turn has ended when nothing more has arrived for this long.
    ///
    /// Not zero: the segmenter emits a trailed-off clause and its continuation
    /// as two statements a beat apart, and summarising between them would spend
    /// a request on half a sentence and put half a thought in the account.
    public static let settleInterval: TimeInterval = 2.5
    /// Somebody who never pauses still gets summarised this often.
    public static let burstStatements = 3
    /// Retained under its old name for any caller that read it. The quiet rule
    /// is now `settleInterval`, which is the same idea at a usable length.
    @available(*, deprecated, renamed: "settleInterval")
    public static let quietInterval: TimeInterval = settleInterval

    public var statementsSinceSummary = 0
    public var lastSummaryAt: Date
    public var lastStatementAt: Date?

    public init(now: Date = Date()) { lastSummaryAt = now }

    public mutating func recordStatement(at date: Date = Date()) { statementsSinceSummary += 1; lastStatementAt = date }
    public mutating func didSummarize(at date: Date = Date()) { statementsSinceSummary = 0; lastSummaryAt = date }

    public func isDue(now: Date = Date(), commitmentOrDecision: Bool, answerInFlight: Bool) -> Bool {
        guard !answerInFlight, statementsSinceSummary > 0 else { return false }
        if commitmentOrDecision { return true }
        if statementsSinceSummary >= Self.burstStatements { return true }
        // The turn has ended: this is the ordinary path, and the one that makes
        // the account keep pace with the conversation.
        if let lastStatementAt, now.timeIntervalSince(lastStatementAt) >= Self.settleInterval {
            return true
        }
        return now.timeIntervalSince(lastSummaryAt) >= Self.maximumInterval
    }
}

public struct SourcedCallItem: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case decision, commitment, actionItem, openQuestion }
    public var id: String
    public var kind: Kind
    public var text: String
    public var fromSeq: Int
    public var toSeq: Int
    public var resolved: Bool

    public init(id: String, kind: Kind, text: String, fromSeq: Int, toSeq: Int, resolved: Bool = false) {
        self.id = id; self.kind = kind; self.text = text; self.fromSeq = fromSeq; self.toSeq = toSeq; self.resolved = resolved
    }
}

public struct CallRecapDraft: Codable, Sendable, Equatable, Identifiable {
    public enum ReviewState: String, Codable, Sendable { case pending, approved, rejected }
    public var id: String { callID }
    public var callID: String
    public var overview: String
    public var items: [SourcedCallItem]
    public var provider: String?
    public var model: String?
    public var failure: String?
    public var reviewState: ReviewState

    public init(callID: String, overview: String, items: [SourcedCallItem], provider: String? = nil,
                model: String? = nil, failure: String? = nil, reviewState: ReviewState = .pending) {
        self.callID = callID; self.overview = overview; self.items = items; self.provider = provider
        self.model = model; self.failure = failure; self.reviewState = reviewState
    }
}

/// When the gateway websocket is opened on a call the local brain is answering.
///
/// Was not a choice at all: the socket connected on every call and received every
/// turn, whether or not the gateway was allowed to answer, and `start()` awaited
/// its handshake before opening either microphone. That cost ~1s of startup for
/// something usually discarded, and shipped the transcript off the Mac even with
/// fallback switched off.
///
/// None of these modes ever block capture — the difference is only *when* the
/// connection is made, and therefore what the gateway knows if it has to take over.
public enum GatewayStandby: String, Codable, Sendable, CaseIterable {
    /// Never opened. Nothing about the call leaves this Mac. A local brain that
    /// fails simply reports the failure — there is nowhere to hand over to.
    case off
    /// Opened only if the local brain gives up, then backfilled with the recent
    /// transcript so the handover is not starting blind. Costs a handshake at the
    /// moment of failure, which is the trade for a call that stays local while it
    /// is going well.
    case onFailure
    /// Opened in the background as the call starts and fed every turn, so a
    /// handover is instant and complete. The default, and what the code did
    /// before this was a setting — minus the blocking.
    case warm

    /// Tolerates the hyphenated spelling as well as the camel-cased raw value.
    ///
    /// The raw value is what goes in JSON and in `UserDefaults`; `on-failure` is
    /// what reads correctly on a command line. Accepting both here means the two
    /// can never drift into a mode that silently resolves to the default.
    public static func named(_ raw: String?) -> GatewayStandby? {
        guard let raw else { return nil }
        switch raw {
        case "off": return .off
        case "on-failure", "onFailure": return .onFailure
        case "warm": return .warm
        default: return nil
        }
    }

    /// The spelling used on the host's command line.
    public var argument: String { self == .onFailure ? "on-failure" : rawValue }
}
