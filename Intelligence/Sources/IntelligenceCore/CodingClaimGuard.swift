import CallaContracts
import Foundation

/// Screens a model move before the candidate reads it out.
///
/// `say` is not advice, it is script — words the candidate speaks to an
/// interviewer. `ClaimGuard` exists on the call side because a copilot once
/// invented a degree its user was about to claim out loud; the coding lane has
/// the same exposure with a different vocabulary. Here the fabrications that
/// matter are structural: a file that is not in the tree, a symbol nobody wrote,
/// a check that cannot run.
///
/// It repairs rather than refuses. A move whose file anchor is wrong is still
/// worth showing without the anchor, and a candidate mid-interview is better
/// served by a smaller true move than by an empty panel — the opposite trade to
/// the call lane, where refusing to answer is safe.
public enum CodingClaimGuard {

    /// Everything the engine can vouch for.
    public struct Evidence: Sendable, Equatable {
        /// Relative paths present in the candidate's tree.
        public var knownPaths: Set<String>
        /// Commands the preflight found a runner for.
        public var runnableCommands: Set<String>
        /// Identifiers seen in the diff, run output, brief or transcript.
        public var knownSymbols: Set<String>

        public init(knownPaths: Set<String> = [], runnableCommands: Set<String> = [],
                    knownSymbols: Set<String> = []) {
            self.knownPaths = knownPaths
            self.runnableCommands = runnableCommands
            self.knownSymbols = knownSymbols
        }

        public mutating func learn(text: String) {
            knownSymbols.formUnion(CodingClaimGuard.identifiers(in: text))
        }
    }

    public enum Problem: Sendable, Equatable {
        case unknownPath(String)
        case unrunnableCheck(String)
        case inventedSymbol(String)
        case oversizeIncrement(added: Int, allowed: Int)
        case codeOnAWordsOnlyIncrement
    }

    public struct Outcome: Sendable, Equatable {
        public var move: CodingMove
        public var problems: [Problem]
        public var withheldCode: Bool
        public var isClean: Bool { problems.isEmpty }
    }

    /// Screen and repair. `increment` is the pacing decision already made.
    public static func screen(_ move: CodingMove, increment: CodingIncrement,
                              evidence: Evidence) -> Outcome {
        var repaired = move
        var problems: [Problem] = []
        var withheld = false

        // A file anchor pointing at nothing is worse than none: the candidate
        // tabs to a path that does not exist, in front of the interviewer.
        if let path = repaired.file?.path, !evidence.knownPaths.isEmpty,
           !evidence.knownPaths.contains(path) {
            problems.append(.unknownPath(path))
            repaired.file = nil
        }

        // A staged check that cannot run turns the Run button into a failure the
        // candidate has to explain.
        if let command = repaired.check?.displayedCommand,
           !evidence.runnableCommands.isEmpty,
           !evidence.runnableCommands.contains(where: { command.hasPrefix($0) || $0.hasPrefix(command) }) {
            problems.append(.unrunnableCheck(command))
            repaired.check = nil
        }

        // Identifiers in the script that exist nowhere. Only checked when we
        // have symbols to check against, and only for backticked or dotted
        // names — prose is not evidence of anything and flagging it would make
        // the guard unsatisfiable.
        if !evidence.knownSymbols.isEmpty {
            let claimed = quotedIdentifiers(in: repaired.say ?? "")
            for symbol in claimed where !evidence.knownSymbols.contains(symbol.lowercased()) {
                problems.append(.inventedSymbol(symbol))
            }
        }

        // Pacing. This is the rule that keeps the candidate human.
        if let code = repaired.code, !code.isEmpty {
            if !increment.allowsCode {
                problems.append(.codeOnAWordsOnlyIncrement)
                repaired.code = nil
                // The patch is what the panel draws. Leaving it behind would
                // show the reader the code this branch just decided to withhold.
                repaired.patch = nil
                withheld = true
            } else {
                let added = CodingCadence.addedLines(in: code)
                if added > increment.maximumAddedLines {
                    problems.append(.oversizeIncrement(added: added,
                                                       allowed: increment.maximumAddedLines))
                    let trimmed = CodingCadence.trim(diff: code, to: increment)
                    repaired.code = trimmed.diff.isEmpty ? nil : trimmed.diff
                    if let patch = repaired.patch {
                        let cut = CodingPatchLimits.trimmed(patch, toAddedLines: increment.maximumAddedLines)
                        repaired.patch = cut.changesAnything ? cut : nil
                        // The blob and the patch must agree about what the step
                        // is, since one is copied and the other is read.
                        if let kept = repaired.patch { repaired.code = kept.copyableText }
                    }
                    withheld = trimmed.withheld
                }
            }
        } else if let patch = repaired.patch, patch.changesAnything {
            // A patch with no blob beside it: `CodingTurn.publish` keeps the two
            // in step, so this only happens to a move assembled elsewhere. Put
            // the blob back rather than dropping the patch — the pacing rule
            // above is about how much code a step hands over, and deleting the
            // step to enforce it would be the wrong end of the trade.
            repaired.code = patch.copyableText
            if !increment.allowsCode {
                problems.append(.codeOnAWordsOnlyIncrement)
                repaired.code = nil
                repaired.patch = nil
                withheld = true
            } else if patch.addedLineCount > increment.maximumAddedLines {
                problems.append(.oversizeIncrement(added: patch.addedLineCount,
                                                   allowed: increment.maximumAddedLines))
                let cut = CodingPatchLimits.trimmed(patch, toAddedLines: increment.maximumAddedLines)
                repaired.patch = cut.changesAnything ? cut : nil
                repaired.code = repaired.patch?.copyableText
                withheld = true
            }
        }

        if withheld {
            let note = "More is staged than this step should hand over — take this much, then keep going."
            repaired.watch = repaired.watch.map { "\($0) \(note)" } ?? note
        }

        return Outcome(move: repaired, problems: problems, withheldCode: withheld)
    }

    /// Backticked or dotted names in prose — the things a candidate would type.
    static func quotedIdentifiers(in text: String) -> Set<String> {
        var found: Set<String> = []
        for chunk in text.components(separatedBy: "`").enumerated()
        where chunk.offset % 2 == 1 {
            found.formUnion(identifiers(in: chunk.element))
        }
        for word in text.components(separatedBy: .whitespacesAndNewlines) {
            let bare = word.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:()[]{}\"'"))
            if bare.contains("("), let name = bare.components(separatedBy: "(").first,
               name.count > 2, !name.contains(" ") {
                found.insert(name)
            }
        }
        return found
    }

    static func identifiers(in text: String) -> Set<String> {
        Set(text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).inverted)
            .filter { $0.count > 2 })
    }
}
