import CallaContracts
import CoreGraphics
import Foundation

/// One `quiz-watch` run: probe frames out, solve frames on request.
///
/// Both the frame loop and the request reader write to the same stdout, so the
/// writes are serialised here. Frames are distinguished by their payload rather
/// than a new wire field: a probe never carries a JPEG, the frame the council
/// answers always does.
public actor QuizWatchSession {
    private let target: QuizWindowTarget
    private var latest: CGImage?
    private var previousProbe: QuizCapturedWindow?
    private var generation = 0
    private var closed = false

    public init(target: QuizWindowTarget) {
        self.target = target
    }

    public var isClosed: Bool { closed }

    public func emitProbe(_ image: CGImage) async {
        latest = image
        guard !closed else { return }
        generation += 1
        guard let captured = try? await QuizWindowCapture.analyze(
            image, target: target, detail: .probe, reusing: previousProbe) else { return }
        previousProbe = captured
        write(captured)
    }

    /// The current image, read at full detail. Nothing is captured again.
    public func emitSolveFrame() async {
        guard !closed, let image = latest else { return }
        generation += 1
        guard let captured = try? await QuizWindowCapture.analyze(
            image, target: target, detail: .solve) else { return }
        write(captured)
    }

    private func write(_ captured: QuizCapturedWindow) {
        let frame = QuizHostFrame(
            target: captured.target, captureGeneration: generation,
            width: captured.width, height: captured.height, jpeg: captured.jpeg,
            normalizedOCR: captured.normalizedOCR, tileHashes: captured.tileHashes,
            visualHash: captured.visualHash, anchors: captured.anchors,
            headlines: captured.headlines)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(frame) else { return }
        line.append(0x0A)
        // A closed pipe means the engine has stopped watching.
        if (try? FileHandle.standardOutput.write(contentsOf: line)) == nil {
            closed = true
        }
    }
}
