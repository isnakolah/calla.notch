import CryptoKit
import ImageIO
import XCTest
@testable import CallaCallHostKit
import CallaContracts
import IntelligenceCore

final class QuizQuestionDetectorTests: XCTestCase {
    private struct Fixture: Decodable {
        let id: String
        let image: String
        let sha256: String
        let expectedOCRContains: [String]
        let expectedAnswer: String
    }

    private func fixture() throws -> (Fixture, CGImage, Data) {
        var root = URL(fileURLWithPath: #filePath)
        while root.path != "/", !FileManager.default.fileExists(
            atPath: root.appendingPathComponent("TestFixtures/Quiz").path) {
            root.deleteLastPathComponent()
        }
        let directory = root.appendingPathComponent("TestFixtures/Quiz")
        let manifestData = try Data(contentsOf: directory.appendingPathComponent(
            "freecodecamp-arborescence-question-2.json"))
        let manifest = try JSONDecoder().decode(Fixture.self, from: manifestData)
        let imageData = try Data(contentsOf: directory.appendingPathComponent(manifest.image))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(imageData as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return (manifest, image, imageData)
    }

    private func observation(_ text: String, at seconds: TimeInterval,
                             capture: Int, tiles: [UInt64] = [1, 2, 3, 4],
                             visual: UInt64 = 0x00ff00ff00ff00ff,
                             anchors: [String] = ["Question 1"]) -> QuizFrameObservation {
        QuizFrameObservation(capturedAt: Date(timeIntervalSince1970: seconds),
                             captureGeneration: capture, normalizedOCR: text,
                             tileHashes: tiles, visualHash: visual, anchors: anchors)
    }

    func testRequiresTwoMatchingFramesSpanning750Milliseconds() {
        var detector = QuizQuestionDetector()
        XCTAssertEqual(detector.observe(observation("Question 1 Which is true", at: 0, capture: 1)), .stabilizing)
        XCTAssertEqual(detector.observe(observation("Question 1 Which is true", at: 0.5, capture: 2)), .stabilizing)
        guard case .newQuestion(let stable) = detector.observe(
            observation("Question 1 Which is true", at: 0.8, capture: 3)) else {
            return XCTFail("expected stable question")
        }
        XCTAssertEqual(stable.generation, 1)
    }

    func testTimerChangesDoNotCreateQuestion() {
        var detector = QuizQuestionDetector()
        _ = detector.observe(observation("Question 1 00:30 Which is true", at: 0, capture: 1))
        guard case .newQuestion = detector.observe(
            observation("Question 1 00:29 Which is true", at: 0.8, capture: 2)) else {
            return XCTFail("timer should normalize")
        }
        guard case .unchanged = detector.observe(
            observation("Question 1 00:28 Which is true", at: 1.6, capture: 3)) else {
            return XCTFail("timer should not advance generation")
        }
    }

    func testScrollWithOCRAnchorPreservesGeneration() {
        var detector = QuizQuestionDetector()
        _ = detector.observe(observation("Question 4 long stem alpha beta", at: 0, capture: 1,
                                         anchors: ["Question 4"]))
        guard case .newQuestion(let first) = detector.observe(
            observation("Question 4 long stem alpha beta", at: 0.8, capture: 2,
                        anchors: ["Question 4"])) else { return XCTFail() }
        detector.markScrollRequested()
        _ = detector.observe(observation("Question 4 beta choices c d", at: 1.0, capture: 3,
                                         tiles: [7, 8, 9, 10], visual: 123,
                                         anchors: ["Question 4"]))
        guard case .continuation(let next) = detector.observe(
            observation("Question 4 beta choices c d", at: 1.8, capture: 4,
                        tiles: [7, 8, 9, 10], visual: 123,
                        anchors: ["Question 4"])) else { return XCTFail() }
        XCTAssertEqual(next.questionID, first.questionID)
        XCTAssertEqual(next.generation, first.generation)
    }

    func testTheSameQuestionRedrawnIsNotANewQuestion() {
        // What the reader saw: the first question answered, and then nothing.
        // A page with any life in it — a caret, a hover state, a lazily-loaded
        // image — moves enough pixels to fail the equivalence check, and every
        // time it settled again the detector minted a new question id, which
        // cancels the answer already being worked on. The words are what tell one
        // question from another, so they get the final say.
        var detector = QuizQuestionDetector()
        let text = "Question 7 which traversal visits the left subtree first"
        _ = detector.observe(observation(text, at: 0, capture: 1))
        guard case .newQuestion(let first) = detector.observe(
            observation(text, at: 0.8, capture: 2)) else { return XCTFail() }

        // Same words, wholly different pixels.
        _ = detector.observe(observation(text + " preorder", at: 2.0, capture: 3,
                                         tiles: [90, 91, 92, 93], visual: UInt64.max))
        let verdict = detector.observe(
            observation(text + " preorder", at: 2.8, capture: 4,
                        tiles: [90, 91, 92, 93], visual: UInt64.max))
        XCTAssertEqual(verdict, .unchanged(first))
    }

    func testADifferentQuestionStillAdvances() {
        var detector = QuizQuestionDetector()
        _ = detector.observe(observation("Question 7 which traversal visits the left subtree first",
                                         at: 0, capture: 1))
        guard case .newQuestion(let first) = detector.observe(
            observation("Question 7 which traversal visits the left subtree first",
                        at: 0.8, capture: 2)) else { return XCTFail() }
        _ = detector.observe(observation("Question 8 what is the height of a balanced tree",
                                         at: 2.0, capture: 3,
                                         tiles: [90, 91, 92, 93], visual: UInt64.max))
        guard case .newQuestion(let second) = detector.observe(
            observation("Question 8 what is the height of a balanced tree",
                        at: 2.8, capture: 4,
                        tiles: [90, 91, 92, 93], visual: UInt64.max)) else { return XCTFail() }
        XCTAssertGreaterThan(second.generation, first.generation)
        XCTAssertNotEqual(second.questionID, first.questionID)
    }

    func testSlowDriftDoesNotAccumulateIntoANewQuestion() {
        // The baseline used to be the frame the question was accepted on and was
        // never moved, so a page drifting a little at a time was eventually
        // compared against a picture minutes old and lost.
        var detector = QuizQuestionDetector()
        let text = "Question 9 pick the correct complexity for the loop below"
        _ = detector.observe(observation(text, at: 0, capture: 1, tiles: [1, 2, 3, 4]))
        guard case .newQuestion(let first) = detector.observe(
            observation(text, at: 0.8, capture: 2, tiles: [1, 2, 3, 4])) else { return XCTFail() }

        // Each step moves one tile against the step before it, and all four
        // against the frame the question started on.
        var tiles: [UInt64] = [1, 2, 3, 4]
        var time = 1.6
        for index in 0 ..< 4 {
            tiles[index] = 500 + UInt64(index)
            let verdict = detector.observe(
                observation(text, at: time, capture: 3 + index, tiles: tiles))
            XCTAssertEqual(verdict, .unchanged(first),
                           "drift step \(index) was treated as something other than this question")
            time += 0.8
        }
    }

    func testTheAnswerKeyIgnoresPixelsSoAnAnsweredQuestionIsNotAnsweredTwice() {
        // The session's answer cache is keyed on this. Keyed on `fingerprint`,
        // which carries the frame's visual hash, scrolling back to a question
        // already answered was a cache miss and cost a whole council again.
        let text = "Question 3 which sort is stable"
        let drawn = QuizFrameObservation(captureGeneration: 1, normalizedOCR: text,
                                         tileHashes: [1, 2, 3, 4], visualHash: 11,
                                         anchors: ["Question 3"])
        let redrawn = QuizFrameObservation(captureGeneration: 9, normalizedOCR: text,
                                           tileHashes: [90, 91, 92, 93], visualHash: .max,
                                           anchors: ["Question 3"])
        XCTAssertEqual(drawn.answerKey, redrawn.answerKey)
        XCTAssertNotEqual(drawn.fingerprint, redrawn.fingerprint)
    }

    func testADifferentQuestionGetsADifferentAnswerKey() {
        let one = QuizFrameObservation(captureGeneration: 1,
                                       normalizedOCR: "Question 3 which sort is stable",
                                       tileHashes: [1, 2, 3, 4], visualHash: 11,
                                       anchors: ["Question 3"])
        let two = QuizFrameObservation(captureGeneration: 2,
                                       normalizedOCR: "Question 4 which sort is in place",
                                       tileHashes: [1, 2, 3, 4], visualHash: 11,
                                       anchors: ["Question 4"])
        XCTAssertNotEqual(one.answerKey, two.answerKey)
    }

    func testAContinuationKeepsTheAnswerKeyOfItsFirstViewport() {
        var detector = QuizQuestionDetector()
        _ = detector.observe(observation("Question 4 alpha choices a b", at: 0, capture: 1,
                                         anchors: ["Question 4"]))
        guard case .newQuestion(let first) = detector.observe(
            observation("Question 4 alpha choices a b", at: 0.8, capture: 2,
                        anchors: ["Question 4"])) else { return XCTFail() }
        detector.markScrollRequested()
        _ = detector.observe(observation("Question 4 beta choices c d", at: 1.0, capture: 3,
                                         tiles: [7, 8, 9, 10], visual: 123,
                                         anchors: ["Question 4"]))
        guard case .continuation(let next) = detector.observe(
            observation("Question 4 beta choices c d", at: 1.8, capture: 4,
                        tiles: [7, 8, 9, 10], visual: 123,
                        anchors: ["Question 4"])) else { return XCTFail() }
        XCTAssertEqual(next.answerKey, first.answerKey)
    }

    func testADifferentQuestionOnAPageOfSharedFurnitureStillAdvances() {
        // The other side of the same-question rule, and the more dangerous one:
        // word similarity is measured over the whole screen, and a quiz page is
        // mostly navigation, progress strip, option letters and footer. If that
        // shared furniture were allowed to carry the vote, the next question
        // would never be asked and no answer would ever appear.
        var detector = QuizQuestionDetector()
        let chrome = "home dashboard courses progress 60 percent complete a b c d "
            + "previous next submit report an issue about privacy terms"
        _ = detector.observe(observation(chrome + " question 4 which sort is stable",
                                         at: 0, capture: 1, anchors: ["Question 4"]))
        guard case .newQuestion(let first) = detector.observe(
            observation(chrome + " question 4 which sort is stable",
                        at: 0.8, capture: 2, anchors: ["Question 4"])) else { return XCTFail() }
        _ = detector.observe(observation(chrome + " question 5 which sort is in place",
                                         at: 2.0, capture: 3, tiles: [90, 91, 92, 93],
                                         visual: .max, anchors: ["Question 5"]))
        guard case .newQuestion(let second) = detector.observe(
            observation(chrome + " question 5 which sort is in place",
                        at: 2.8, capture: 4, tiles: [90, 91, 92, 93],
                        visual: .max, anchors: ["Question 5"])) else { return XCTFail() }
        XCTAssertGreaterThan(second.generation, first.generation)
    }

    func testNewStableVisualQuestionAdvancesWithoutOCR() {
        var detector = QuizQuestionDetector()
        _ = detector.observe(observation("", at: 0, capture: 1, visual: 1, anchors: []))
        guard case .newQuestion(let first) = detector.observe(
            observation("", at: 0.8, capture: 2, visual: 1, anchors: [])) else { return XCTFail() }
        _ = detector.observe(observation("", at: 1.0, capture: 3,
                                         tiles: [100, 101, 102, 103], visual: UInt64.max,
                                         anchors: []))
        guard case .newQuestion(let second) = detector.observe(
            observation("", at: 1.8, capture: 4,
                        tiles: [100, 101, 102, 103], visual: UInt64.max,
                        anchors: [])) else { return XCTFail() }
        XCTAssertGreaterThan(second.generation, first.generation)
    }

    func testViewportCollectorRejectsFifthViewport() throws {
        var collector = QuizViewportCollector()
        for index in 0 ..< 5 {
            let frame = QuizCaptureFrame(
                sessionID: "session-1234", questionID: "question-1234",
                questionGeneration: 1, captureGeneration: index + 1,
                viewportIndex: min(index, 3), width: 1, height: 1,
                jpeg: Data([0xff, 0xd8, 0xff, 0xd9]),
                normalizedOCR: "question", fingerprint: "fingerprint")
            try collector.append(frame)
        }
        XCTAssertEqual(collector.frames.count, 4)
    }

    /// The watcher runs twice a second and compares frames; only the frame that
    /// reaches the council needs a JPEG or accurate OCR. Encoding one on every
    /// discarded frame — up to nine encodes when the first exceeded the 3 MiB cap,
    /// then a base64 round-trip through JSON — was the pipeline's dominant cost.
    func testProbeFrameSkipsEncodingButStillSupportsStabilityComparison() async throws {
        let (_, image, _) = try fixture()
        let target = QuizWindowTarget(
            processID: 42, windowID: 7, bundleID: "app.zen-browser.zen",
            applicationName: "Zen", windowTitle: "freeCodeCamp Developer Quiz",
            pixelWidth: image.width, pixelHeight: image.height)

        let probe = try await QuizWindowCapture.analyze(image, target: target, detail: .probe)
        XCTAssertTrue(probe.jpeg.isEmpty, "a probe must not pay for a JPEG")
        // Everything stability detection actually reads is still present.
        XCTAssertFalse(probe.tileHashes.isEmpty)
        XCTAssertNotEqual(probe.visualHash, 0)
        XCTAssertFalse(probe.normalizedOCR.isEmpty)

        let solve = try await QuizWindowCapture.analyze(image, target: target, detail: .solve)
        XCTAssertFalse(solve.jpeg.isEmpty)
        XCTAssertTrue(solve.jpeg.starts(with: [0xff, 0xd8, 0xff]))

        // The two detail levels must agree visually on identical pixels, because
        // that is the check the engine uses to confirm the screen has not moved
        // between accepting a question and capturing the frame it answers. OCR
        // cannot serve there: `.fast` and `.accurate` disagree on the same image.
        XCTAssertEqual(probe.tileHashes, solve.tileHashes)
        XCTAssertEqual(probe.visualHash, solve.visualHash)
    }

    /// The watcher runs twice a second on screens that mostly sit still. Reading
    /// an unchanged frame with Vision produces the same words at a cost that
    /// dwarfs everything else in the pipeline.
    func testAnUnchangedProbeReusesItsTextInsteadOfReadingAgain() async throws {
        let (_, image, _) = try fixture()
        let target = QuizWindowTarget(
            processID: 42, windowID: 7, bundleID: "app.zen-browser.zen",
            applicationName: "Zen", windowTitle: "q",
            pixelWidth: image.width, pixelHeight: image.height)

        let first = try await QuizWindowCapture.analyze(image, target: target, detail: .probe)
        XCTAssertFalse(first.normalizedOCR.isEmpty)

        let repeated = try await QuizWindowCapture.analyze(
            image, target: target, detail: .probe, reusing: first)
        // Identical pixels: the same words, the same hashes, no second read.
        XCTAssertEqual(repeated.normalizedOCR, first.normalizedOCR)
        XCTAssertEqual(repeated.tileHashes, first.tileHashes)
        XCTAssertEqual(repeated.visualHash, first.visualHash)
        XCTAssertEqual(repeated.anchors, first.anchors)
    }

    func testASolveFrameIsNeverReused() async throws {
        // The frame the council answers must carry a real JPEG and the accurate
        // two-pass read, whatever the previous frame looked like.
        let (_, image, _) = try fixture()
        let target = QuizWindowTarget(
            processID: 42, windowID: 7, bundleID: "app.zen-browser.zen",
            applicationName: "Zen", windowTitle: "q",
            pixelWidth: image.width, pixelHeight: image.height)
        let probe = try await QuizWindowCapture.analyze(image, target: target, detail: .probe)
        let solve = try await QuizWindowCapture.analyze(
            image, target: target, detail: .solve, reusing: probe)
        XCTAssertFalse(solve.jpeg.isEmpty)
        XCTAssertTrue(solve.jpeg.starts(with: [0xff, 0xd8, 0xff]))
    }

    func testUserSuppliedFreeCodeCampFixtureRunsExactCaptureAndDetectionPipeline() async throws {
        let (manifest, image, imageData) = try fixture()
        let digest = SHA256.hash(data: imageData).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, manifest.sha256, "frozen fixture drifted")
        XCTAssertEqual(image.width, 3_402)
        XCTAssertEqual(image.height, 2_128)

        let target = QuizWindowTarget(
            processID: 42, windowID: 7, bundleID: "app.zen-browser.zen",
            applicationName: "Zen", windowTitle: "freeCodeCamp Developer Quiz",
            pixelWidth: image.width, pixelHeight: image.height)
        let captured = try await QuizWindowCapture.analyze(image, target: target)

        XCTAssertEqual(captured.target, target)
        XCTAssertLessThanOrEqual(captured.jpeg.count, QuizContract.maximumCaptureBytes)
        XCTAssertTrue(captured.jpeg.starts(with: [0xff, 0xd8, 0xff]))
        XCTAssertEqual(captured.jpeg.suffix(2), Data([0xff, 0xd9]))
        XCTAssertFalse(captured.tileHashes.isEmpty)
        XCTAssertNotEqual(captured.visualHash, 0)
        XCTAssertTrue(captured.anchors.contains { $0.contains("question 2") })
        for expected in manifest.expectedOCRContains {
            XCTAssertTrue(captured.normalizedOCR.contains(expected),
                          "missing OCR fragment: \(expected)\nOCR: \(captured.normalizedOCR)")
        }
        XCTAssertTrue(manifest.expectedAnswer.hasPrefix("C —"))

        var detector = QuizQuestionDetector()
        let first = QuizFrameObservation(
            capturedAt: Date(timeIntervalSince1970: 0), captureGeneration: 1,
            normalizedOCR: captured.normalizedOCR, tileHashes: captured.tileHashes,
            visualHash: captured.visualHash, anchors: captured.anchors)
        let second = QuizFrameObservation(
            capturedAt: Date(timeIntervalSince1970: 0.8), captureGeneration: 2,
            normalizedOCR: captured.normalizedOCR, tileHashes: captured.tileHashes,
            visualHash: captured.visualHash, anchors: captured.anchors)
        XCTAssertEqual(detector.observe(first), .stabilizing)
        guard case .newQuestion(let stable) = detector.observe(second) else {
            return XCTFail("fixture did not become stable question")
        }
        XCTAssertEqual(stable.generation, 1)
        XCTAssertFalse(stable.fingerprint.isEmpty)
    }
}
