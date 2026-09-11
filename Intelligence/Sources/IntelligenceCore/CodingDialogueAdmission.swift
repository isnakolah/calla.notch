import Foundation

/// Whether a completed utterance is worth a dialogue turn.
///
/// `CodingSessionController.consider` sends every completed utterance to the
/// dialogue lane on purpose: narration is where `discussedSteps` credit comes
/// from, so suppressing it the way `CodingDirector` suppresses narration for the
/// *move* lane would cost the candidate reasoning they actually did.
///
/// That leaves one class this reasoning does not cover. An acknowledgement
/// carries no idea, earns no step, and cannot change a fact — but the lane is
/// serial, so it still costs a full model turn, and a question arriving behind
/// two of them waits longer for the acknowledgements than for the model. This is
/// the narrowest possible filter for that: every token has to be an
/// acknowledgement or a filler before an utterance is dropped.
///
/// Deliberately *not* a judgement about usefulness. "That makes sense because
/// the range is inclusive" is not an acknowledgement — it names a reason, and
/// the second half is exactly what the reducer is for.
public enum CodingDialogueAdmission {

    /// True when the utterance is nothing but acknowledgement.
    ///
    /// Callers must not apply this while a clarification is open: a bare "yes"
    /// or "no" is an *answer* there, and `CodingInterviewFlow.apply` resolves
    /// clarifications from exactly that (`allowsYesNo` with a recorded `asked`).
    /// The caller holds the flow state, so the caller makes that check.
    public static func isAcknowledgement(_ text: String) -> Bool {
        let tokens = text
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: { !$0.isLetter && $0 != "'" })
            .map(String.init)
        // An empty flush is not an acknowledgement; it is nothing, and the
        // segmenter has already decided what to do with it.
        guard !tokens.isEmpty else { return false }
        // A long utterance that merely opens on "okay" is a real one. The
        // all-tokens rule below would reject it anyway; this is the cheap guard
        // that stops a long sentence being tokenised for no reason.
        guard tokens.count <= 6 else { return false }
        return tokens.allSatisfy { acknowledgements.contains($0) || fillers.contains($0) }
    }

    /// Words that only ever signal receipt.
    ///
    /// "no" and "yes" are here because they dominate back-channel, and the
    /// clarification guard above is what keeps them safe.
    static let acknowledgements: Set<String> = [
        "yes", "yeah", "yea", "yep", "yup", "no", "nope", "nah",
        "ok", "okay", "kay", "right", "sure", "cool", "nice", "great",
        "good", "fine", "perfect", "lovely", "excellent",
        "mm", "mhm", "mmhm", "mmhmm", "hmm", "huh", "ah", "oh",
        "gotcha", "understood", "exactly", "indeed", "absolutely", "totally",
        "definitely", "true", "correct", "agreed",
        "thanks", "thank", "cheers", "sorry",
        // Only ever reached as part of a phrase whose other words are all in
        // here too — "got it", "makes sense", "i see", "sounds good".
        "got", "it", "makes", "make", "sense", "i", "see", "sounds", "sound",
        "that", "this", "you", "we", "all", "of", "course",
    ]

    /// Speech disfluency. Never evidence on its own.
    static let fillers: Set<String> = [
        "um", "uh", "erm", "er", "like", "so", "well", "just", "then",
        "and", "but", "alright", "anyway", "now",
    ]
}
