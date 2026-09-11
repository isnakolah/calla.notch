import CallaContracts
import CryptoKit
import Foundation

public struct QuizFrameObservation: Sendable, Equatable {
    public let capturedAt: Date
    public let captureGeneration: Int
    public let normalizedOCR: String
    public let tileHashes: [UInt64]
    public let visualHash: UInt64
    public let anchors: [String]

    public init(capturedAt: Date = Date(), captureGeneration: Int,
                normalizedOCR: String, tileHashes: [UInt64], visualHash: UInt64,
                anchors: [String] = []) {
        self.capturedAt = capturedAt
        self.captureGeneration = captureGeneration
        self.normalizedOCR = Self.normalizeOCR(normalizedOCR)
        self.tileHashes = Array(tileHashes.prefix(4_096))
        self.visualHash = visualHash
        self.anchors = Array(anchors.map(Self.normalizeOCR).filter { !$0.isEmpty }.prefix(64))
    }

    public static func normalizeOCR(_ value: String) -> String {
        var result = value.lowercased()
            .replacingOccurrences(of: #"\b\d{1,2}:\d{2}(?::\d{2})?\b"#,
                                  with: "<timer>", options: .regularExpression)
            .replacingOccurrences(of: #"\b\d+(?:\.\d+)?\s*%\s*(?:remaining|left)?\b"#,
                                  with: "<progress>", options: .regularExpression)
        result = result.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "\n" || scalar == " "
                ? String(scalar) : " "
        }.joined()
        return result.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// How much of the frame moved, as a fraction of its tiles.
    ///
    /// Exposed because the capture host needs the same measure the detector uses:
    /// a frame whose tiles have not moved does not need to be read again.
    public static func tileDifference(_ lhs: [UInt64], _ rhs: [UInt64]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return lhs == rhs ? 0 : 1 }
        let changed = zip(lhs, rhs).reduce(0) { $0 + (($1.0 ^ $1.1).nonzeroBitCount > 4 ? 1 : 0) }
        return Double(changed) / Double(lhs.count)
    }

    public var fingerprint: String {
        let anchorText = anchors.sorted().joined(separator: "|")
        let source = "\(normalizedOCR)|\(anchorText)|\(String(visualHash, radix: 16))"
        return SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// What identifies a *question*, as against `fingerprint`, which identifies a
    /// frame.
    ///
    /// The difference is `visualHash`, and it is the whole point. The session's
    /// answer cache is keyed on this, so meeting a question again — scrolled back
    /// to, redrawn, shown with a different hover state or at a different scroll
    /// offset — is answered from what the session already knows instead of
    /// spending a council on it a second time. Keyed on the frame's hash, every
    /// one of those was a miss.
    public var answerKey: String {
        let anchorText = anchors.sorted().joined(separator: "|")
        return SHA256.hash(data: Data("\(normalizedOCR)|\(anchorText)".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

public struct QuizStableQuestion: Sendable, Equatable {
    public let questionID: String
    public let generation: Int
    public let fingerprint: String
    /// Text-and-anchors identity, for the session's answer cache.
    public let answerKey: String
    public let captureGeneration: Int
    public let continuedViewport: Bool

    public init(questionID: String, generation: Int, fingerprint: String,
                answerKey: String = "", captureGeneration: Int, continuedViewport: Bool) {
        self.questionID = questionID
        self.generation = generation
        self.fingerprint = fingerprint
        self.answerKey = answerKey
        self.captureGeneration = captureGeneration
        self.continuedViewport = continuedViewport
    }
}

public enum QuizDetection: Sendable, Equatable {
    case ignoredAnimation
    case stabilizing
    case unchanged(QuizStableQuestion)
    case newQuestion(QuizStableQuestion)
    case continuation(QuizStableQuestion)
}

/// Pure stable-frame detector. Watcher frames stay memory-only; only a stable
/// observation can become a submitted viewport.
public struct QuizQuestionDetector: Sendable {
    public var stableInterval: TimeInterval
    public var maximumAnimationTileRatio: Double
    public var minimumOCRSimilarity: Double
    /// How much of the words have to survive for this to still be the question
    /// already on screen.
    ///
    /// Deliberately looser than `minimumOCRSimilarity`. That one asks "is this
    /// frame the same picture"; this one asks "is this the same question", and a
    /// question does not stop being itself because a hint expanded, an option
    /// got a hover state, or the fast OCR pass read one word differently.
    public var minimumSameQuestionSimilarity: Double

    private var candidate: QuizFrameObservation?
    private var current: (observation: QuizFrameObservation, question: QuizStableQuestion)?
    private var nextGeneration = 0
    private var expectsContinuation = false

    public init(stableInterval: TimeInterval = 0.75,
                maximumAnimationTileRatio: Double = 0.08,
                minimumOCRSimilarity: Double = 0.94,
                minimumSameQuestionSimilarity: Double = 0.9) {
        self.stableInterval = max(0.1, stableInterval)
        self.maximumAnimationTileRatio = min(1, max(0, maximumAnimationTileRatio))
        self.minimumOCRSimilarity = min(1, max(0, minimumOCRSimilarity))
        self.minimumSameQuestionSimilarity = min(1, max(0, minimumSameQuestionSimilarity))
    }

    public mutating func markScrollRequested() {
        expectsContinuation = true
        candidate = nil
    }

    public mutating func resetForRetarget() {
        candidate = nil
        current = nil
        expectsContinuation = false
        nextGeneration += 1
    }

    public mutating func observe(_ observation: QuizFrameObservation) -> QuizDetection {
        if let current, isEquivalent(observation, current.observation) {
            candidate = nil
            // The baseline moves with the screen. Held at the frame the question
            // was accepted on, a page that drifts a little at a time — a caret, a
            // hover state, a lazily-loaded image, a clock — eventually drifts
            // past the threshold against a picture minutes old, and the same
            // question on the same screen is declared a new one.
            self.current = (observation, current.question)
            return .unchanged(current.question)
        }

        if let candidate {
            guard isStableMatch(candidate, observation) else {
                let animation = isSmallAnimation(candidate, observation)
                self.candidate = observation
                return animation ? .ignoredAnimation : .stabilizing
            }
            guard observation.capturedAt.timeIntervalSince(candidate.capturedAt) >= stableInterval else {
                return .stabilizing
            }
        } else {
            candidate = observation
            return .stabilizing
        }

        let prior = current
        candidate = nil
        // A screen that settled again is not necessarily a different question.
        //
        // Only pixels were consulted here, so anything that moved enough to fail
        // the equivalence check minted a new question id and a new generation —
        // which cancels the answer already being worked on. On a page with any
        // life in it that repeated every few seconds, and the reader saw the
        // first question answered and then nothing: each attempt was superseded
        // before the council could finish. Words are the thing that actually
        // distinguishes one question from another, so they get the final say.
        if !expectsContinuation, let prior,
           isSameQuestionText(prior.observation, observation) {
            current = (observation, prior.question)
            return .unchanged(prior.question)
        }
        if expectsContinuation, let prior, isContinuation(from: prior.observation, to: observation) {
            expectsContinuation = false
            let question = QuizStableQuestion(
                questionID: prior.question.questionID,
                generation: prior.question.generation,
                fingerprint: prior.question.fingerprint,
                answerKey: prior.question.answerKey,
                captureGeneration: observation.captureGeneration,
                continuedViewport: true)
            current = (observation, question)
            return .continuation(question)
        }

        expectsContinuation = false
        nextGeneration += 1
        let question = QuizStableQuestion(
            questionID: "question-" + UUID().uuidString.lowercased(),
            generation: nextGeneration,
            fingerprint: observation.fingerprint,
            answerKey: observation.answerKey,
            captureGeneration: observation.captureGeneration,
            continuedViewport: false)
        current = (observation, question)
        return .newQuestion(question)
    }

    private func isStableMatch(_ lhs: QuizFrameObservation, _ rhs: QuizFrameObservation) -> Bool {
        tileDifference(lhs.tileHashes, rhs.tileHashes) <= maximumAnimationTileRatio
            && textSimilarity(lhs.normalizedOCR, rhs.normalizedOCR) >= minimumOCRSimilarity
            && lhs.visualHash.nonzeroBitCountDistance(to: rhs.visualHash) <= 6
    }

    private func isEquivalent(_ lhs: QuizFrameObservation, _ rhs: QuizFrameObservation) -> Bool {
        lhs.fingerprint == rhs.fingerprint || isStableMatch(lhs, rhs)
    }

    private func isSmallAnimation(_ lhs: QuizFrameObservation, _ rhs: QuizFrameObservation) -> Bool {
        textSimilarity(lhs.normalizedOCR, rhs.normalizedOCR) >= minimumOCRSimilarity
            && tileDifference(lhs.tileHashes, rhs.tileHashes) <= maximumAnimationTileRatio * 2
    }

    /// Whether two settled frames are readably the same question.
    ///
    /// Only meaningful when there is something to read. A screenshot-only
    /// question has no words at all, and two empty strings are trivially
    /// "similar" — so on those frames the pixels stay the only evidence and this
    /// declines to answer. `minimumWordsToJudge` is what makes that decision
    /// explicit rather than an accident of the similarity formula.
    private func isSameQuestionText(_ lhs: QuizFrameObservation,
                                    _ rhs: QuizFrameObservation) -> Bool {
        let left = lhs.normalizedOCR.split(separator: " ")
        let right = rhs.normalizedOCR.split(separator: " ")
        guard left.count >= Self.minimumWordsToJudge,
              right.count >= Self.minimumWordsToJudge else { return false }
        // Anchors settle it outright when there are any.
        //
        // Word similarity is measured over the whole screen, and a quiz page is
        // mostly furniture: navigation, a progress strip, the same four option
        // letters, a footer. Two consecutive questions can therefore share most
        // of their words, and treating that as "still the same question" would
        // mean the next question is never asked at all — the failure this rule
        // exists to prevent, in the opposite direction. The anchors are the
        // headline lines, so `question 4` and `question 5` part here.
        if !lhs.anchors.isEmpty || !rhs.anchors.isEmpty {
            guard Set(lhs.anchors) == Set(rhs.anchors) else { return false }
        }
        return textSimilarity(lhs.normalizedOCR, rhs.normalizedOCR)
            >= minimumSameQuestionSimilarity
    }

    /// Fewer words than this and the frame is not carrying a question's text.
    private static let minimumWordsToJudge = 5

    private func isContinuation(from lhs: QuizFrameObservation, to rhs: QuizFrameObservation) -> Bool {
        let left = Set(lhs.normalizedOCR.split(separator: " ").map(String.init))
        let right = Set(rhs.normalizedOCR.split(separator: " ").map(String.init))
        let overlap = left.intersection(right).count
        let denominator = max(1, min(left.count, right.count))
        let anchorOverlap = !Set(lhs.anchors).intersection(rhs.anchors).isEmpty
        return anchorOverlap || Double(overlap) / Double(denominator) >= 0.25
    }

    private func tileDifference(_ lhs: [UInt64], _ rhs: [UInt64]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return lhs == rhs ? 0 : 1 }
        let changed = zip(lhs, rhs).reduce(0) { $0 + ($1.0.nonzeroBitCountDistance(to: $1.1) > 4 ? 1 : 0) }
        return Double(changed) / Double(lhs.count)
    }

    private func textSimilarity(_ lhs: String, _ rhs: String) -> Double {
        if lhs == rhs { return 1 }
        let left = Set(lhs.split(separator: " ").map(String.init))
        let right = Set(rhs.split(separator: " ").map(String.init))
        guard !left.isEmpty || !right.isEmpty else { return 1 }
        return Double(left.intersection(right).count) / Double(max(1, left.union(right).count))
    }
}

public struct QuizViewportCollector: Sendable {
    public private(set) var frames: [QuizCaptureFrame] = []

    public init() {}

    public mutating func append(_ frame: QuizCaptureFrame) throws {
        try QuizContractValidation.validate(frame)
        guard frames.count < QuizContract.maximumViewports else { return }
        guard frames.allSatisfy({ $0.sessionID == frame.sessionID
            && $0.questionID == frame.questionID
            && $0.questionGeneration == frame.questionGeneration }) else {
            frames.removeAll(keepingCapacity: true)
            frames.append(frame)
            return
        }
        frames.append(frame)
    }
}

private extension UInt64 {
    func nonzeroBitCountDistance(to other: UInt64) -> Int { (self ^ other).nonzeroBitCount }
}

/// Joins the OCR of a question's viewports for the prompt.
///
/// A scrolled continuation deliberately overlaps the frame before it — that
/// overlap is what proves the two halves belong to the same question. Joining
/// the texts raw then fed the shared region to the model twice, so a
/// four-viewport question could repeat most of its own prompt back at the
/// council as though the repetition were more evidence.
public enum QuizViewportOCR {
    public static func merged(_ viewports: [String]) -> String {
        var merged: [String] = []
        var seen = Set<String>()
        for (index, text) in viewports.enumerated() {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            // The first viewport is kept whole; only what a later one repeats
            // from an earlier one is dropped.
            let kept = index == 0 ? lines : lines.filter { !seen.contains($0) }
            seen.formUnion(lines)
            guard !kept.isEmpty else { continue }
            merged.append(kept.joined(separator: "\n"))
        }
        return merged.joined(separator: "\n--- viewport ---\n")
    }
}
