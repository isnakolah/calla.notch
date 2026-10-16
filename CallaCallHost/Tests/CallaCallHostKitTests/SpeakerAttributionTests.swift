import Foundation
import XCTest
@testable import CallaCallHostKit

/// Remote turns borrow a voice from the diarizer by time overlap. Cases follow
/// Muesli's `TranscriptFormatterTests`, adapted to Calla's per-leg turns.
final class SpeakerAttributionTests: XCTestCase {
    private func span(_ id: String, _ start: Double, _ end: Double) -> DiarizedSpan {
        DiarizedSpan(speakerID: id, start: start, end: end)
    }

    func testSpeakersAreNumberedInOrderOfFirstAppearance() {
        let map = SpeakerAttribution.numbering([
            span("spk_7", 10, 12), span("spk_2", 0, 3), span("spk_7", 4, 6), span("spk_0", 20, 22),
        ])
        XCTAssertEqual(map, ["spk_2": "S1", "spk_7": "S2", "spk_0": "S3"])
    }

    func testTheVoiceWithTheMostOverlapWins() {
        let spans = [span("a", 0, 2.2), span("b", 2.2, 6)]
        XCTAssertEqual(SpeakerAttribution.speaker(forTurnFrom: 1.8, to: 5, in: spans), "b")
        XCTAssertEqual(SpeakerAttribution.speaker(forTurnFrom: 0, to: 2.5, in: spans), "a")
    }

    func testASingleVoiceTakesEveryRemoteTurn() {
        XCTAssertEqual(SpeakerAttribution.speaker(forTurnFrom: 50, to: 51, in: [span("a", 0, 2)]), "a")
    }

    func testATurnInAGapBorrowsTheNearestVoiceOnlyWhenClose() {
        let spans = [span("a", 0, 2), span("b", 10, 12)]
        XCTAssertEqual(SpeakerAttribution.speaker(forTurnFrom: 2.5, to: 3, in: spans), "a")
        XCTAssertNil(SpeakerAttribution.speaker(forTurnFrom: 5, to: 6, in: spans))
    }

    func testMicTurnsAreAlwaysTheUser() {
        let result = SpeakerAttribution.assign(
            turns: [(0, true, 0, 1), (1, false, 1, 2), (2, false, 5, 6)],
            spans: [span("x", 0.5, 2.5), span("y", 4.5, 7)])
        XCTAssertEqual(result.turns, [0: "me", 1: "S1", 2: "S2"])
        XCTAssertEqual(result.labels, ["x": "S1", "y": "S2"])
    }

    func testNoSpansLeavesRemoteTurnsUnassigned() {
        XCTAssertEqual(SpeakerAttribution.assign(turns: [(0, false, 0, 1)], spans: []).turns, [:])
    }

    func testAVoiceThatNeverOwnsATurnGetsNoLabel() {
        // The diarizer hears a cough or a short "mm" that whisper dropped; it
        // must not become "Speaker 1" with nothing said.
        let result = SpeakerAttribution.assign(
            turns: [(0, false, 10, 12)],
            spans: [span("cough", 0, 0.4), span("talker", 9.5, 12.5)])
        XCTAssertEqual(result.labels, ["talker": "S1"])
    }

    func testTheM1GPUWorkaroundOnlyAppliesToMacOS151() {
        let v151 = OperatingSystemVersion(majorVersion: 15, minorVersion: 1, patchVersion: 1)
        let v152 = OperatingSystemVersion(majorVersion: 15, minorVersion: 2, patchVersion: 0)
        XCTAssertEqual(DiarizerRuntimePolicy.resolve(cpuBrand: "Apple M1 Pro", version: v151).computeUnits, .cpuAndNeuralEngine)
        XCTAssertEqual(DiarizerRuntimePolicy.resolve(cpuBrand: "Apple M1 Pro", version: v152).computeUnits, .all)
        XCTAssertEqual(DiarizerRuntimePolicy.resolve(cpuBrand: "Apple M2", version: v151).computeUnits, .all)
    }
}
