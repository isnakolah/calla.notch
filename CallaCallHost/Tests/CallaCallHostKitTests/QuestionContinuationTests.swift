import XCTest
@testable import CallaCallHostKit

final class QuestionContinuationTests: XCTestCase {
    func testOnlyExplicitShortContinuationShapesSupersede() {
        XCTAssertTrue(CopilotAdvisor.isQuestionContinuation("What about Europe?"))
        XCTAssertTrue(CopilotAdvisor.isQuestionContinuation("And the renewal date?"))
        XCTAssertFalse(CopilotAdvisor.isQuestionContinuation("What is the independent support SLA?"))
        XCTAssertFalse(CopilotAdvisor.isQuestionContinuation(
            "And can you explain every separate requirement in the proposed migration plan for all regions and customer tiers?"))
    }
}
