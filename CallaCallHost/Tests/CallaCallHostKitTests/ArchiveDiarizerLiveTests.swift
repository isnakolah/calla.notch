import IntelligenceStore
import XCTest
@testable import CallaCallHostKit

/// Runs the real diarizer over a recorded call. Opt-in: needs a `system.wav`
/// path in `CALLA_DIARIZE_WAV`, and downloads the models on first run.
final class ArchiveDiarizerLiveTests: XCTestCase {
    func testDiarizesARecordedCall() async throws {
        guard let path = ProcessInfo.processInfo.environment["CALLA_DIARIZE_WAV"] else {
            throw XCTSkip("set CALLA_DIARIZE_WAV to a call's system.wav")
        }
        let started = Date()
        let result = try await ArchiveDiarizer.diarize(systemAudio: URL(fileURLWithPath: path))
        let seconds = SpeakerAttribution.speechSeconds(result.spans)
        print("diarized in \(Int(Date().timeIntervalSince(started)))s:", seconds.sorted { $0.key < $1.key }
            .map { "\($0.key)=\(Int($0.value))s" }.joined(separator: " "))
        XCTAssertFalse(result.spans.isEmpty)
        XCTAssertEqual(Set(result.embeddings.keys), Set(result.spans.map(\.speakerID)))
    }
}

/// The whole speaker pass over a copy of a real store and call folder. Opt-in:
/// `CALLA_SPEAKER_CALL_DIR` (a copied call folder whose name is its id) and
/// `CALLA_SPEAKER_STORE` (a copied calla.sqlite).
final class SpeakerPassLiveTests: XCTestCase {
    func testLabelsARecordedCall() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["CALLA_SPEAKER_CALL_DIR"], let db = env["CALLA_SPEAKER_STORE"] else {
            throw XCTSkip("set CALLA_SPEAKER_CALL_DIR and CALLA_SPEAKER_STORE")
        }
        let store = try CallaStore(path: URL(fileURLWithPath: db))
        let directory = URL(fileURLWithPath: dir)
        let outcome = try await SpeakerPass.run(callDirectory: directory, store: store)
        print("outcome:", String(describing: outcome))
        let turns = try await store.turns(forCall: directory.lastPathComponent)
        for turn in turns.prefix(40) {
            print(String(format: "[%05.1f]", turn.t0), turn.speakerID ?? "-", turn.text.prefix(60))
        }
        XCTAssertNotNil(outcome)
    }
}
