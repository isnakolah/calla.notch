import CallaContracts
import XCTest
@testable import IntelligenceCore

final class CodingWorkspaceTests: XCTestCase {
    private var root: URL!
    private var workspace: CodingWorkspace!

    private let brief = InterviewBrief(
        source: .text, title: "Sliding window maximum",
        rubric: ["state the time complexity"],
        constraints: ["no external libraries"],
        depriorities: ["input validation"])

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("coding-workspace-\(UUID().uuidString)")
        workspace = CodingWorkspace(root: root)
        try FileManager.default.createDirectory(at: workspace.workURL,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func read(_ relative: String) throws -> String {
        try String(contentsOf: workspace.contextURL.appendingPathComponent(relative),
                   encoding: .utf8)
    }

    // MARK: - The layout the CLI actually requires

    /// `agy` refuses to start when a directory containing `.agents/` is passed
    /// to `--add-dir`, so the agent definition must live outside both roots.
    func testTheAgentDefinitionIsOutsideEveryWorkspaceRoot() throws {
        try workspace.seed(brief: brief, persona: "algorithms", pack: PromptPack())
        let definition = workspace.twinURL
            .appendingPathComponent(".agents/agents/coding-twin/agent.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: definition.path))
        for root in workspace.addDirectoryArguments where root != "--add-dir" {
            XCTAssertFalse(definition.path.hasPrefix(root + "/"),
                           "the agent definition is inside workspace root \(root)")
        }
    }

    /// In print mode the working directory is not a root, so anything the agent
    /// must read has to sit under an added one.
    func testBothRootsArePassedAndTheContextIsInsideOne() throws {
        try workspace.seed(brief: brief, persona: "generic", pack: PromptPack())
        let arguments = workspace.addDirectoryArguments
        XCTAssertEqual(arguments.filter { $0 == "--add-dir" }.count, 2)
        XCTAssertTrue(arguments.contains(workspace.contextURL.path))
        XCTAssertTrue(arguments.contains(workspace.workURL.path))
        XCTAssertTrue(workspace.contextURL.appendingPathComponent("AGENTS.md").path
            .hasPrefix(workspace.contextURL.path))
    }

    // MARK: - The architecture's load-bearing property

    /// The engine must never write into the candidate's tree: anything here
    /// surfaces in `diff.patch` as their own work and is merged back into their
    /// repository by the three-way reconcile.
    func testNothingIsEverWrittenIntoTheCandidatesTree() throws {
        try workspace.seed(brief: brief, persona: "generic", pack: PromptPack())
        try workspace.write(state: .init(phase: .implementing, increment: .skeleton,
                                         sourceRevision: "abc123def456", syncState: .current))
        try workspace.write(rubric: CodingRubricTracker(brief: brief).states)
        try workspace.write(ledger: CodingLedger())
        try workspace.write(diff: "+one")
        try workspace.record(run: CodingRun(id: "r1", relativeCWD: ".",
                                            displayedCommand: "swift test",
                                            lifecycle: .passed, evidenceRevision: "abc"),
                             verdict: .satisfied)

        let contents = try FileManager.default
            .contentsOfDirectory(atPath: workspace.workURL.path)
        XCTAssertEqual(contents, [], "engine wrote \(contents) into the candidate's tree")
    }

    func testTearDownLeavesTheCandidatesTreeAlone() throws {
        try workspace.seed(brief: brief, persona: "generic", pack: PromptPack())
        let candidateFile = workspace.workURL.appendingPathComponent("solve.py")
        try Data("print(1)".utf8).write(to: candidateFile)
        workspace.tearDown()
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.contextURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidateFile.path))
    }

    // MARK: - What the twin reads

    func testTheBriefNamesWhatNotToSpendTimeOn() throws {
        try workspace.seed(brief: brief, persona: "generic", pack: PromptPack())
        let text = try read("brief.md")
        XCTAssertTrue(text.contains("Do not spend time on"))
        XCTAssertTrue(text.contains("input validation"))
    }

    /// The twin is told the step, not left to choose its own size.
    func testStateNamesTheIncrementAndItsLineBudget() throws {
        try workspace.seed(brief: brief, persona: "generic", pack: PromptPack())
        try workspace.write(state: .init(phase: .implementing, increment: .skeleton,
                                         sourceRevision: "abc123def456789",
                                         syncState: .current, remainingSeconds: 540,
                                         pendingCommand: "swift test",
                                         lastVerdict: .unsatisfied, addedLines: 4))
        let text = try read("state.md")
        XCTAssertTrue(text.contains("**skeleton**"))
        XCTAssertTrue(text.contains("at most 12 added lines"))
        XCTAssertTrue(text.contains("9 min"))
        XCTAssertTrue(text.contains("swift test"))
        XCTAssertTrue(text.contains("**unsatisfied**"))
        XCTAssertTrue(text.contains("Produce the `skeleton` step and stop."))
        XCTAssertFalse(text.contains("abc123def456789"), "full revision should be abbreviated")
    }

    func testAWordsOnlyIncrementSaysSoInState() throws {
        try workspace.seed(brief: brief, persona: "generic", pack: PromptPack())
        try workspace.write(state: .init(phase: .designing, increment: .sketch,
                                         sourceRevision: "abc", syncState: .current))
        XCTAssertTrue(try read("state.md").contains("no code"))
    }

    func testCoverageRendersAsACheckedList() throws {
        try workspace.seed(brief: brief, persona: "generic", pack: PromptPack())
        var tracker = CodingRubricTracker(brief: brief)
        tracker.noteSpoken("the time complexity here is linear")
        try workspace.write(rubric: tracker.states)
        let text = try read("rubric.md")
        XCTAssertTrue(text.contains("state the time complexity — spoken"))
        XCTAssertTrue(text.contains("(constraint) no external libraries"))
    }

    func testTheAgentDefinitionCarriesTheToolAllowlistAndThePersona() throws {
        try workspace.seed(brief: brief, persona: "algorithms", pack: PromptPack())
        let text = try String(contentsOf: workspace.twinURL
            .appendingPathComponent(".agents/agents/coding-twin/agent.md"), encoding: .utf8)
        XCTAssertTrue(text.contains("name: coding-twin"))
        XCTAssertTrue(text.contains("tools: [read_file, list_directory, search_file_content, view_file"))
        XCTAssertTrue(text.contains("write_file, replace_file_content"))
        XCTAssertTrue(text.contains("State the complexity before writing the body"))
        XCTAssertTrue(text.contains("Never hand over a finished solution"))
    }

    func testAnEmptyDiffSaysSoRatherThanBeingAnEmptyFile() throws {
        try workspace.seed(brief: brief, persona: "generic", pack: PromptPack())
        try workspace.write(diff: "")
        XCTAssertTrue(try read("diff.patch").contains("no changes yet"))
    }

    func testARunIsFiledWithItsVerdict() throws {
        try workspace.seed(brief: brief, persona: "generic", pack: PromptPack())
        try workspace.record(
            run: CodingRun(id: "run-7", relativeCWD: ".", displayedCommand: "swift test",
                           lifecycle: .failed, exitCode: 1,
                           outputSummary: "error: cannot find 'window' in scope",
                           evidenceRevision: "abc"),
            verdict: .unsatisfied)
        let text = try String(contentsOf: workspace.runsURL
            .appendingPathComponent("run-7.md"), encoding: .utf8)
        XCTAssertTrue(text.contains("**unsatisfied**"))
        XCTAssertTrue(text.contains("cannot find 'window' in scope"))
    }

    func testSeedingIsIdempotent() throws {
        try workspace.seed(brief: brief, persona: "generic", pack: PromptPack())
        XCTAssertNoThrow(try workspace.seed(brief: brief, persona: "generic", pack: PromptPack()))
    }

    func testASessionWithNoBriefStillGetsUsableContext() throws {
        try workspace.seed(brief: nil, persona: "generic", pack: PromptPack())
        XCTAssertTrue(try read("brief.md").contains("Establish the objective by asking, once."))
    }
}
