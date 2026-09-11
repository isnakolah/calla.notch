import Foundation

public extension StatementRules {
    /// Tuned for a candidate thinking aloud rather than answering.
    ///
    /// The call preset assumes a two-party exchange where somebody is always
    /// making a point. A coding interview is mostly one person reasoning at a
    /// keyboard, with long silences that mean "typing", not "finished". Flushing
    /// those at 1.5s the way `.call` does turns one thought into four statements
    /// and spends four requests chasing fragments of it.
    ///
    /// Three deliberate divergences from `.call`:
    ///
    /// - `silenceGap` and `hangingGap` roughly double. A pause mid-implementation
    ///   is the normal state, not a boundary.
    /// - `requestFloor` rises to 4s. Moves are expensive to read while typing,
    ///   and the panel changing under the candidate is worse than being a beat
    ///   late.
    /// - `questionGap` is untouched. The interviewer asking something is the one
    ///   input that is wanted immediately, and it already bypasses the floor.
    static let coding = StatementRules(
        vadCapSeconds: 9.5,
        cappedContinuationGap: 0.3,
        questionGap: 0.35,
        terminalGap: 1.0,
        silenceGap: 3.0,
        hangingGap: 4.5,
        minWords: 1,
        maxWords: 120,
        maxSpan: 30,
        idleWait: 6,
        requestFloor: 4.0,
        minMeaningfulWords: 1,
        codingRequests: true
    )
}
