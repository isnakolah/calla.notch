import CallaContracts
import XCTest
@testable import IntelligenceCore

/// Replays a real transcript through segmentation, intent and the director.
///
/// No model, no quota — this measures the half of the system that decides
/// whether a model is asked at all, which is where silence comes from.
///
///     CODING_TRANSCRIPT=../TestFixtures/Coding/interview-turns.json \
///       swift test --filter CodingReplayTests
final class CodingReplayTests: XCTestCase {

    private struct RawTurn: Decodable {
        let seq: Int; let source: String
        let t0: Double; let t1: Double
        let text: String; let confidence: Double
    }

    private func loadTurns() throws -> [TranscriptTurn] {
        guard let path = ProcessInfo.processInfo.environment["CODING_TRANSCRIPT"] else {
            throw XCTSkip("set CODING_TRANSCRIPT to a transcript json to replay it")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode([RawTurn].self, from: data).map {
            TranscriptTurn(seq: $0.seq,
                           speaker: $0.source == "me" ? .local : .remote,
                           start: $0.t0, end: $0.t1,
                           text: $0.confidence < 0.5 ? $0.text + " [unclear]" : $0.text)
        }
    }

    func testReplayTheInterview() throws {
        let turns = try loadTurns()
        var segmenter = StatementSegmenter(rules: .coding)
        var statements: [Statement] = []

        // Drive it the way the session does: ingest each turn, then advance the
        // clock to the next turn so idle flushes actually fire.
        for (index, turn) in turns.enumerated() {
            statements += segmenter.ingest(turn)
            let next = index + 1 < turns.count ? turns[index + 1].start : turn.end + 10
            var cursor = turn.end
            while cursor < next {
                cursor = min(cursor + 0.5, next)
                statements += segmenter.tick(now: cursor)
            }
        }
        statements += segmenter.drain(now: (turns.last?.end ?? 0) + 30)

        var asks = 0, silent = 0, deterministic = 0
        var reasons: [String: Int] = [:]
        var intents: [CodingIntent: Int] = [:]
        var missed: [Statement] = []

        for statement in statements {
            let intent = CodingIntentClassifier.classify(statement.text)
            intents[intent, default: 0] += 1
            let facts = CodingDirector.Facts(
                cadence: CodingCadenceFacts(phase: .implementing, hasCode: true))
            switch CodingDirector.decide(statement: statement, facts: facts) {
            case .ask: asks += 1
            case .deterministic: deterministic += 1
            case .silent(let reason):
                silent += 1
                reasons[reason, default: 0] += 1
                // A statement the director ignored that carried a real request
                // is the failure this replay exists to surface.
                if intent != .none, statement.speaker == .local { missed.append(statement) }
            }
        }

        let turnsPerStatement = Double(turns.count) / Double(max(statements.count, 1))
        print("""

        ── replay ─────────────────────────────────────────────
        turns              \(turns.count)
        statements         \(statements.count)   (\(String(format: "%.1f", turnsPerStatement)) turns each)
        ask                \(asks)
        deterministic      \(deterministic)
        silent             \(silent)

        intents            \(intents.sorted { $0.value > $1.value }
                                .map { "\($0.key.rawValue)=\($0.value)" }.joined(separator: "  "))
        silence reasons    \(reasons.sorted { $0.value > $1.value }
                                .map { "\($0.key)=\($0.value)" }.joined(separator: "  "))

        MISSED REQUESTS    \(missed.count)
        """)
        for statement in missed.prefix(12) {
            print("  · [\(CodingIntentClassifier.classify(statement.text).rawValue)] \(statement.text.prefix(96))")
        }
        print("───────────────────────────────────────────────────────\n")

        XCTAssertFalse(statements.isEmpty, "segmenter produced nothing from a real call")
    }
}
