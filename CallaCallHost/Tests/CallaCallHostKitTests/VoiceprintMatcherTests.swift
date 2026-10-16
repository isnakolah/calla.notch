import IntelligenceStore
import XCTest
@testable import CallaCallHostKit

/// Remembered voices name a new call's speakers only when the match is clear.
final class VoiceprintMatcherTests: XCTestCase {
    private func print(_ name: String, _ embedding: [Float]) -> Voiceprint {
        Voiceprint(personID: CallSpeaker.personID(for: name), displayName: name,
                   embedding: VoiceVector.normalised(embedding), speechSeconds: 60)
    }

    func testAClearMatchIsNamed() {
        let matches = VoiceprintMatcher.match(
            clusters: ["S1": [1, 0.05, 0], "S2": [0, 0, 1]],
            voiceprints: [print("Sarah", [1, 0, 0]), print("Tom", [0, 1, 0])])
        XCTAssertEqual(matches.map(\.label), ["S1"])
        XCTAssertEqual(matches.first?.displayName, "Sarah")
    }

    func testOnePersonIsNeverGivenToTwoVoices() {
        let matches = VoiceprintMatcher.match(
            clusters: ["S1": [1, 0.02, 0], "S2": [1, 0.1, 0]],
            voiceprints: [print("Sarah", [1, 0, 0])])
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.label, "S1")
    }

    func testANearTieBetweenTwoPeopleIsLeftUnnamed() {
        let matches = VoiceprintMatcher.match(
            clusters: ["S1": [1, 1, 0]],
            voiceprints: [print("Sarah", [1, 0.98, 0]), print("Tom", [0.98, 1, 0])])
        XCTAssertTrue(matches.isEmpty)
    }

    func testAWeakMatchIsLeftUnnamed() {
        // cosine ≈ 0.55, under the 0.65 floor.
        let weak = VoiceprintMatcher.match(clusters: ["S1": [1, 1.5, 0]], voiceprints: [print("Sarah", [1, 0, 0])])
        XCTAssertTrue(weak.isEmpty)
    }
}
