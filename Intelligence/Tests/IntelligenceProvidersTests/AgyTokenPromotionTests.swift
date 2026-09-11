import XCTest
@testable import IntelligenceProviders

/// Keeping the `agy` credential alive across app use.
///
/// Workers run against a copy of the token in a private HOME. The access token
/// lasts an hour, so a worker routinely refreshes it — and that refreshed token
/// used to be deleted along with the worker's directory, so app use could only
/// ever spend the freshness of the last time somebody ran `agy` by hand.
final class AgyTokenPromotionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agy-token-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func token(expiry: String, access: String = "at", refresh: String = "rt") -> String {
        """
        {"auth_method":"consumer","token":{"access_token":"\(access)",\
        "refresh_token":"\(refresh)","token_type":"Bearer","expiry":"\(expiry)"}}
        """
    }

    private func writeWorkerToken(_ contents: String) throws -> URL {
        let home = root.appendingPathComponent("home-0")
        let cli = home.appendingPathComponent(".gemini/antigravity-cli")
        try FileManager.default.createDirectory(at: cli, withIntermediateDirectories: true)
        try contents.write(to: cli.appendingPathComponent("antigravity-oauth-token"),
                           atomically: true, encoding: .utf8)
        return home
    }

    private func writeDestination(_ contents: String) throws -> URL {
        let url = root.appendingPathComponent("antigravity-oauth-token")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testANewerWorkerTokenIsPromoted() throws {
        let home = try writeWorkerToken(token(expiry: "2026-08-31T02:53:05.729239+03:00"))
        let destination = try writeDestination(token(expiry: "2026-08-31T01:53:05.729239+03:00"))
        XCTAssertTrue(AgyEnvironment.promoteRefreshedToken(from: home, into: destination))
        let promoted = try XCTUnwrap(AgyEnvironment.storedToken(at: destination))
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(promoted.expiry, parser.date(from: "2026-08-31T02:53:05.729+03:00"))
    }

    func testAnOlderWorkerTokenIsLeftAlone() throws {
        let home = try writeWorkerToken(token(expiry: "2026-08-31T00:00:00.000000+03:00"))
        let destination = try writeDestination(token(expiry: "2026-08-31T01:53:05.729239+03:00",
                                                     access: "keep", refresh: "keep"))
        XCTAssertFalse(AgyEnvironment.promoteRefreshedToken(from: home, into: destination))
        XCTAssertTrue(try String(contentsOf: destination, encoding: .utf8).contains("keep"))
    }

    func testAnEmptyTokenNeverOverwritesAGoodOne() throws {
        // A blob with an empty token in it authenticates as nobody, and does so
        // silently — the exact shape that once broke the Claude usage probe.
        let home = try writeWorkerToken(
            token(expiry: "2099-01-01T00:00:00.000000+03:00", access: "", refresh: ""))
        let destination = try writeDestination(token(expiry: "2026-08-31T01:53:05.729239+03:00",
                                                     access: "keep", refresh: "keep"))
        XCTAssertFalse(AgyEnvironment.promoteRefreshedToken(from: home, into: destination))
        XCTAssertTrue(try String(contentsOf: destination, encoding: .utf8).contains("keep"))
    }

    func testGarbageIsNotACredential() throws {
        let home = try writeWorkerToken("not json at all")
        let destination = try writeDestination(token(expiry: "2026-08-31T01:53:05.729239+03:00",
                                                     access: "keep", refresh: "keep"))
        XCTAssertFalse(AgyEnvironment.promoteRefreshedToken(from: home, into: destination))
        XCTAssertTrue(try String(contentsOf: destination, encoding: .utf8).contains("keep"))
    }

    func testAMissingDestinationIsWritten() throws {
        // First run on a machine whose only credential lives in the keychain the
        // CLI cannot read non-interactively.
        let home = try writeWorkerToken(token(expiry: "2026-08-31T02:53:05.729239+03:00"))
        let destination = root.appendingPathComponent("fresh/antigravity-oauth-token")
        XCTAssertTrue(AgyEnvironment.promoteRefreshedToken(from: home, into: destination))
        XCTAssertNotNil(AgyEnvironment.storedToken(at: destination))
    }

    func testTheSixDigitFractionalExpiryParses() throws {
        // `agy` writes microseconds, which `ISO8601DateFormatter` does not always
        // accept — and an unreadable expiry would mean never promoting anything.
        let home = try writeWorkerToken(token(expiry: "2026-08-31T01:53:05.729239+03:00"))
        let source = home.appendingPathComponent(
            ".gemini/antigravity-cli/antigravity-oauth-token")
        let parsed = try XCTUnwrap(AgyEnvironment.storedToken(at: source))
        XCTAssertTrue(parsed.isUsable)
    }
}
