import CryptoKit
import Foundation
import XCTest
@testable import DistributionCore

final class DistributionCoreTests: XCTestCase {
    func testAIReadinessRequiresAnActualSuccessfulResponse() {
        XCTAssertTrue(Readiness.aiResponded(Data(#"{"status":"SUCCESS","response":"READY\n"}"#.utf8)))
        XCTAssertFalse(Readiness.aiResponded(Data(#"{"status":"ERROR","response":"READY"}"#.utf8)))
        XCTAssertFalse(Readiness.aiResponded(Data(#"{"status":"SUCCESS","prompt":"Reply READY"}"#.utf8)))
        XCTAssertFalse(Readiness.aiResponded(Data(#"{"status":"SUCCESS","response":"Not READY"}"#.utf8)))
    }

    func testDependencyRejectsUntrustedAndMalformedDownloads() throws {
        let checksum = String(repeating: "a", count: 128)
        let good = ReleaseManifest.Dependency(version: "1.3.5", url: URL(string: "https://storage.googleapis.com/example.tar.gz")!, algorithm: "sha512", checksum: checksum)
        try good.validate()
        var invalid = good; invalid.url = URL(string: "https://evil.example/payload")!
        XCTAssertThrowsError(try invalid.validate())
        invalid = good; invalid.url = URL(string: "http://storage.googleapis.com/payload")!
        XCTAssertThrowsError(try invalid.validate())
        invalid = good; invalid.checksum = "short"
        XCTAssertThrowsError(try invalid.validate())
        invalid = good; invalid.version = "../../somewhere"
        XCTAssertThrowsError(try invalid.validate())
    }

    func testStreamingChecksumDetectsCorruption() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Layout.privateDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("payload")
        try Data(repeating: 42, count: 2_100_000).write(to: file)
        let expected = try Checksums.digest(file, algorithm: "sha512")
        let dependency = ReleaseManifest.Dependency(version: "1.3.5", url: URL(string: "https://storage.googleapis.com/example")!, algorithm: "sha512", checksum: expected)
        try Checksums.verify(file, dependency: dependency)
        try Data("corrupt".utf8).write(to: file)
        XCTAssertThrowsError(try Checksums.verify(file, dependency: dependency))
    }

    func testShellQuotingRoundTripsArbitraryPaths() throws {
        let value = "/tmp/a 'quoted' file $(echo bad) `echo bad`\nline"
        let result = try Commands.run("/bin/sh", ["-c", "printf %s " + Commands.shellQuote(value)])
        XCTAssertEqual(result.output, value)
    }

    func testFailedInstallLeavesExistingAppAndCleansStage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Layout.privateDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("Old 'app'.app")
        let next = root.appendingPathComponent("Next app.app")
        try Layout.privateDirectory(old); try Layout.privateDirectory(next)
        try Data("keep me".utf8).write(to: old.appendingPathComponent("history"))
        let result = try Commands.run("/bin/sh", ["-c", PackageInstaller.transactionScript(source: next, destination: old)], check: false)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertEqual(try String(contentsOf: old.appendingPathComponent("history")), "keep me")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), [next.lastPathComponent, old.lastPathComponent].sorted())
    }

    func testCommandTimeoutTerminatesChild() {
        XCTAssertThrowsError(try Commands.run("/bin/sleep", ["30"], timeout: 0.1))
    }

    func testSetupProgressRetainsSkippedAndCompletedSteps() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("progress.json")
        var progress = Progress(); progress.completed.insert("models"); progress.skipped.insert("gateway")
        try progress.write(file)
        let read = Progress.read(file)
        XCTAssertEqual(read.completed, ["models"]); XCTAssertEqual(read.skipped, ["gateway"])
        XCTAssertFalse(read.meetingTestPassed)
    }
}
