import CallaContracts
import Foundation

public enum QuizWorkerSentinel: String, Sendable, Codable, CaseIterable {
    case needsScrollUp = "__NEEDS_SCROLL_UP__"
    case needsScrollDown = "__NEEDS_SCROLL_DOWN__"
    case notAQuestion = "__NOT_A_QUESTION__"
}

public struct QuizWorkerOutput: Sendable, Equatable {
    public let answer: String
    public let confidence: Int
    /// Why this answer is better than the one it replaces.
    ///
    /// Only a refiner fills this in. Voters are held to exactly `answer` and
    /// `confidence` — a free-text field is somewhere for a prompt injection to
    /// hide, and nothing reads it on the voting path.
    public let rationale: String?

    public init(answer: String, confidence: Int, rationale: String? = nil) {
        self.answer = answer
        self.confidence = confidence
        self.rationale = rationale.map { String($0.prefix(4_000)) }
    }

    public var sentinel: QuizWorkerSentinel? { QuizWorkerSentinel(rawValue: answer) }
}

public enum QuizWorkerOutputParser {
    public enum Failure: Error, Equatable, Sendable, LocalizedError {
        case notJSONObject, wrongKeys, invalidAnswer, invalidConfidence

        public var errorDescription: String? {
            switch self {
            case .notJSONObject: "Quiz worker did not return one JSON object"
            case .wrongKeys: "Quiz worker output must contain only answer and confidence"
            case .invalidAnswer: "Quiz worker answer is invalid"
            case .invalidConfidence: "Quiz worker confidence must be integer 0 through 100"
            }
        }
    }

    public static let schema = #"{"type":"object","additionalProperties":false,"properties":{"answer":{"type":"string"},"confidence":{"type":"integer","minimum":0,"maximum":100}},"required":["answer","confidence"]}"#

    /// The refiner's schema: the same, plus the reasoning it was asked for.
    public static let refinementSchema = #"{"type":"object","additionalProperties":false,"properties":{"answer":{"type":"string"},"confidence":{"type":"integer","minimum":0,"maximum":100},"rationale":{"type":"string"}},"required":["answer","confidence","rationale"]}"#

    public static func parse(_ data: Data, allowingRationale: Bool = false) throws -> QuizWorkerOutput {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.notJSONObject
        }
        let permitted: Set<String> = allowingRationale
            ? ["answer", "confidence", "rationale"] : ["answer", "confidence"]
        guard Set(object.keys).isSubset(of: permitted),
              object["answer"] != nil, object["confidence"] != nil else { throw Failure.wrongKeys }
        guard let rawAnswer = object["answer"] as? String else { throw Failure.invalidAnswer }
        let answer = unwrapNestedEnvelope(rawAnswer)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty, answer.utf8.count <= 32_000 else { throw Failure.invalidAnswer }
        guard let number = object["confidence"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { throw Failure.invalidConfidence }
        let double = number.doubleValue
        let confidence = number.intValue
        guard double == Double(confidence), (0 ... 100).contains(confidence) else {
            throw Failure.invalidConfidence
        }
        if QuizWorkerSentinel(rawValue: answer) != nil, confidence != 0 {
            throw Failure.invalidConfidence
        }
        var rationale: String?
        if allowingRationale, let text = object["rationale"] as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            rationale = trimmed.isEmpty ? nil : trimmed
        }
        return QuizWorkerOutput(answer: answer, confidence: confidence, rationale: rationale)
    }

    /// Some providers satisfy the outer schema but serialize that same schema
    /// again inside `answer`. Recover the answer while keeping the outer,
    /// schema-validated confidence authoritative.
    private static func unwrapNestedEnvelope(_ value: String) -> String {
        var candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasPrefix("```json"), candidate.hasSuffix("```") {
            candidate.removeFirst("```json".count)
            candidate.removeLast(3)
            candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = candidate.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["answer", "confidence"],
              object["confidence"] is NSNumber,
              let answer = object["answer"] as? String,
              !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return value
        }
        return answer
    }
}

public enum QuizAnswerCanonicalizer {
    /// Anything a model might put between an option label and its prose.
    ///
    /// This used to be the single character `—`, copied from the example in the
    /// voter prompt. A voter that answered `B) Paris` or `B - Paris` instead of
    /// `B — Paris` produced a different canonical form from one that followed the
    /// example, so three voters agreeing on `B` were recorded as disagreeing and
    /// escalated to a full arbiter round. That is a latency bug as much as an
    /// accuracy one: every spurious disagreement costs a model call.
    private static let labelSeparators: Set<Character> = ["—", "–", "-", ":", ")", ".", "]"]

    public static func canonical(_ answer: String, kind: QuizQuestionKind) -> String {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .singleChoice:
            let head = optionLabel(trimmed)
            return head.uppercased()
        case .multipleChoice:
            return optionTokens(optionLabel(trimmed)).joined(separator: ",")
        case .boolean:
            switch trimmed.lowercased() {
            case "true", "yes", "t": return "true"
            case "false", "no", "f": return "false"
            default: return normalizedText(trimmed)
            }
        case .numeric:
            return normalizedNumeric(trimmed)
        case .code:
            return trimmed.replacingOccurrences(of: "\r\n", with: "\n")
        case .text, .image, .diagram, .unknown:
            return normalizedText(trimmed)
        }
    }

    /// The leading option label, if the answer opens with one.
    ///
    /// A short leading token followed by a separator is a label (`B`, `(B)`,
    /// `B.`, `A, C`). Anything longer is prose, and prose is compared whole —
    /// splitting it would make two genuinely different sentences that share a
    /// first word look identical.
    private static func optionLabel(_ answer: String) -> String {
        var text = answer
        while let first = text.first, first == "(" || first == "[" {
            text.removeFirst()
        }
        guard let index = text.firstIndex(where: labelSeparators.contains) else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let head = text[..<index].trimmingCharacters(in: .whitespacesAndNewlines)
        let body = head.uppercased().filter { !$0.isWhitespace && $0 != "," && $0 != ";" && $0 != "/" }
        // Only characters an option label is actually made of. A first draft
        // allowed any short run of letters, which made `Paris - the capital` and
        // `Paris - the largest city` both canonicalise to `PARIS`. Reading two
        // different answers as agreement is worse than the arbiter round this
        // whole change exists to avoid.
        guard !body.isEmpty, body.count <= 5,
              body.allSatisfy({ ($0.isLetter && $0 <= "H") || ("1" ... "9").contains($0) })
        else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return head
    }

    /// One selection per element, sorted so order never decides agreement.
    private static func optionTokens(_ label: String) -> [String] {
        let parts = label
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "/" || $0 == "&" || $0.isWhitespace })
            .map { $0.uppercased() }
            .filter { !$0.isEmpty && $0 != "AND" }
        // `AC` and `A, C` are the same selection written two ways.
        if parts.count == 1, let only = parts.first, only.count > 1,
           only.allSatisfy({ $0.isLetter && $0 <= "H" }) {
            return only.map(String.init).sorted()
        }
        return parts.sorted()
    }

    /// `3`, `3.0` and `3.00` are one answer. So are `1,000` and `1000`.
    private static func normalizedNumeric(_ text: String) -> String {
        let collapsed = text.lowercased()
            .replacingOccurrences(of: "\u{2212}", with: "-")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s*([/%°])\s*"#, with: "$1", options: .regularExpression)
        return collapsed.split(separator: " ", omittingEmptySubsequences: true)
            .map { normalizedNumberToken(String($0)) }
            .joined(separator: " ")
    }

    private static func normalizedNumberToken(_ token: String) -> String {
        var value = token
        var suffix = ""
        // Keep a trailing unit or punctuation attached rather than dropping it.
        while let last = value.last, !last.isNumber {
            suffix = String(last) + suffix
            value.removeLast()
        }
        var sign = ""
        if value.hasPrefix("-") || value.hasPrefix("+") {
            sign = value.hasPrefix("-") ? "-" : ""
            value.removeFirst()
        }
        let stripped = value.replacingOccurrences(of: ",", with: "")
        guard !stripped.isEmpty, stripped.allSatisfy({ $0.isNumber || $0 == "." }),
              stripped.filter({ $0 == "." }).count <= 1 else { return token }
        guard stripped.contains(".") else { return sign + trimLeadingZeros(stripped) + suffix }
        var parts = stripped.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        var fraction = String(parts.count > 1 ? parts[1] : "")
        while fraction.hasSuffix("0") { fraction.removeLast() }
        let whole = trimLeadingZeros(String(parts[0]).isEmpty ? "0" : String(parts[0]))
        return sign + (fraction.isEmpty ? whole : whole + "." + fraction) + suffix
    }

    private static func trimLeadingZeros(_ value: String) -> String {
        var text = value
        while text.count > 1, text.hasPrefix("0") { text.removeFirst() }
        return text
    }

    private static func normalizedText(_ text: String) -> String {
        text.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

public struct QuizConfidenceCalibration: Sendable, Equatable {
    public struct Bucket: Sendable, Equatable, Hashable {
        public let kind: QuizQuestionKind
        public let lowerBound: Int
        public let measuredAccuracy: Double
        public let sampleCount: Int

        public init(kind: QuizQuestionKind, lowerBound: Int,
                    measuredAccuracy: Double, sampleCount: Int) {
            self.kind = kind
            self.lowerBound = min(90, max(0, lowerBound / 10 * 10))
            self.measuredAccuracy = min(1, max(0, measuredAccuracy))
            self.sampleCount = max(0, sampleCount)
        }
    }

    public let buckets: [Bucket]
    public let overallAccuracyByKind: [QuizQuestionKind: Double]
    public let minimumBucketSize: Int

    public init(buckets: [Bucket] = [], overallAccuracyByKind: [QuizQuestionKind: Double] = [:],
                minimumBucketSize: Int = 20) {
        self.buckets = buckets
        self.overallAccuracyByKind = overallAccuracyByKind
        self.minimumBucketSize = max(1, minimumBucketSize)
    }

    public func display(raw: Int, kind: QuizQuestionKind) -> Int {
        let value = min(100, max(0, raw))
        let lower = min(90, value / 10 * 10)
        let bucket = buckets.first { $0.kind == kind && $0.lowerBound == lower }
        let accuracy = bucket.flatMap { $0.sampleCount >= minimumBucketSize ? $0.measuredAccuracy : nil }
            ?? overallAccuracyByKind[kind]
        guard let accuracy else { return value }
        return min(value, Int(floor(accuracy * 100)))
    }
}

public enum QuizEnsembleDecision: Sendable, Equatable {
    case publish(answer: String, confidence: Int)
    case arbitrate
    case scroll(QuizWorkerSentinel)
    case notAQuestion
}

public enum QuizEnsembleResolver {
    private static let objective: Set<QuizQuestionKind> = [
        .singleChoice, .multipleChoice, .boolean, .numeric
    ]

    /// Whether voter unanimity can settle this kind without the arbiter.
    ///
    /// For every other kind `decide` returns `.arbitrate` no matter what the
    /// voters say, which is what lets the caller dispatch the arbiter alongside
    /// them instead of paying for a second serial round-trip.
    public static func canPublishWithoutArbiter(kind: QuizQuestionKind) -> Bool {
        objective.contains(kind)
    }

    public static func decide(votes: [QuizWorkerOutput?], kind: QuizQuestionKind,
                              calibration: QuizConfidenceCalibration = .init()) -> QuizEnsembleDecision {
        let valid = votes.compactMap { $0 }
        let sentinels = valid.compactMap(\.sentinel)
        for sentinel in [QuizWorkerSentinel.needsScrollUp, .needsScrollDown] {
            if sentinels.filter({ $0 == sentinel }).count >= 2 { return .scroll(sentinel) }
        }
        if sentinels.filter({ $0 == .notAQuestion }).count >= 2 { return .notAQuestion }
        guard valid.count == 3, sentinels.isEmpty, objective.contains(kind) else { return .arbitrate }
        let canonical = valid.map { QuizAnswerCanonicalizer.canonical($0.answer, kind: kind) }
        guard Set(canonical).count == 1 else { return .arbitrate }
        let confidence = calibration.display(raw: valid.map(\.confidence).min() ?? 0, kind: kind)
        return .publish(answer: valid[0].answer, confidence: confidence)
    }

    public static func resolveArbiter(_ arbiter: QuizWorkerOutput?, votes: [QuizWorkerOutput?],
                                      kind: QuizQuestionKind,
                                      calibration: QuizConfidenceCalibration = .init()) -> (String, Int)? {
        guard let arbiter, arbiter.sentinel == nil else { return nil }
        let canonical = QuizAnswerCanonicalizer.canonical(arbiter.answer, kind: kind)
        let supporting = votes.compactMap { $0 }.filter {
            $0.sentinel == nil && QuizAnswerCanonicalizer.canonical($0.answer, kind: kind) == canonical
        }.map(\.confidence).sorted()
        let raw: Int
        if supporting.isEmpty {
            raw = min(50, arbiter.confidence)
        } else {
            raw = min(arbiter.confidence, supporting[supporting.count / 2])
        }
        return (arbiter.answer, calibration.display(raw: raw, kind: kind))
    }
}

/// Identity gate used by capture, workers, arbiter, and UI publication. Any
/// question transition replaces token; late work then fails closed.
public actor QuizGenerationGate {
    public struct Token: Sendable, Equatable, Hashable {
        public let sessionID: String
        public let questionID: String
        public let questionGeneration: Int
        public let captureGeneration: Int

        public init(sessionID: String, questionID: String, questionGeneration: Int,
                    captureGeneration: Int) {
            self.sessionID = sessionID
            self.questionID = questionID
            self.questionGeneration = questionGeneration
            self.captureGeneration = captureGeneration
        }
    }

    private var current: Token?
    public init() {}
    public func replace(with token: Token) { current = token }
    public func clear() { current = nil }
    public func accepts(_ token: Token) -> Bool { current == token }
}
