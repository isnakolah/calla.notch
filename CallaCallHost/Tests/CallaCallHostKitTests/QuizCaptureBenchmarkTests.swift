import CallaContracts
@testable import CallaCallHostKit
import CoreGraphics
import IntelligenceCore
import ImageIO
import XCTest

/// Temporary measurement harness, not a gate.
final class QuizCaptureBenchmarkTests: XCTestCase {
    func testMeasureProbeVersusSolve() async throws {
        guard ProcessInfo.processInfo.environment["QUIZ_BENCH"] == "1" else {
            throw XCTSkip("set QUIZ_BENCH=1")
        }
        var root = URL(fileURLWithPath: #filePath)
        while root.path != "/", !FileManager.default.fileExists(
            atPath: root.appendingPathComponent("TestFixtures/Quiz").path) {
            root.deleteLastPathComponent()
        }
        let directory = root.appendingPathComponent("TestFixtures/Quiz")
        let manifest = try JSONSerialization.jsonObject(
            with: Data(contentsOf: directory.appendingPathComponent(
                "freecodecamp-arborescence-question-2.json"))) as? [String: Any]
        let name = try XCTUnwrap(manifest?["image"] as? String)
        let imageData = try Data(contentsOf: directory.appendingPathComponent(name))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(imageData as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let target = QuizWindowTarget(
            processID: 42, windowID: 7, bundleID: "app.zen-browser.zen",
            applicationName: "Zen", windowTitle: "q", pixelWidth: image.width,
            pixelHeight: image.height)

        // A probe of an unchanged screen: the case the watcher is in most of the
        // time.
        let warmProbe = try await QuizWindowCapture.analyze(image, target: target, detail: .probe)
        var unchangedTotal = 0.0
        for _ in 0 ..< 5 {
            let start = Date()
            _ = try await QuizWindowCapture.analyze(image, target: target, detail: .probe,
                                                    reusing: warmProbe)
            unchangedTotal += Date().timeIntervalSince(start)
        }
        print("BENCH probe-unchanged: \(String(format: "%.0f", unchangedTotal / 5 * 1000)) ms/frame")

        for detail in [QuizCaptureDetail.solve, .probe] {
            // Warm once so neither level pays first-touch Vision setup.
            _ = try await QuizWindowCapture.analyze(image, target: target, detail: detail)
            var total = 0.0
            let runs = 5
            for _ in 0 ..< runs {
                let start = Date()
                _ = try await QuizWindowCapture.analyze(image, target: target, detail: detail)
                total += Date().timeIntervalSince(start)
            }
            print("BENCH \(detail.rawValue): \(String(format: "%.0f", total / Double(runs) * 1000)) ms/frame")
        }
    }
}
