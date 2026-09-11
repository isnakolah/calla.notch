import Foundation

public enum LiveCodingContract {
    public static let version = 2
    public static let maximumBriefBytes = 256 * 1_024
    public static let maximumTextBytes = 128 * 1_024
    public static let maximumOutputBytes = 96 * 1_024
    public static let maximumEvents = 2_000
    public static let maximumMoves = 500
}

public enum CodingSpeaker: String, Codable, Sendable { case me, them }
public enum CodingLifecycle: String, Codable, Sendable {
    case preparing, ready, capturing, stopping, interrupted, finished, failed
    public var active: Bool { [.preparing, .ready, .capturing, .stopping].contains(self) }
}
public enum CodingSyncState: String, Codable, Sendable {
    case preparing, current, syncing, conflict, unavailable
}
public enum CodingPhase: String, Codable, Sendable {
    case understanding, designing, implementing, debugging, verifying, wrappingUp
}
public enum CodingMoveKind: String, Codable, Sendable {
    case explanation, design, implementation, edit, diagnostic, verification, watch
}
public enum CodingMoveStatus: String, Codable, Sendable { case current, completed, stale, superseded }

/// Whether a move is an engine fact or a model claim.
///
/// The panel must be able to say which it is showing. A deterministic move is
/// assembled from the clock, the diff, the run verdict and rubric coverage —
/// things the engine knows — and is published within milliseconds. A model move
/// arrives later and can be wrong, so it is the one the claim guard screens.
public enum CodingMoveOrigin: String, Codable, Sendable { case deterministic, model }

/// How much a move is worth interrupting for.
///
/// Borrowed from race-engineer radio discipline: most traffic is `info` and is
/// never spoken over the driver. `urgent` is reserved for the cases where
/// staying quiet costs the interview — a failing check nobody noticed, or the
/// clock running out with the rubric uncovered.
public enum CodingMovePriority: String, Codable, Sendable {
    case info, advisory, urgent
}

/// How far a rubric item has got.
///
/// Deliberately four states rather than done/not-done: an interviewer scores
/// "said it" and "shipped it" differently, and the copilot's advice differs too.
/// Saying a thing you have not built is a risk to flag, not a box to tick.
public enum CodingRubricStatus: String, Codable, Sendable {
    case open, spoken, implemented, verified
}

/// Which part of the frozen brief an item came from.
public enum CodingBriefItemKind: String, Codable, Sendable {
    case rubric, constraint, task, suppliedInterface, deprioritised
}
public enum CodingRunLifecycle: String, Codable, Sendable {
    case pending, running, passed, failed, timedOut, cancelled, environmentFailure
}
public enum CodingEventKind: String, Codable, Sendable {
    case lifecycle, sourceRevision, move, run, failure
}
public enum CodingBriefSourceKind: String, Codable, Sendable { case text, file, url }

public struct CodingTextAnchor: Codable, Hashable, Sendable {
    public var fromSequence: Int
    public var toSequence: Int
    public init(fromSequence: Int, toSequence: Int) {
        self.fromSequence = fromSequence; self.toSequence = toSequence
    }
}

public struct CodingFileAnchor: Codable, Hashable, Sendable {
    public var path: String
    public var symbol: String?
    public var line: Int?
    public init(path: String, symbol: String? = nil, line: Int? = nil) {
        self.path = path; self.symbol = symbol; self.line = line
    }
}

/// One addressable line of the frozen brief.
///
/// The brief is authored as plain string arrays so the Settings panes can bind
/// straight to them. Ids are *derived* from position rather than stored, which
/// is safe precisely because the brief is frozen at `frozenAt` and never edited
/// during a session — and it keeps the authored shape unchanged.
public struct CodingBriefItem: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: CodingBriefItemKind
    public var text: String
    public init(id: String, kind: CodingBriefItemKind, text: String) {
        self.id = id; self.kind = kind; self.text = text
    }
}

/// Live coverage of one brief item.
public struct CodingRubricState: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: CodingBriefItemKind
    public var text: String
    public var status: CodingRubricStatus
    /// The revision or run that last moved this item, so the panel can show why.
    public var evidence: String?
    public init(id: String, kind: CodingBriefItemKind, text: String,
                status: CodingRubricStatus = .open, evidence: String? = nil) {
        self.id = id; self.kind = kind; self.text = text
        self.status = status; self.evidence = evidence
    }
}

/// Which brain answered, and how long it took.
///
/// Mirrors the intelligence layer's `Attribution` across the XPC boundary, for
/// the same reason it exists there: a silent failover is a bug, and a move that
/// came from a slower fallback should be visible as one.
public struct CodingAttribution: Codable, Equatable, Sendable {
    public var provider: String
    public var model: String
    public var latencyMilliseconds: Int
    public var fellBack: Bool
    public var lane: String
    public init(provider: String, model: String, latencyMilliseconds: Int,
                fellBack: Bool = false, lane: String = "move") {
        self.provider = provider; self.model = model
        self.latencyMilliseconds = latencyMilliseconds
        self.fellBack = fellBack; self.lane = lane
    }
}

public struct InterviewBrief: Codable, Equatable, Sendable {
    public var source: CodingBriefSourceKind
    public var title: String
    public var rubric: [String]
    public var constraints: [String]
    public var taskOrdering: [String]
    public var suppliedInterfaces: [String]
    public var depriorities: [String]
    public var frozenAt: Date

    public init(source: CodingBriefSourceKind, title: String, rubric: [String] = [],
                constraints: [String] = [], taskOrdering: [String] = [],
                suppliedInterfaces: [String] = [], depriorities: [String] = [],
                frozenAt: Date = Date()) {
        self.source = source; self.title = title; self.rubric = rubric
        self.constraints = constraints; self.taskOrdering = taskOrdering
        self.suppliedInterfaces = suppliedInterfaces; self.depriorities = depriorities
        self.frozenAt = frozenAt
    }

    /// Every scorable line of the brief, in a stable order.
    ///
    /// Ids are derived from position rather than stored. That is safe precisely
    /// because the brief is frozen at `frozenAt` and never edited during a
    /// session, and it leaves the authored `[String]` shape — which the Settings
    /// panes bind to directly — unchanged.
    ///
    /// `depriorities` are included deliberately: the copilot needs to know what
    /// *not* to spend time on as much as what to cover, and an item the brief
    /// deprioritised is a common way to burn the clock.
    public var items: [CodingBriefItem] {
        func mapped(_ values: [String], _ kind: CodingBriefItemKind,
                    _ prefix: String) -> [CodingBriefItem] {
            values.enumerated().map {
                CodingBriefItem(id: "\(prefix)-\($0.offset)", kind: kind, text: $0.element)
            }
        }
        return mapped(rubric, .rubric, "rubric")
            + mapped(constraints, .constraint, "constraint")
            + mapped(taskOrdering, .task, "task")
            + mapped(suppliedInterfaces, .suppliedInterface, "interface")
            + mapped(depriorities, .deprioritised, "deprioritised")
    }
}

/// One lane's model and how hard it is allowed to think.
///
/// The same shape as `QuizModelSelection`, deliberately: Quiz already proved
/// that per-role control is what makes a local council usable, and Live Coding
/// has the same problem with three lanes that want very different tradeoffs.
public struct CodingModelSelection: Codable, Sendable, Equatable, Hashable {
    public let modelID: String
    /// `low` | `medium` | `high`. Ignored by preset-thinking models, which
    /// reject `--effort` outright.
    public let effort: String

    /// A named preset already specifies the thinking level. Avoid overriding it
    /// with a second independently persisted value.
    public var presetEffort: String? {
        let id = modelID.lowercased()
        return ["low", "medium", "high", "thinking"].first { id.hasSuffix("-" + $0) }
    }
    public var effortArguments: [String] { presetEffort == nil ? ["--effort", effort] : [] }

    public init(modelID: String, effort: String = "low") {
        self.modelID = String(modelID.prefix(160))
        self.effort = effort
    }
}

/// Which model answers each Live Coding lane.
///
/// Three lanes with opposite requirements, which is exactly why one global
/// `model` was the wrong shape:
///
/// - `move` is what the candidate waits on mid-sentence. Fast tier, low effort.
/// - `plan` reads the workspace and restates where the work stands. Balanced.
/// - `edit` does real work in the shadow tree and nobody is watching the clock
///   on it. Deep tier, high effort.
public struct CodingModelProfile: Codable, Sendable, Equatable {
    public var move: CodingModelSelection
    public var plan: CodingModelSelection
    public var edit: CodingModelSelection

    public init(move: CodingModelSelection = .init(modelID: "gemini-3.8-flash-low", effort: "low"),
                plan: CodingModelSelection = .init(modelID: "gemini-3.8-flash-medium", effort: "medium"),
                edit: CodingModelSelection = .init(modelID: "gemini-3.1-pro-high", effort: "high")) {
        self.move = move; self.plan = plan; self.edit = edit
    }

    public static let standard = CodingModelProfile()
}

/// What the session is doing right now.
///
/// Live Coding published lifecycle and a move and nothing in between, so a
/// twin that was deliberately silent looked identical to one that had died.
/// Most of an interview is spent in `listening` — saying so is the difference
/// between "working as designed" and "broken".
public enum CodingActivity: String, Codable, Sendable {
    case preparing
    /// Segmenting speech; nothing worth a move yet.
    case listening
    /// A statement closed and the twin is being asked.
    case thinking
    /// A check is executing.
    case running
    /// The candidate saved; the shadow is reconciling.
    case syncing
    /// Deliberately quiet — the candidate is fluent.
    case silent
    /// Something is wrong and named in `failure`.
    case blocked
    case ended
}

public struct CodingNetworkPolicy: Codable, Equatable, Sendable {
    public var commandsMayUseNetwork: Bool
    public var discloseRemoteAgent: Bool
    public init(commandsMayUseNetwork: Bool = true, discloseRemoteAgent: Bool = true) {
        self.commandsMayUseNetwork = commandsMayUseNetwork
        self.discloseRemoteAgent = discloseRemoteAgent
    }
}

public struct CodingSessionConfiguration: Codable, Equatable, Sendable {
    public var interviewProfile: String?
    /// Whether this is a rehearsal rather than the interview itself.
    ///
    /// Optional so a snapshot written before rehearsals existed still decodes —
    /// and `nil` reads as "not stated", which the engine treats as a rehearsal,
    /// because claiming a practice run was the real sitting is the costlier
    /// mistake.
    public var rehearsal: Bool?
    public var observationTarget: QuizWindowTarget?
    public var contractVersion: Int
    public var sessionID: String
    public var callID: String
    public var generation: Int
    public var folderCapabilityID: String
    public var brief: InterviewBrief?
    public var provider: String
    /// The move lane's model. Defaults to the **fast** tier, not the deep one.
    ///
    /// This used to default to `gemini-3.1-pro-high` — the pro tier — for a
    /// reaction the candidate is waiting on mid-sentence. Measured local round
    /// trips are ~2.5-3.5s on flash; pro is several times that, and a move that
    /// lands after the moment has passed is worth less than nothing.
    public var model: String
    public var retainUntilDeleted: Bool
    public var networkPolicy: CodingNetworkPolicy
    /// How long the interview is booked for, from the calendar event.
    ///
    /// The single most directive fact the copilot has. "You have nine minutes
    /// and have not run a test" is worth more than any amount of advice about
    /// the code, and none of it is derivable without this.
    public var plannedDurationMinutes: Int?
    public var startedAt: Date
    /// Per-lane model and effort. `model` above is the move lane's id, kept so
    /// existing snapshots and history keep rendering.
    public var profile: CodingModelProfile

    public init(sessionID: String, callID: String, generation: Int,
                folderCapabilityID: String, brief: InterviewBrief? = nil,
                provider: String = "local", model: String = "gemini-3.8-flash-low",
                retainUntilDeleted: Bool = true,
                networkPolicy: CodingNetworkPolicy = .init(),
                plannedDurationMinutes: Int? = nil, startedAt: Date = Date(),
                profile: CodingModelProfile = .standard,
                contractVersion: Int = LiveCodingContract.version) {
        self.contractVersion = contractVersion; self.sessionID = sessionID
        self.callID = callID; self.generation = generation
        self.folderCapabilityID = folderCapabilityID; self.brief = brief
        self.provider = provider; self.model = model
        self.retainUntilDeleted = retainUntilDeleted; self.networkPolicy = networkPolicy
        self.plannedDurationMinutes = plannedDurationMinutes; self.startedAt = startedAt
        self.profile = profile
    }

    /// Tolerant decode so a session sealed under contract v1 still loads.
    ///
    /// Version is checked by `LiveCodingValidation`, which can only run on a
    /// value that decoded. Without this, a v1 record in the vault throws here and
    /// the session simply vanishes from History rather than being reported as
    /// out of date.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        interviewProfile = try values.decodeIfPresent(String.self, forKey: .interviewProfile)
        observationTarget = try values.decodeIfPresent(QuizWindowTarget.self, forKey: .observationTarget)
        contractVersion = try values.decode(Int.self, forKey: .contractVersion)
        sessionID = try values.decode(String.self, forKey: .sessionID)
        callID = try values.decode(String.self, forKey: .callID)
        generation = try values.decode(Int.self, forKey: .generation)
        folderCapabilityID = try values.decode(String.self, forKey: .folderCapabilityID)
        brief = try values.decodeIfPresent(InterviewBrief.self, forKey: .brief)
        provider = try values.decode(String.self, forKey: .provider)
        model = try values.decode(String.self, forKey: .model)
        retainUntilDeleted = try values.decode(Bool.self, forKey: .retainUntilDeleted)
        networkPolicy = try values.decode(CodingNetworkPolicy.self, forKey: .networkPolicy)
        plannedDurationMinutes = try values.decodeIfPresent(Int.self, forKey: .plannedDurationMinutes)
        startedAt = try values.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
        profile = try values.decodeIfPresent(CodingModelProfile.self, forKey: .profile) ?? .standard
    }
}

public struct CodingRunPlan: Codable, Equatable, Sendable {
    public var id: String
    public var relativeCWD: String
    public var displayedCommand: String
    public var expectedEvidence: String?
    public init(id: String = UUID().uuidString.lowercased(), relativeCWD: String = ".",
                displayedCommand: String, expectedEvidence: String? = nil) {
        self.id = id; self.relativeCWD = relativeCWD
        self.displayedCommand = displayedCommand; self.expectedEvidence = expectedEvidence
    }
}

/// What one line of a proposed step is doing.
public enum CodingPatchLineKind: String, Codable, Equatable, Sendable {
    /// Already in the file. Shown so the reader can find the place.
    case context
    /// New. This is what they type.
    case add
    /// Goes away.
    case remove
}

public struct CodingPatchLine: Codable, Equatable, Sendable {
    public var kind: CodingPatchLineKind
    /// Source, byte for byte. Never prose — the note is where prose goes.
    public var text: String
    /// The id of the note anchored to this line, if one is.
    public var note: Int?

    public init(kind: CodingPatchLineKind, text: String, note: Int? = nil) {
        self.kind = kind; self.text = text; self.note = note
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decodeIfPresent(CodingPatchLineKind.self, forKey: .kind) ?? .context
        text = try values.decodeIfPresent(String.self, forKey: .text) ?? ""
        note = try values.decodeIfPresent(Int.self, forKey: .note)
    }
}

/// Why one line is there. Not what it says — the line already says that.
public struct CodingPatchNote: Codable, Equatable, Sendable, Identifiable {
    public var id: Int
    public var text: String
    public init(id: Int, text: String) { self.id = id; self.text = text }
}

/// A step, as something that can be read rather than as one string.
///
/// `CodingMove.code` was a blob, so the panel could only draw it flat: every
/// line the same weight, numbered from 1, with no way to say which lines were
/// new or which one the caution was about. None of that can be inferred after
/// the fact, so the model has to say it, and `CodingPatchLimits` is what it is
/// held to.
public struct CodingPatch: Codable, Equatable, Sendable {
    /// For highlighting. Free text — the renderer falls back to plain when it
    /// does not recognise it.
    public var language: String?
    /// The file line `lines.first` sits on. The reader is looking at their own
    /// editor, so numbering a snippet from 1 is numbering the wrong thing.
    public var startLine: Int?
    public var lines: [CodingPatchLine]
    public var notes: [CodingPatchNote]

    public init(language: String? = nil, startLine: Int? = nil,
                lines: [CodingPatchLine] = [], notes: [CodingPatchNote] = []) {
        self.language = language; self.startLine = startLine
        self.lines = lines; self.notes = notes
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        language = try values.decodeIfPresent(String.self, forKey: .language)
        startLine = try values.decodeIfPresent(Int.self, forKey: .startLine)
        lines = try values.decodeIfPresent([CodingPatchLine].self, forKey: .lines) ?? []
        notes = try values.decodeIfPresent([CodingPatchNote].self, forKey: .notes) ?? []
    }

    /// The complete text a reader copies: the file as this step leaves it.
    /// Removed lines are not part of it; that is the point of removing them.
    public var copyableText: String {
        lines.filter { $0.kind != .remove }.map(\.text).joined(separator: "\n")
    }

    public var addedLineCount: Int { lines.filter { $0.kind == .add }.count }
    public var changesAnything: Bool { lines.contains { $0.kind != .context } }
}

/// What a patch has to be before the panel will draw it.
///
/// These are the reasons a step is sent back to be redone rather than shown
/// plain. A panel 600pt wide and a reader mid-sentence are the whole argument
/// for every number here.
public enum CodingPatchLimits {
    /// A step longer than this is not one step.
    public static let maximumLines = 12
    /// Enough to find the place, not enough to re-read the file.
    public static let maximumContextRun = 3
    /// Two things worth saying about a step. A third is a different step.
    public static let maximumNotes = 2
    public static let maximumNoteCharacters = 80
    /// Anything wider wraps in the panel, and wrapped code stops being code.
    public static let maximumLineCharacters = 120

    public enum Problem: String, Equatable, Sendable {
        case empty
        case changesNothing
        case tooManyLines
        case tooMuchContext
        case tooManyNotes
        case noteTooLong
        case noteNotAnchored
        case noteOnUnchangedLine
        case lineTooWide
    }

    /// Everything wrong with a patch, in the order worth telling a model about.
    public static func problems(with patch: CodingPatch) -> [Problem] {
        var found: [Problem] = []
        if patch.lines.isEmpty { return [.empty] }
        if !patch.changesAnything { found.append(.changesNothing) }
        if patch.lines.count > maximumLines { found.append(.tooManyLines) }

        var run = 0
        for line in patch.lines {
            run = line.kind == .context ? run + 1 : 0
            if run > maximumContextRun { found.append(.tooMuchContext); break }
        }

        if patch.notes.count > maximumNotes { found.append(.tooManyNotes) }
        if patch.notes.contains(where: { $0.text.count > maximumNoteCharacters }) {
            found.append(.noteTooLong)
        }

        let anchored = Set(patch.lines.compactMap(\.note))
        if patch.notes.contains(where: { !anchored.contains($0.id) }) {
            found.append(.noteNotAnchored)
        }
        if patch.lines.contains(where: { $0.note != nil && $0.kind == .context }) {
            found.append(.noteOnUnchangedLine)
        }
        if patch.lines.contains(where: { $0.text.count > maximumLineCharacters }) {
            found.append(.lineTooWide)
        }
        return found
    }

    /// The patch, trimmed to what will actually draw.
    ///
    /// Trimming rather than rejecting, because a step that is 90% right and one
    /// context line too long is still the step — and a panel that shows nothing
    /// mid-interview is the worst outcome available.
    public static func normalised(_ patch: CodingPatch) -> CodingPatch {
        var result = patch

        // Trim runs of context from the outside in: the lines furthest from a
        // change are the ones least worth the height.
        var lines = result.lines
        while lines.count > maximumLines,
              let index = outermostContextIndex(in: lines) {
            lines.remove(at: index)
        }
        if lines.count > maximumLines { lines = Array(lines.prefix(maximumLines)) }
        result.lines = lines

        let anchored = Set(result.lines.compactMap(\.note))
        result.notes = result.notes
            .filter { anchored.contains($0.id) }
            .prefix(maximumNotes)
            .map { CodingPatchNote(id: $0.id, text: String($0.text.prefix(maximumNoteCharacters))) }

        // A note whose text was dropped leaves a marker pointing at nothing.
        let kept = Set(result.notes.map(\.id))
        result.lines = result.lines.map { line in
            guard let note = line.note, !kept.contains(note) else { return line }
            return CodingPatchLine(kind: line.kind, text: line.text, note: nil)
        }
        return result
    }

    /// The patch cut back to a pacing budget.
    ///
    /// The claim guard trims `code` when a step hands over more than the
    /// increment allows. The patch has to be cut to match: it is what the panel
    /// draws, so a patch left whole beside a trimmed blob would show the reader
    /// exactly the code the guard decided to withhold.
    public static func trimmed(_ patch: CodingPatch, toAddedLines budget: Int) -> CodingPatch {
        guard budget >= 0, patch.addedLineCount > budget else { return patch }

        var kept: [CodingPatchLine] = []
        var added = 0
        for line in patch.lines {
            if line.kind == .add {
                if added == budget { break }
                added += 1
            }
            kept.append(line)
        }
        // Context trailing the last change locates nothing.
        while let last = kept.last, last.kind == .context { kept.removeLast() }

        var result = patch
        result.lines = kept
        return normalised(result)
    }

    private static func outermostContextIndex(in lines: [CodingPatchLine]) -> Int? {
        if lines.first?.kind == .context { return 0 }
        if lines.last?.kind == .context { return lines.count - 1 }
        return nil
    }
}

public struct CodingMove: Codable, Equatable, Identifiable, Sendable {
    public var pendingWorkID: String?
    public var implementationStage: CodingInterviewStage?
    public var id: String
    public var ordinal: Int
    public var transcriptAnchor: CodingTextAnchor?
    public var sourceRevision: String
    public var kind: CodingMoveKind
    public var say: String?
    public var file: CodingFileAnchor?
    public var code: String?
    /// The same step, said in a way the panel can draw: which lines are new,
    /// which file line they land on, and what is worth a note. `code` remains
    /// the plain text for copying and for moves published before this existed.
    public var patch: CodingPatch?
    public var why: String?
    public var check: CodingRunPlan?
    public var result: String?
    public var watch: String?
    public var status: CodingMoveStatus
    public var supersededBy: String?
    /// Engine fact or model claim. See `CodingMoveOrigin`.
    public var origin: CodingMoveOrigin
    /// How much this is worth interrupting for.
    public var priority: CodingMovePriority
    /// 0-100, calibrated before display. Never set on a deterministic move —
    /// the engine does not guess about facts it computed.
    public var confidence: Int?
    /// Which brief items this move advances, so coverage can be attributed.
    public var rubricIDs: [String]
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String = UUID().uuidString.lowercased(), ordinal: Int,
                transcriptAnchor: CodingTextAnchor? = nil, sourceRevision: String,
                kind: CodingMoveKind, say: String? = nil, file: CodingFileAnchor? = nil,
                code: String? = nil, patch: CodingPatch? = nil,
                why: String? = nil, check: CodingRunPlan? = nil,
                result: String? = nil, watch: String? = nil,
                status: CodingMoveStatus = .current, supersededBy: String? = nil,
                origin: CodingMoveOrigin = .model,
                priority: CodingMovePriority = .advisory,
                confidence: Int? = nil, rubricIDs: [String] = [],
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id; self.ordinal = ordinal; self.transcriptAnchor = transcriptAnchor
        self.sourceRevision = sourceRevision; self.kind = kind; self.say = say
        self.file = file; self.code = code; self.patch = patch
        self.why = why; self.check = check
        self.result = result; self.watch = watch; self.status = status
        self.supersededBy = supersededBy
        self.origin = origin; self.priority = priority
        self.confidence = confidence.map { min(100, max(0, $0)) }
        self.rubricIDs = rubricIDs
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    /// Tolerant decode, for the same reason as `CodingSessionConfiguration`:
    /// moves are persisted in the event ledger and the vault.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        pendingWorkID = try values.decodeIfPresent(String.self, forKey: .pendingWorkID)
        implementationStage = try values.decodeIfPresent(CodingInterviewStage.self, forKey: .implementationStage)
        id = try values.decode(String.self, forKey: .id)
        ordinal = try values.decode(Int.self, forKey: .ordinal)
        transcriptAnchor = try values.decodeIfPresent(CodingTextAnchor.self, forKey: .transcriptAnchor)
        sourceRevision = try values.decode(String.self, forKey: .sourceRevision)
        kind = try values.decode(CodingMoveKind.self, forKey: .kind)
        say = try values.decodeIfPresent(String.self, forKey: .say)
        file = try values.decodeIfPresent(CodingFileAnchor.self, forKey: .file)
        code = try values.decodeIfPresent(String.self, forKey: .code)
        patch = try values.decodeIfPresent(CodingPatch.self, forKey: .patch)
        why = try values.decodeIfPresent(String.self, forKey: .why)
        check = try values.decodeIfPresent(CodingRunPlan.self, forKey: .check)
        result = try values.decodeIfPresent(String.self, forKey: .result)
        watch = try values.decodeIfPresent(String.self, forKey: .watch)
        status = try values.decode(CodingMoveStatus.self, forKey: .status)
        supersededBy = try values.decodeIfPresent(String.self, forKey: .supersededBy)
        origin = try values.decodeIfPresent(CodingMoveOrigin.self, forKey: .origin) ?? .model
        priority = try values.decodeIfPresent(CodingMovePriority.self, forKey: .priority) ?? .advisory
        confidence = try values.decodeIfPresent(Int.self, forKey: .confidence)
        rubricIDs = try values.decodeIfPresent([String].self, forKey: .rubricIDs) ?? []
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
    }
}

public struct CodingRun: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var relativeCWD: String
    public var displayedCommand: String
    public var lifecycle: CodingRunLifecycle
    public var exitCode: Int32?
    public var durationMilliseconds: Int?
    public var outputSummary: String
    public var outputTruncated: Bool
    public var evidenceRevision: String
    public var startedAt: Date?
    public var endedAt: Date?

    public init(id: String, relativeCWD: String, displayedCommand: String,
                lifecycle: CodingRunLifecycle, exitCode: Int32? = nil,
                durationMilliseconds: Int? = nil, outputSummary: String = "",
                outputTruncated: Bool = false, evidenceRevision: String,
                startedAt: Date? = nil, endedAt: Date? = nil) {
        self.id = id; self.relativeCWD = relativeCWD; self.displayedCommand = displayedCommand
        self.lifecycle = lifecycle; self.exitCode = exitCode
        self.durationMilliseconds = durationMilliseconds; self.outputSummary = outputSummary
        self.outputTruncated = outputTruncated; self.evidenceRevision = evidenceRevision
        self.startedAt = startedAt; self.endedAt = endedAt
    }
}

public struct CodingFailure: Codable, Equatable, Sendable {
    public var code: String
    public var message: String
    public var recovery: String?
    public init(code: String, message: String, recovery: String? = nil) {
        self.code = code; self.message = message; self.recovery = recovery
    }
}

public struct CodingSessionSnapshot: Codable, Equatable, Sendable {
    public var interviewFlow: CodingInterviewFlowState?
    public var interviewProfile: String?
    public var observationTarget: QuizWindowTarget?
    public var wave: WaveInterviewState?
    public var contractVersion: Int
    public var sessionID: String?
    public var callID: String?
    public var generation: Int
    public var lifecycle: CodingLifecycle
    public var sourceRevision: String?
    public var workRevision: String?
    public var syncState: CodingSyncState
    public var phase: CodingPhase
    public var pendingRun: CodingRunPlan?
    public var activeMove: CodingMove?
    public var provider: String?
    public var model: String?
    public var failure: CodingFailure?
    public var latestSequence: Int
    /// Seconds left of the booked interview, or nil when it is not timeboxed.
    public var remainingSeconds: Int?
    /// What the session is doing right now, for the panel to say out loud.
    public var activity: CodingActivity
    /// One short line of detail for `activity`, when there is one worth showing.
    public var activityDetail: String?
    /// Live coverage of the frozen brief.
    public var rubric: [CodingRubricState]
    /// Which brain produced the active move, and how long it took.
    public var attribution: CodingAttribution?

    public init(sessionID: String? = nil, callID: String? = nil, generation: Int = 0,
                lifecycle: CodingLifecycle = .finished, sourceRevision: String? = nil,
                workRevision: String? = nil, syncState: CodingSyncState = .unavailable,
                phase: CodingPhase = .understanding, pendingRun: CodingRunPlan? = nil,
                activeMove: CodingMove? = nil, provider: String? = nil, model: String? = nil,
                failure: CodingFailure? = nil, latestSequence: Int = -1,
                remainingSeconds: Int? = nil,
                activity: CodingActivity = .preparing, activityDetail: String? = nil,
                rubric: [CodingRubricState] = [],
                attribution: CodingAttribution? = nil,
                contractVersion: Int = LiveCodingContract.version) {
        self.contractVersion = contractVersion; self.sessionID = sessionID; self.callID = callID
        self.generation = generation; self.lifecycle = lifecycle
        self.sourceRevision = sourceRevision; self.workRevision = workRevision
        self.syncState = syncState; self.phase = phase; self.pendingRun = pendingRun
        self.activeMove = activeMove; self.provider = provider; self.model = model
        self.failure = failure; self.latestSequence = latestSequence
        self.remainingSeconds = remainingSeconds
        self.activity = activity; self.activityDetail = activityDetail
        self.rubric = rubric; self.attribution = attribution
    }

    /// Tolerant decode; the snapshot is persisted as `snapshot.json` and inside
    /// the active ledger.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        interviewFlow = try values.decodeIfPresent(CodingInterviewFlowState.self, forKey: .interviewFlow)
        interviewProfile = try values.decodeIfPresent(String.self, forKey: .interviewProfile)
        observationTarget = try values.decodeIfPresent(QuizWindowTarget.self, forKey: .observationTarget)
        contractVersion = try values.decode(Int.self, forKey: .contractVersion)
        wave = try values.decodeIfPresent(WaveInterviewState.self, forKey: .wave)
        sessionID = try values.decodeIfPresent(String.self, forKey: .sessionID)
        callID = try values.decodeIfPresent(String.self, forKey: .callID)
        generation = try values.decode(Int.self, forKey: .generation)
        lifecycle = try values.decode(CodingLifecycle.self, forKey: .lifecycle)
        sourceRevision = try values.decodeIfPresent(String.self, forKey: .sourceRevision)
        workRevision = try values.decodeIfPresent(String.self, forKey: .workRevision)
        syncState = try values.decode(CodingSyncState.self, forKey: .syncState)
        phase = try values.decode(CodingPhase.self, forKey: .phase)
        pendingRun = try values.decodeIfPresent(CodingRunPlan.self, forKey: .pendingRun)
        activeMove = try values.decodeIfPresent(CodingMove.self, forKey: .activeMove)
        provider = try values.decodeIfPresent(String.self, forKey: .provider)
        model = try values.decodeIfPresent(String.self, forKey: .model)
        failure = try values.decodeIfPresent(CodingFailure.self, forKey: .failure)
        latestSequence = try values.decode(Int.self, forKey: .latestSequence)
        remainingSeconds = try values.decodeIfPresent(Int.self, forKey: .remainingSeconds)
        activity = try values.decodeIfPresent(CodingActivity.self, forKey: .activity) ?? .preparing
        activityDetail = try values.decodeIfPresent(String.self, forKey: .activityDetail)
        rubric = try values.decodeIfPresent([CodingRubricState].self, forKey: .rubric) ?? []
        attribution = try values.decodeIfPresent(CodingAttribution.self, forKey: .attribution)
    }

    public func accepts(_ event: CodingEvent) -> Bool {
        event.contractVersion == contractVersion && event.sessionID == sessionID
            && event.callID == callID && event.generation == generation
            && event.sequence > latestSequence
    }
}

public struct CodingEvent: Codable, Equatable, Sendable {
    public var interviewFlow: CodingInterviewFlowState?
    public var contractVersion: Int
    public var sessionID: String
    public var callID: String
    public var generation: Int
    public var sequence: Int
    public var kind: CodingEventKind
    public var lifecycle: CodingLifecycle?
    public var sourceRevision: String?
    public var move: CodingMove?
    public var run: CodingRun?
    public var failure: CodingFailure?
    public var createdAt: Date

    public init(sessionID: String, callID: String, generation: Int, sequence: Int,
                kind: CodingEventKind, lifecycle: CodingLifecycle? = nil,
                sourceRevision: String? = nil, move: CodingMove? = nil,
                run: CodingRun? = nil, failure: CodingFailure? = nil,
                createdAt: Date = Date(), contractVersion: Int = LiveCodingContract.version) {
        self.contractVersion = contractVersion; self.sessionID = sessionID; self.callID = callID
        self.generation = generation; self.sequence = sequence; self.kind = kind
        self.lifecycle = lifecycle; self.sourceRevision = sourceRevision
        self.move = move; self.run = run; self.failure = failure; self.createdAt = createdAt
    }
}

public enum CodingCommandKind: String, Codable, Sendable {
    case start, end, resume, runPending, cancelRun, requestMove, delete, selectWindow, waveContinue, waveReturn, waveQuestion, waveHold, waveResume, armSpokenQuestion, explainDisplayed
}

public struct CodingCommand: Codable, Equatable, Sendable {
    public var observationTarget: QuizWindowTarget?
    public var questionID: String?
    public var contractVersion: Int
    public var sessionID: String
    public var callID: String
    public var generation: Int
    public var kind: CodingCommandKind
    public var runID: String?
    public var transcript: String?
    public var speaker: CodingSpeaker?
    public var confidence: Double?
    /// Turn start and end on the call's clock.
    ///
    /// Carried so the engine can segment turns into statements. Without timing
    /// there is no silence to measure, and every ASR fragment looks like a
    /// complete thought — which is exactly how one request per turn happened.
    public var t0: Double?
    public var t1: Double?
    /// Original call transcript sequence; optional for older clients.
    public var transcriptSequence: Int?

    public init(sessionID: String, callID: String, generation: Int, kind: CodingCommandKind,
                runID: String? = nil, transcript: String? = nil,
                speaker: CodingSpeaker? = nil, confidence: Double? = nil,
                t0: Double? = nil, t1: Double? = nil,
                transcriptSequence: Int? = nil,
                contractVersion: Int = LiveCodingContract.version) {
        self.contractVersion = contractVersion; self.sessionID = sessionID; self.callID = callID
        self.generation = generation; self.kind = kind; self.runID = runID
        self.transcript = transcript; self.speaker = speaker; self.confidence = confidence
        self.t0 = t0; self.t1 = t1
        self.transcriptSequence = transcriptSequence
    }
}

public struct CodingFolderPreflight: Codable, Equatable, Sendable {
    public var capabilityID: String
    public var folderName: String
    public var branch: String?
    public var dirty: Bool
    public var languages: [String]
    public var suggestedCommands: [CodingRunPlan]
    public var snapshotBytes: Int64
    public var fileCount: Int
    public var withheldPaths: [String]
    public var externalSymlinks: [String]
    public var folderReadable: Bool
    public var shadowReady: Bool
    public var agyAuthenticated: Bool

    public init(capabilityID: String, folderName: String, branch: String? = nil,
                dirty: Bool = false, languages: [String] = [],
                suggestedCommands: [CodingRunPlan] = [], snapshotBytes: Int64 = 0,
                fileCount: Int = 0, withheldPaths: [String] = [],
                externalSymlinks: [String] = [], folderReadable: Bool = false,
                shadowReady: Bool = false, agyAuthenticated: Bool = false) {
        self.capabilityID = capabilityID; self.folderName = folderName; self.branch = branch
        self.dirty = dirty; self.languages = languages; self.suggestedCommands = suggestedCommands
        self.snapshotBytes = snapshotBytes; self.fileCount = fileCount
        self.withheldPaths = withheldPaths; self.externalSymlinks = externalSymlinks
        self.folderReadable = folderReadable; self.shadowReady = shadowReady
        self.agyAuthenticated = agyAuthenticated
    }
}

public struct CodingRetainedSession: Codable, Equatable, Identifiable, Sendable {
    public var id: String { sessionID }
    public var sessionID: String
    public var folderName: String
    public var lifecycle: CodingLifecycle
    public var startedAt: Date
    public var endedAt: Date?
    public var moveCount: Int
    public init(sessionID: String, folderName: String, lifecycle: CodingLifecycle,
                startedAt: Date, endedAt: Date? = nil, moveCount: Int = 0) {
        self.sessionID = sessionID; self.folderName = folderName; self.lifecycle = lifecycle
        self.startedAt = startedAt; self.endedAt = endedAt; self.moveCount = moveCount
    }
}

public enum LiveCodingValidation {
    public enum Failure: Error, Equatable { case wrongVersion, invalidIdentity, tooLarge, invalidPath, invalidCommand }

    public static func validate(_ configuration: CodingSessionConfiguration) throws {
        guard configuration.contractVersion == LiveCodingContract.version else { throw Failure.wrongVersion }
        guard validID(configuration.sessionID), validID(configuration.callID),
              validID(configuration.folderCapabilityID), configuration.generation > 0 else {
            throw Failure.invalidIdentity
        }
        guard bounded(configuration.provider, 100), bounded(configuration.model, 200),
              briefBytes(configuration.brief) <= LiveCodingContract.maximumBriefBytes else { throw Failure.tooLarge }
    }

    public static func validate(_ command: CodingCommand, against snapshot: CodingSessionSnapshot) throws {
        guard command.contractVersion == LiveCodingContract.version else { throw Failure.wrongVersion }
        guard command.sessionID == snapshot.sessionID, command.callID == snapshot.callID,
              command.generation == snapshot.generation else { throw Failure.invalidIdentity }
        if let transcript = command.transcript, !bounded(transcript, LiveCodingContract.maximumTextBytes) {
            throw Failure.tooLarge
        }
        if let sequence = command.transcriptSequence, sequence < 0 || sequence == Int.max {
            throw Failure.invalidCommand
        }
    }

    public static func validate(relativePath: String) throws {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !relativePath.contains("\0"),
              !relativePath.split(separator: "/").contains("..") else { throw Failure.invalidPath }
    }

    private static func validID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9._-]{8,160}$", options: .regularExpression) != nil
    }
    private static func bounded(_ value: String, _ bytes: Int) -> Bool { value.utf8.count <= bytes }
    private static func briefBytes(_ brief: InterviewBrief?) -> Int {
        guard let brief else { return 0 }
        return (try? JSONEncoder().encode(brief).count) ?? Int.max
    }
}

/// Capture ownership is an engine fact, independent of UI event subscribers.
public enum CodingCallReconciliation: Equatable, Sendable {
    case none, capturing, finished, interrupted

    public static func action(coding: CodingSessionSnapshot, call: CallLifecycleSnapshot) -> Self {
        guard call.contractVersion == CallaContract.version,
              coding.callID == call.callID, coding.generation == call.generation,
              coding.lifecycle.active else { return .none }
        switch call.state {
        case .capturing:
            return coding.lifecycle == .ready && (call.capture.microphone || call.capture.systemAudio)
                ? .capturing : .none
        case .stopping, .processingRecap, .finished: return .finished
        case .failed: return .interrupted
        case .starting, .prewarming, .ready: return .none
        }
    }
}
