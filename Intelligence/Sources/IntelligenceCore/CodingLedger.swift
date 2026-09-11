import CallaContracts
import Foundation

/// The interview's memory, in three layers.
///
/// The same shape as `CallLedger`, and for the same reason: an hour of interview
/// must not become an hour of prompt. The account **grows** rather than being
/// rewritten — decisions are appended and never re-emitted, so a context
/// rollover or a worker restart cannot silently lose one.
///
/// Unlike the call ledger this one also carries evidence, because in a coding
/// interview the durable facts are as much the diff and the run history as the
/// conversation.
public struct CodingLedger: Sendable, Equatable {
    /// One folded paragraph for the part nobody is working on any more.
    public private(set) var standing: String = ""
    /// Appended as the interview settles things. Never rewritten.
    public private(set) var decisions: [String] = []
    /// The last few statements, verbatim, not yet folded.
    public private(set) var tail: [Statement] = []
    /// Runs, newest last, capped.
    public private(set) var runs: [RunNote] = []
    /// Verbatim interviewer requirements, distinct from suggested approaches.
    public private(set) var interviewerContext: [Statement] = []

    public struct RunNote: Sendable, Equatable {
        public var id: String
        public var command: String
        public var verdict: CodingVerdict
        public var summary: String
        public init(id: String, command: String, verdict: CodingVerdict, summary: String) {
            self.id = id; self.command = command; self.verdict = verdict
            self.summary = String(summary.suffix(600))
        }
    }

    public var maximumTail = 6
    public var maximumDecisions = 14
    public var maximumRuns = 5

    public init() {}

    public mutating func append(_ statement: Statement) {
        tail.append(statement)
        if tail.count > maximumTail { tail.removeFirst(tail.count - maximumTail) }
        if statement.speaker == .remote, !statement.truncated,
           !statement.text.contains("[unclear]"),
           CodingInterviewerSignal.detect(statement.text) != nil {
            interviewerContext.append(statement)
            if interviewerContext.count > 8 { interviewerContext.removeFirst() }
        }
    }

    /// Record something settled. Ignores a duplicate of the newest entry, which
    /// is what a re-asked question produces.
    public mutating func decide(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, decisions.last != value else { return }
        decisions.append(value)
        if decisions.count > maximumDecisions { fold() }
    }

    public mutating func record(_ run: RunNote) {
        runs.removeAll { $0.id == run.id }
        runs.append(run)
        if runs.count > maximumRuns { runs.removeFirst(runs.count - maximumRuns) }
    }

    /// Oldest decisions become one standing line and leave.
    ///
    /// Nothing folded is recorded anywhere else, so whatever this drops is gone
    /// for the rest of the interview — hence folding the *oldest* half only, and
    /// keeping the sentence rather than summarising it away.
    public mutating func fold() {
        let half = decisions.count / 2
        guard half > 0 else { return }
        let folded = decisions.prefix(half).joined(separator: "; ")
        standing = standing.isEmpty ? folded : standing + "; " + folded
        decisions.removeFirst(half)
        if standing.count > 1_200 { standing = String(standing.suffix(1_200)) }
    }

    /// The bounded account, rendered for `ledger.md`.
    public func markdown() -> String {
        var lines = ["# Ledger", ""]
        if !standing.isEmpty { lines += ["## Standing", standing, ""] }
        if !decisions.isEmpty {
            lines.append("## Decisions")
            lines += decisions.map { "- \($0)" }
            lines.append("")
        }
        if !runs.isEmpty {
            lines.append("## Checks")
            lines += runs.map { "- `\($0.command)` → **\($0.verdict.rawValue)**" }
            lines.append("")
        }
        if !interviewerContext.isEmpty {
            lines += ["## Interviewer requirements (latest correction wins)"]
            lines += interviewerContext.map { "- [\($0.toSeq)] \(String($0.text.prefix(300)))" }
            lines.append("")
        }
        if !tail.isEmpty {
            lines.append("## Just said")
            lines += tail.map { "- \($0.speaker == .local ? "Me" : "Them"): \($0.text)" }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
