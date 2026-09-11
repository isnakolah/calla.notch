import CallaContracts
import Foundation
import XCTest
@testable import IntelligenceCore
@testable import IntelligenceProviders

/// Proves the seeded workspace is one the real CLI accepts.
///
/// Skipped unless `AGY_LIVE=1`, because it spends model quota and needs a
/// signed-in `agy`:
///
///     AGY_LIVE=1 swift test --filter CodingWorkspaceLiveTests
///
/// This is the acceptance gate for the workspace layout. Every rule it encodes
/// was measured rather than assumed, and each one fails silently in a different
/// way: a root that is not passed is simply invisible, and `.agents/` inside a
/// root makes the process exit before it costs a single token.
final class CodingWorkspaceLiveTests: XCTestCase {
    private func requireLive() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["AGY_LIVE"] == "1",
            "set AGY_LIVE=1 to run tests that call the real agy")
        try XCTSkipUnless(AgyLocator.locate() != nil && AgyLocator.hasCredentials(),
                          "agy is not installed or not signed in")
    }

    private struct Reply {
        var status: String
        var response: String
        var denied: Bool
    }

    private func ask(_ prompt: String, workspace: CodingWorkspace) throws -> Reply {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: AgyLocator.locate()!)
        process.currentDirectoryURL = workspace.twinURL
        process.arguments = [
            "--print", prompt,
            "--model", "gemini-3.7-flash-low",
            "--output-format", "json",
            "--agent", CodingWorkspace.agentName,
            "--sandbox", "--disable-slash-commands", "--print-timeout", "120s"
        ] + workspace.addDirectoryArguments
        var environment = AgyEnvironment.processEnvironment()
        environment["HOME"] = AgyEnvironment.userHome
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard let start = text.firstIndex(of: "{"),
              let object = try JSONSerialization.jsonObject(
                with: Data(text[start...].utf8)) as? [String: Any] else {
            throw XCTSkip("agy returned no JSON object: \(text.suffix(400))")
        }
        return Reply(status: object["status"] as? String ?? "?",
                     response: object["response"] as? String ?? "",
                     denied: (object["denied_actions"] as? [Any])?.isEmpty == false)
    }

    private func seededWorkspace() throws -> CodingWorkspace {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("coding-live-\(UUID().uuidString)")
        let workspace = CodingWorkspace(root: root)
        try FileManager.default.createDirectory(at: workspace.workURL,
                                                withIntermediateDirectories: true)
        try Data("def solve(nums, k):\n    return []\n".utf8)
            .write(to: workspace.workURL.appendingPathComponent("solve.py"))
        try workspace.seed(
            brief: InterviewBrief(source: .text, title: "Sliding window maximum",
                                  rubric: ["state the time complexity"],
                                  constraints: ["no external libraries"]),
            persona: "algorithms", pack: PromptPack())
        try workspace.write(state: .init(phase: .implementing, increment: .skeleton,
                                         sourceRevision: "abc123", syncState: .current,
                                         remainingSeconds: 1_200))
        try workspace.write(rubric: CodingRubricTracker(
            brief: InterviewBrief(source: .text, title: "t",
                                  rubric: ["state the time complexity"])).states)
        try workspace.write(ledger: CodingLedger())
        try workspace.write(diff: "")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return workspace
    }

    /// The whole architecture in one assertion: the twin can see the engine's
    /// facts and the candidate's code at once, and nothing was auto-denied.
    func testTheSeededWorkspaceIsReadableByTheRealCLI() throws {
        try requireLive()
        let workspace = try seededWorkspace()
        let reply = try ask("""
        Reply with only a comma-separated list of these four answers: \
        the interview title from brief.md, the phase from state.md, \
        the next step named in state.md, and the name of the function \
        defined in solve.py in the project root.
        """, workspace: workspace)

        XCTAssertEqual(reply.status, "SUCCESS")
        XCTAssertFalse(reply.denied, "a tool was auto-denied; check permissions.allow")
        let answer = reply.response.lowercased()
        XCTAssertTrue(answer.contains("sliding window"), reply.response)
        XCTAssertTrue(answer.contains("implementing"), reply.response)
        XCTAssertTrue(answer.contains("skeleton"), reply.response)
        XCTAssertTrue(answer.contains("solve"), reply.response)
    }

    /// The layout rule that costs nothing to get wrong and everything to debug.
    ///
    /// Selecting an agent with `--agent` while the `.agents/` directory that
    /// defines it also sits inside a passed workspace root makes `agy` exit
    /// immediately — `status: ERROR`, zero duration, no tokens spent. Either
    /// half alone is fine, which is what makes it easy to reintroduce: the
    /// agent directory may live in the working directory, and the working
    /// directory may even be passed as a root, but not both at once.
    func testSelectingAnAgentDefinedInsideAPassedRootBreaksStartup() throws {
        try requireLive()
        let workspace = try seededWorkspace()

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: AgyLocator.locate()!)
        process.currentDirectoryURL = workspace.twinURL
        process.arguments = [
            "--print", "say ok", "--model", "gemini-3.7-flash-low",
            "--output-format", "json", "--sandbox", "--disable-slash-commands",
            "--print-timeout", "60s",
            "--agent", CodingWorkspace.agentName,
            "--add-dir", workspace.twinURL.path
        ]
        var environment = AgyEnvironment.processEnvironment()
        environment["HOME"] = AgyEnvironment.userHome
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"status\":\"ERROR\""),
                      "expected startup failure, got: \(text.suffix(300))")
    }
}
