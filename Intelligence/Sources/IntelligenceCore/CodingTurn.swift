import CallaContracts
import Foundation

/// What the model returns, before it is allowed near the panel.
public struct CodingMoveDraft: Codable, Sendable, Equatable {
    public var dialogue: CodingDialogueUpdate?
    public var kind: CodingMoveKind?
    public var say: String?
    public var file: CodingFileAnchor?
    /// The step, line by line. What the panel actually draws.
    public var patch: CodingPatch?
    /// The older shape: one blob. Still accepted, because a model that ignores
    /// the schema should degrade to the previous panel rather than to silence.
    public var code: String?
    public var why: String?
    public var check: CodingRunPlan?
    public var watch: String?

    public init(kind: CodingMoveKind? = nil, say: String? = nil,
                file: CodingFileAnchor? = nil, patch: CodingPatch? = nil,
                code: String? = nil, why: String? = nil,
                check: CodingRunPlan? = nil, watch: String? = nil) {
        self.kind = kind; self.say = say; self.file = file
        self.patch = patch; self.code = code
        self.why = why; self.check = check; self.watch = watch
    }

    /// The step's code, whichever shape it arrived in.
    ///
    /// A patch that survives its limits is the step; otherwise the blob is. The
    /// two are kept in step so `code` is always the text a reader would copy —
    /// the file as this step leaves it, without the lines it takes out.
    public var resolved: (patch: CodingPatch?, code: String?, problems: [CodingPatchLimits.Problem]) {
        if let patch, !patch.lines.isEmpty {
            let problems = CodingPatchLimits.problems(with: patch)
            // `changesNothing` and `empty` mean there is no step here to draw as
            // one. Everything else is a patch worth trimming rather than losing.
            guard !problems.contains(.empty), !problems.contains(.changesNothing) else {
                return (nil, code ?? patch.copyableText, problems)
            }
            let normalised = CodingPatchLimits.normalised(patch)
            return (normalised, normalised.copyableText, problems)
        }
        return (nil, code, [])
    }
}

/// Builds the turn frame, and turns a draft into a publishable move.
///
/// The frame is deliberately *not* "everything, in files". Context on disk is
/// cheap in tokens but expensive in turns: every read is a tool round-trip, and
/// the move lane has six seconds. So the small volatile facts the engine already
/// holds go inline, and the workspace carries the depth the model can choose to
/// go and get.
public enum CodingTurn {

    /// The inline frame for the fast move lane.
    ///
    /// Bounded on purpose. Everything here is already in `context/` — this is
    /// the part worth spending prompt on so the common case needs no file read
    /// at all.
    public static func frame(statement: Statement, state: CodingWorkspace.State,
                             openRubric: [CodingRubricState],
                             recentlySaid: [Statement],
                             intent: CodingIntent = .none,
                             brief: InterviewBrief? = nil,
                             interviewerContext: [Statement] = [],
                             lastRun: CodingLedger.RunNote? = nil) -> String {
        var lines: [String] = []
        // What was actually asked for, named rather than inferred from prose.
        switch intent {
        case .runCommand:
            lines.append("They want a command. Propose one runnable `check` for this "
                + "project with the evidence that proves it worked. No code.")
        case .writeCode:
            lines.append("They want code, at the step named below and no further.")
        case .explain:
            lines.append("They want to understand something. Explain, do not write code.")
        case .design:
            lines.append("They want the shape before the code. Approach and complexity, no body.")
        case .none:
            break
        }
        lines.append("Step: \(state.increment.rawValue) — "
            + (state.increment.allowsCode
                ? "at most \(state.increment.maximumAddedLines) added lines."
                : "words only, no code."))
        lines.append("Phase: \(state.phase.rawValue).")
        if let brief {
            lines.append("Problem: \(bounded(brief.title, 240))")
            if !brief.constraints.isEmpty {
                lines.append("Brief constraints: " + brief.constraints.prefix(4)
                    .map { bounded($0, 180) }.joined(separator: "; "))
            }
            if !brief.suppliedInterfaces.isEmpty {
                lines.append("Given interfaces: " + brief.suppliedInterfaces.prefix(2)
                    .map { bounded($0, 180) }.joined(separator: "; "))
            }
        }
        if let remaining = state.remainingSeconds {
            lines.append("Time left: \(remaining / 60) min.")
        }
        if let verdict = state.lastVerdict, verdict != .satisfied {
            lines.append("Last check: \(verdict.rawValue).")
        }
        if let pending = state.pendingCommand {
            lines.append("Staged check (not a result): \(bounded(pending, 240))")
        }
        if let lastRun {
            lines.append("Check evidence [\(lastRun.verdict.rawValue)]: " + bounded(lastRun.summary, 500))
        }
        let uncovered = openRubric.prefix(3).map { bounded($0.text, 180) }
        if !uncovered.isEmpty {
            lines.append("Still uncovered: \(uncovered.joined(separator: "; ")).")
        }
        let requirements = interviewerContext.filter { $0.toSeq <= statement.toSeq }.suffix(4)
        if !requirements.isEmpty {
            lines.append("Interviewer context (latest explicit correction wins; hints are optional):")
            lines += requirements.map { "- [\($0.toSeq)] \(bounded($0.text, 240))" }
        }
        if !recentlySaid.isEmpty {
            lines.append("")
            lines.append("Just said:")
            lines += recentlySaid.filter { $0.toSeq < statement.fromSeq }.suffix(4).map {
                "- \($0.speaker == .local ? "Me" : "Them"): \(bounded($0.text, 320))"
            }
        }
        lines.append("")
        lines.append("\(statement.speaker == .local ? "Me" : "Them"): \(bounded(statement.text, 1_200))")
        lines.append("")
        lines.append("Read context/ if you need more. Reply with one JSON object, "
            + "or `__NO_MOVE__` as `say` if nothing is worth saying.")
        return lines.joined(separator: "\n")
    }

    private static func bounded(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + " [truncated]"
    }

    public enum Publication: Sendable, Equatable {
        /// The twin declined, or everything it offered was screened away.
        case noMove(reason: String)
        case move(CodingMove, problems: [CodingClaimGuard.Problem])
    }

    /// Turn a draft into a move the candidate can act on, or nothing.
    ///
    /// Order matters: the sentinel is honoured first (a declined turn must not
    /// be resurrected by the repair path), then pacing decides the shape, then
    /// the guard screens what is left. A move that has been stripped of
    /// everything is not published as an empty panel — it is silence.
    public static func publish(draft: CodingMoveDraft, increment: CodingIncrement,
                               ordinal: Int, sourceRevision: String,
                               anchor: CodingTextAnchor?, priority: CodingMovePriority,
                               rubricIDs: [String], confidence: Int?,
                               evidence: CodingClaimGuard.Evidence) -> Publication {
        if CodingSentinel.isNoMove(draft.say) {
            return .noMove(reason: "twin returned __NO_MOVE__")
        }
        let say = draft.say?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = draft.resolved
        let hasSubstance = !(say ?? "").isEmpty || resolved.code != nil || draft.check != nil
        guard hasSubstance else { return .noMove(reason: "draft carried nothing") }

        let candidate = CodingMove(
            ordinal: ordinal, transcriptAnchor: anchor, sourceRevision: sourceRevision,
            kind: draft.kind ?? increment.moveKind,
            say: (say?.isEmpty ?? true) ? nil : say,
            file: draft.file, code: resolved.code, patch: resolved.patch, why: draft.why,
            check: draft.check, watch: draft.watch,
            origin: .model, priority: priority, confidence: confidence,
            rubricIDs: rubricIDs)

        let screened = CodingClaimGuard.screen(candidate, increment: increment,
                                               evidence: evidence)
        let move = screened.move
        let survives = move.say != nil || move.code != nil || move.check != nil
        guard survives else {
            return .noMove(reason: "nothing survived screening")
        }
        return .move(move, problems: screened.problems)
    }

    /// The engine's own move, published immediately and never screened — there
    /// is nothing to screen, because the engine wrote it from facts it holds.
    public static func deterministic(say: String, increment: CodingIncrement,
                                     ordinal: Int, sourceRevision: String,
                                     priority: CodingMovePriority,
                                     check: CodingRunPlan? = nil) -> CodingMove {
        CodingMove(ordinal: ordinal, sourceRevision: sourceRevision,
                   kind: increment.moveKind, say: say, check: check,
                   origin: .deterministic, priority: priority,
                   confidence: nil)
    }
}
