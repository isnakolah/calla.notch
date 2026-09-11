import CallaContracts
import Foundation

public struct QuizCalibrationSample: Sendable, Equatable {
    public let kind: QuizQuestionKind
    public let displayedConfidence: Int
    public let correct: Bool

    public init(kind: QuizQuestionKind, displayedConfidence: Int, correct: Bool) {
        self.kind = kind
        self.displayedConfidence = min(100, max(0, displayedConfidence))
        self.correct = correct
    }
}

/// Turns graded answers into the calibration the resolver applies.
///
/// `QuizConfidenceCalibration` has always accepted a set of measured buckets,
/// and both resolver entry points have always taken one — but nothing built one,
/// so both call sites passed the empty default and `display(raw:kind:)` returned
/// the raw value untouched. The number in the notch was the model's own estimate
/// of itself.
///
/// The missing half was ground truth: no correctness was recorded anywhere. Now
/// that answers can be graded, this converts them into per-kind, per-decile
/// accuracy, and `display` uses it to cap a confidence at what that band has
/// actually earned. Bands below `minimumBucketSize` fall back to the kind's
/// overall accuracy rather than trusting a handful of samples.
public enum QuizCalibrationBuilder {
    public static func build(from samples: [QuizCalibrationSample],
                            minimumBucketSize: Int = 20) -> QuizConfidenceCalibration {
        guard !samples.isEmpty else { return QuizConfidenceCalibration() }

        var overall: [QuizQuestionKind: Double] = [:]
        for kind in Set(samples.map(\.kind)) {
            let forKind = samples.filter { $0.kind == kind }
            guard !forKind.isEmpty else { continue }
            overall[kind] = Double(forKind.filter(\.correct).count) / Double(forKind.count)
        }

        var buckets: [QuizConfidenceCalibration.Bucket] = []
        for kind in Set(samples.map(\.kind)) {
            for lower in stride(from: 0, through: 90, by: 10) {
                let inBucket = samples.filter {
                    $0.kind == kind && bucketFloor($0.displayedConfidence) == lower
                }
                guard !inBucket.isEmpty else { continue }
                buckets.append(.init(
                    kind: kind, lowerBound: lower,
                    measuredAccuracy: Double(inBucket.filter(\.correct).count) / Double(inBucket.count),
                    sampleCount: inBucket.count))
            }
        }

        return QuizConfidenceCalibration(buckets: buckets, overallAccuracyByKind: overall,
                                         minimumBucketSize: minimumBucketSize)
    }

    /// Matches the decile arithmetic `QuizConfidenceCalibration.display` uses, so
    /// a sample lands in the bucket that will be consulted for it.
    private static func bucketFloor(_ confidence: Int) -> Int {
        min(90, max(0, confidence) / 10 * 10)
    }
}
