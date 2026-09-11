import CallaContracts
import Foundation

/// The shape of the next step, and how much of it the candidate may be handed.
///
/// A live coding interview is scored on the working-through, not the artefact.
/// Real candidates write a signature, then a naive body, then an edge case, then
/// the optimisation once something passes — and an interviewer who watches a
/// complete optimal solution appear in one keystroke has learned only that the
/// candidate is reading it off something.
///
/// So pacing is enforced here rather than asked for in a prompt. Each increment
/// declares how many added lines it may carry, and `trim` cuts anything larger
/// back to a whole hunk. This is the same principle as `ClaimGuard`: a prompt
/// cannot be the only thing standing between a model and the screen.
public enum CodingIncrement: String, Codable, Sendable, CaseIterable {
    /// One question, because the ambiguity changes the design.
    case clarify
    /// Approach and complexity, in words. No code.
    case sketch
    /// Signature, types, and a `TODO` body. Deliberately not working.
    case skeleton
    /// One branch, case, or step of something that already exists.
    case fillOne
    /// One edge case.
    case harden
    /// Replace a naive step with the better one. Only after something passes.
    case optimise
    /// Run the check.
    case verify
    /// Say what just happened. No code.
    case narrate

    /// Added lines this increment may hand over.
    ///
    /// Sized from what a candidate plausibly types while still talking. A
    /// skeleton is a signature and a `TODO`; filling one branch is a handful of
    /// lines. Nothing here is large enough to be a whole solution, which is the
    /// point.
    public var maximumAddedLines: Int {
        switch self {
        case .clarify, .sketch, .verify, .narrate: 0
        case .skeleton: 12
        case .fillOne: 16
        case .harden: 10
        case .optimise: 20
        }
    }

    public var allowsCode: Bool { maximumAddedLines > 0 }

    /// The move kind this increment publishes as.
    public var moveKind: CodingMoveKind {
        switch self {
        case .clarify: .explanation
        case .sketch: .design
        case .skeleton, .fillOne: .implementation
        case .harden, .optimise: .edit
        case .verify: .verification
        case .narrate: .explanation
        }
    }
}

/// What the engine knows about how far the work has got.
///
/// Every field is an engine fact — none of it is model output read back.
public struct CodingCadenceFacts: Sendable, Equatable {
    public var phase: CodingPhase
    /// The candidate's tree already contains something for this task.
    public var hasCode: Bool
    /// At least one check has passed against the current revision.
    public var hasPassingRun: Bool
    /// The most recent run failed.
    public var hasFailingRun: Bool
    /// A check is staged and not yet run.
    public var hasPendingRun: Bool
    /// Fraction of the booked time already spent, when the interview is boxed.
    public var elapsedFraction: Double?

    public init(phase: CodingPhase, hasCode: Bool = false, hasPassingRun: Bool = false,
                hasFailingRun: Bool = false, hasPendingRun: Bool = false,
                elapsedFraction: Double? = nil) {
        self.phase = phase; self.hasCode = hasCode
        self.hasPassingRun = hasPassingRun; self.hasFailingRun = hasFailingRun
        self.hasPendingRun = hasPendingRun; self.elapsedFraction = elapsedFraction
    }
}

public enum CodingCadence {
    /// Which increments are legitimate right now, best first.
    ///
    /// Order matters: the head of this list is what the model is asked for, and
    /// what a rejected oversize move is downgraded to.
    public static func allowed(_ facts: CodingCadenceFacts) -> [CodingIncrement] {
        // A failing check outranks everything. Nothing else is worth saying
        // while the thing on screen is red.
        if facts.hasFailingRun { return [.fillOne, .harden, .narrate] }

        switch facts.phase {
        case .understanding:
            return [.clarify, .sketch]
        case .designing:
            return facts.hasCode ? [.sketch, .skeleton] : [.sketch, .clarify]
        case .implementing:
            // The skeleton comes before any body. This is the single rule that
            // stops a finished function appearing at once.
            return facts.hasCode ? [.fillOne, .harden, .verify] : [.skeleton, .sketch]
        case .debugging:
            return [.fillOne, .harden, .narrate]
        case .verifying:
            // Optimisation is unreachable until something passes: rewriting for
            // speed before it is correct is the mistake this ordering prevents.
            return facts.hasPassingRun ? [.harden, .optimise, .narrate] : [.verify, .fillOne]
        case .wrappingUp:
            return [.narrate, .harden]
        }
    }

    /// Whether an increment may be published at all given the facts.
    public static func permits(_ increment: CodingIncrement, _ facts: CodingCadenceFacts) -> Bool {
        if increment == .optimise, !facts.hasPassingRun { return false }
        if increment == .verify, !facts.hasPendingRun { return false }
        return allowed(facts).contains(increment)
    }

    /// Cut a unified diff back to what this increment is allowed to hand over.
    ///
    /// Returns the trimmed diff and whether anything was withheld. Cutting at a
    /// hunk boundary keeps the result a valid, typeable change; cutting at an
    /// arbitrary line would hand the candidate something that does not apply.
    /// A single hunk larger than the cap is kept whole rather than mangled — the
    /// caller downgrades the move instead.
    public static func trim(diff: String, to increment: CodingIncrement)
        -> (diff: String, withheld: Bool) {
        guard increment.allowsCode else { return (diff.isEmpty ? "" : "", !diff.isEmpty) }
        let cap = increment.maximumAddedLines
        guard addedLines(in: diff) > cap else { return (diff, false) }

        var kept: [String] = []
        var current: [String] = []
        var added = 0
        var withheld = false
        var inHunk = false

        func flush() {
            guard !current.isEmpty else { return }
            kept.append(contentsOf: current)
            current.removeAll()
        }

        for line in diff.components(separatedBy: "\n") {
            if line.hasPrefix("@@") {
                // A hunk boundary: commit what we have, then decide whether the
                // next hunk still fits.
                flush()
                if added >= cap { withheld = true; break }
                inHunk = true
                current = [line]
                continue
            }
            if !inHunk { kept.append(line); continue }
            if isAdded(line) {
                if added >= cap { withheld = true; flush(); break }
                added += 1
            }
            current.append(line)
        }
        flush()
        let trimmed = kept.joined(separator: "\n").trimmingCharacters(in: .newlines)
        return (trimmed, withheld)
    }

    /// Added lines in a unified diff, ignoring the `+++` file header.
    public static func addedLines(in diff: String) -> Int {
        diff.components(separatedBy: "\n").reduce(into: 0) { total, line in
            if isAdded(line) { total += 1 }
        }
    }

    private static func isAdded(_ line: String) -> Bool {
        line.hasPrefix("+") && !line.hasPrefix("+++")
    }
}
