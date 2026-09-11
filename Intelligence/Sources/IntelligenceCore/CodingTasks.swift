import CallaContracts
import Foundation

/// The two Live Coding lanes.
///
/// Same two-lane shape the call copilot settled on, for the same reason: the
/// urgent job and the thinking job have opposite requirements and must not
/// queue behind each other.
///
/// Until now Live Coding had no task at all — `CodingAgyWorker` talked to the
/// binary directly, so there was no budget, no attribution and no fallback, only
/// a 120 s timeout. A move that lands two minutes after the moment is worse than
/// no move, because the candidate has already said something else.
public enum CodingTasks {

    /// The next step, while the candidate is mid-sentence.
    ///
    /// `.fast` and a 6 s budget: measured local round trips are ~2.5-3.5 s, and
    /// the deterministic tier has already put something on screen, so this is
    /// the *refinement* — worth waiting a beat for, never worth waiting a minute.
    ///
    /// No `--json-schema` on this lane. It works, but it spends an extra turn,
    /// which is most of the budget. `ContractParser` recovers the object from
    /// the reply instead, exactly as the call lanes do.
    public static let move = IntelligenceTask(
        id: "coding.move",
        defaultTier: .fast,
        contract: .json(keys: ["kind", "say", "file", "code", "why", "check", "watch"]),
        latencyBudget: 6,
        conversation: .perSession,
        batching: .statement(.coding),
        allowedProviders: [.localAgy])

    /// The read-only conversation lane: interpret one completed utterance,
    /// update the dialogue state, offer the next pointer.
    ///
    /// Its own task rather than `move` because what it returns is a different
    /// shape. `move`'s key list names `file`, `code` and `check` — the things
    /// this lane must never fill, because code is prepared privately by another
    /// worker. Insisting on them here would fail the parse on a correct reply.
    ///
    /// The budget is the ceiling the read-only worker already applied to a warm
    /// turn, kept deliberately unchanged: measured round trips are 2.6-3.8s, and
    /// this lane now paints the deterministic pointer before it waits, so the
    /// panel is never blank while the refinement is in flight.
    public static let dialogue = IntelligenceTask(
        id: "coding.dialogue",
        defaultTier: .fast,
        contract: .json(keys: ["say", "dialogue"]),
        latencyBudget: 12,
        conversation: .perSession,
        batching: .statement(.coding),
        allowedProviders: [.localAgy])

    /// Where the work actually stands, and the next few steps.
    ///
    /// Runs at the start and on a phase change, never on a statement. It reads
    /// the workspace files rather than being handed context, so it is allowed to
    /// spend turns on tool calls that the move lane cannot afford.
    public static let plan = IntelligenceTask(
        id: "coding.plan",
        defaultTier: .balanced,
        contract: .json(keys: ["standing", "open_questions", "next_increments"]),
        latencyBudget: 45,
        conversation: .perSession,
        batching: .manual,
        allowedProviders: [.localAgy])

    /// The edit-capable worktree lane.
    ///
    /// Deep tier and a long budget because it is doing real work in the shadow
    /// tree and its result is a diff the engine computes, not prose the candidate
    /// is waiting on.
    public static let edit = IntelligenceTask(
        id: "coding.edit",
        defaultTier: .deep,
        contract: .json(keys: ["kind", "say", "file", "code", "why", "check", "watch"]),
        latencyBudget: 90,
        conversation: .perSession,
        batching: .manual,
        allowedProviders: [.localAgy])

    public static let all = [move, dialogue, plan, edit]

    /// Conversation key for a session's lane. Distinct keys keep the lanes from
    /// sharing a conversation and overwriting each other's session state.
    public static func sessionKey(_ sessionID: String, lane: IntelligenceTask) -> String {
        lane.id == move.id ? sessionID : "\(sessionID)#\(lane.id)"
    }
}

/// The sentinel the twin returns when there is nothing worth saying.
///
/// Borrowed from `QuizWorkerSentinel.notAQuestion`. Silence has to be something
/// the model can *express*, otherwise every request produces a move and the
/// panel churns through advice nobody needed.
public enum CodingSentinel {
    public static let noMove = "__NO_MOVE__"

    public static func isNoMove(_ say: String?) -> Bool {
        guard let say else { return false }
        return say.trimmingCharacters(in: .whitespacesAndNewlines) == noMove
    }
}
