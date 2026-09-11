import CallaContracts
import Foundation

/// The agent's context, on disk.
///
/// Live Coding is a coding environment, so its intelligence is given a working
/// directory the way Claude Code or Codex would be: facts as `.md` files, indexed
/// by an `AGENTS.md`, read by the agent's own tools. What used to be a Swift
/// string literal re-sent on every turn is now a directory the engine keeps
/// current.
///
/// Three roots, and the split between them is load-bearing:
///
/// - `twin/` is the process working directory. It holds `.agents/` and nothing
///   else, and is **never** passed as a workspace root — `agy` fails to start
///   outright (`status: ERROR`, zero duration) when a directory containing
///   `.agents/` is given to `--add-dir`.
/// - `context/` is engine-owned and refreshed as facts change.
/// - `work/` is the candidate's tree. The engine never writes a byte into it:
///   anything here shows up in `diff.patch` as the candidate's own work, and
///   would be merged back into their repo by the three-way reconcile.
///
/// Both `context/` and `work/` are passed with a repeated `--add-dir`. In print
/// mode the process working directory is *not* a workspace root, so a file the
/// agent is expected to read has to be under one of them.
public struct CodingWorkspace: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    /// Not stored: `FileManager` is not `Sendable`, and this type crosses into
    /// the session actor. Every use is a synchronous call on the thread-safe
    /// default instance.
    private var fileManager: FileManager { .default }

    /// Process working directory. Holds `.agents/`, never a workspace root.
    public var twinURL: URL { root.appendingPathComponent("twin", isDirectory: true) }
    /// Engine-owned facts. A workspace root.
    public var contextURL: URL { root.appendingPathComponent("context", isDirectory: true) }
    /// The candidate's tree. A workspace root. Never written to by the engine.
    public var workURL: URL { root.appendingPathComponent("work", isDirectory: true) }
    public var runsURL: URL { contextURL.appendingPathComponent("runs", isDirectory: true) }

    /// The agent name selected with `--agent`.
    public static let agentName = "coding-twin"

    /// Directory arguments, in the order they should be passed.
    public var addDirectoryArguments: [String] {
        ["--add-dir", contextURL.path, "--add-dir", workURL.path]
    }

    public func seedWaveContext() throws {
        guard let bundled = PromptPack.bundledRoot?.appendingPathComponent("coding/wave-v1") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let target = contextURL.appendingPathComponent("wave-v1")
        if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
        try fileManager.copyItem(at: bundled, to: target)
    }

    // MARK: - Seeding

    /// Write everything that does not change during the session.
    /// Tools a worker gets on top of reading, searching and editing.
    ///
    /// Commands are granted to the private proposal jobs: each one owns a full
    /// throwaway copy of the tree, so a worker that wants to run the project's
    /// own tests to check its edit is doing exactly what the interview needs.
    /// They execute in the engine's process rather than inside
    /// `CodingShadowRunner`'s sandbox, which is why they are a parameter and not
    /// the default.
    public static let commandTools = ["run_command", "run_terminal_cmd", "shell"]

    public func seed(brief: InterviewBrief?, persona: String, pack: PromptPack,
                     readOnly: Bool = false, allowsCommands: Bool = false) throws {
        for directory in [twinURL, contextURL, runsURL] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
        }
        let agents = twinURL.appendingPathComponent(".agents/agents/\(Self.agentName)",
                                                    isDirectory: true)
        try fileManager.createDirectory(at: agents, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])

        // The agent definition carries the tool allowlist. It is a declaration,
        // not the enforcement: the worker still rejects a command tool mid-stream,
        // because a frontmatter list is only as good as the CLI honouring it.
        let definition = """
        ---
        name: \(Self.agentName)
        description: App-owned Live Coding interview twin.
        tools: [read_file, list_directory, search_file_content, view_file, list_dir, grep_search, find_by_name, view_code_item, view_file_outline\(readOnly ? "" : ", edit_file, write_file, replace_file_content, multi_replace_file_content, write_to_file")\(allowsCommands ? ", " + Self.commandTools.joined(separator: ", ") : "")]
        mainAgent: true
        subagent: false
        ---
        \(pack.text(.codingAgents))

        \(pack.codingPersona(persona))
        """
        try write(definition, to: agents.appendingPathComponent("agent.md"))

        try write("""
        \(pack.text(.codingAgents))

        ## This interview

        \(pack.codingPersona(persona))
        """, to: contextURL.appendingPathComponent("AGENTS.md"))

        try write(Self.briefMarkdown(brief), to: contextURL.appendingPathComponent("brief.md"))
        try write(pack.text(.codingLaneMove), to: contextURL.appendingPathComponent("lane-move.md"))
    }

    // MARK: - Volatile facts

    /// Everything the twin needs to know about *now*.
    public struct State: Sendable, Equatable {
        public var phase: CodingPhase
        public var increment: CodingIncrement
        public var sourceRevision: String
        public var syncState: CodingSyncState
        public var remainingSeconds: Int?
        public var pendingCommand: String?
        public var lastVerdict: CodingVerdict?
        public var addedLines: Int

        public init(phase: CodingPhase, increment: CodingIncrement, sourceRevision: String,
                    syncState: CodingSyncState, remainingSeconds: Int? = nil,
                    pendingCommand: String? = nil, lastVerdict: CodingVerdict? = nil,
                    addedLines: Int = 0) {
            self.phase = phase; self.increment = increment
            self.sourceRevision = sourceRevision; self.syncState = syncState
            self.remainingSeconds = remainingSeconds; self.pendingCommand = pendingCommand
            self.lastVerdict = lastVerdict; self.addedLines = addedLines
        }
    }

    public func write(state: State) throws {
        var lines = [
            "# State", "",
            "- phase: **\(state.phase.rawValue)**",
            "- next step: **\(state.increment.rawValue)** " +
                "(at most \(state.increment.maximumAddedLines) added lines" +
                (state.increment.allowsCode ? ")" : "; no code)"),
            "- revision: `\(String(state.sourceRevision.prefix(12)))`",
            "- sync: \(state.syncState.rawValue)",
            "- lines written so far: \(state.addedLines)"
        ]
        if let remaining = state.remainingSeconds {
            lines.append("- time left: **\(remaining / 60) min**")
        }
        if let pending = state.pendingCommand {
            lines.append("- staged check: `\(pending)` (not run yet)")
        }
        if let verdict = state.lastVerdict {
            lines.append("- last check: **\(verdict.rawValue)**")
        }
        lines += ["", "Produce the `\(state.increment.rawValue)` step and stop."]
        try write(lines.joined(separator: "\n") + "\n",
                  to: contextURL.appendingPathComponent("state.md"))
    }

    public func write(rubric states: [CodingRubricState]) throws {
        var lines = ["# Coverage", ""]
        if states.isEmpty {
            lines.append("No brief was supplied; infer the objective from the transcript.")
        } else {
            for state in states {
                let mark = state.status == .verified ? "x" : " "
                let note = state.status == .open ? "" : " — \(state.status.rawValue)"
                lines.append("- [\(mark)] (\(state.kind.rawValue)) \(state.text)\(note)")
            }
        }
        try write(lines.joined(separator: "\n") + "\n",
                  to: contextURL.appendingPathComponent("rubric.md"))
    }

    public func write(ledger: CodingLedger) throws {
        try write(ledger.markdown(), to: contextURL.appendingPathComponent("ledger.md"))
    }

    /// The engine-computed diff. This is the truth about what the candidate has
    /// written; the agent's own recollection of its edits is not.
    public func write(diff: String) throws {
        try write(diff.isEmpty ? "(no changes yet)\n" : diff,
                  to: contextURL.appendingPathComponent("diff.patch"))
    }

    public func record(run: CodingRun, verdict: CodingVerdict) throws {
        let body = """
        # \(run.displayedCommand)

        - verdict: **\(verdict.rawValue)**
        - exit: \(run.exitCode.map(String.init) ?? "n/a")
        - duration: \(run.durationMilliseconds.map { "\($0) ms" } ?? "n/a")
        \(run.outputTruncated ? "- output was truncated\n" : "")
        ```
        \(String(run.outputSummary.suffix(4_000)))
        ```
        """
        try write(body, to: runsURL.appendingPathComponent("\(run.id).md"))
    }

    /// Remove the whole context tree. The candidate's `work/` is untouched.
    public func tearDown() {
        try? fileManager.removeItem(at: twinURL)
        try? fileManager.removeItem(at: contextURL)
    }

    // MARK: - Rendering

    /// The brief as the twin reads it.
    ///
    /// Public because the dialogue lane no longer has a workspace to read
    /// `brief.md` from — it runs on the shared resident host and is handed the
    /// same text as a prompt block instead.
    public static func briefMarkdown(_ brief: InterviewBrief?) -> String {
        guard let brief else {
            return "# Brief\n\nNone supplied. Establish the objective by asking, once.\n"
        }
        var lines = ["# \(brief.title)", ""]
        func section(_ title: String, _ values: [String]) {
            guard !values.isEmpty else { return }
            lines.append("## \(title)")
            lines += values.map { "- \($0)" }
            lines.append("")
        }
        section("Scored on", brief.rubric)
        section("Constraints", brief.constraints)
        section("Order", brief.taskOrdering)
        section("Given to you", brief.suppliedInterfaces)
        // Named explicitly rather than omitted: knowing what not to spend time
        // on is as directive as knowing what to cover.
        section("Do not spend time on", brief.depriorities)
        return lines.joined(separator: "\n")
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
