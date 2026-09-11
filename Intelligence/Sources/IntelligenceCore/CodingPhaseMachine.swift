import CallaContracts
import Foundation

/// Where the interview has actually got to.
///
/// `CodingPhase` has been in the contract since v1 and was never once assigned —
/// every snapshot ever published said `.understanding`. That is not a cosmetic
/// gap: phase is what decides whether the right next move is a clarifying
/// question or an edge case, so without it every move is guessed at the wrong
/// altitude.
///
/// Advanced only by evidence the engine holds — a diff, a run, the clock. Never
/// by model output, for the same reason Tutor refuses it (`pedagogy.md`: "Model
/// output is never parsed as a target, command, verifier result or progression
/// decision").
public struct CodingPhaseMachine: Sendable, Equatable {
    public private(set) var phase: CodingPhase
    /// Phase never walks backwards on its own. An interview that has started
    /// implementing does not return to `understanding` because the candidate
    /// asked a question; only an explicit reset does that.
    private var highWater: Int

    public init(phase: CodingPhase = .understanding) {
        self.phase = phase
        self.highWater = Self.rank(phase)
    }

    public struct Evidence: Sendable, Equatable {
        /// Added lines in the candidate's tree since the session began.
        public var addedLines: Int
        public var lastVerdict: CodingVerdict?
        public var hasPendingRun: Bool
        /// 0...1 of the booked interview spent, nil when not timeboxed.
        public var elapsedFraction: Double?
        /// The candidate has spoken about approach or complexity.
        public var discussedApproach: Bool

        public init(addedLines: Int = 0, lastVerdict: CodingVerdict? = nil,
                    hasPendingRun: Bool = false, elapsedFraction: Double? = nil,
                    discussedApproach: Bool = false) {
            self.addedLines = addedLines; self.lastVerdict = lastVerdict
            self.hasPendingRun = hasPendingRun; self.elapsedFraction = elapsedFraction
            self.discussedApproach = discussedApproach
        }
    }

    @discardableResult
    public mutating func advance(_ evidence: Evidence) -> CodingPhase {
        var candidate = derive(evidence)

        // Wrapping up outranks the ladder: past the threshold, what matters is
        // landing what exists, whatever stage the code is at.
        if let fraction = evidence.elapsedFraction, fraction >= 0.8 {
            candidate = .wrappingUp
        }

        let rank = Self.rank(candidate)
        if rank >= highWater {
            highWater = rank
            phase = candidate
        } else if candidate == .debugging {
            // Debugging is the one legitimate step back: a failing check after a
            // passing one is real, and pretending otherwise would keep offering
            // optimisations over red output.
            phase = .debugging
        }
        return phase
    }

    private func derive(_ evidence: Evidence) -> CodingPhase {
        if evidence.lastVerdict == .unsatisfied { return .debugging }
        if evidence.lastVerdict == .satisfied { return .verifying }
        if evidence.hasPendingRun, evidence.addedLines > 0 { return .verifying }
        if evidence.addedLines > 0 { return .implementing }
        if evidence.discussedApproach { return .designing }
        return .understanding
    }

    private static func rank(_ phase: CodingPhase) -> Int {
        switch phase {
        case .understanding: 0
        case .designing: 1
        case .implementing: 2
        case .debugging: 3
        case .verifying: 4
        case .wrappingUp: 5
        }
    }
}
