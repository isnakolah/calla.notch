import CallaContracts
import Foundation

public struct QuizEvaluationRecord: Sendable, Equatable {
    public let exampleID: String
    public let kind: QuizQuestionKind
    public let voterCorrect: [Bool]
    public let ensembleCorrect: Bool
    public let answeredOrFailed: Bool
    public let transitionDetected: Bool
    public let stalePublications: Int
    public let duration: TimeInterval
    public let displayedConfidence: Int
    public let workers: [QuizWorkerIdentity]

    public init(exampleID: String, kind: QuizQuestionKind, voterCorrect: [Bool],
                ensembleCorrect: Bool, answeredOrFailed: Bool = true,
                transitionDetected: Bool = true, stalePublications: Int = 0,
                duration: TimeInterval, displayedConfidence: Int,
                workers: [QuizWorkerIdentity]) {
        self.exampleID = exampleID
        self.kind = kind
        self.voterCorrect = voterCorrect
        self.ensembleCorrect = ensembleCorrect
        self.answeredOrFailed = answeredOrFailed
        self.transitionDetected = transitionDetected
        self.stalePublications = stalePublications
        self.duration = duration
        self.displayedConfidence = displayedConfidence
        self.workers = workers
    }
}

public struct QuizAccuracyGateReport: Sendable, Equatable {
    public let passed: Bool
    public let failures: [String]
    public let ensembleAccuracy: Double
    public let voterAccuracies: [Double]
}

/// Pure release gate over frozen-corpus results. Runner remains separate so
/// licensed question material and remote credentials never enter package tests.
public enum QuizAccuracyGate {
    public static let supportedKinds: [QuizQuestionKind] = [
        .singleChoice, .multipleChoice, .boolean, .text,
        .numeric, .code, .image, .diagram,
    ]

    public static func evaluate(_ records: [QuizEvaluationRecord],
                                minimumPerKind: Int = 20,
                                minimumConfidenceBucket: Int = 20) -> QuizAccuracyGateReport {
        var failures: [String] = []
        for kind in supportedKinds where records.filter({ $0.kind == kind }).count < minimumPerKind {
            failures.append("fewer than \(minimumPerKind) examples for \(kind.rawValue)")
        }
        guard !records.isEmpty else {
            return .init(passed: false, failures: failures + ["empty corpus"],
                         ensembleAccuracy: 0, voterAccuracies: [])
        }
        // The council is the user's to size, so the corpus decides how many
        // voters an example has — it only has to be consistent about it.
        let voterCount = records[0].voterCorrect.count
        guard voterCount > 0,
              records.allSatisfy({ $0.voterCorrect.count == voterCount
                                   && $0.workers.count == voterCount }) else {
            return .init(passed: false,
                         failures: failures + ["every example needs the same voter count"],
                         ensembleAccuracy: 0, voterAccuracies: [])
        }

        let count = Double(records.count)
        let ensemble = Double(records.filter(\.ensembleCorrect).count) / count
        let voters = (0 ..< voterCount).map { slot in
            Double(records.filter { $0.voterCorrect[slot] }.count) / count
        }
        // A council of one *is* its voter, so "the ensemble beats every voter"
        // is not a bar it can clear — it is the same number by construction.
        if voterCount > 1,
           !voters.allSatisfy({ ensemble > $0 || (ensemble == 1 && $0 == 1) }) {
            failures.append("ensemble does not beat every voter")
        }
        if records.contains(where: { !$0.transitionDetected }) {
            failures.append("transition detection below 100 percent")
        }
        if records.contains(where: { $0.stalePublications != 0 }) {
            failures.append("stale publication observed")
        }
        if records.contains(where: { !$0.answeredOrFailed || $0.duration > 120 }) {
            failures.append("answer or explicit failure exceeded 120 seconds")
        }
        let identities = records.flatMap(\.workers)
        if identities.contains(where: { !$0.provesIsolation })
            || Set(identities.map(\.conversationID)).count != identities.count {
            failures.append("worker conversation isolation failed")
        }
        failures.append(contentsOf: confidenceFailures(records,
                                                        minimumBucket: minimumConfidenceBucket))
        return .init(passed: failures.isEmpty, failures: failures,
                     ensembleAccuracy: ensemble, voterAccuracies: voters)
    }

    private static func confidenceFailures(_ records: [QuizEvaluationRecord],
                                           minimumBucket: Int) -> [String] {
        var failures: [String] = []
        for kind in supportedKinds {
            let kindRecords = records.filter { $0.kind == kind }
            guard !kindRecords.isEmpty else { continue }
            let overall = Double(kindRecords.filter(\.ensembleCorrect).count) / Double(kindRecords.count)
            for lower in stride(from: 0, through: 90, by: 10) {
                let bucket = kindRecords.filter {
                    min(90, max(0, $0.displayedConfidence) / 10 * 10) == lower
                }
                guard !bucket.isEmpty else { continue }
                let observed = bucket.count >= minimumBucket
                    ? Double(bucket.filter(\.ensembleCorrect).count) / Double(bucket.count)
                    : overall
                let ceiling = Int(floor(observed * 100))
                if bucket.contains(where: { $0.displayedConfidence > ceiling }) {
                    failures.append("confidence overstates \(kind.rawValue) bucket \(lower)")
                }
            }
        }
        return failures
    }
}
