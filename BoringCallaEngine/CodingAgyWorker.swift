import CallaContracts
import Darwin
import Foundation
import IntelligenceCore
import IntelligenceProviders

enum CodingAgyWorkerFailure: Error, LocalizedError {
    case unavailable, busy, ended, timedOut, malformed, forbiddenTool(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: "AGY is unavailable or unauthenticated"
        case .busy: "The coding worker already has a turn in flight"
        case .ended: "The coding worker exited"
        case .timedOut: "The coding response exceeded its time budget"
        case .malformed: "AGY returned an invalid coding move"
        // Named for what it means to the person reading the notch mid-sentence,
        // not for the CLI's tool id. The worker cannot run anything — checks
        // are staged and executed by the engine when Run is pressed — so a
        // model reaching for a shell is a preparation that produced nothing,
        // which is the only part that affects the reader. The tool name stays
        // for the log.
        case .forbiddenTool(let tool):
            "Background preparation tried to run a command, which it cannot do (\(tool))"
        }
    }
}

/// The draft type lives in `IntelligenceCore` so the pacing screen, the claim
/// guard and the eval harness all agree on its shape without the engine being a
/// dependency of any of them.
typealias CodingAgyMoveDraft = CodingMoveDraft

/// One continuous edit-capable AGY conversation over the session workspace.
///
/// Two roots: the engine-owned `context/`, which holds the brief, the live state
/// and the diff as files, and the candidate's `work/`, which it may read, search
/// and edit. Command tools are rejected; execution belongs to
/// `CodingShadowRunner` after a local cue or a button.
///
/// The context used to be a string literal rebuilt and re-sent on every turn.
/// Moving it into the workspace is what makes a rollover survivable: a respawned
/// worker reads `context/` and is caught up, where before it started blank.
actor CodingAgyWorker {
    private let workspace: CodingWorkspace
    private let isolatedHome: URL
    private let selection: CodingModelSelection
    private let readOnly: Bool
    private let dialogue: Bool
    private let allowsCommands: Bool
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var turnInFlight = false
    private var firstTurn = true
    private var contextBytes = 0
    private let rolloverBytes = 180_000

    /// Cold bootstrap allowance. Warm moves use the task's actual live budget.
    static let turnTimeoutSeconds: Double = 20

    init(workspace: CodingWorkspace, isolatedHome: URL,
         selection: CodingModelSelection, readOnly: Bool = false, dialogue: Bool = false,
         allowsCommands: Bool = false) throws {
        self.workspace = workspace; self.isolatedHome = isolatedHome
        self.selection = selection; self.readOnly = readOnly; self.dialogue = dialogue
        self.allowsCommands = allowsCommands
        try Self.prepareHome(isolatedHome)
        let spawned = try Self.spawn(workspace: workspace, isolatedHome: isolatedHome,
                                     selection: selection, readOnly: readOnly, dialogue: dialogue,
                                     allowsCommands: allowsCommands)
        process = spawned.process; input = spawned.input; output = spawned.output
    }

    /// Ask for one move.
    ///
    /// `frame` is built by `CodingTurn.frame` and carries only the small
    /// volatile facts; everything else is on disk for the twin to read if it
    /// needs to. A rollover here is no longer amnesia — the replacement process
    /// starts against the same workspace.
    func respond(frame: String, timeoutSeconds: Double? = nil) async throws -> CodingAgyMoveDraft {
        guard !turnInFlight else { throw CodingAgyWorkerFailure.busy }
        if contextBytes + frame.utf8.count > rolloverBytes {
            stop(); try Self.prepareHome(isolatedHome)
            let spawned = try Self.spawn(workspace: workspace, isolatedHome: isolatedHome,
                                         selection: selection, readOnly: readOnly, dialogue: dialogue,
                                         allowsCommands: allowsCommands)
            process = spawned.process; input = spawned.input; output = spawned.output
            firstTurn = true; contextBytes = 0
        }
        guard process?.isRunning == true, let input, let output else { throw CodingAgyWorkerFailure.ended }
        turnInFlight = true
        defer { turnInFlight = false; firstTurn = false }
        // Deliberately no "read these files first". The twin's constitution is
        // already in its agent definition, and the frame carries the volatile
        // facts inline — telling it to open the workspace as well bought two
        // tool round trips per move and nothing else. The files are there to be
        // consulted when it actually needs depth.
        let prompt = frame
        let envelope: [String: Any] = ["event": "user", "message": ["content": prompt]]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        try input.write(contentsOf: data + Data("\n".utf8))
        let timeout = timeoutSeconds ?? (firstTurn ? (readOnly ? 45 : Self.turnTimeoutSeconds) : (readOnly ? 12 : CodingTasks.move.latencyBudget))
        do {
            let readOnly = self.readOnly
            let commandsAllowed = allowsCommands
            let draft = try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: CodingAgyMoveDraft.self) { group in
                group.addTask {
                    return try await Self.readResultOffActor(output, readOnly: readOnly,
                                                            allowsCommands: commandsAllowed)
                }
                group.addTask { [weak self] in
                    try await Task.sleep(for: .seconds(timeout))
                    await self?.stop()
                    throw CodingAgyWorkerFailure.timedOut
                }
                guard let value = try await group.next() else { throw CodingAgyWorkerFailure.ended }
                group.cancelAll(); return value
                }
            } onCancel: { [weak self] in Task { await self?.stop() } }
            contextBytes += prompt.utf8.count + ((try? JSONEncoder().encode(draft).count) ?? 0)
            return draft
        } catch {
            stop()
            throw error
            }
    }

    func stop() {
        try? input?.close(); input = nil; output = nil
        guard let process else { return }
        let pid = process.processIdentifier
        if process.isRunning { process.terminate() }
        if pid > 0 { Self.terminateDescendants(of: pid); kill(pid, SIGKILL) }
        self.process = nil
    }

    private static func spawn(workspace: CodingWorkspace, isolatedHome: URL,
                              selection: CodingModelSelection, readOnly: Bool, dialogue: Bool,
                              allowsCommands: Bool) throws
        -> (process: Process, input: FileHandle, output: FileHandle) {
        guard let binary = AgyLocator.locate(), AgyLocator.hasCredentials() else {
            throw CodingAgyWorkerFailure.unavailable
        }
        // Noninteractive AGY requires an explicit write_file allow-rule even in
        // accept-edits mode. It is scoped to this job's private copy.
        //
        // A private proposal job also gets commands. It owns a throwaway copy of
        // the whole tree, so running the project's own tests against its own
        // edit is the point of it — and a tool it reaches for and is refused
        // used to discard the turn outright, which mid-interview means an empty
        // panel. The kernel sandbox stays authoritative either way: the profile
        // below permits exec but confines every write to the workspace.
        let settings = isolatedHome.appendingPathComponent(".gemini/antigravity-cli/settings.json")
        let resolvedWork = realpath(workspace.workURL.path, nil)
        let canonicalWork = resolvedWork.map { String(cString: $0) } ?? workspace.workURL.path
        if let resolvedWork { free(resolvedWork) }
        var permissions = readOnly
            ? []
            : Array(Set([workspace.workURL.path, canonicalWork])).map { "write_file(\($0))" }
        if allowsCommands { permissions += CodingWorkspace.commandTools.map { "\($0)()" } }
        let settingsData = try JSONSerialization.data(withJSONObject: ["permissions": ["allow": permissions]])
        try settingsData.write(to: settings, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settings.path)
        let child = Process(); let stdin = Pipe(); let stdout = Pipe()
        child.executableURL = URL(fileURLWithPath: binary)
        // The working directory holds `.agents/` and is deliberately *not* one
        // of the workspace roots: selecting an agent whose definition also sits
        // inside a passed root makes `agy` exit before it does any work.
        child.currentDirectoryURL = workspace.twinURL
        child.arguments = ["--input-format", "stream-json", "--output-format", "stream-json",
                           "--json-schema", responseSchema(dialogue: dialogue), "--model", selection.modelID,
                           "--agent", CodingWorkspace.agentName,
                           "--mode", readOnly ? "plan" : "accept-edits", "--sandbox",
                           "--disable-slash-commands",
                           "--print-timeout", readOnly ? "45s" : "90s"]
            + Self.effortArguments(selection)
            + workspace.addDirectoryArguments
        var environment = AgyEnvironment.processEnvironment()
        environment["HOME"] = isolatedHome.path
        child.environment = environment
        let sandbox = "/usr/bin/sandbox-exec"
        guard FileManager.default.isExecutableFile(atPath: sandbox) else { throw CodingAgyWorkerFailure.unavailable }
        let temporary = isolatedHome.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        environment["TMPDIR"] = temporary.path
        child.environment = environment
        child.arguments = ["-p", sandboxProfile(workspace: workspace, isolatedHome: isolatedHome, readOnly: readOnly), binary]
            + (child.arguments ?? [])
        child.executableURL = URL(fileURLWithPath: sandbox)
        child.standardInput = stdin; child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        try child.run()
        return (child, stdin.fileHandleForWriting, stdout.fileHandleForReading)
    }

    /// Kernel boundary: only a coder's private copy is writable. This also
    /// denies writes through symlinks and absolute paths to the selected folder.
    static func sandboxProfile(workspace: CodingWorkspace, isolatedHome: URL, readOnly: Bool) -> String {
        func quoted(_ url: URL) -> String {
            let resolved = realpath(url.path, nil)
            defer { if let resolved { free(resolved) } }
            let path = resolved.map { String(cString: $0) } ?? url.path
            return "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let writable = [isolatedHome, workspace.twinURL] + (readOnly ? [] : [workspace.workURL])
        return "(version 1)(allow default)(deny file-write* (require-not (require-any "
            + writable.map { "(subpath " + quoted($0) + ")" }.joined(separator: " ") + ")))"
    }

    /// Named thinking presets already choose their level. Send an independent
    /// override only for models whose IDs do not include a preset.
    static func effortArguments(_ selection: CodingModelSelection) -> [String] {
        selection.effortArguments
    }

    private nonisolated static func readResultOffActor(_ output: FileHandle, readOnly: Bool,
                                                       allowsCommands: Bool) async throws -> CodingAgyMoveDraft {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try Self.readResult(output, readOnly: readOnly, allowsCommands: allowsCommands)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private nonisolated static func readResult(_ output: FileHandle, readOnly: Bool,
                                               allowsCommands: Bool) throws -> CodingAgyMoveDraft {
        var pending = Data()
        // Remembered rather than thrown on. A model that reaches for a tool it
        // does not have, is refused, and then answers anyway has still answered;
        // throwing mid-stream threw that answer away too. This only becomes a
        // failure if the turn ends up producing nothing.
        var refusedTool: String?
        while true {
            let chunk = output.availableData
            guard !chunk.isEmpty else { throw CodingAgyWorkerFailure.ended }
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[..<newline]; pending.removeSubrange(...newline)
                guard let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let name = event["event"] as? String else { continue }
                if name == "step_update", let step = event["step_update"] as? [String: Any],
                   step["step_type"] as? String == "tool" {
                    let tool = ((step["tool_name"] as? String) ?? "").lowercased()
                    let isCommand = tool.contains("shell") || tool.contains("command")
                        || tool.contains("terminal")
                    let readOnlyViolation = readOnly && !isCommand && ![
                        "read_file", "list_directory", "search_file_content", "view_file",
                        "list_dir", "grep_search", "find_by_name", "view_code_item",
                        "view_file_outline", "finish"
                    ].contains(tool)
                    if (isCommand && !allowsCommands) || readOnlyViolation {
                        refusedTool = tool
                    }
                }
                guard name == "result", let result = event["result"] as? [String: Any],
                      result["status"] as? String == "SUCCESS" else { continue }
                if let denied = result["denied_actions"] as? [[String: Any]], let first = denied.first {
                    refusedTool = first["action"] as? String ?? refusedTool ?? "unknown"
                }
                let json: Data
                if let structured = result["structured_output"] as? [String: Any] {
                    json = try JSONSerialization.data(withJSONObject: structured)
                } else if let response = result["response"] as? String {
                    json = Data(Self.extractJSON(response).utf8)
                } else if let tool = refusedTool {
                    throw CodingAgyWorkerFailure.forbiddenTool(tool)
                } else { throw CodingAgyWorkerFailure.malformed }
                guard !json.isEmpty else {
                    if let tool = refusedTool { throw CodingAgyWorkerFailure.forbiddenTool(tool) }
                    throw CodingAgyWorkerFailure.malformed
                }
                let draft = try JSONDecoder().decode(CodingAgyMoveDraft.self, from: json)
                try Self.validate(draft)
                return draft
            }
        }
    }

    private static func validate(_ value: CodingAgyMoveDraft) throws {
        let strings = [value.say, value.code, value.why, value.watch, value.check?.displayedCommand]
        guard strings.compactMap({ $0 }).allSatisfy({ $0.utf8.count <= LiveCodingContract.maximumTextBytes }) else {
            throw CodingAgyWorkerFailure.malformed
        }
        if let path = value.file?.path { try LiveCodingValidation.validate(relativePath: path) }
        if let cwd = value.check?.relativeCWD { try LiveCodingValidation.validate(relativePath: cwd) }
    }

    private static func extractJSON(_ value: String) -> String {
        guard let start = value.firstIndex(of: "{"), let end = value.lastIndex(of: "}") else { return value }
        return String(value[start ... end])
    }

    private static let moveSchema = #"{"type":"object","additionalProperties":false,"required":["kind","say","file","code","why","check","watch"],"properties":{"kind":{"enum":["explanation","design","implementation","edit","diagnostic","verification","watch"]},"say":{"type":["string","null"]},"file":{"anyOf":[{"type":"null"},{"type":"object","additionalProperties":false,"required":["path","symbol","line"],"properties":{"path":{"type":"string"},"symbol":{"type":["string","null"]},"line":{"type":["integer","null"]}}}]},"code":{"type":["string","null"]},"why":{"type":["string","null"]},"check":{"anyOf":[{"type":"null"},{"type":"object","additionalProperties":false,"required":["id","relativeCWD","displayedCommand","expectedEvidence"],"properties":{"id":{"type":"string"},"relativeCWD":{"type":"string"},"displayedCommand":{"type":"string"},"expectedEvidence":{"type":["string","null"]}}}]},"watch":{"type":["string","null"]},"dialogue":{"anyOf":[{"type":"null"},{"type":"object","required":["sessionID","generation","sourceRevision","requirementRevision","taskRevision","discussedSteps","evidence","pointers"],"properties":{"sessionID":{"type":"string"},"sourceRevision":{"type":"string"},"limitation":{"type":"string"},"retry":{"type":"string"},"generation":{"type":"integer"},"requirementRevision":{"type":"integer"},"taskRevision":{"type":"integer"},"facts":{"type":"array","items":{"type":"object","required":["id","text","kind","evidence"],"properties":{"id":{"type":"string"},"text":{"type":"string"},"kind":{"enum":["interviewerRequirement","candidateChoice","assumption"]},"evidence":{"type":"array","items":{"type":"object","required":["anchor","speaker","quote"],"properties":{"anchor":{"type":"object","required":["fromSequence","toSequence"],"properties":{"fromSequence":{"type":"integer"},"toSequence":{"type":"integer"}}},"speaker":{"enum":["me","them"]},"quote":{"type":"string"}}}}}}},"clarification":{"type":"object","required":["id","question","allowsYesNo","evidence","resolved"],"properties":{"id":{"type":"string"},"question":{"type":"string"},"allowsYesNo":{"type":"boolean"},"asked":{"type":"object","required":["anchor","speaker","quote"],"properties":{"anchor":{"type":"object","required":["fromSequence","toSequence"],"properties":{"fromSequence":{"type":"integer"},"toSequence":{"type":"integer"}}},"speaker":{"enum":["me","them"]},"quote":{"type":"string"}}},"answer":{"type":"string"},"evidence":{"type":"array","items":{"type":"object","required":["anchor","speaker","quote"],"properties":{"anchor":{"type":"object","required":["fromSequence","toSequence"],"properties":{"fromSequence":{"type":"integer"},"toSequence":{"type":"integer"}}},"speaker":{"enum":["me","them"]},"quote":{"type":"string"}}}},"resolved":{"type":"boolean"}}},"discussedStep":{"enum":["example","approach","correctness","complexity"]},"evidence":{"type":"array","items":{"type":"object","required":["anchor","speaker","quote"],"properties":{"anchor":{"type":"object","required":["fromSequence","toSequence"],"properties":{"fromSequence":{"type":"integer"},"toSequence":{"type":"integer"}}},"speaker":{"enum":["me","them"]},"quote":{"type":"string"}}}},"pointers":{"type":"array","items":{"type":"string"}},"questionToAssistant":{"type":"object","required":["anchor","speaker","quote"],"properties":{"anchor":{"type":"object","required":["fromSequence","toSequence"],"properties":{"fromSequence":{"type":"integer"},"toSequence":{"type":"integer"}}},"speaker":{"enum":["me","them"]},"quote":{"type":"string"}}},"pending":{"type":"array","items":{"type":"object","required":["id","text","stage","required","requirementIDs"],"properties":{"id":{"type":"string"},"text":{"type":"string"},"stage":{"enum":["understanding","reasoning","simple","hardening","optimization","verification","concluded"]},"required":{"type":"boolean"},"requirementIDs":{"type":"array","items":{"type":"string"}},"completedEvidence":{"type":"object","required":["sourceRevision","path","excerpt"],"properties":{"sourceRevision":{"type":"string"},"path":{"type":"string"},"excerpt":{"type":"string"}}}}}},"discussedSteps":{"type":"array","items":{"enum":["example","approach","correctness","complexity"]}}}}]}}}"#

    private static func responseSchema(dialogue: Bool) -> String {
        guard dialogue, var schema = try? JSONSerialization.jsonObject(with: Data(moveSchema.utf8)) as? [String: Any],
              var properties = schema["properties"] as? [String: Any],
              let wrapper = properties["dialogue"] as? [String: Any],
              let choices = wrapper["anyOf"] as? [[String: Any]], let object = choices.last else { return moveSchema }
        properties["dialogue"] = object
        schema["properties"] = properties
        schema["required"] = (schema["required"] as? [String] ?? []) + ["dialogue"]
        return (try? JSONSerialization.data(withJSONObject: schema)).map { String(decoding: $0, as: UTF8.self) } ?? moveSchema
    }

    private static func prepareHome(_ home: URL) throws {
        let manager = FileManager.default
        let gemini = home.appendingPathComponent(".gemini", isDirectory: true)
        let cli = gemini.appendingPathComponent("antigravity-cli", isDirectory: true)
        try manager.createDirectory(at: cli, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        for source in [AgyEnvironment.credentialsFile, AgyEnvironment.accountsFile]
            where manager.fileExists(atPath: source.path) {
            let destination = gemini.appendingPathComponent(source.lastPathComponent)
            try? manager.removeItem(at: destination); try manager.copyItem(at: source, to: destination)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
        let token = AgyEnvironment.cliOAuthTokenFile
        if manager.fileExists(atPath: token.path) {
            let destination = cli.appendingPathComponent(token.lastPathComponent)
            try? manager.removeItem(at: destination); try manager.copyItem(at: token, to: destination)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
    }

    private static func terminateDescendants(of pid: pid_t) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        task.arguments = ["-TERM", "-P", String(pid)]
        task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
        try? task.run(); task.waitUntilExit()
    }
}
