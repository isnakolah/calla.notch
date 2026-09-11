import CallaContracts
import Foundation

/// Where one voter has got to.
///
/// The pool used to report a voter as `QuizAgyWorkerResult?`, which collapsed two
/// very different states into `nil`: "has not answered yet" and "answered with
/// nothing". That distinction is the whole of early settling — a *failure* under
/// unanimity means "all N agree" is already unreachable and the council can stop
/// waiting, while a *pending* slot could still agree with everyone else.
public enum QuizVoteSlot: Sendable, Equatable {
    case pending
    case failed
    case returned(QuizWorkerOutput)

    public var output: QuizWorkerOutput? {
        if case .returned(let output) = self { return output }
        return nil
    }

    public var isPending: Bool { self == .pending }
}

/// Decides whether a council has said enough.
///
/// `QuizEnsembleResolver.decide` answers "given every vote, what is the verdict".
/// This answers the question that actually saves time: "given the votes so far,
/// can the outstanding ones still change it". Whenever the answer is no, the
/// stragglers are cancelled and the answer publishes — so a council costs the
/// time of the voter that *settles* it rather than the time of its slowest member.
public enum QuizCouncil {
    /// A sentinel wins on a majority of the voters, not a fixed two.
    ///
    /// The old threshold was the literal `>= 2`, which is unreachable for a
    /// council of one — a lone voter asking to scroll would have been ignored —
    /// and far too weak for a council of eight. A majority is the same 2 at three
    /// voters, so nothing changes at the old size.
    public static func sentinelThreshold(of count: Int) -> Int {
        max(1, (max(1, count) + 1) / 2)
    }

    /// `nil` means the outstanding voters could still change the outcome.
    public static func earlyDecision(
        slots: [QuizVoteSlot],
        kind: QuizQuestionKind,
        strategy: QuizAnswerStrategy,
        hasArbiter: Bool,
        calibration: QuizConfidenceCalibration = .init()
    ) -> QuizEnsembleDecision? {
        let total = slots.count
        guard total > 0 else { return .arbitrate }
        let returned = slots.compactMap(\.output)
        let pending = slots.filter(\.isPending).count

        // Sentinels first: a council that says it cannot see the whole question
        // has not answered it, whatever else the votes say.
        let sentinels = returned.compactMap(\.sentinel)
        let threshold = sentinelThreshold(of: total)
        for sentinel in [QuizWorkerSentinel.needsScrollUp, .needsScrollDown] {
            if sentinels.filter({ $0 == sentinel }).count >= threshold { return .scroll(sentinel) }
        }
        if sentinels.filter({ $0 == .notAQuestion }).count >= threshold { return .notAQuestion }

        let answers = returned.filter { $0.sentinel == nil }
        let required = strategy.requiredAgreement(of: total)

        // `first` means the first answer, whatever the kind. There is no
        // agreement to check, so the objective/subjective split does not apply —
        // and this is the only rule that can publish a written or code answer
        // without an arbiter round, which is the point of choosing it.
        if strategy == .first, let answer = answers.first {
            return .publish(answer: answer.answer,
                            confidence: calibration.display(raw: answer.confidence, kind: kind))
        }

        // For everything else, a kind that voter agreement can never settle is
        // destined for the arbiter. The votes still matter — they are what cap
        // the arbiter's confidence — so this waits for them rather than
        // cancelling them the moment the first lands.
        guard QuizEnsembleResolver.canPublishWithoutArbiter(kind: kind) else {
            return pending == 0 ? .arbitrate : nil
        }

        // Group by canonical form so "B", "B) Paris" and "B — Paris" count as the
        // same vote.
        var groups: [String: [QuizWorkerOutput]] = [:]
        for answer in answers {
            groups[QuizAnswerCanonicalizer.canonical(answer.answer, kind: kind), default: []]
                .append(answer)
        }
        let best = groups.values.max { $0.count < $1.count }

        if let best, best.count >= required {
            // Confidence is the weakest agreeing voter's, then capped by whatever
            // that band has actually been measured to be worth.
            let raw = best.map(\.confidence).min() ?? 0
            return .publish(answer: best[0].answer,
                            confidence: calibration.display(raw: raw, kind: kind))
        }

        // Nothing has won yet. Can anything still?
        let reachable = (best?.count ?? 0) + pending
        if reachable < required {
            // No group can still reach the threshold — under unanimity that is
            // true the moment one voter fails or two disagree, which is where
            // most of the waiting used to happen.
            return .arbitrate
        }
        return pending == 0 ? .arbitrate : nil
    }
}
