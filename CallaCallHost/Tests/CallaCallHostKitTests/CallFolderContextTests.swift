import XCTest
@testable import CallaCallHostKit

final class CallFolderContextTests: XCTestCase {
    func testClosingSummaryReadsTitleDecisionsAndActions() throws {
        let payload = Data(#"{"title":"Importer status and billing","summary":"Shipped.","decisions":["Freeze Friday"," "],"action_items":["Ben: fix login (by Tue)"],"open_questions":["Who owns billing?"]}"#.utf8)
        let closing = try CopilotClosingSummary.decode(payload)
        XCTAssertEqual(closing.title, "Importer status and billing")
        XCTAssertEqual(closing.decisions, ["Freeze Friday"])
        XCTAssertEqual(closing.actionItems, ["Ben: fix login (by Tue)"])
        XCTAssertEqual(closing.openQuestions, ["Who owns billing?"])
    }

    func testOlderClosingPayloadStillDecodes() throws {
        let closing = try CopilotClosingSummary.decode(Data(#"{"summary":"Shipped.","open_questions":[]}"#.utf8))
        XCTAssertEqual(closing.overview, "Shipped.")
        XCTAssertEqual(closing.title, "")
        XCTAssertTrue(closing.decisions.isEmpty && closing.actionItems.isEmpty)
    }

    func testScreenTextReachesQuestionsAndTheClosingBriefBounded() {
        var ledger = CallLedger()
        for index in 0 ..< 6 { ledger.addScreen("Slide \(index): revenue 4.2M", at: "1:0\(index)") }
        ledger.addScreen("   ", at: "2:00")
        XCTAssertEqual(ledger.screens.count, CallLedger.screensKept)
        let context = ledger.questionContext([])
        XCTAssertTrue(context.contains("On screen (read from screenshots):"))
        XCTAssertTrue(context.contains("Slide 5"))
        XCTAssertFalse(context.contains("Slide 0"))
        XCTAssertTrue(ledger.closingBrief().contains("Shown on screen:"))
    }
}
