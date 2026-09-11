import CallaContracts
import Foundation

/// Did the check prove what it was supposed to prove.
///
/// Three states rather than two, for the reason Tutor's verifier uses three
/// (`pedagogy.md`, PED-5): a command that could not run, timed out, or produced
/// nothing to match against is *unknown*, and treating unknown as failure sends
/// the candidate debugging code that is fine.
public enum CodingVerdict: String, Codable, Sendable, Equatable {
    case satisfied, unsatisfied, unknown
}

public enum CodingRunVerdictJudge {
    /// Compare a finished run against the evidence its plan asked for.
    ///
    /// `expectedEvidence` has been written into every plan since the contract
    /// existed and never once been read, so a green exit code was the only
    /// signal — which is wrong in both directions. A test runner that skips
    /// every test exits 0; a linter that prints the expected warning exits 1.
    public static func judge(run: CodingRun, expected: String?) -> CodingVerdict {
        switch run.lifecycle {
        case .pending, .running:
            return .unknown
        case .cancelled, .timedOut, .environmentFailure:
            return .unknown
        case .passed, .failed:
            break
        }

        guard let expected = expected?.trimmingCharacters(in: .whitespacesAndNewlines),
              !expected.isEmpty else {
            // Nothing to match: fall back to the exit code, which is all the
            // information there is.
            return run.lifecycle == .passed ? .satisfied : .unsatisfied
        }

        // Output truncation means absence is not evidence of absence.
        if run.outputTruncated, !matches(expected, in: run.outputSummary) { return .unknown }
        if run.outputSummary.isEmpty { return .unknown }

        let found = matches(expected, in: run.outputSummary)
        if run.lifecycle == .passed { return found ? .satisfied : .unknown }
        return found ? .satisfied : .unsatisfied
    }

    /// Loose containment: every significant word of the expectation appears.
    ///
    /// Deliberately not a regex. `expectedEvidence` is authored as a sentence
    /// ("All Swift tests pass"), and holding it to an exact substring of tool
    /// output would make it never match — a guard nobody can satisfy gets
    /// removed, which is how `ClaimGuard` earned its 5-character prefix rule.
    static func matches(_ expected: String, in output: String) -> Bool {
        let haystack = output.lowercased()
        let needles = expected.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 3 && !stopWords.contains($0) }
        guard !needles.isEmpty else { return haystack.contains(expected.lowercased()) }
        return needles.allSatisfy { haystack.contains($0) }
    }

    private static let stopWords: Set<String> = [
        "the", "all", "and", "that", "with", "from", "this", "have", "been", "will"
    ]
}
