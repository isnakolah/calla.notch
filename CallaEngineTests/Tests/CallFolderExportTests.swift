import CallaContracts
import XCTest
@testable import CallaEngineValidation

final class CallFolderExportTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let start = Date(timeIntervalSince1970: 1_792_143_000) // 2026-10-16 09:30 UTC

    private func input(_ persona: String, event: String? = nil, aiTitle: String? = nil) -> CallFolderExport.Input {
        CallFolderExport.Input(
            callID: "call-1234567890ab", persona: persona, startedAt: start,
            endedAt: start.addingTimeInterval(14 * 60),
            meeting: .init(title: event, attendees: ["Ana", "Ben"]),
            recap: CallRecapDraft(callID: "call-1234567890ab", overview: "Shipped the importer.",
                                  items: [.init(id: "d", kind: .decision, text: "Freeze on Friday", fromSeq: 1, toSeq: 2),
                                          .init(id: "a", kind: .actionItem, text: "Ben: fix login (by Tue)", fromSeq: 1, toSeq: 2),
                                          .init(id: "q", kind: .openQuestion, text: "Who owns billing?", fromSeq: 1, toSeq: 2)],
                                  title: aiTitle),
            turns: [.init(seq: 0, isMe: false, t0: 3, text: "Morning"), .init(seq: 1, isMe: true, t0: 65, text: "Blocked on review")],
            answers: [.init(afterSeq: 1, headline: "Ask Ana to review", angles: ["She owns the module"])])
    }

    func testCeremonyIsNamedAfterItsMeetingAndFiledByType() {
        XCTAssertEqual(CallFolderExport.folderPath(for: input("standup", event: "Daily Standup", aiTitle: "Importer status"), timeZone: utc),
                       "Standup/2026-10-16 0930 Daily Standup")
        XCTAssertEqual(CallFolderExport.folderPath(for: input("retro"), timeZone: utc), "Retro/2026-10-16 0930 Retro")
    }

    func testOtherCallsUseTheGeneratedTitle() {
        XCTAssertEqual(CallFolderExport.folderPath(for: input("generic", event: "Sync", aiTitle: "Pricing review with Acme"), timeZone: utc),
                       "General/2026-10-16 0930 Pricing review with Acme")
        XCTAssertEqual(CallFolderExport.folderPath(for: input("generic"), timeZone: utc), "General/2026-10-16 0930 Call")
        XCTAssertEqual(CallFolderExport.folderPath(for: input("one-on-one", aiTitle: "Growth plan"), timeZone: utc),
                       "One-on-one/2026-10-16 0930 Growth plan")
    }

    func testSanitizeKeepsOneSafePathComponent() {
        XCTAssertEqual(CallFolderExport.sanitize("Q3/Q4: plan\n\\ review"), "Q3 Q4 plan review")
        XCTAssertEqual(CallFolderExport.sanitize("..hidden"), "hidden")
        XCTAssertEqual(CallFolderExport.sanitize("   "), "Call")
        XCTAssertEqual(CallFolderExport.sanitize(String(repeating: "a", count: 200), limit: 10).count, 10)
        XCTAssertEqual(CallFolderExport.unique("Retro", taken: ["Retro", "Retro 2"]), "Retro 3")
    }

    func testSummaryHasEverySection() {
        let summary = CallFolderExport.summary(input("standup", event: "Daily Standup"), timeZone: utc)
        XCTAssertTrue(summary.hasPrefix("# Daily Standup\n"))
        XCTAssertTrue(summary.contains("**Length:** 14 min"))
        XCTAssertTrue(summary.contains("**With:** Ana, Ben"))
        XCTAssertTrue(summary.contains("## Decisions\n\n- Freeze on Friday"))
        XCTAssertTrue(summary.contains("## Action items\n\n- [ ] Ben: fix login (by Tue)"))
        XCTAssertTrue(summary.contains("## Open questions\n\n- Who owns billing?"))
    }

    func testMissingRecapStillWritesAReadableSummary() {
        var value = input("generic"); value.recap = nil
        XCTAssertTrue(CallFolderExport.summary(value, timeZone: utc).contains("No summary was produced"))
    }

    func testTranscriptAndAnswersPlaceScreenshotsAndReplies() {
        var value = input("standup")
        value.captures = [.init(file: "0-30.png", offset: 30, text: "Burndown chart")]
        let transcript = CallFolderExport.transcript(value)
        XCTAssertTrue(transcript.contains("**[0:03] Them:** Morning"))
        XCTAssertTrue(transcript.contains("**[1:05] Me:** Blocked on review"))
        let shot = transcript.range(of: "screenshots/0-30.png")!.lowerBound
        XCTAssertLessThan(transcript.range(of: "Morning")!.lowerBound, shot)
        XCTAssertLessThan(shot, transcript.range(of: "Blocked on review")!.lowerBound)
        let summary = CallFolderExport.summary(value, timeZone: utc)
        XCTAssertTrue(summary.contains("![Screenshot at 0:30](screenshots/0-30.png)"))
        XCTAssertFalse(summary.contains("Burndown chart"))
        XCTAssertEqual(CallFolderExport.files(for: value)["screenshots/0-30.txt"], "Burndown chart\n")
        let answers = CallFolderExport.answers(value)
        XCTAssertTrue(answers.contains("> **[1:05] Me:** Blocked on review\n\n**Ask Ana to review**\n- She owns the module"))
    }

    func testDiarizedSpeakersAreNamedInTheTranscript() {
        var value = input("standup")
        value.turns = [.init(seq: 0, isMe: false, t0: 3, text: "Morning", speaker: "Ana"),
                       .init(seq: 1, isMe: false, t0: 9, text: "Hi", speaker: "Speaker 2"),
                       .init(seq: 2, isMe: true, t0: 65, text: "Blocked on review", speaker: "Ana")]
        let transcript = CallFolderExport.transcript(value)
        XCTAssertTrue(transcript.contains("**[0:03] Ana:** Morning"))
        XCTAssertTrue(transcript.contains("**[0:09] Speaker 2:** Hi"))
        // The mic leg is the user no matter what a speaker field says.
        XCTAssertTrue(transcript.contains("**[1:05] Me:** Blocked on review"))
    }

    func testNotesBecomeFilesWithUniqueNames() {
        var value = input("standup")
        value.meeting.notes = "Agenda: demo"
        value.notes = [.init(title: "Spec", body: "v1"), .init(title: "Spec", body: "v2"), .init(title: "Empty", body: " ")]
        let files = CallFolderExport.files(for: value, timeZone: utc)
        XCTAssertEqual(files["notes/meeting-invite.md"]?.contains("Agenda: demo"), true)
        XCTAssertNotNil(files["notes/Spec.md"]); XCTAssertNotNil(files["notes/Spec 2.md"])
        XCTAssertNil(files["notes/Empty.md"])
        value.answers = [.init(afterSeq: 1, headline: "")]
        XCTAssertNil(CallFolderExport.files(for: value)["answers.md"])
    }

    func testContinuityCarriesOpenItemsWithinItsLimit() {
        let draft = CallRecapDraft(callID: "call-x", overview: "Importer shipped.",
                                   items: [.init(id: "a", kind: .actionItem, text: "Ben: fix login", fromSeq: 1, toSeq: 1),
                                           .init(id: "d", kind: .decision, text: "Freeze", fromSeq: 1, toSeq: 1)])
        let block = CallFolderExport.continuity(persona: "standup", entries: [(start, draft)], limit: 500, timeZone: utc)!
        XCTAssertTrue(block.hasPrefix("Previous standup meetings"))
        XCTAssertTrue(block.contains("Fri 16 Oct: Importer shipped.\nStill open: Ben: fix login"))
        XCTAssertFalse(block.contains("Freeze"))
        XCTAssertNil(CallFolderExport.continuity(persona: "standup", entries: [], limit: 500))
        XCTAssertFalse(CallFolderExport.continuity(persona: "standup", entries: [(start, draft)], limit: 40)!.contains("Importer"))
    }

    func testPersonaCatalogue() {
        XCTAssertTrue(CallaPersonaCatalog.isCeremony("standup"))
        XCTAssertTrue(CallaPersonaCatalog.isCeremony("incident"))
        XCTAssertFalse(CallaPersonaCatalog.isCeremony("generic"))
        XCTAssertEqual(CallaPersonaCatalog.folderName("one-on-one"), "One-on-one")
        XCTAssertEqual(CallaPersonaCatalog.title("board-review"), "Board review")
    }
}
