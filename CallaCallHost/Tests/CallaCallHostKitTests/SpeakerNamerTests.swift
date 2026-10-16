import Foundation
import XCTest
@testable import CallaCallHostKit

/// Names are only accepted when the calendar or the conversation backs them.
final class SpeakerNamerTests: XCTestCase {
    private func request(attendees: [String] = ["Sarah Chen", "Tom Ruiz", "me@acme.com"],
                         turns: [(String, String)]) -> SpeakerNamingRequest {
        SpeakerNamingRequest(
            attendees: attendees, knownNames: [], unnamed: ["S1", "S2"],
            turns: turns.enumerated().map { index, turn in
                .init(speakerID: turn.0, knownName: nil, t0: Double(index * 5), text: turn.1)
            })
    }

    func testParsesTheContract() throws {
        let payload = Data(#"{"speakers":[{"speaker":"S1","name":"Sarah","confidence":0.9,"evidence":"thanks Sarah"},{"speaker":"S2","name":null}]}"#.utf8)
        let guesses = try SpeakerNamer.parse(payload)
        XCTAssertEqual(guesses.keys.sorted(), ["S1"])
        XCTAssertEqual(guesses["S1"]?.name, "Sarah")
    }

    func testAFirstNameBecomesTheAttendeesFullName() {
        let accepted = SpeakerNamer.accept(
            ["S1": .init(name: "sarah", confidence: 0.8)],
            for: request(turns: [("me", "Thanks Sarah"), ("S1", "Sure")]))
        XCTAssertEqual(accepted["S1"]?.name, "Sarah Chen")
    }

    func testANameNobodySaidAndNobodyInvitedIsRejected() {
        let accepted = SpeakerNamer.accept(
            ["S1": .init(name: "Priya Patel", confidence: 0.95)],
            for: request(turns: [("S1", "Hello everyone")]))
        XCTAssertTrue(accepted.isEmpty)
    }

    func testASelfIntroductionCountsWithoutAnInvite() {
        let accepted = SpeakerNamer.accept(
            ["S2": .init(name: "Priya", confidence: 0.85)],
            for: request(turns: [("S2", "Hi, I'm Priya from finance")]))
        XCTAssertEqual(accepted["S2"]?.name, "Priya")
    }

    func testLowConfidenceAndUnaskedLabelsAreDropped() {
        let accepted = SpeakerNamer.accept(
            ["S1": .init(name: "Sarah Chen", confidence: 0.4), "S9": .init(name: "Tom Ruiz", confidence: 0.9)],
            for: request(turns: [("S1", "Hi")]))
        XCTAssertTrue(accepted.isEmpty)
    }

    func testEmailAttendeesReadAsNames() {
        XCTAssertEqual(SpeakerNamer.display("sarah.chen@acme.com"), "Sarah Chen")
        XCTAssertEqual(SpeakerNamer.attendee(matching: "Sarah Chen", in: ["sarah.chen@acme.com"]), "Sarah Chen")
    }

    func testLongCallsAreTrimmedToTheLinesThatCarryNames() {
        var turns: [(String, String)] = (0..<600).map { ("S1", "filler line number \($0) about the roadmap and budget") }
        turns.insert(("me", "Over to you, Tom"), at: 300)
        turns.insert(("S2", "Thanks, so on billing"), at: 301)
        let lines = SpeakerNamer.excerpt(request(turns: turns))
        XCTAssertLessThan(lines.joined(separator: "\n").count, SpeakerNamer.excerptBudget + 200)
        XCTAssertTrue(lines.contains { $0.contains("Over to you, Tom") })
        XCTAssertTrue(lines.contains { $0.contains("S2: Thanks, so on billing") })
    }
}
