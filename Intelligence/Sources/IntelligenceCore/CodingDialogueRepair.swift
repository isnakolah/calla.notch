import CallaContracts
import Foundation

/// Makes one dialogue reply readable without inventing anything.
///
/// The dialogue contract has required fields at six levels — an anchor's two
/// sequence numbers, an evidence item's anchor/speaker/quote, a fact's
/// id/text/kind/evidence, a clarification's five, a pending item's five, a
/// completion's three. Under `--json-schema` the model could not omit one. On
/// the resident language server there is no schema — `agentapi` takes no such
/// flag — so it omits them routinely, and a single missing field used to throw
/// away the entire turn: `"The reply left out dialogue.evidence.Index 0.anchor"`
/// with three perfectly good pointers sitting in the same object.
///
/// Two repairs, in this order, neither of which can admit anything the strict
/// decoder would have rejected:
///
/// 1. **Recover an anchor from the quote.** An evidence item with a quote but
///    no anchor is looked up in the transcript the *engine* recorded. Exactly
///    one match means the anchor is not a guess, it is a lookup in our own
///    data; zero or several means it is dropped. This is what keeps the stage
///    machine moving, because `discussedSteps` is refused without cited
///    evidence and the interview then sits in `understanding` for ever.
/// 2. **Drop what still cannot be read.** Per item, by trial decode, so there
///    is no second copy of the schema here to drift from the types.
///
/// What survives is still checked by `CodingInterviewFlow.apply`: every anchor
/// must match a recorded turn, a requirement must be quoted from the
/// interviewer, a completion must appear in the saved file. Pruning only
/// decides what reaches those rules; it never relaxes them.
public enum CodingDialogueRepair {

    /// Repair the `dialogue` object of one reply, in place, against the
    /// transcript the engine recorded.
    public static func repair(dialogue: [String: Any],
                              transcript: [CodingDialogueEvidence]) -> [String: Any] {
        var out = dialogue

        out["evidence"] = evidenceList(dialogue["evidence"], transcript: transcript)

        if let facts = dialogue["facts"] as? [[String: Any]] {
            out["facts"] = facts.compactMap { fact -> [String: Any]? in
                var item = fact
                item["evidence"] = evidenceList(fact["evidence"], transcript: transcript)
                // A fact with no readable citation is exactly what `apply`
                // refuses, and one unreadable fact must not cost the pointers.
                guard (item["evidence"] as? [Any])?.isEmpty == false else { return nil }
                return decodes(item, as: CodingDialogueFact.self) ? item : nil
            }
        }

        if let pending = dialogue["pending"] as? [[String: Any]] {
            out["pending"] = pending.compactMap { work -> [String: Any]? in
                var item = work
                // A completion whose proof cannot be read is an ordinary
                // outstanding item, not a lost one.
                if let proof = work["completedEvidence"],
                   !decodes(proof, as: CodingSavedEvidence.self) {
                    item["completedEvidence"] = nil
                }
                return decodes(item, as: CodingPendingWork.self) ? item : nil
            }
        }

        if let clarification = dialogue["clarification"] as? [String: Any] {
            var item = clarification
            item["evidence"] = evidenceList(clarification["evidence"], transcript: transcript)
            if let asked = clarification["asked"] {
                item["asked"] = single(asked, transcript: transcript)
            }
            out["clarification"] = decodes(item, as: CodingClarification.self) ? item : nil
        }

        if let question = dialogue["questionToAssistant"] {
            out["questionToAssistant"] = single(question, transcript: transcript)
        }

        return out.compactMapValues { $0 is NSNull ? nil : $0 }
    }

    // MARK: - Evidence

    private static func evidenceList(_ value: Any?,
                                     transcript: [CodingDialogueEvidence]) -> [[String: Any]] {
        guard let items = value as? [[String: Any]] else { return [] }
        return items.compactMap { single($0, transcript: transcript) }
    }

    /// One evidence item, anchored if it can be, dropped if it cannot.
    private static func single(_ value: Any,
                               transcript: [CodingDialogueEvidence]) -> [String: Any]? {
        guard var item = value as? [String: Any] else { return nil }
        if item["anchor"] == nil || !decodes(item["anchor"] as Any, as: CodingTextAnchor.self),
           let quote = item["quote"] as? String,
           let anchor = anchor(forQuote: quote, in: transcript) {
            item["anchor"] = ["fromSequence": anchor.fromSequence, "toSequence": anchor.toSequence]
        }
        return decodes(item, as: CodingDialogueEvidence.self) ? item : nil
    }

    /// The one recorded turn containing this quote, or nothing.
    ///
    /// Unambiguous or not at all: a quote appearing in two turns cannot say
    /// which one the model meant, and picking either would be the invention
    /// this whole file exists to avoid.
    static func anchor(forQuote quote: String,
                       in transcript: [CodingDialogueEvidence]) -> CodingTextAnchor? {
        let needle = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        let matches = transcript.filter { $0.quote.contains(needle) }
        guard matches.count == 1 else { return nil }
        return matches[0].anchor
    }

    // MARK: - Trial decode

    /// Whether this fragment satisfies its type. Asking the decoder rather than
    /// listing required fields is what keeps this file from becoming a second,
    /// drifting copy of the contract.
    private static func decodes<T: Decodable>(_ fragment: Any, as type: T.Type) -> Bool {
        guard JSONSerialization.isValidJSONObject(fragment)
                || fragment is [String: Any] || fragment is [Any],
              let data = try? JSONSerialization.data(withJSONObject: fragment)
        else { return false }
        return (try? JSONDecoder().decode(type, from: data)) != nil
    }
}
