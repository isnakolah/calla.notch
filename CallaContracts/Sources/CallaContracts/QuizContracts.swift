import Foundation

/// Additive Screen Quiz wire contract. Call contract version remains unchanged.
public enum QuizContract {
    public static let version = 1
    public static let maximumCaptureBytes = 3 * 1_024 * 1_024
    public static let maximumViewports = 4
    public static let maximumContextBytes = 256 * 1_024
    /// How far back the live panel can step through a session's answers.
    public static let maximumAnswerHistory = 20
    /// The council is the user's to size, but not without a ceiling: every voter
    /// is a resident `agy` child of roughly 190 MB.
    public static let maximumVoters = 8
    public static let defaultCaptureResolution = QuizCaptureResolution.fullHD
}

public enum QuizCaptureResolution: String, Codable, Sendable, CaseIterable, Identifiable {
    case hd720 = "720p"
    case hd900 = "900p"
    case fullHD = "1080p"
    case twoK = "2k"
    case fourteenForty = "1440p"
    case fourK = "4k"
    case fiveK = "5k"
    case sixK = "6k"
    case eightK = "8k"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .hd720: "720p"
        case .hd900: "900p"
        case .fullHD: "1080p"
        case .twoK: "2K"
        case .fourteenForty: "1440p"
        case .fourK: "4K"
        case .fiveK: "5K"
        case .sixK: "6K"
        case .eightK: "8K"
        }
    }

    public var maximumWidth: Int {
        switch self {
        case .hd720: 1_280
        case .hd900: 1_600
        case .fullHD: 1_920
        case .twoK: 2_048
        case .fourteenForty: 2_560
        case .fourK: 3_840
        case .fiveK: 5_120
        case .sixK: 6_016
        case .eightK: 7_680
        }
    }

    public var maximumHeight: Int {
        switch self {
        case .hd720: 720
        case .hd900: 900
        case .fullHD, .twoK: 1_080
        case .fourteenForty: 1_440
        case .fourK: 2_160
        case .fiveK: 2_880
        case .sixK: 3_384
        case .eightK: 4_320
        }
    }
}

/// How much of the pipeline a frame needs.
///
/// The watcher compares consecutive frames to decide when the screen has
/// settled on a new question. That comparison reads only `tileHashes`,
/// `visualHash` and `normalizedOCR` — it never looks at the JPEG. Encoding one
/// anyway meant every discarded frame paid a full JPEG encode (up to nine, when
/// the first exceeded the 3 MiB cap) plus a base64 round-trip through JSON, at
/// two frames a second, for bytes nothing read.
///
/// `probe` is that comparison frame. `solve` is the one frame per question that
/// actually reaches the council, and it keeps the full-quality encode and the
/// two-pass accurate OCR the answer depends on.
public enum QuizCaptureDetail: String, Sendable, Equatable {
    case probe
    case solve

    public var needsJPEG: Bool { self == .solve }
    /// Stability only needs OCR good enough for a word-overlap ratio; the
    /// council needs every answer row.
    public var needsAccurateOCR: Bool { self == .solve }
}

public struct QuizWindowTarget: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: String { "\(processID):\(windowID):\(bundleID)" }
    public let processID: Int32
    public let windowID: UInt32
    public let bundleID: String
    public let applicationName: String
    public let windowTitle: String
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(processID: Int32, windowID: UInt32, bundleID: String,
                applicationName: String, windowTitle: String,
                pixelWidth: Int, pixelHeight: Int) {
        self.processID = processID
        self.windowID = windowID
        self.bundleID = String(bundleID.prefix(240))
        self.applicationName = String(applicationName.prefix(160))
        self.windowTitle = String(windowTitle.prefix(320))
        self.pixelWidth = max(0, pixelWidth)
        self.pixelHeight = max(0, pixelHeight)
    }
}

public enum QuizWindowSelection {
    /// Restore only explicit user intent. Current exact identity wins, followed
    /// by remembered exact identity, then stable app/title fallback after app
    /// relaunch. No match means no selection; first window is never assumed.
    public static func resolve(
        windows: [QuizWindowTarget],
        currentID: String?,
        rememberedID: String,
        rememberedBundleID: String,
        rememberedWindowTitle: String
    ) -> QuizWindowTarget? {
        if let currentID, let current = windows.first(where: { $0.id == currentID }) {
            return current
        }
        if !rememberedID.isEmpty,
           let exact = windows.first(where: { $0.id == rememberedID }) {
            return exact
        }
        guard !rememberedBundleID.isEmpty, !rememberedWindowTitle.isEmpty else { return nil }
        return windows.first {
            $0.bundleID == rememberedBundleID && $0.windowTitle == rememberedWindowTitle
        }
    }
}

public struct QuizModelSelection: Codable, Sendable, Equatable, Hashable {
    public let modelID: String
    public let effort: String

    public init(modelID: String, effort: String = "high") {
        self.modelID = String(modelID.prefix(160))
        self.effort = effort
    }
}

public enum QuizContextScope: String, Codable, Sendable, CaseIterable {
    case event, series
}

public struct QuizPermissionReadiness: Codable, Sendable, Equatable {
    public let screenRecording: Bool
    public let accessibility: Bool
    public init(screenRecording: Bool, accessibility: Bool) {
        self.screenRecording = screenRecording
        self.accessibility = accessibility
    }
}

public struct QuizContextReference: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let id: String
    public let revision: String
    public let title: String
    public let scope: QuizContextScope
    public let kind: String
    public let text: String

    public init(id: String, revision: String, title: String, scope: QuizContextScope,
                kind: String, text: String) {
        self.id = String(id.prefix(160))
        self.revision = String(revision.prefix(160))
        self.title = String(title.prefix(240))
        self.scope = scope
        self.kind = String(kind.prefix(40))
        self.text = String(text.prefix(QuizContract.maximumContextBytes))
    }
}

public struct QuizSessionConfiguration: Codable, Sendable, Equatable {
    public let contractVersion: Int
    public let sessionID: String
    public let target: QuizWindowTarget
    public let eventID: String?
    public let eventLabel: String?
    public let context: [QuizContextReference]
    public let excludedContextIDs: [String]
    /// The legacy flat council, kept so a version-1 configuration still decodes
    /// and so a profile-less setup has something to fall back to.
    public let voters: [QuizModelSelection]
    public let arbiter: QuizModelSelection
    /// Optional preserves decoding of version-1 configurations created before
    /// capture resolution became user-configurable.
    public let captureResolution: QuizCaptureResolution?
    /// One council per mode, keyed by `QuizMode.rawValue`.
    ///
    /// Optional for the same reason `captureResolution` is: a configuration
    /// written before modes existed has to keep working, and it does — the
    /// legacy `voters`/`arbiter` pair becomes every mode's council.
    public let profiles: [String: QuizModeProfile]?
    /// Which mode's council is spawned at session start. The others are spawned
    /// when a question of that mode first appears.
    public let warmMode: QuizMode?
    /// Start spawning a council while the screen is still settling, rather than
    /// after. Optional so a version-1 configuration keeps the old behaviour.
    public let speculative: Bool?

    public var effectiveCaptureResolution: QuizCaptureResolution {
        captureResolution ?? QuizContract.defaultCaptureResolution
    }

    public var effectiveWarmMode: QuizMode { warmMode ?? .choice }

    public var speculativeSpawn: Bool { speculative ?? false }

    /// The council for a mode, always answering — falling back to the flat
    /// legacy council when this configuration carries no profile for it.
    public func profile(for mode: QuizMode) -> QuizModeProfile {
        if let profiles, let profile = profiles[mode.rawValue], !profile.voters.isEmpty {
            return profile
        }
        return QuizModeProfile(voters: voters, arbiter: arbiter, strategy: .unanimous)
    }

    public func profile(for kind: QuizQuestionKind) -> QuizModeProfile {
        profile(for: QuizMode.mode(for: kind))
    }

    /// Every model this configuration could ask for, which is what the engine
    /// checks against the AGY catalogue before it starts.
    public var referencedModelIDs: Set<String> {
        var found = Set(voters.map(\.modelID))
        found.insert(arbiter.modelID)
        for profile in profiles?.values ?? [:].values {
            found.formUnion(profile.voters.map(\.modelID))
            if let arbiter = profile.arbiter { found.insert(arbiter.modelID) }
        }
        return found
    }

    public init(sessionID: String = UUID().uuidString.lowercased(), target: QuizWindowTarget,
                eventID: String? = nil, eventLabel: String? = nil,
                context: [QuizContextReference] = [], excludedContextIDs: [String] = [],
                voters: [QuizModelSelection], arbiter: QuizModelSelection,
                captureResolution: QuizCaptureResolution? = QuizContract.defaultCaptureResolution,
                profiles: [String: QuizModeProfile]? = nil, warmMode: QuizMode? = nil,
                speculative: Bool? = nil,
                contractVersion: Int = QuizContract.version) {
        self.contractVersion = contractVersion
        self.sessionID = sessionID
        self.target = target
        self.eventID = eventID.map { String($0.prefix(240)) }
        self.eventLabel = eventLabel.map { String($0.prefix(240)) }
        self.context = Array(context.prefix(128))
        self.excludedContextIDs = Array(excludedContextIDs.prefix(128))
        self.voters = Array(voters.prefix(QuizContract.maximumVoters))
        self.arbiter = arbiter
        self.captureResolution = captureResolution
        self.profiles = profiles
        self.warmMode = warmMode
        self.speculative = speculative
    }
}

public enum QuizSessionState: String, Codable, Sendable, CaseIterable {
    case starting, preparingWorkers, watching, collecting, solving, retrying, arbitrating, answered
    case paused, stopping, finished, failed

    public var isRunning: Bool {
        ![.finished, .failed].contains(self)
    }
}

public enum QuizQuestionKind: String, Codable, Sendable, CaseIterable {
    case singleChoice, multipleChoice, boolean, text, numeric, code, image, diagram, unknown
}

/// How a council decides it has an answer.
///
/// Strict unanimity was the only rule, and it is the reason a single slow voter
/// holds up an answer the rest already agree on: `decide` could not return until
/// every voter had. Which rule suits a question depends on the question, so this
/// is chosen per mode.
public enum QuizAnswerStrategy: String, Codable, Sendable, Equatable, CaseIterable {
    /// The first answer back wins. No cross-check; the fastest a council can be,
    /// and the natural rule for a council of one.
    case first
    /// A majority agreeing is enough; the stragglers are cancelled.
    case majority
    /// Every voter must agree, or the arbiter decides.
    case unanimous

    public var label: String {
        switch self {
        case .first: "First answer"
        case .majority: "Majority"
        case .unanimous: "Unanimous"
        }
    }

    /// How many matching voters this rule needs out of `count`.
    public func requiredAgreement(of count: Int) -> Int {
        let total = max(1, count)
        switch self {
        case .first: return 1
        case .majority: return (total + 1) / 2
        case .unanimous: return total
        }
    }
}

/// The kinds of question that want different treatment, grouped.
///
/// One profile per `QuizQuestionKind` would be nine blocks of settings that mostly
/// ended up identical. These five are the groupings that actually differ: a
/// multiple choice wants a small fast council, a code exercise wants depth.
/// Adding a sixth is a case here and a row in Settings.
public enum QuizMode: String, Codable, Sendable, Equatable, CaseIterable, Identifiable {
    case choice
    case numeric
    case open
    case visual
    case fallback

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .choice: "Multiple choice"
        case .numeric: "Numeric"
        case .open: "Written and code"
        case .visual: "Image and diagram"
        case .fallback: "Anything else"
        }
    }

    public var detail: String {
        switch self {
        case .choice: "One right option out of several, or true and false."
        case .numeric: "A value, with or without a unit."
        case .open: "Prose or code the model has to compose."
        case .visual: "The question is in the picture."
        case .fallback: "Used when the kind could not be determined."
        }
    }

    public static func mode(for kind: QuizQuestionKind) -> QuizMode {
        switch kind {
        case .singleChoice, .multipleChoice, .boolean: .choice
        case .numeric: .numeric
        case .text, .code: .open
        case .image, .diagram: .visual
        case .unknown: .fallback
        }
    }
}

/// One mode's council: who answers, how hard they think, and what settles it.
public struct QuizModeProfile: Codable, Sendable, Equatable {
    public let voters: [QuizModelSelection]
    /// `nil` means this mode has no arbiter; a council that cannot agree reports
    /// that it could not, rather than escalating.
    public let arbiter: QuizModelSelection?
    public let strategy: QuizAnswerStrategy
    /// Route this mode through the resident `agy agentapi` host. Much faster, but
    /// it only accepts coarse Gemini tiers, so the model actually answering is
    /// not the one named in `voters`.
    public let turbo: Bool
    /// A stronger model that takes the published answer and tries to beat it.
    ///
    /// The council answers as fast as it can; the refiner then reasons properly
    /// about the same question with that answer in hand, and returns a better
    /// implementation plus why it is better. Its result arrives as another
    /// revision of the same question rather than replacing what is on screen.
    public let refiner: QuizModelSelection?

    public init(voters: [QuizModelSelection], arbiter: QuizModelSelection? = nil,
                strategy: QuizAnswerStrategy = .unanimous, turbo: Bool = false,
                refiner: QuizModelSelection? = nil) {
        self.voters = Array(voters.prefix(QuizContract.maximumVoters))
        self.arbiter = arbiter
        self.strategy = strategy
        self.turbo = turbo
        self.refiner = refiner
    }

    public var hasRefiner: Bool { refiner != nil }

    public var hasArbiter: Bool { arbiter != nil }

    // Decoding a profile written before `turbo` existed.
    private enum CodingKeys: String, CodingKey {
        case voters, arbiter, strategy, turbo, refiner
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            voters: try container.decode([QuizModelSelection].self, forKey: .voters),
            arbiter: try container.decodeIfPresent(QuizModelSelection.self, forKey: .arbiter),
            strategy: try container.decodeIfPresent(QuizAnswerStrategy.self, forKey: .strategy)
                ?? .unanimous,
            turbo: try container.decodeIfPresent(Bool.self, forKey: .turbo) ?? false,
            refiner: try container.decodeIfPresent(QuizModelSelection.self, forKey: .refiner))
    }
}

public struct QuizCaptureFrame: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let sessionID: String
    public let questionID: String
    public let questionGeneration: Int
    public let captureGeneration: Int
    public let viewportIndex: Int
    public let capturedAt: Date
    public let width: Int
    public let height: Int
    public let jpeg: Data
    public let normalizedOCR: String
    public let fingerprint: String
    /// See `QuizHostFrame.headlines`.
    public let headlines: [String]?

    public init(id: String = UUID().uuidString.lowercased(), sessionID: String,
                questionID: String, questionGeneration: Int, captureGeneration: Int,
                viewportIndex: Int, capturedAt: Date = Date(), width: Int, height: Int,
                jpeg: Data, normalizedOCR: String, fingerprint: String,
                headlines: [String]? = nil) {
        self.id = id
        self.sessionID = sessionID
        self.questionID = questionID
        self.questionGeneration = max(0, questionGeneration)
        self.captureGeneration = max(0, captureGeneration)
        self.viewportIndex = max(0, min(QuizContract.maximumViewports - 1, viewportIndex))
        self.capturedAt = capturedAt
        self.width = max(0, width)
        self.height = max(0, height)
        self.jpeg = jpeg
        self.normalizedOCR = String(normalizedOCR.prefix(32_000))
        self.fingerprint = String(fingerprint.prefix(128))
        self.headlines = headlines.map { Array($0.prefix(12).map { String($0.prefix(200)) }) }
    }

    public var isBounded: Bool {
        contractVersionIsValid && jpeg.count <= QuizContract.maximumCaptureBytes && width > 0 && height > 0
    }

    private var contractVersionIsValid: Bool { !sessionID.isEmpty && !questionID.isEmpty }
}

/// One bounded host-to-engine watcher frame. Engine runs stability detection
/// before converting it to durable `QuizCaptureFrame`.
public struct QuizHostFrame: Codable, Sendable, Equatable {
    public let contractVersion: Int
    public let target: QuizWindowTarget
    public let capturedAt: Date
    public let captureGeneration: Int
    public let width: Int
    public let height: Int
    public let jpeg: Data
    public let normalizedOCR: String
    public let tileHashes: [UInt64]
    public let visualHash: UInt64
    public let anchors: [String]
    /// The first few OCR lines, as written — case and punctuation intact.
    ///
    /// `normalizedOCR` is lower-cased with punctuation flattened, which is right
    /// for fingerprinting and useless for showing a reader what the question was:
    /// it turns a title into "2091 removing minimum and maximum from array".
    /// Carried only on the frame that reaches the council, so a probe pays
    /// nothing for it.
    public let headlines: [String]?

    public init(target: QuizWindowTarget, capturedAt: Date = Date(), captureGeneration: Int,
                width: Int, height: Int, jpeg: Data, normalizedOCR: String,
                tileHashes: [UInt64], visualHash: UInt64, anchors: [String],
                headlines: [String]? = nil,
                contractVersion: Int = QuizContract.version) {
        self.contractVersion = contractVersion
        self.target = target
        self.capturedAt = capturedAt
        self.captureGeneration = captureGeneration
        self.width = width
        self.height = height
        self.jpeg = jpeg
        self.normalizedOCR = String(normalizedOCR.prefix(32_000))
        self.tileHashes = Array(tileHashes.prefix(4_096))
        self.visualHash = visualHash
        self.anchors = Array(anchors.prefix(64))
        self.headlines = headlines.map { Array($0.prefix(12).map { String($0.prefix(200)) }) }
    }

    public var isBounded: Bool {
        contractVersion == QuizContract.version && jpeg.count <= QuizContract.maximumCaptureBytes
            && width > 0 && height > 0 && target.windowID > 0 && target.processID > 0
    }
}

public struct QuizResearchSource: Codable, Sendable, Equatable, Hashable {
    public let url: String
    public let title: String?
    public let query: String?
    public let accessedAt: Date

    public init(url: String, title: String? = nil, query: String? = nil, accessedAt: Date = Date()) {
        self.url = String(url.prefix(2_048))
        self.title = title.map { String($0.prefix(320)) }
        self.query = query.map { String($0.prefix(320)) }
        self.accessedAt = accessedAt
    }
}

public struct QuizWorkerIdentity: Codable, Sendable, Equatable, Hashable {
    public let slot: Int
    public let modelID: String
    public let effort: String
    public let conversationID: String
    public let numberOfTurns: Int

    public init(slot: Int, modelID: String, effort: String,
                conversationID: String, numberOfTurns: Int) {
        self.slot = slot
        self.modelID = String(modelID.prefix(160))
        self.effort = effort
        self.conversationID = String(conversationID.prefix(160))
        self.numberOfTurns = numberOfTurns
    }

    public var provesIsolation: Bool { !conversationID.isEmpty && numberOfTurns == 1 }
}

public struct QuizVote: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let sessionID: String
    public let questionID: String
    public let questionGeneration: Int
    public let answer: String
    public let confidence: Int
    public let worker: QuizWorkerIdentity
    public let sources: [QuizResearchSource]

    public init(id: String = UUID().uuidString.lowercased(), sessionID: String,
                questionID: String, questionGeneration: Int, answer: String,
                confidence: Int, worker: QuizWorkerIdentity,
                sources: [QuizResearchSource] = []) {
        self.id = id
        self.sessionID = sessionID
        self.questionID = questionID
        self.questionGeneration = questionGeneration
        self.answer = String(answer.prefix(32_000))
        self.confidence = min(100, max(0, confidence))
        self.worker = worker
        self.sources = Array(sources.prefix(24))
    }
}

/// The reader's verdict on a published answer.
///
/// Crosses the XPC boundary, and is the ground truth confidence calibration is
/// built from — without graded answers a displayed percentage is only the
/// model's own estimate of itself.
public enum QuizAnswerGrade: Int, Codable, Sendable, Equatable, CaseIterable {
    case ungraded = 0
    case correct = 1
    case incorrect = 2
}

public struct QuizFinalAnswer: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let sessionID: String
    public let questionID: String
    public let questionGeneration: Int
    public let kind: QuizQuestionKind
    public let answer: String
    public let confidence: Int
    public let verified: Bool
    public let answeredAt: Date
    /// 0 is what the council published; each refinement pass adds one.
    public let revision: Int
    /// Why this revision is better than the one before it. Refinements only.
    public let rationale: String?
    /// A few words naming the question this answers, so a reader stepping through
    /// a session's answers can tell which is which.
    public let summary: String?
    /// Seconds from noticing the question to publishing this answer.
    ///
    /// Carried on the answer rather than derived from a running clock: the clock
    /// restarts with the next question, so it could never tell a reader what the
    /// answer in front of them had actually cost — and that number is the whole
    /// point when the flow feels slow.
    public let elapsed: Double?

    public var isRefinement: Bool { revision > 0 }

    public init(id: String = UUID().uuidString.lowercased(), sessionID: String,
                questionID: String, questionGeneration: Int, kind: QuizQuestionKind,
                answer: String, confidence: Int, verified: Bool, answeredAt: Date = Date(),
                revision: Int = 0, rationale: String? = nil, summary: String? = nil,
                elapsed: Double? = nil) {
        self.id = id
        self.sessionID = sessionID
        self.questionID = questionID
        self.questionGeneration = questionGeneration
        self.kind = kind
        self.answer = verified ? String(answer.prefix(32_000)) : "Unable to verify"
        self.confidence = verified ? min(100, max(0, confidence)) : 0
        self.verified = verified
        self.answeredAt = answeredAt
        self.revision = max(0, revision)
        self.rationale = verified ? rationale.map { String($0.prefix(4_000)) } : nil
        self.summary = summary.map { String($0.prefix(160)) }
        self.elapsed = elapsed.map { max(0, $0) }
    }

    public static func unable(sessionID: String, questionID: String,
                              generation: Int, kind: QuizQuestionKind = .unknown) -> Self {
        .init(sessionID: sessionID, questionID: questionID, questionGeneration: generation,
              kind: kind, answer: "Unable to verify", confidence: 0, verified: false)
    }
}

public enum QuizCommandKind: String, Codable, Sendable, CaseIterable {
    case stop, pause, resume, retarget, scrollUp, scrollDown
}

public struct QuizCommand: Codable, Sendable, Equatable {
    public let contractVersion: Int
    public let sessionID: String
    public let command: QuizCommandKind
    public let target: QuizWindowTarget?

    public init(sessionID: String, command: QuizCommandKind, target: QuizWindowTarget? = nil,
                contractVersion: Int = QuizContract.version) {
        self.contractVersion = contractVersion
        self.sessionID = sessionID
        self.command = command
        self.target = target
    }
}

public enum QuizEventKind: String, Codable, Sendable {
    case lifecycle, question, answer, scrollPrompt, targetLost, failure
}

public struct QuizEvent: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let contractVersion: Int
    public let sessionID: String
    public let questionID: String?
    public let questionGeneration: Int
    public let captureGeneration: Int
    public let sequence: Int
    public let kind: QuizEventKind
    public let state: QuizSessionState
    public let finalAnswer: QuizFinalAnswer?
    public let message: String?
    public let at: Date

    public init(id: String = UUID().uuidString.lowercased(), sessionID: String,
                questionID: String? = nil, questionGeneration: Int = 0,
                captureGeneration: Int = 0, sequence: Int, kind: QuizEventKind,
                state: QuizSessionState, finalAnswer: QuizFinalAnswer? = nil,
                message: String? = nil, at: Date = Date(),
                contractVersion: Int = QuizContract.version) {
        self.id = id
        self.contractVersion = contractVersion
        self.sessionID = sessionID
        self.questionID = questionID
        self.questionGeneration = questionGeneration
        self.captureGeneration = captureGeneration
        self.sequence = sequence
        self.kind = kind
        self.state = state
        self.finalAnswer = finalAnswer
        self.message = message.map { String($0.prefix(240)) }
        self.at = at
    }

    public func matches(sessionID: String, questionID: String?, generation: Int) -> Bool {
        contractVersion == QuizContract.version && self.sessionID == sessionID
            && self.questionID == questionID && questionGeneration == generation
    }
}

public struct QuizSessionSnapshot: Codable, Sendable, Equatable {
    public let contractVersion: Int
    public let sessionID: String?
    public let state: QuizSessionState
    public let target: QuizWindowTarget?
    public let screenRecordingReady: Bool
    public let accessibilityReady: Bool
    public let agyAuthenticated: Bool
    public let modelsReady: Bool
    public let workersReady: Bool
    public let answer: QuizFinalAnswer?
    /// Every answer this session has published, oldest first, so the panel can
    /// step back through them instead of losing each one to the next question.
    ///
    /// Optional preserves decoding of version-1 snapshots, which carried only
    /// the latest answer — the same reason `QuizSessionConfiguration` keeps
    /// `captureResolution` optional.
    public let answers: [QuizFinalAnswer]?
    public let scrollPrompt: QuizCommandKind?
    public let failure: String?
    /// When the current question settled on screen.
    ///
    /// The panel's clock used to run from the start of the *session*, which after
    /// twenty minutes said nothing about the question being worked on now. What
    /// the reader wants to know is how long this one has been going, against a
    /// 120-second budget.
    public let questionStartedAt: Date?

    /// The session's answers, newest last. Falls back to the single latest
    /// answer when the payload predates `answers`.
    public var answerHistory: [QuizFinalAnswer] {
        if let answers, !answers.isEmpty { return answers }
        return answer.map { [$0] } ?? []
    }

    public init(sessionID: String? = nil, state: QuizSessionState = .finished,
                target: QuizWindowTarget? = nil, screenRecordingReady: Bool = false,
                accessibilityReady: Bool = false, agyAuthenticated: Bool = false,
                modelsReady: Bool = false, workersReady: Bool = false,
                answer: QuizFinalAnswer? = nil, answers: [QuizFinalAnswer]? = nil,
                scrollPrompt: QuizCommandKind? = nil, failure: String? = nil,
                questionStartedAt: Date? = nil,
                contractVersion: Int = QuizContract.version) {
        self.contractVersion = contractVersion
        self.sessionID = sessionID
        self.state = state
        self.target = target
        self.screenRecordingReady = screenRecordingReady
        self.accessibilityReady = accessibilityReady
        self.agyAuthenticated = agyAuthenticated
        self.modelsReady = modelsReady
        self.workersReady = workersReady
        self.answer = answer
        self.answers = answers.map { Array($0.suffix(QuizContract.maximumAnswerHistory)) }
        self.scrollPrompt = scrollPrompt
        self.questionStartedAt = questionStartedAt
        self.failure = failure.map { String($0.prefix(240)) }
    }

    public var active: Bool { sessionID != nil && state.isRunning }
}

public struct QuizHistorySession: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let startedAt: Date
    public let endedAt: Date?
    public let eventLabel: String?
    public let targetApplication: String
    public let targetWindow: String
    public let answers: [QuizFinalAnswer]
    public let captureIDs: [String]

    public init(id: String, startedAt: Date, endedAt: Date?, eventLabel: String?,
                targetApplication: String, targetWindow: String,
                answers: [QuizFinalAnswer], captureIDs: [String] = []) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.eventLabel = eventLabel
        self.targetApplication = targetApplication
        self.targetWindow = targetWindow
        self.answers = answers
        self.captureIDs = captureIDs
    }
}

/// Asks the Engine to bring a council up before there is a session.
///
/// The preflight knows which window is going to be watched long before Start is
/// pressed — the reader still has to reach for the button — and every `agy` child
/// spends seconds handshaking with Google before it can answer anything. This
/// spends that time while the panel is on screen instead of after the press.
///
/// It carries a council and nothing else. No target, no session identifier and
/// no context: warming grants no capture authority and starts no session, so
/// there is nothing here for a target to be needed for.
public struct QuizWarmRequest: Codable, Sendable, Equatable {
    public let contractVersion: Int
    public let mode: QuizMode
    public let profile: QuizModeProfile

    public init(mode: QuizMode, profile: QuizModeProfile,
                contractVersion: Int = QuizContract.version) {
        self.contractVersion = contractVersion
        self.mode = mode
        self.profile = profile
    }
}

public enum QuizContractValidation {
    public enum Failure: Error, Equatable, Sendable, LocalizedError {
        case wrongVersion, invalidSession, invalidTarget, invalidModels, contextTooLarge
        case invalidFrame, invalidCommand

        public var errorDescription: String? {
            switch self {
            case .wrongVersion: "Unsupported Quiz contract version"
            case .invalidSession: "Quiz session identifier is invalid"
            case .invalidTarget: "Quiz target window is invalid"
            case .invalidModels:
                "Every Quiz council needs between one and \(QuizContract.maximumVoters) valid voters"
            case .contextTooLarge: "Quiz context is too large"
            case .invalidFrame: "Quiz capture frame is invalid"
            case .invalidCommand: "Quiz command is invalid"
            }
        }
    }

    public static func validate(_ configuration: QuizSessionConfiguration) throws {
        guard configuration.contractVersion == QuizContract.version else { throw Failure.wrongVersion }
        guard validIdentifier(configuration.sessionID) else { throw Failure.invalidSession }
        guard configuration.target.processID > 0, configuration.target.windowID > 0,
              validBundleID(configuration.target.bundleID) else { throw Failure.invalidTarget }
        // The council is the user's to size. Only its bounds are the contract's
        // business, and an arbiter is now optional — a mode can be set to report
        // that it could not agree rather than escalate.
        guard validCouncil(voters: configuration.voters, arbiter: configuration.arbiter)
        else { throw Failure.invalidModels }
        for profile in configuration.profiles?.values ?? [:].values {
            guard validCouncil(voters: profile.voters, arbiter: profile.arbiter)
            else { throw Failure.invalidModels }
        }
        let bytes = configuration.context.reduce(0) { $0 + $1.text.utf8.count }
        guard bytes <= QuizContract.maximumContextBytes else { throw Failure.contextTooLarge }
    }

    public static func validate(_ warm: QuizWarmRequest) throws {
        guard warm.contractVersion == QuizContract.version else { throw Failure.wrongVersion }
        guard validCouncil(voters: warm.profile.voters, arbiter: warm.profile.arbiter)
        else { throw Failure.invalidModels }
    }

    public static func validate(_ frame: QuizCaptureFrame) throws {
        guard validIdentifier(frame.sessionID), validIdentifier(frame.questionID), frame.isBounded,
              frame.viewportIndex < QuizContract.maximumViewports else { throw Failure.invalidFrame }
    }

    public static func validate(_ command: QuizCommand, activeSessionID: String) throws {
        guard command.contractVersion == QuizContract.version,
              command.sessionID == activeSessionID else { throw Failure.invalidCommand }
        if command.command == .retarget {
            guard let target = command.target, target.processID > 0, target.windowID > 0,
                  validBundleID(target.bundleID) else { throw Failure.invalidTarget }
        } else if command.target != nil {
            throw Failure.invalidCommand
        }
    }

    private static func validIdentifier(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{7,159}$", options: .regularExpression) != nil
    }

    private static func validBundleID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]{2,239}$", options: .regularExpression) != nil
    }

    private static func validCouncil(voters: [QuizModelSelection],
                                     arbiter: QuizModelSelection?) -> Bool {
        guard (1 ... QuizContract.maximumVoters).contains(voters.count),
              voters.allSatisfy({ validModel($0) }) else { return false }
        guard let arbiter else { return true }
        return validModel(arbiter)
    }

    private static func validModel(_ selection: QuizModelSelection) -> Bool {
        selection.modelID.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{2,159}$", options: .regularExpression) != nil
            && ["low", "medium", "high"].contains(selection.effort)
    }
}
