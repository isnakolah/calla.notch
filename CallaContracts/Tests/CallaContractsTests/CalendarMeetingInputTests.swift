import XCTest
@testable import CallaContracts

final class CalendarMeetingInputTests: XCTestCase {
    func testLongInviteFieldsAreBounded() {
        XCTAssertEqual(CalendarMeetingInput.text(String(repeating: "n", count: 5_000), limit: 4_000)?.count, 4_000)
        XCTAssertEqual(CalendarMeetingInput.text(String(repeating: "t", count: 250), limit: 200)?.count, 200)
        XCTAssertEqual(CalendarMeetingInput.attendees((1...50).map { _ in String(repeating: "a", count: 150) }).count, 40)
        XCTAssertTrue(CalendarMeetingInput.attendees([String(repeating: "a", count: 150)]).allSatisfy { $0.count <= 120 })
    }

    func testUnsafeControlsAreRemovedButInviteFormattingRemains() {
        XCTAssertEqual(CalendarMeetingInput.text("Agenda\u{0}\nItem\tA\r\n", limit: 200), "Agenda\nItem\tA")
        XCTAssertNil(CalendarMeetingInput.identifier("event\n1"))
        XCTAssertNil(CalendarMeetingInput.identifier(String(repeating: "e", count: 257)))
    }
}
