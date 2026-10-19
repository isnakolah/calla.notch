import CallaContracts
import CryptoKit
import Foundation
import IntelligenceCore
import IntelligenceProviders

actor CodingSessionController {
    private struct ActiveLedger: Codable {
        var configuration: CodingSessionConfiguration
        var snapshot: CodingSessionSnapshot
        var events: [CodingEvent]
        var preflight: CodingFolderPreflight
        var bookmark: Data
        var startedAt: Date
    }

    private struct Capability {
        var source: URL
        var bookmark: Data
        var accessing: Bool
        var preflight: CodingFolderPreflight
    }

    private let root: URL
    private let hostExecutable: @Sendable () -> URL?
    private let askCall: @Sendable (String, Int, UUID, String, CodingDialogueEvidence?) async -> Bool
    private struct PreparedStep {
        var pendingID: String
        var revision: WaveRevision
        var move: CodingMove
        var work: URL
    }
    private var preparedSteps: [PreparedStep] = []
    private var heldMove: CodingMove?
    /// Injected only by the integration harness; production routes the lane
    /// through `router` and the resident provider.
    private let dialogueResponder: (@Sendable (String) async throws -> CodingMoveDraft)?
    private let preparesInBackground: Bool
    private let historyKeyProvider: @Sendable () throws -> SymmetricKey
    private var spokenQuestionIDs: [String: UUID] = [:]
    private var observationTask: Task<Void, Never>?
    private let fileManager: FileManager
    private var capabilities: [String: Capability] = [:]
    private var configuration: CodingSessionConfiguration?
    private var status = CodingSessionSnapshot()
    private var events: [CodingEvent] = []
    private var watcher: Task<Void, Never>?
    private var activeRun: CodingShadowRunner?
    private var runTask: Task<Void, Never>?
    /// The dialogue lane's resident language server, and the router in front
    /// of it.
    ///
    /// This lane used to spawn its own `agy` process per session and pay the
    /// ~6-8s Google handshake on its first real turn — which, in an interview,
    /// is the first question. The provider keeps one process alive and submits
    /// through `agentapi` in ~0.06s instead, and `openSession` makes the opening
    /// request a plain append rather than a bootstrap.
    ///
    /// Deliberately a *second* host rather than the call copilot's: `AgyHost`
    /// reaps every orphan matching its own workspace path, so pointing this at
    /// the copilot's runtime root would kill the warm conversation that answers
    /// the interviewer's questions. One extra resident process, against one
    /// fewer spawn per session.
    private let provider: AgyProvider
    private let router: IntelligenceRouter
    private var waveWorkers: WaveWorkerPool?
    private var wavePreparationTask: Task<Void, Never>?
    /// Where the pointers currently on screen are about.
    ///
    /// A words-only step carries no code, so it used to carry no file either —
    /// and an explanation about `_evaluate` is worth twice as much when the
    /// panel also says which file and symbol it is in. The dialogue lane can
    /// name it, so it does; the engine checks the path exists in its own mirror
    /// before the panel prints it, because a plausible wrong filename
    /// mid-interview is worse than none.
    private var dialogueAnchor: CodingFileAnchor?
    private var preparationDebounce: Task<Void, Never>?
    /// What the last accepted preparation was for. A save that changes nothing
    /// the coders were asked about must not restart them.
    private var lastPreparationFingerprint: String?
    private var waveProposalPaths: [String: URL] = [:]
    private var preparedContexts: [String: URL] = [:]
    private var preparingWave = false
    private var activeRunToken: UUID?
    private var guidanceTask: Task<Void, Never>?
    private var guidanceID: UUID?
    private var guidanceQueue = CodingGuidanceQueue()
    private var nextSequence = 0
    private var startedAt = Date()

    // The control plane. Every field here is an engine fact; none of it is
    // model output read back.
    private var workspace: CodingWorkspace?
    private var segmenter = StatementSegmenter(rules: .coding)
    private var phaseMachine = CodingPhaseMachine()
    private var rubric = CodingRubricTracker(brief: nil)
    private var ledger = CodingLedger()
    private var lastVerdict: CodingVerdict?
    private var lastCommand: String?
    private var addedLines = 0
    private var lastSaveAt: Date?
    private var transcriptClock: Double = 0
    private var transcriptSequence = -1
    private var transcriptClockSetAt = Date()
    private var ticker: Task<Void, Never>?

    private var vault: CodingSessionVault { CodingSessionVault(keyProvider: historyKeyProvider, root: root, fileManager: fileManager) }

    /// The twin's wording lives in the prompt pack so it stays overridable and
    /// lintable, even though it is delivered as files rather than as a prompt.
    private var promptPack: PromptPack { PromptPack() }

    init(root: URL, fileManager: FileManager = .default,
         hostExecutable: @escaping @Sendable () -> URL? = { nil },
         askCall: @escaping @Sendable (String, Int, UUID, String, CodingDialogueEvidence?) async -> Bool = { _, _, _, _, _ in false },
         dialogueResponder: (@Sendable (String) async throws -> CodingMoveDraft)? = nil,
         preparesInBackground: Bool = true,
         historyKeyProvider: @escaping @Sendable () throws -> SymmetricKey = { try CodeHistoryKey.loadOrCreate() }) {
        self.dialogueResponder = dialogueResponder; self.preparesInBackground = preparesInBackground
        self.historyKeyProvider = historyKeyProvider
        self.hostExecutable = hostExecutable
        self.askCall = askCall
        self.root = root.standardizedFileURL
        self.fileManager = fileManager
        let provider = AgyProvider(configuration: .init(runtimeRoot: self.root))
        self.provider = provider
        self.router = IntelligenceRouter(
            providers: [provider],
            policy: .init(preferred: [CodingTasks.dialogue.id: .localAgy],
                          fallbackEnabled: false))
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: 0o700])
        Self.recoverAbandonedSessions(root: self.root, fileManager: fileManager, historyKeyProvider: historyKeyProvider)
    }

    deinit {
        watcher?.cancel(); ticker?.cancel(); runTask?.cancel(); observationTask?.cancel()
        for capability in capabilities.values where capability.accessing {
            capability.source.stopAccessingSecurityScopedResource()
        }
    }

    /// The dialogue lane's conversation, one per session.
    private func dialogueSessionKey(_ sessionID: String) -> String {
        CodingTasks.sessionKey(sessionID, lane: CodingTasks.dialogue)
    }

    /// What the dialogue lane is told once, at the top of its conversation.
    ///
    /// The same three pieces `CodingWorkspace.seed` writes as files, because
    /// this lane no longer has a workspace to read them from.
    /// `PromptComposer.bootstrap` adds the house rules and the JSON contract on
    /// top and sends the whole thing exactly once per conversation, so none of
    /// it is re-paid per question.
    private func dialogueBlocks(brief: InterviewBrief?) -> PromptBlocks {
        let pack = promptPack
        return PromptBlocks(
            base: pack.text(.codingAgents),
            role: pack.codingPersona(Self.persona),
            knowledge: CodingWorkspace.briefMarkdown(brief),
            taskGuidance: pack.text(.codingLaneMove))
    }

    /// Open the conversation before anyone is waiting on it.
    ///
    /// Never awaited by its caller, for the same reason `CallSession.start` does
    /// not await the call lanes: booting the language server measured ~5.9s, and
    /// the session has a shadow project to build in the meantime.
    private func prewarmDialogue(sessionID: String, brief: InterviewBrief?) {
        guard dialogueResponder == nil else { return }
        let key = dialogueSessionKey(sessionID)
        let blocks = dialogueBlocks(brief: brief)
        Task { [provider] in
            await provider.openSession(task: CodingTasks.dialogue, sessionKey: key, system: blocks)
        }
    }

    /// The coding persona every workspace is seeded with:
    /// `coding/personas/interview.md`.
    static let persona = "interview"

    /// The `interviewProfile` value that turns on the Wave context pack, the
    /// task ladder and the reading viewport. Mirrors `WaveInterview.profileID`
    /// in the app; the two processes do not share a module.
    enum WaveInterviewProfile { static let wave = "wave" }

    func prepareWave(_ request: WavePreparationRequest) async -> WavePreparationResult {
        guard !status.lifecycle.active, !preparingWave else {
            return .init(failure: "End the active coding session or wait for preparation to finish before importing materials.")
        }
        preparingWave = true
        defer { preparingWave = false }
        do {
            let source = try CodingFolderBookmark.resolve(request.projectBookmark).url
            let access = source.startAccessingSecurityScopedResource()
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            // No import step. Supplied material is put into the working folder
            // by hand, so Prepare reads whatever is there — which means the
            // thing it probes is the thing the interview runs against, with no
            // staged merge to diverge from it.
            let preflight = try await registerFolder(bookmark: request.projectBookmark)
            let preparation = root.appendingPathComponent("prepared/" + preflight.capabilityID)
            let manifest = try CodingShadowProject.prepare(source: source,
                mirror: preparation.appendingPathComponent("mirror"), work: preparation.appendingPathComponent("work"))
            let space = CodingWorkspace(root: preparation)
            try space.seed(brief: nil, persona: CodingSessionController.persona, pack: promptPack)
            try space.seedWaveContext()
            var report = "Private snapshot: \(manifest.entries.count) entries. Source revision: \(manifest.revision).\n"
                + "No interview implementation was generated.\n"
            let workRoot = preparation.appendingPathComponent("work")
            // The Python project is not always the repository root, and for this
            // interview it is not: material intake needs the git root (`git
            // clone` refuses a subdirectory outright), while the package, its
            // requirements and its venv live one level down. Preparing at the
            // repository root meant `import sheet` failed and the whole
            // conformance probe reported nothing.
            let work = Self.pythonRoot(in: workRoot, fileManager: fileManager)
            if work != workRoot {
                report += "Python project: \(Self.relativePath(work, under: workRoot))\n"
            }
            let runner = CodingShadowRunner(work: work, isolatedHome: preparation.appendingPathComponent("home"),
                temporary: preparation.appendingPathComponent("tmp"), networkEnabled: true)
            var setupCommand = "python3 -m venv .venv"
            // `requirements-dev.txt` is what this project actually ships, and
            // only `requirements.txt` was looked for.
            for name in ["requirements.txt", "requirements-dev.txt"]
            where fileManager.fileExists(atPath: work.appendingPathComponent(name).path) {
                setupCommand += " && .venv/bin/python -m pip install -r \(name)"
            }
            if fileManager.fileExists(atPath: work.appendingPathComponent("pyproject.toml").path)
                || fileManager.fileExists(atPath: work.appendingPathComponent("setup.py").path) {
                setupCommand += " && .venv/bin/python -m pip install -e ."
            }
            let setup = await runner.run(plan: .init(displayedCommand: setupCommand), evidenceRevision: manifest.revision)
            report += "Dependency setup [\(setup.lifecycle.rawValue)]:\n\(setup.outputSummary)\n"
            // Every documented fact in the published spec, checked against the
            // installed libraries. It used to sample six expressions and print
            // whatever came back, which recorded what the library does but not
            // whether that is what the spec says — and the differences are the
            // only rows worth a model's attention on Monday morning.
            let probeFile = work.appendingPathComponent(".wave-interface-probe.py")
            // Written into the Python root and run with that as the working
            // directory, so `sys.path[0]` is the package's parent and
            // `import sheet` resolves the way it does for the candidate.
            try Data(WaveSpecConformance.probeScript().utf8).write(to: probeFile, options: .atomic)
            let probeRun = await runner.run(
                plan: .init(displayedCommand: ".venv/bin/python .wave-interface-probe.py"),
                evidenceRevision: manifest.revision)
            report += "Conformance probe [\(probeRun.lifecycle.rawValue)]\n"
            var conformance = ""
            // Truncated output is not partial evidence: the JSON is unparseable
            // and half a probe would read as a wall of differences that are
            // really just missing rows.
            if probeRun.lifecycle == .passed, !probeRun.outputTruncated,
               let json = Self.jsonObject(in: probeRun.outputSummary) {
                let outcome = WaveSpecConformance.result(fromProbeJSON: json)
                conformance = WaveSpecConformance.report(outcome)
                let differing = WaveSpecConformance.differences(outcome.rows).count
                if !outcome.missingModules.isEmpty {
                    report += "Not installed: "
                        + outcome.missingModules.keys.sorted().joined(separator: ", ")
                        + ". Add the supplied files to the project and Prepare again.\n"
                }
                report += differing == 0
                    ? "Every fact that could be checked holds on the installed libraries.\n"
                    : "\(differing) documented fact(s) differ; see the conformance report.\n"
            } else {
                conformance = "# Library conformance\n\nThe probe did not run, so no "
                    + "published fact is confirmed. Treat every signature in `spec.md` as "
                    + "unverified until Prepare succeeds.\n\n```\n"
                    + probeRun.outputSummary + "\n```\n"
                report += "Unresolved: supplied APIs are not confirmed. Add the supplied files to the project and Prepare again.\n"
            }
            report += probeRun.outputSummary + "\n"
            try Data(conformance.utf8).write(to: space.contextURL.appendingPathComponent("library-probe.md"), options: .atomic)
            // A map of the candidate's own code, read from the tree rather than
            // written by hand. The pack's baseline describes the *published*
            // part 1; this project's real structure differs, and rediscovering
            // it live costs interview minutes.
            let map = Self.projectMap(root: work, workRoot: workRoot, fileManager: fileManager)
            try Data(map.utf8).write(to: space.contextURL.appendingPathComponent("project-map.md"), options: .atomic)
            try Data(report.utf8).write(to: preparation.appendingPathComponent("preparation-report.txt"), options: .atomic)
            preparedContexts[source.resolvingSymlinksInPath().path] = space.contextURL
            return .init(preflight: preflight, revision: manifest.revision, report: report)
        } catch { return .init(failure: error.localizedDescription) }
    }

    /// The candidate's own code, as the model should find it.
    ///
    /// Generated, so it cannot drift the way a hand-written baseline did: every
    /// module with its public names, and the private helpers, which are the
    /// ones a step has to name to be actionable. Signatures only — never a
    /// body, because the pack forbids retrieving part-2 solutions and this runs
    /// against a tree that may already contain some.
    static func projectMap(root: URL, workRoot: URL, fileManager: FileManager = .default) -> String {
        var out = "# This project, as it actually is\n\n"
        if root != workRoot {
            out += "Python package root: `\(relativePath(root, under: workRoot))`.\n\n"
        }
        let files = ((try? fileManager.contentsOfDirectory(atPath: root.appendingPathComponent("sheet").path)) ?? [])
            .filter { $0.hasSuffix(".py") }.sorted()
        guard !files.isEmpty else { return out + "No `sheet` package found.\n" }
        for name in files {
            let url = root.appendingPathComponent("sheet/" + name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var definitions: [String] = []
            var exports: String?
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("__all__") { exports = trimmed }
                guard trimmed.hasPrefix("def ") || trimmed.hasPrefix("class ") else { continue }
                // Keep the signature, drop the body and the trailing colon.
                let signature = trimmed
                    .replacingOccurrences(of: ":", with: "", options: [], range: trimmed.range(of: ":", options: .backwards))
                let indented = line.hasPrefix(" ") || line.hasPrefix("\t")
                definitions.append((indented ? "  " : "") + signature)
            }
            out += "## `sheet/\(name)`\n\n"
            if let exports { out += "`\(exports)`\n\n" }
            if definitions.isEmpty {
                out += "No definitions.\n\n"
            } else {
                out += "```python\n" + definitions.joined(separator: "\n") + "\n```\n\n"
            }
        }
        out += "Private names are the ones a step must name to be actionable — "
        out += "an explanation about \"the evaluator\" is half an answer.\n"
        return out
    }

    /// Where the Python package actually lives inside a copied tree.
    ///
    /// The root first, then one level down — deep enough for the common
    /// `repo/python/` layout, shallow enough that it cannot wander. A directory
    /// counts when it holds an importable package or the files that build one.
    static func pythonRoot(in root: URL, fileManager: FileManager = .default) -> URL {
        func isProject(_ url: URL) -> Bool {
            if fileManager.fileExists(atPath: url.appendingPathComponent("sheet/__init__.py").path) {
                return true
            }
            return ["pyproject.toml", "setup.py", "requirements.txt", "requirements-dev.txt"]
                .contains { fileManager.fileExists(atPath: url.appendingPathComponent($0).path) }
        }
        if isProject(root) { return root }
        // Names, then built back onto the caller's own root. Enumerated URLs come
        // back symlink-resolved (`/var` becomes `/private/var`), and handing one
        // of those back would make the returned path stop being a child of what
        // was passed in — which `relativePath` below then cannot describe.
        let names = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        // Sorted so the choice is the same on every run rather than whatever
        // order the filesystem happened to hand back.
        for name in names.sorted() where !name.hasPrefix(".") {
            let child = root.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: child.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            if isProject(child) { return child }
        }
        return root
    }

    static func relativePath(_ url: URL, under root: URL) -> String {
        let base = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(base + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(base.count + 1))
    }

    /// The probe prints one JSON object; the runner hands back a summary that
    /// may have command echo or warnings around it. Taking the outermost braces
    /// is enough, and is why the script prints nothing else on success.
    static func jsonObject(in output: String) -> Data? {
        guard let start = output.firstIndex(of: "{"),
              let end = output.lastIndex(of: "}"), start < end else { return nil }
        return String(output[start...end]).data(using: .utf8)
    }

    func registerFolder(bookmark: Data) async throws -> CodingFolderPreflight {
        let source = try CodingFolderBookmark.resolve(bookmark).url
            .resolvingSymlinksInPath().standardizedFileURL
        let accessing = source.startAccessingSecurityScopedResource()
        guard accessing || fileManager.isReadableFile(atPath: source.path) else {
            throw CodingSessionCoreFailure.sourceUnavailable
        }
        let manifest = try CodingShadowProject.inspect(source: source, fileManager: fileManager)
        let id = "folder-\(UUID().uuidString.lowercased())"
        let git = Self.gitFacts(at: source)
        let preflight = CodingFolderPreflight(
            capabilityID: id, folderName: source.lastPathComponent,
            branch: git.branch, dirty: git.dirty,
            languages: CodingShadowProject.detectedLanguages(manifest),
            suggestedCommands: CodingShadowProject.suggestedCommands(manifest),
            snapshotBytes: manifest.totalBytes, fileCount: manifest.entries.filter { $0.kind == "file" }.count,
            withheldPaths: Array(manifest.withheld.prefix(200)),
            externalSymlinks: Array(manifest.externalSymlinks.prefix(200)),
            folderReadable: true, shadowReady: true,
            agyAuthenticated: AgyLocator.hasCredentials())
        capabilities[id] = Capability(source: source, bookmark: bookmark,
                                      accessing: accessing, preflight: preflight)
        return preflight
    }

    func start(_ proposed: CodingSessionConfiguration) async throws -> CodingSessionSnapshot {
        try LiveCodingValidation.validate(proposed)
        guard configuration == nil else {
            throw CodingSessionCoreFailure.commandDenied("another Code interview is active")
        }
        guard let capability = capabilities[proposed.folderCapabilityID] else {
            throw CodingSessionCoreFailure.sourceUnavailable
        }
        configuration = proposed
        defer {
            if status.lifecycle == .preparing {
                configuration = nil; status.lifecycle = .failed
            }
        }
        startedAt = Date()
        events.removeAll(keepingCapacity: true); nextSequence = 0
        let sessionRoot = root.appendingPathComponent("active/\(proposed.sessionID)", isDirectory: true)
        let mirror = sessionRoot.appendingPathComponent("mirror", isDirectory: true)
        let work = sessionRoot.appendingPathComponent("work", isDirectory: true)
        try fileManager.createDirectory(at: sessionRoot, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        status = CodingSessionSnapshot(
            sessionID: proposed.sessionID, callID: proposed.callID, generation: proposed.generation,
            lifecycle: .preparing, syncState: .preparing, provider: proposed.provider, model: proposed.model)
        emit(kind: .lifecycle, lifecycle: .preparing)
        let manifest = try CodingShadowProject.prepare(
            source: capability.source, mirror: mirror, work: work, fileManager: fileManager)

        // The twin's context is a directory, not a prompt. Seeded once here,
        // refreshed as facts change, and read by the agent's own tools.
        let space = CodingWorkspace(root: sessionRoot)
        workspace = space
        try fileManager.copyItem(at: mirror, to: sessionRoot.appendingPathComponent("baseline"))
        status.interviewFlow = CodingInterviewFlowState(sessionID: proposed.sessionID,
            generation: proposed.generation, sourceRevision: manifest.revision)
        status.interviewFlow?.brief = proposed.brief
        status.interviewFlow?.pending = [.init(id: "basic", text: proposed.brief?.title ?? "Agreed basic behavior", stage: .simple)]
        preparedSteps = []; heldMove = nil; spokenQuestionIDs = [:]; dialogueAnchor = nil
        segmenter = StatementSegmenter(rules: .coding)
        phaseMachine = CodingPhaseMachine()
        rubric = CodingRubricTracker(brief: proposed.brief)
        ledger = CodingLedger()
        guidanceQueue.reset(); guidanceID = nil
        transcriptSequence = -1
        lastVerdict = nil; lastCommand = nil; addedLines = 0; lastSaveAt = nil
        // Same persona the preparation workspace and the worker pool seed. It
        // was "generic" here and "interview" in both of those, so the session
        // the candidate reads and the proposals behind it were written to
        // different guidance.
        try space.seed(brief: proposed.brief, persona: CodingSessionController.persona,
                       pack: promptPack, readOnly: true)
        if proposed.interviewProfile == WaveInterviewProfile.wave {
            try space.seedWaveContext()
            if let prepared = preparedContexts[capability.source.resolvingSymlinksInPath().path],
               let report = try? Data(contentsOf: prepared.appendingPathComponent("library-probe.md")) {
                try report.write(to: space.contextURL.appendingPathComponent("library-probe.md"), options: .atomic)
            }
        }
        try space.write(rubric: rubric.states)
        try space.write(ledger: ledger)
        try space.write(diff: "")

        prewarmDialogue(sessionID: proposed.sessionID, brief: proposed.brief)
        let firstPlan = capability.preflight.suggestedCommands.first
        let move = CodingMove(
            ordinal: 1, sourceRevision: manifest.revision, kind: .design,
            say: "I’ll confirm the requested behavior, then implement the smallest vertical slice.",
            why: "Keep the interface simple, preserve momentum, and verify each slice before expanding it.",
            check: firstPlan,
            watch: manifest.externalSymlinks.isEmpty ? nil : "External symlinks were withheld from the shadow project.")
        status.interviewProfile = proposed.interviewProfile
        status.observationTarget = proposed.observationTarget
        if proposed.interviewProfile == WaveInterviewProfile.wave {
            status.wave = WaveInterviewState(sessionID: proposed.sessionID, sourceRevision: manifest.revision)
            let wavePending: [CodingPendingWork] = status.wave?.tasks.map {
                .init(id: $0.id, text: $0.title, stage: ["dates", "sqrt"].contains($0.id) ? .hardening : .simple,
                      required: !["dates", "sqrt"].contains($0.id))
            } ?? []
            status.interviewFlow?.pending = wavePending
        }
        status.lifecycle = .ready; status.syncState = .current
        status.activity = .listening
        status.sourceRevision = manifest.revision; status.workRevision = manifest.revision
        status.activeMove = move; status.pendingRun = firstPlan
        emit(kind: .sourceRevision, sourceRevision: manifest.revision)
        emit(kind: .move, move: move)
        emit(kind: .lifecycle, lifecycle: .ready)
        persistActiveState(sessionRoot: sessionRoot)
        beginWatching(source: capability.source, mirror: mirror, work: work,
                      knownRevision: manifest.revision)
        beginTicking()
        scheduleWaveSteps()
        beginEditorObservation()
        return status
    }

    func snapshot() -> CodingSessionSnapshot { status }
    func flushCompletedSpeechForValidation(now: Double) async {
        for statement in segmenter.tick(now: now) { await consider(statement) }
    }
    func acceptPreparedForValidation(_ draft: CodingMoveDraft, pendingID: String = "basic") {
        guard let revision = preparationRevision, let workspace else { return }
        let result = WaveWorkerPool.Result(job: .init(role: .coder, revision: revision, proposalDirectory: workspace.workURL.path),
                                           draft: draft, work: workspace.workURL)
        acceptPreparedStep(result, pendingID: pendingID, stage: status.interviewFlow?.nextStage ?? .simple)
    }
    func observeSavedSourceForValidation() {
        guard let configuration, let source = capabilities[configuration.folderCapabilityID]?.source,
              let manifest = try? CodingShadowProject.inspect(source: source) else { return }
        let active = root.appendingPathComponent("active/\(configuration.sessionID)")
        sourceChanged(manifest, source: source, mirror: active.appendingPathComponent("mirror"), work: active.appendingPathComponent("work"))
    }

    func markCapturing() {
        guard status.lifecycle == .ready else { return }
        status.lifecycle = .capturing
        emit(kind: .lifecycle, lifecycle: .capturing)
    }

    func reconcileCall(_ call: CallLifecycleSnapshot) async {
        switch CodingCallReconciliation.action(coding: status, call: call) {
        case .capturing: markCapturing()
        case .finished: await end(interrupted: false)
        case .interrupted: await end(interrupted: true, detail: call.actionableError ?? "Call capture was interrupted.")
        case .none: break
        }
    }

    func finishAfterCall(interrupted: Bool) async {
        guard status.lifecycle.active else { return }
        await end(interrupted: interrupted)
    }

    func interruptIfStillAwaitingCall(sessionID: String, generation: Int) async {
        guard status.sessionID == sessionID, status.generation == generation,
              status.lifecycle == .ready else { return }
        await end(interrupted: true, detail: "Call capture did not start. The coding session was saved for recovery.")
    }

    func replay(since sequence: Int) -> [CodingEvent] {
        Array(events.filter { $0.sequence > sequence }.suffix(LiveCodingContract.maximumEvents))
    }

    func retainedSessions() -> [CodingRetainedSession] {
        var values = vault.records().map {
            CodingRetainedSession(sessionID: $0.configuration.sessionID,
                                  folderName: $0.preflight.folderName,
                                  lifecycle: $0.snapshot.lifecycle,
                                  startedAt: $0.startedAt, endedAt: $0.endedAt,
                                  moveCount: $0.events.compactMap(\.move).count)
        }
        if let configuration, status.lifecycle.active {
            values.append(.init(sessionID: configuration.sessionID,
                                folderName: capabilities[configuration.folderCapabilityID]?.preflight.folderName ?? "Project",
                                lifecycle: status.lifecycle, startedAt: startedAt,
                                moveCount: events.compactMap(\.move).count))
        }
        return values.sorted { $0.startedAt > $1.startedAt }
    }

    func send(_ command: CodingCommand) async throws -> CodingSessionSnapshot {
        if command.kind == .resume, configuration == nil {
            return try resume(command)
        }
        if command.kind == .delete, configuration?.sessionID != command.sessionID {
            try vault.delete(sessionID: command.sessionID)
            return status
        }
        try LiveCodingValidation.validate(command, against: status)
        switch command.kind {
        case .selectWindow:
            guard status.lifecycle.active, configuration != nil else {
                throw CodingSessionCoreFailure.commandDenied("start or resume the session before changing its window")
            }
            if let target = command.observationTarget {
                guard target.processID > 0, target.windowID > 0,
                      ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"].contains(target.bundleID) else {
                    throw CodingSessionCoreFailure.commandDenied("select a valid VS Code window")
                }
            }
            configuration?.observationTarget = command.observationTarget
            status.observationTarget = command.observationTarget
            if let workspace { try? fileManager.removeItem(at: workspace.contextURL.appendingPathComponent("editor-observation.md")) }
            beginEditorObservation()
            persistActiveLedger()
        case .waveQuestion:
            if let questionID = command.questionID { _ = status.wave?.dispatchQuestion(id: questionID) }
            persistActiveLedger()
        case .waveHold:
            status.interviewFlow?.held = true
            status.wave?.held = true; persistActiveLedger()
        case .waveResume:
            status.interviewFlow?.held = false
            status.wave?.held = false; status.wave?.unread = 0
            if let heldMove { self.heldMove = nil; supersedeActive(with: heldMove) }
            publishPreparedIfAuthorized(); persistActiveLedger()
        case .waveContinue:
            // Continue is a user decision, so it moves the ladder cursor as
            // well as authorizing the next stage. It only authorized before,
            // which left `currentTaskID` pinned to the first task for the whole
            // session — so the step the panel named and the task the ladder
            // thought it was on disagreed, and nothing was ever marked done.
            status.wave?.advance(explicit: true)
            if var flow = status.interviewFlow {
                if CodingInterviewFlow.authorize(flow.nextStage, state: &flow) {
                    status.interviewFlow = flow
                    publishFlowPointer(); publishPreparedIfAuthorized()
                } else { status.interviewFlow = flow; persistActiveLedger() }
            }
        case .waveReturn:
            status.interviewFlow?.foregroundQuestionID = nil
            status.wave?.returnToCoding(); persistActiveLedger()
        case .armSpokenQuestion:
            status.interviewFlow?.spokenQuestionArmed.toggle()
            persistActiveLedger()
        case .explainDisplayed:
            let text = command.transcript ?? status.activeMove?.say ?? "the current reasoning step"
            await routeQuestion("Explain this displayed item in words: " + String(text.prefix(900)), anchor: nil)
        case .runPending:
            try await beginPendingRun()
        case .cancelRun:
            await cancelRun()
        case .requestMove:
            await ingest(command)
        case .end:
            if configuration == nil {
                // Closing an already archived attempt dismisses its presentation;
                // its interrupted history record remains intact.
                status = CodingSessionSnapshot(); events.removeAll(); nextSequence = 0
            } else { await end(interrupted: false) }
        case .delete:
            await delete(sessionID: command.sessionID)
        case .resume, .start:
            throw CodingSessionCoreFailure.commandDenied("use the dedicated start or resume operation")
        }
        return status
    }

    func shutdown() async { await end(interrupted: status.lifecycle.active) }

    /// One transcript turn in.
    ///
    /// Turns are not thoughts. They used to become one model request each —
    /// including the interviewer saying "mm-hmm" — so the lane was busy
    /// chasing fragments whenever a real question arrived. Now a turn feeds the
    /// segmenter, only a completed statement can cost anything, and an utterance
    /// that is nothing but acknowledgement costs nothing even then.
    private func ingest(_ command: CodingCommand) async {
        guard let text = command.transcript, let speaker = command.speaker else { return }
        if let sequence = command.transcriptSequence {
            guard sequence > transcriptSequence else { return }
            transcriptSequence = sequence
        } else {
            transcriptSequence += 1
        }

        // Execution cues are still judged on the raw turn: "let me run that" is
        // an instruction about right now, and waiting for a statement boundary
        // would answer it after the moment.
        let cue = status.interviewFlow?.spokenQuestionArmed == true ? CodingCueDecision.steer : CodingCueClassifier.classify(
            text: text, speaker: speaker, confidence: command.confidence ?? 0,
            hasPendingRun: status.pendingRun != nil, runActive: activeRun != nil)
        switch cue {
        case .run: try? await beginPendingRun(); return
        case .cancel: await cancelRun(); return
        case .illuminateRun:
            status.failure = CodingFailure(code: "cue_needs_confirmation",
                                           message: "Run cue was uncertain.",
                                           recovery: "Press Run to execute the pending check.")
            return
        case .ignore: return
        case .steer: break
        }

        // A turn heard poorly is marked rather than dropped: dropping it would
        // make the segmenter think the room went quiet.
        let confident = (command.confidence ?? 1) >= 0.5
        let turn = TranscriptTurn(
            seq: transcriptSequence, speaker: speaker == .me ? .local : .remote,
            start: command.t0 ?? Date().timeIntervalSince(startedAt),
            end: command.t1 ?? Date().timeIntervalSince(startedAt),
            text: confident ? text : text + " [unclear]")

        // One ingest. This read the turn twice for a while — the statements the
        // first call returned were dropped on the floor and the same turn was
        // fed in again, which is why nothing ever reached the panel.
        let statements = segmenter.ingest(turn)
        transcriptClock = max(transcriptClock, turn.end)
        transcriptClockSetAt = Date()
        if statements.isEmpty, guidanceTask == nil { setActivity(.listening, "hearing you out") }
        for statement in statements { await consider(statement) }
    }

    /// Flush a statement the candidate stopped mid-thought.
    ///
    /// The segmenter only emits on `ingest` or on a tick, so without a clock
    /// driving it the last thing said before a silence sits in the buffer for
    /// ever — which is exactly the case that matters, because a candidate who
    /// has stopped talking is the one waiting for a move.
    private func tickSegmenter() async {
        guard status.lifecycle.active else { return }
        for statement in segmenter.tick(now: transcriptNow()) {
            await consider(statement)
        }
    }

    /// "Now" on the transcript's own clock.
    ///
    /// Turn timings are relative to the call, not to this session, so wall time
    /// cannot be used directly — it would be offset by however long the shadow
    /// took to build. Advancing the last turn's end by real elapsed time keeps
    /// the two in step whatever the offset.
    private func transcriptNow() -> Double {
        transcriptClock + Date().timeIntervalSince(transcriptClockSetAt)
    }

    /// One completed statement. Decide, then act.
    private func consider(_ statement: Statement) async {
        ledger.append(statement)
        if statement.speaker == .local {
            rubric.noteSpoken(statement.text)
        }
        refreshFacts()

        guard var flow = status.interviewFlow else { return }
        let previousAuthorization = flow.authorizedStage
        CodingInterviewFlow.record(statement, in: &flow)
        if statement.speaker == .remote, !statement.truncated, !statement.text.contains("[unclear]"),
           let signal = CodingInterviewerSignal.detect(statement.text), signal != .hint {
            flow.taskRevision += 1; flow.authorizedStage = nil
            flow.stage = .reasoning
            // A new task is about somewhere else until the lane says otherwise.
            dialogueAnchor = nil
            preparedSteps = []; wavePreparationTask?.cancel()
        }
        status.interviewFlow = flow
        if statement.truncated || statement.text.contains("[unclear]") {
            persistActiveLedger(); return
        }
        if flow.spokenQuestionArmed, statement.speaker == .local {
            status.interviewFlow?.spokenQuestionArmed = false
            await routeQuestion(statement.text, anchor: CodingInterviewFlow.evidence(statement))
            return
        }
        if previousAuthorization != flow.authorizedStage {
            publishFlowPointer(); publishPreparedIfAuthorized()
        }
        if statement.speaker == .remote, flow.clarification == nil, statement.invitesAnAnswer {
            await routeQuestion(statement.text, anchor: CodingInterviewFlow.evidence(statement))
        }
        // Every completed utterance reaches the dialogue lane before narration
        // suppression, because narration is where reasoning credit comes from.
        // The one exception is an utterance that carries no idea at all: the
        // lane is serial, so "yeah, okay" costs a whole model turn and the
        // question behind it waits for it. A bare yes or no while a
        // clarification is open is an *answer*, not back-channel, so the
        // exception does not apply there.
        if flow.clarification == nil,
           CodingDialogueAdmission.isAcknowledgement(statement.text) {
            try? workspace?.write(ledger: ledger); persistActiveLedger(); return
        }
        switch guidanceQueue.enqueue(statement, context: ledger.tail,
                                     priority: Self.dialoguePriority(for: statement)) {
        case .accepted: startGuidanceIfNeeded()
        case .duplicate: break
        case .full:
            status.interviewFlow?.retry = "Several points are waiting. Please repeat the last one shortly."
            status.failure = CodingFailure(code: "coding_queue_full", message: "The conversation queue is full.",
                                           recovery: status.interviewFlow?.retry)
            emit(kind: .failure, failure: status.failure)
        }
        try? workspace?.write(ledger: ledger); persistActiveLedger()
    }

    /// How far up the queue this utterance goes.
    ///
    /// The interviewer asking or directing is the one input wanted *now*, and it
    /// is exactly the case `CodingDirector` already labels `.urgent`. Candidate
    /// narration stays advisory: it is worth interpreting, never worth making a
    /// question wait.
    static func dialoguePriority(for statement: Statement) -> CodingMovePriority {
        guard statement.speaker == .remote else { return .advisory }
        if CodingInterviewerSignal.detect(statement.text) != nil { return .urgent }
        if CodingIntentClassifier.classify(statement.text) != .none { return .urgent }
        return statement.invitesAnAnswer ? .urgent : .advisory
    }

    private func routeQuestion(_ text: String, anchor: CodingDialogueEvidence?) async {
        guard let configuration, let flow = status.interviewFlow else { return }
        let key = anchor.map { "\($0.anchor.fromSequence):\($0.anchor.toSequence):\($0.speaker.rawValue)" } ?? UUID().uuidString
        let id = spokenQuestionIDs[key] ?? UUID()
        if flow.questionOwners[id.uuidString] != nil { return }
        spokenQuestionIDs[key] = id
        writeWaveCallContext()
        let accepted = await askCall(configuration.callID, configuration.generation, id, String(text.prefix(1200)), anchor)
        guard self.configuration?.sessionID == configuration.sessionID,
              self.configuration?.generation == configuration.generation,
              status.interviewFlow?.requirementRevision == flow.requirementRevision,
              status.lifecycle.active else { return }
        if accepted {
            status.interviewFlow?.questionOwners[id.uuidString] = "call"
            status.interviewFlow?.foregroundQuestionID = id.uuidString
            _ = status.wave?.dispatchQuestion(id: id.uuidString)
        } else {
            status.interviewFlow?.retry = "Your question was not queued. Press Ask and repeat it."
            status.failure = CodingFailure(code: "coding_question_not_queued", message: "Call could not accept the question.", recovery: status.interviewFlow?.retry)
        }
        persistActiveLedger()
    }

    private func beginEditorObservation() {
        observationTask?.cancel()
        guard let target = configuration?.observationTarget, let executable = hostExecutable(),
              ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"].contains(target.bundleID) else { return }
        observationTask = Task { [weak self] in
            var sequence = 0
            while !Task.isCancelled {
                sequence += 1
                do {
                    let data = try await QuizHostRunner.run(executable: executable,
                        arguments: ["quiz-capture", "--generation", "\(sequence)", "--detail", "probe"],
                        input: try JSONEncoder().encode(target), timeout: 15)
                    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                    let frame = try decoder.decode(QuizHostFrame.self, from: data)
                    guard frame.isBounded, frame.target.id == target.id else { throw CodingSessionCoreFailure.sourceUnavailable }
                    await self?.recordWindowObservation(frame.normalizedOCR, target: target)
                } catch {
                    await self?.windowObservationFailed(target: target)
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
    private func recordWindowObservation(_ text: String, target: QuizWindowTarget) {
        guard status.lifecycle.active, configuration?.observationTarget == target else { return }
        if let wave = status.wave {
            status.wave?.observe(.init(taskID: wave.currentTaskID, revision: wave.revision,
                kind: .editor, detail: String(text.prefix(3000)), succeeded: false, shadow: false))
        }
        let content = "Selected VS Code window observation; may include unsaved code. Not saved or checked evidence.\n" + String(text.prefix(6000))
        if let workspace { try? Data(content.utf8).write(to: workspace.contextURL.appendingPathComponent("editor-observation.md"), options: .atomic) }
    }
    private func windowObservationFailed(target: QuizWindowTarget) {
        guard status.lifecycle.active, configuration?.observationTarget == target else { return }
        setActivity(.listening, "Selected editor window unavailable; reselect it in the session setup. Call and saved-file observation continue")
    }

    private var preparationRevision: WaveRevision? {
        guard let flow = status.interviewFlow else { return nil }
        return WaveRevision(session: "\(flow.sessionID):\(flow.generation)", source: flow.sourceRevision,
                            requirements: flow.requirementRevision, proposal: flow.taskRevision)
    }

    /// What a preparation run is *for*: the stage, the behaviours authorised
    /// within it, and the outstanding work list. Not the source revision — the
    /// coders start from a fresh copy of the tree either way, so a save that
    /// leaves this identical would produce the same three edits.
    private func preparationFingerprint() -> String? {
        guard let flow = status.interviewFlow else { return nil }
        let stage = (flow.authorizedStage ?? flow.nextStage).rawValue
        let authorized = (flow.authorizedPendingIDs ?? []).sorted().joined(separator: ",")
        let outstanding = flow.pending
            .filter { $0.completedEvidence == nil }
            .map { "\($0.id):\($0.stage.rawValue)" }
            .sorted().joined(separator: ",")
        return "\(stage)|\(authorized)|\(outstanding)"
    }

    /// Re-prepare only when the work changed, and only once typing settles.
    ///
    /// `scheduleWaveSteps` cancels the pool, copies the whole tree again for
    /// every job and respawns a planner plus up to three coders serially. Firing
    /// it on each save meant the prepared step never finished during ordinary
    /// typing: every ⌘S threw away the run that was nearly done. The debounce is
    /// what lets one of them reach the panel.
    private func schedulePreparationDebounced() {
        guard preparesInBackground else { return }
        guard let fingerprint = preparationFingerprint() else { return }
        guard fingerprint != lastPreparationFingerprint else { return }
        preparationDebounce?.cancel()
        preparationDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1_500))
            guard !Task.isCancelled else { return }
            await self?.commitPreparation(fingerprint)
        }
    }

    private func commitPreparation(_ fingerprint: String) {
        guard status.lifecycle.active, preparationFingerprint() == fingerprint else { return }
        scheduleWaveSteps()
    }

    /// The same private planning/edit machinery serves both Code profiles.
    private func scheduleWaveSteps() {
        guard preparesInBackground, let configuration, let flow = status.interviewFlow,
              let revision = preparationRevision, let workspace else { return }
        lastPreparationFingerprint = preparationFingerprint()
        wavePreparationTask?.cancel(); preparedSteps = []
        let oldPool = waveWorkers
        let pool = WaveWorkerPool(root: root.appendingPathComponent("active/\(configuration.sessionID)/proposals"))
        waveWorkers = pool
        let source = root.appendingPathComponent("active/\(configuration.sessionID)/mirror")
        let stage = flow.authorizedStage ?? flow.nextStage
        let tasks = Array(flow.pending.filter { $0.completedEvidence == nil && $0.stage == stage }.prefix(3))
        guard !tasks.isEmpty else { return }
        let context = String(decoding: (try? JSONEncoder().encode(flow)) ?? Data(), as: UTF8.self)
        // The pack asks for simulated evidence to be labelled rehearsal. It can
        // only do that if it is told which run this is.
        let run = isRehearsal
            ? "This is a rehearsal, not the interview. Label simulated or stand-in evidence as rehearsal. "
            : ""
        wavePreparationTask = Task { [weak self] in
            await oldPool?.cancel()
            do {
                let plan = try await pool.respond(role: .planner, revision: revision, source: source,
                    context: workspace.contextURL, selection: configuration.profile.plan,
                    prompt: "Plan up to three complete small edits for these pending behaviors: \(tasks.map { $0.text + Self.acceptanceSuffix(forPendingID: $0.id) }.joined(separator: "; ")). Start with the simplest correct approach, never an artificial inefficient version or TODO-only step. Assumptions stay explicit. Words only. Interview state: " + context)
                var base = source
                for task in tasks {
                    try Task.checkCancellation()
                    let result = try await pool.respond(role: .coder, revision: revision, source: base,
                        context: workspace.contextURL, selection: configuration.profile.edit,
                        prompt: "\(run)Prepare only this behavior in stage \(stage.rawValue): \(task.text). Plan: \(plan.draft.say ?? ""). \(Self.acceptance(forPendingID: task.id))Make one complete edit in work only, maximum 20 added lines. File and symbol required; name the symbol in the reasoning, not the path or line. Describe exact placement and why before code. Return a complete code block, no truncation, no future behaviors. You have no shell and no command tool: a check is text you propose for the engine to run later, so never call one and never wait on a result. State: " + context)
                    base = result.work
                    await self?.acceptPreparedStep(result, pendingID: task.id, stage: stage)
                }
            } catch {
                guard !Task.isCancelled else { return }
                await self?.preparationFailed(error.localizedDescription, revision: revision)
            }
        }
    }
    /// What the published spec says one task has to handle.
    ///
    /// Keyed on the pending item's own id, which is the ladder id verbatim.
    /// This used to read `status.wave?.currentTask?.checks` — the *cursor's*
    /// task — while the loop around it coded a different one, so the coder was
    /// told "Prepare only this behavior: sum" with the cell-reference checks
    /// pasted after it. `currentTaskID` never moves during a session, so it was
    /// always the first task's list.
    static func checks(forPendingID id: String) -> [String] {
        WaveInterviewState.ladder.first { $0.id == id }?.checks ?? []
    }

    /// The checks as a sentence for the coder, or nothing.
    static func acceptance(forPendingID id: String) -> String {
        let checks = checks(forPendingID: id)
        return checks.isEmpty ? "" : "It must handle: " + checks.joined(separator: "; ") + ". "
    }

    /// The checks as a parenthetical, for a list of several behaviours.
    static func acceptanceSuffix(forPendingID id: String) -> String {
        let checks = checks(forPendingID: id)
        return checks.isEmpty ? "" : " (must handle: " + checks.joined(separator: "; ") + ")"
    }

    private func acceptPreparedStep(_ result: WaveWorkerPool.Result, pendingID: String, stage: CodingInterviewStage) {
        guard status.lifecycle.active, preparationRevision == result.job.revision,
              let file = result.draft.file, (try? LiveCodingValidation.validate(relativePath: file.path)) != nil,
              let code = result.draft.code, !code.isEmpty,
              code.split(separator: "\n").count <= 28,
              code.utf8.count <= LiveCodingContract.maximumTextBytes else { return }
        var move = CodingMove(ordinal: (events.compactMap(\.move).map(\.ordinal).max() ?? 0) + preparedSteps.count + 1,
            sourceRevision: result.job.revision.source, kind: .edit, say: result.draft.say,
            file: file, code: code, why: result.draft.why, check: result.draft.check, watch: result.draft.watch)
        move.implementationStage = stage; move.pendingWorkID = pendingID
        preparedSteps.append(.init(pendingID: pendingID, revision: result.job.revision, move: move, work: result.work))
        publishPreparedIfAuthorized()
    }
    private func publishPreparedIfAuthorized() {
        guard let flow = status.interviewFlow, !flow.held, flow.foregroundQuestionID == nil,
              let step = preparedSteps.first(where: { item in
                  item.revision == preparationRevision && flow.pending.contains { $0.id == item.pendingID && $0.completedEvidence == nil && flow.authorizedPendingIDs?.contains($0.id) == true }
              }), CodingInterviewPublication.permitsCode(step.move.implementationStage, flow: flow),
              status.activeMove?.id != step.move.id else { return }
        waveProposalPaths[step.move.id] = step.work
        supersedeActive(with: step.move); status.pendingRun = step.move.check
    }
    private func preparationFailed(_ message: String, revision: WaveRevision) {
        guard preparationRevision == revision else { return }
        status.failure = CodingFailure(code: "coding_preparation_failed", message: message,
                                       recovery: "Continue speaking or save to retry preparation.")
        emit(kind: .failure, failure: status.failure)
    }
    private func publishFlowPointer() {
        guard let flow = status.interviewFlow else { return }
        let say = flow.retry ?? flow.clarification?.question ?? flow.pointers.first ?? flow.sayNext
        let move = CodingMove(ordinal: (status.activeMove?.ordinal ?? 0) + 1,
            sourceRevision: flow.sourceRevision, kind: .design, say: say,
            file: flow.retry == nil && flow.clarification == nil ? dialogueAnchor : nil,
            why: flow.pointers.dropFirst().joined(separator: "\n"), watch: flow.limitation,
            origin: .deterministic)
        supersedeActive(with: move)
        if flow.stage == .verification {
            status.pendingRun = configuration.flatMap { capabilities[$0.folderCapabilityID]?.preflight.suggestedCommands.first }
        }
    }
    private func startGuidanceIfNeeded() {
        guard guidanceTask == nil, !guidanceQueue.pending.isEmpty else { return }
        let id = UUID()
        guidanceID = id
        guidanceTask = Task { [weak self] in await self?.drainGuidance(id: id) }
    }

    private func drainGuidance(id: UUID) async {
        defer {
            if guidanceID == id { guidanceTask = nil; guidanceID = nil }
        }
        while !Task.isCancelled, guidanceID == id, status.lifecycle.active,
              let request = guidanceQueue.next() {
            let statement = request.statement
            // A queued question is evaluated against the current project state.
            refreshFacts()
            let increment: CodingIncrement = .sketch
            let intent: CodingIntent = .design
            let priority: CodingMovePriority = .advisory
            // No pointer is published here on purpose. Two rules already
            // written into this file rule it out: a failed turn must leave the
            // displayed card exactly as it was, and a new move must not reset a
            // reader mid-scroll. The pointers the flow holds are about the
            // *previous* utterance, so republishing them as a fresh move would
            // churn the card with stale content and break both. The activity
            // line is what says work is in flight.
            setActivity(.thinking, "Following the conversation")
            await produceGuidance(statement: statement, increment: increment,
                                  intent: intent, priority: priority, requestID: id,
                                  recentContext: request.context)
        }
    }

    /// Recompute every engine fact and write it where the twin can read it.
    private func refreshFacts() {
        guard let configuration, let workspace else { return }
        let sessionRoot = root.appendingPathComponent("active/\(configuration.sessionID)")
        let diff = Self.diff(mirror: sessionRoot.appendingPathComponent("baseline"),
                             work: sessionRoot.appendingPathComponent("mirror"))
        addedLines = CodingCadence.addedLines(in: diff)
        status.phase = status.interviewFlow?.phase ?? .understanding
        phaseMachine = CodingPhaseMachine(phase: status.phase)
        status.rubric = rubric.states
        status.remainingSeconds = remainingSeconds()

        try? workspace.write(diff: diff)
        try? workspace.write(rubric: rubric.states)
        try? workspace.write(ledger: ledger)
        try? workspace.write(state: workspaceState())
    }

    private func workspaceState() -> CodingWorkspace.State {
        CodingWorkspace.State(
            phase: phaseMachine.phase, increment: currentIncrement(),
            sourceRevision: status.sourceRevision ?? "unknown",
            syncState: status.syncState, remainingSeconds: remainingSeconds(),
            pendingCommand: status.pendingRun?.displayedCommand,
            lastVerdict: lastVerdict, addedLines: addedLines)
    }

    private func currentIncrement() -> CodingIncrement {
        switch status.interviewFlow?.stage {
        case .understanding: .clarify
        case .reasoning: .sketch
        case .simple: .fillOne
        case .hardening: .harden
        case .optimization: .optimise
        case .verification: .verify
        default: .narrate
        }
    }

    /// "flash-low · 2.4s" — which brain answered, and how long it took.
    private func attributionSummary() -> String? {
        guard let attribution = status.attribution else { return nil }
        let model = attribution.model.replacingOccurrences(of: "gemini-", with: "")
        return "\(model) · \(String(format: "%.1f", Double(attribution.latencyMilliseconds) / 1_000))s"
    }

    private func remainingSeconds() -> Int? {
        guard let minutes = configuration?.plannedDurationMinutes, minutes > 0 else { return nil }
        let spent = Date().timeIntervalSince(startedAt)
        return max(0, Int(Double(minutes) * 60 - spent))
    }

    private func elapsedFraction() -> Double? {
        guard let minutes = configuration?.plannedDurationMinutes, minutes > 0 else { return nil }
        return min(1, Date().timeIntervalSince(startedAt) / (Double(minutes) * 60))
    }

    /// Say what the session is doing, so a deliberately quiet twin does not
    /// look like a dead one.
    private func setActivity(_ activity: CodingActivity, _ detail: String? = nil) {
        guard status.activity != activity || status.activityDetail != detail else { return }
        status.activity = activity
        status.activityDetail = detail
    }

    private func beginPendingRun() async throws {
        guard activeRun == nil, var plan = status.pendingRun,
              let configuration else { return }
        guard status.wave == nil || status.activeMove?.sourceRevision == status.sourceRevision else {
            throw CodingSessionCoreFailure.commandDenied("The proposal is stale; wait for a step for the current saved code")
        }
        let sessionRoot = root.appendingPathComponent("active/\(configuration.sessionID)")
        let savedWork = sessionRoot.appendingPathComponent("saved-checks/" + UUID().uuidString + "/work")
        try fileManager.createDirectory(at: savedWork.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: sessionRoot.appendingPathComponent("mirror"), to: savedWork)
        let runner = CodingShadowRunner(
            work: savedWork,
            isolatedHome: sessionRoot.appendingPathComponent("home"),
            temporary: sessionRoot.appendingPathComponent("tmp"),
            networkEnabled: configuration.networkPolicy.commandsMayUseNetwork)
        activeRun = runner
        // Run where the package is. The model proposes a command and usually no
        // working directory, and this repository keeps its Python one level
        // down — so `python3 -c "from sheet.formula import parse"` at the copied
        // root fails with ModuleNotFoundError, every time. That made `.checked`
        // evidence unobtainable, which is the evidence advancement asks for.
        // "." is the default the contract ships, so both readings mean "unset".
        if plan.relativeCWD.isEmpty || plan.relativeCWD == "." {
            let pythonRoot = Self.pythonRoot(in: savedWork, fileManager: fileManager)
            if pythonRoot != savedWork {
                plan.relativeCWD = Self.relativePath(pythonRoot, under: savedWork)
            }
        }
        let revision = status.sourceRevision ?? "unknown"
        setActivity(.running, plan.displayedCommand)
        let running = CodingRun(id: plan.id, relativeCWD: plan.relativeCWD,
                                displayedCommand: plan.displayedCommand, lifecycle: .running,
                                evidenceRevision: revision, startedAt: Date())
        emit(kind: .run, run: running)
        let waveRevision = status.wave?.revision
        let taskID = status.wave?.currentTaskID
        let token = UUID(); activeRunToken = token
        runTask = Task { [weak self] in
            var result = await runner.run(plan: plan, evidenceRevision: revision)
            if (try? CodingShadowProject.inspect(source: savedWork).revision) != revision {
                result.lifecycle = .failed; result.exitCode = nil
                result.outputSummary += "\nCheck mutated the saved snapshot; completion is not established."
            }
            await self?.finishRun(result, token: token, waveRevision: waveRevision, taskID: taskID, expected: plan.expectedEvidence, savedCode: true)
        }
    }

    private func finishRun(_ run: CodingRun, token: UUID, waveRevision: WaveRevision? = nil, taskID: String? = nil,
                           expected: String? = nil, savedCode: Bool = false) {
        guard activeRunToken == token else { return }
        activeRun = nil; runTask = nil; activeRunToken = nil
        let actualSourceCurrent: Bool
        if savedCode, let configuration, let source = capabilities[configuration.folderCapabilityID]?.source {
            actualSourceCurrent = (try? CodingShadowProject.inspect(source: source).revision) == run.evidenceRevision
        } else { actualSourceCurrent = true }
        guard run.evidenceRevision == status.sourceRevision,
              waveRevision == status.wave?.revision,
              taskID == status.wave?.currentTaskID, actualSourceCurrent else {
            var discarded = run
            discarded.lifecycle = .cancelled
            discarded.outputSummary = "Check result discarded because the source, requirements or task changed."
            discarded.exitCode = nil
            emit(kind: .run, run: discarded)
            setActivity(.listening, discarded.outputSummary)
            return
        }
        emit(kind: .run, run: run)

        // `expectedEvidence` has been written into every plan since v1 and never
        // read. A runner that skipped every test still exits 0, so the exit code
        // alone is the wrong signal in both directions.
        let verdict = CodingRunVerdictJudge.judge(run: run, expected: expected)
        if savedCode { lastVerdict = verdict }
        if savedCode && verdict == .satisfied { status.interviewFlow?.checkedSourceRevision = run.evidenceRevision }
        lastCommand = run.displayedCommand
        if status.pendingRun?.id == run.id { status.pendingRun = nil }
        if let wave = status.wave {
            status.wave?.observe(WaveEvidence(taskID: wave.currentTaskID, revision: wave.revision,
                kind: .checked, detail: (savedCode ? "Saved-code snapshot: " : "Proposal: ") + run.outputSummary,
                succeeded: verdict == .satisfied, shadow: !savedCode))
            
        } else if savedCode { rubric.noteVerified(expected: expected, verdict: verdict, runID: run.id) }
        ledger.record(.init(id: run.id, command: run.displayedCommand,
                            verdict: verdict, summary: run.outputSummary))
        try? workspace?.record(run: run, verdict: verdict)
        refreshFacts()

        let say: String
        let why: String
        switch verdict {
        case .satisfied:
            say = "That passes — say exactly what it proves."
            why = "The output shows the behaviour the check was written for."
        case .unsatisfied:
            say = "That fails. Read the first error and fix only that."
            why = "The first actionable error is the smallest correct next step."
        case .unknown:
            say = "That did not prove anything yet — check the command, not the code."
            why = "Nothing ran, or the output never showed the expected evidence."
        }
        let move = CodingMove(
            ordinal: (status.activeMove?.ordinal ?? 0) + 1,
            sourceRevision: run.evidenceRevision,
            kind: verdict == .satisfied ? .verification : .diagnostic,
            say: say, why: why, result: run.outputSummary, status: .current,
            origin: .deterministic,
            priority: verdict == .unsatisfied ? .urgent : .advisory)
        if status.wave == nil { supersedeActive(with: move) }
        else { persistActiveLedger() }
    }

    private func cancelRun() async {
        await activeRun?.cancel()
        runTask?.cancel(); runTask = nil; activeRun = nil; activeRunToken = nil
    }

    private func supersedeActive(with proposed: CodingMove) {
        let move = status.interviewFlow.map { CodingInterviewPublication.screen(proposed, flow: $0) } ?? proposed
        if status.interviewFlow?.held == true { heldMove = move; return }
        if var old = status.activeMove {
            old.status = .superseded; old.supersededBy = move.id; old.updatedAt = Date()
            emit(kind: .move, move: old)
        }
        status.activeMove = move
        emit(kind: .move, move: move)
    }

    private func end(interrupted: Bool, detail: String? = nil) async {
        watcher?.cancel(); watcher = nil
        observationTask?.cancel(); observationTask = nil
        ticker?.cancel(); ticker = nil
        guidanceID = nil; guidanceQueue.reset()
        guidanceTask?.cancel(); guidanceTask = nil
        wavePreparationTask?.cancel(); wavePreparationTask = nil
        preparationDebounce?.cancel(); preparationDebounce = nil
        await waveWorkers?.cancel(); waveWorkers = nil
        if let configuration { await provider.closeSession(dialogueSessionKey(configuration.sessionID)) }
        await cancelRun()
        guard let configuration else { return }
        defer { self.configuration = nil }
        status.lifecycle = interrupted ? .interrupted : .finished
        status.activity = .ended
        status.activityDetail = interrupted ? (detail ?? "The coding session was interrupted and saved for recovery.") : nil
        emit(kind: .lifecycle, lifecycle: status.lifecycle)
        let sessionRoot = root.appendingPathComponent("active/\(configuration.sessionID)")
        try? fileManager.removeItem(at: sessionRoot.appendingPathComponent("agy-home"))
        // The twin's context is engine-owned scratch; the candidate's `work/`
        // is what gets sealed, and it is left exactly as it is.
        workspace?.tearDown(); workspace = nil
        guard fileManager.fileExists(atPath: sessionRoot.path),
              let capability = capabilities[configuration.folderCapabilityID] else { return }
        do {
            try vault.seal(active: sessionRoot, configuration: configuration,
                           snapshot: status, events: events,
                           preflight: capability.preflight, bookmark: capability.bookmark,
                           startedAt: startedAt)
            if capability.accessing { capability.source.stopAccessingSecurityScopedResource() }
            capabilities.removeValue(forKey: configuration.folderCapabilityID)
        } catch {
            status.lifecycle = .failed
            let failure = CodingFailure(code: "archive_failed", message: error.localizedDescription,
                                        recovery: "The private plaintext workspace was retained for recovery.")
            status.failure = failure; emit(kind: .failure, failure: failure)
        }
    }

    private func delete(sessionID: String) async {
        guard configuration?.sessionID == sessionID else { return }
        await cancelRun(); watcher?.cancel(); watcher = nil
        ticker?.cancel(); ticker = nil
        guidanceID = nil; guidanceQueue.reset()
        guidanceTask?.cancel(); guidanceTask = nil
        wavePreparationTask?.cancel(); wavePreparationTask = nil
        preparationDebounce?.cancel(); preparationDebounce = nil
        await waveWorkers?.cancel(); waveWorkers = nil
        await provider.closeSession(dialogueSessionKey(sessionID))
        let sessionRoot = root.appendingPathComponent("active/\(sessionID)")
        try? fileManager.removeItem(at: sessionRoot)
        try? vault.delete(sessionID: sessionID)
        if let capabilityID = configuration?.folderCapabilityID,
           let capability = capabilities.removeValue(forKey: capabilityID), capability.accessing {
            capability.source.stopAccessingSecurityScopedResource()
        }
        configuration = nil; events.removeAll(); nextSequence = 0
        status = CodingSessionSnapshot()
    }

    private func beginTicking() {
        ticker?.cancel()
        transcriptClockSetAt = Date()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                // 250ms is what the flow plan specifies. At 500 a statement
                // that settled on silence waited half a second for the tick
                // that noticed.
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                await self?.tickSegmenter()
            }
        }
    }

    private func beginWatching(source: URL, mirror: URL, work: URL, knownRevision: String) {
        watcher?.cancel()
        watcher = Task { [weak self] in
            var revision = knownRevision
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(650))
                guard !Task.isCancelled,
                      let manifest = try? CodingShadowProject.inspect(source: source),
                      manifest.revision != revision else { continue }
                revision = manifest.revision
                await self?.sourceChanged(manifest, source: source, mirror: mirror, work: work)
            }
        }
    }

    /// One command slot is shared by proposal checks and exact saved-source
    /// checks. Checking a copied saved tree never executes in the selected folder.
    private func sourceChanged(_ manifest: CodingSnapshotManifest, source: URL, mirror: URL, work: URL) {
        status.syncState = .syncing
        setActivity(.syncing, "picking up your save")
        do {
            let reconciled = try CodingShadowProject.reconcile(
                source: source, mirror: mirror, work: work, fileManager: fileManager)
            status.sourceRevision = reconciled.manifest.revision
            // A save is `.saved` evidence for the task in hand, at the revision
            // it produced. `advance(explicit: false)` has always asked for it
            // alongside a `.checked` verdict, and it was never recorded — so
            // the automatic path could not fire however well the check went.
            // Recorded before `sourceChanged` bumps the revision, so the
            // evidence carries the revision it actually belongs to.
            if let wave = status.wave, let taskID = wave.currentTask?.id {
                status.wave?.observe(WaveEvidence(
                    taskID: taskID, revision: wave.revision, kind: .saved,
                    detail: "Saved \(reconciled.manifest.entries.count) entries at "
                        + reconciled.manifest.revision.prefix(12),
                    succeeded: true, shadow: false))
            }
            status.wave?.sourceChanged(reconciled.manifest.revision)
            status.interviewFlow?.sourceRevision = reconciled.manifest.revision
            status.interviewFlow?.checkedSourceRevision = nil
            if var flow = status.interviewFlow {
                for index in flow.pending.indices {
                    guard let proof = flow.pending[index].completedEvidence else { continue }
                    let file = mirror.appendingPathComponent(proof.path).resolvingSymlinksInPath()
                    let text = file.path.hasPrefix(mirror.resolvingSymlinksInPath().path + "/") ? try? String(contentsOf: file) : nil
                    if text?.contains(proof.excerpt) != true { flow.pending[index].completedEvidence = nil }
                }
                status.interviewFlow = flow
            }
            lastVerdict = nil
            schedulePreparationDebounced()
            // Re-evaluate the last actual utterance against this saved revision,
            // but only when the save is what the answer was waiting on: an
            // authorised behaviour with no accepted evidence yet. Re-asking on
            // every save made the lane answer a sentence it had already answered
            // while the next real question queued behind it. No synthetic speech.
            if pendingCompletionUnverified(), let statement = ledger.tail.last {
                _ = guidanceQueue.enqueue(statement, context: ledger.tail, priority: .urgent)
                startGuidanceIfNeeded()
            }
            status.workRevision = (try? CodingShadowProject.inspect(source: work).revision)
            status.syncState = .current
            status.pendingRun = nil
            lastSaveAt = Date()
            if reconciled.outcome == .conflict, var stale = status.activeMove {
                stale.status = .stale; stale.updatedAt = Date(); status.activeMove = stale
                emit(kind: .move, move: stale)
            }
            emit(kind: .sourceRevision, sourceRevision: reconciled.manifest.revision)
        } catch {
            status.syncState = .conflict
            let failure = CodingFailure(code: "mirror_sync_failed", message: error.localizedDescription,
                                        recovery: "Save again or reselect the folder.")
            status.failure = failure; emit(kind: .failure, failure: failure)
        }
    }

    /// Whether a save can still change the answer.
    ///
    /// True while an authorised behaviour has no accepted source evidence: that
    /// is the one case where re-reading what the candidate just wrote can move
    /// the interview on. Everything else the save changes is an engine fact the
    /// panel already shows without asking a model.
    private func pendingCompletionUnverified() -> Bool {
        guard let flow = status.interviewFlow else { return false }
        let authorized = flow.authorizedPendingIDs ?? []
        guard !authorized.isEmpty else { return false }
        return flow.pending.contains { authorized.contains($0.id) && $0.completedEvidence == nil }
    }

    private func emit(kind: CodingEventKind, lifecycle: CodingLifecycle? = nil,
                      sourceRevision: String? = nil, move: CodingMove? = nil,
                      run: CodingRun? = nil, failure: CodingFailure? = nil) {
        guard let configuration else { return }
        var event = CodingEvent(sessionID: configuration.sessionID, callID: configuration.callID,
                                generation: configuration.generation, sequence: nextSequence,
                                kind: kind, lifecycle: lifecycle, sourceRevision: sourceRevision,
                                move: move, run: run, failure: failure)
        var eventFlow = status.interviewFlow
        eventFlow?.transcript = []; eventFlow?.clarificationHistory = []
        event.interviewFlow = eventFlow
        nextSequence += 1; events.append(event)
        if events.count > LiveCodingContract.maximumEvents {
            events.removeFirst(events.count - LiveCodingContract.maximumEvents)
        }
        status.latestSequence = event.sequence
        persistActiveLedger()
        writeWaveCallContext()
    }

    private func writeWaveCallContext() {
        guard let configuration, let flow = status.interviewFlow else { return }
        let file = root.deletingLastPathComponent().appendingPathComponent("copilot/wave-" + configuration.callID + ".json")
        if !status.lifecycle.active { try? fileManager.removeItem(at: file); return }
        var excerpt = "No source excerpt selected. Verify the actual file before giving code-specific advice."
        if let path = status.activeMove?.file?.path,
           (try? LiveCodingValidation.validate(relativePath: path)) != nil {
            let url = root.appendingPathComponent("active/\(configuration.sessionID)/mirror/" + path)
            if let text = try? String(contentsOf: url, encoding: .utf8) { excerpt = path + "\n" + String(text.prefix(6000)) }
        }
        var context = WaveCallContext(callID: configuration.callID, generation: configuration.generation,
            revision: preparationRevision ?? WaveRevision(session: configuration.sessionID, source: flow.sourceRevision),
            task: (isRehearsal ? "[rehearsal] " : "")
                + Self.taskDescription(flow: flow, wave: status.wave),
            decisions: flow.facts.map { "\($0.kind.rawValue): \($0.text)" },
            sourceExcerpt: excerpt)
        var compactFlow = flow
        compactFlow.transcript = []
        compactFlow.clarificationHistory = Array(flow.clarificationHistory.suffix(4))
        context.interviewFlow = compactFlow
        try? fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(context) {
            try? data.write(to: file, options: [.atomic, .completeFileProtection])
        }
    }

    /// Whether this session is practice.
    ///
    /// `nil` reads as a rehearsal: a configuration written before rehearsals
    /// existed cannot vouch for having been the real sitting, and claiming a
    /// practice run was the interview is the costlier direction to be wrong in.
    private var isRehearsal: Bool { configuration?.rehearsal ?? true }

    /// The step Call should answer against: the pending behaviour, plus what
    /// the spec says that step has to handle.
    private static func taskDescription(flow: CodingInterviewFlowState,
                                        wave: WaveInterviewState?) -> String {
        // Both halves from the same pending item. They used to be mixed — the
        // text from `flow.pending`, the checks from `wave.currentTask` — so
        // Call was told one task and given another's acceptance list.
        guard let pending = flow.pending.first(where: { $0.completedEvidence == nil }) else {
            return wave?.currentTask?.title ?? "Interview"
        }
        let checks = Self.checks(forPendingID: pending.id)
        guard !checks.isEmpty else { return pending.text }
        return pending.text + " — must handle: " + checks.joined(separator: "; ")
    }

    private func persistActiveState(sessionRoot: URL) {
        if let data = try? JSONEncoder().encode(status) {
            try? data.write(to: sessionRoot.appendingPathComponent("snapshot.json"), options: [.atomic, .completeFileProtection])
        }
    }

    private func persistActiveLedger() {
        guard let configuration,
              let capability = capabilities[configuration.folderCapabilityID],
              status.lifecycle.active || status.lifecycle == .interrupted || status.lifecycle == .finished else { return }
        let sessionRoot = root.appendingPathComponent("active/\(configuration.sessionID)")
        guard fileManager.fileExists(atPath: sessionRoot.path) else { return }
        let ledger = ActiveLedger(configuration: configuration, snapshot: status, events: events,
                                  preflight: capability.preflight, bookmark: capability.bookmark,
                                  startedAt: startedAt)
        if let data = try? JSONEncoder().encode(ledger) {
            try? data.write(to: sessionRoot.appendingPathComponent("coding-ledger.json"),
                            options: [.atomic, .completeFileProtection])
        }
        writeWaveCallContext()
    }

    private func resume(_ command: CodingCommand) throws -> CodingSessionSnapshot {
        guard command.contractVersion == LiveCodingContract.version,
              !command.sessionID.isEmpty, !command.callID.isEmpty, command.generation > 0 else {
            throw LiveCodingValidation.Failure.invalidIdentity
        }
        let record = try vault.record(sessionID: command.sessionID)
        let source = try CodingFolderBookmark.resolve(record.bookmark).url
            .resolvingSymlinksInPath().standardizedFileURL
        let accessing = source.startAccessingSecurityScopedResource()
        guard accessing || fileManager.isReadableFile(atPath: source.path) else {
            throw CodingSessionCoreFailure.sourceUnavailable
        }
        let capabilityID = record.configuration.folderCapabilityID
        capabilities[capabilityID] = Capability(source: source, bookmark: record.bookmark,
                                                accessing: accessing, preflight: record.preflight)
        var restoredConfiguration = record.configuration
        restoredConfiguration.callID = command.callID
        restoredConfiguration.generation = command.generation
        configuration = restoredConfiguration
        startedAt = record.startedAt
        let active = root.appendingPathComponent("active/\(command.sessionID)", isDirectory: true)
        try vault.restore(record, to: active)
        events = record.events.map { old in
            var event = old; event.callID = command.callID; event.generation = command.generation
            return event
        }
        nextSequence = (events.map(\.sequence).max() ?? -1) + 1
        status = record.snapshot
        status.callID = command.callID; status.generation = command.generation
        if status.interviewFlow == nil {
            status.interviewFlow = CodingInterviewFlowState(sessionID: command.sessionID,
                generation: command.generation, sourceRevision: status.sourceRevision ?? "")
        }
        let restoredSourceRevision = status.sourceRevision ?? ""
        status.interviewFlow?.restore(generation: command.generation, sourceRevision: restoredSourceRevision)
        if let flow = status.interviewFlow, let move = status.activeMove {
            status.activeMove = CodingInterviewPublication.screen(move, flow: flow)
        }
        preparedSteps = []; heldMove = nil; spokenQuestionIDs = [:]; dialogueAnchor = nil
        if status.wave != nil {
            status.pendingRun = nil; waveProposalPaths.removeAll()
            if let data = try? Data(contentsOf: active.appendingPathComponent("wave-proposals.json")),
               let paths = try? JSONDecoder().decode([String: String].self, from: data) {
                for (id, relative) in paths where relative.hasPrefix("proposals/") {
                    guard (try? LiveCodingValidation.validate(relativePath: relative)) != nil else { continue }
                    let path = active.appendingPathComponent(relative).resolvingSymlinksInPath()
                    guard path.path.hasPrefix(active.appendingPathComponent("proposals").path + "/"),
                          fileManager.fileExists(atPath: path.path) else { continue }
                    waveProposalPaths[id] = path
                }
            }
            if let move = status.activeMove, waveProposalPaths[move.id] != nil {
                status.pendingRun = move.check
            }
        }
        status.lifecycle = .ready; status.failure = nil
        status.activity = .listening; status.activityDetail = nil
        emit(kind: .lifecycle, lifecycle: .ready)
        let mirror = active.appendingPathComponent("mirror", isDirectory: true)
        let work = active.appendingPathComponent("work", isDirectory: true)
        // Rebuilding the workspace on resume is what makes a restart cheap: the
        // twin reads its way back to where the interview was.
        let space = CodingWorkspace(root: active)
        workspace = space
        segmenter = StatementSegmenter(rules: .coding)
        phaseMachine = CodingPhaseMachine(phase: status.phase)
        rubric = CodingRubricTracker(brief: restoredConfiguration.brief)
        ledger = CodingLedger()
        guidanceQueue.reset(); guidanceID = nil; transcriptSequence = -1
        try? space.seed(brief: restoredConfiguration.brief,
                        persona: CodingSessionController.persona,
                        pack: promptPack, readOnly: true)
        // A resumed session is the same interview, so it needs the same context
        // pack. `seed` rewrites the workspace, and this was not re-run after
        // it — a session resumed after a restart read the spec, the flow and
        // the library probe as missing files.
        if restoredConfiguration.interviewProfile == WaveInterviewProfile.wave {
            try? space.seedWaveContext()
            if let prepared = preparedContexts[source.resolvingSymlinksInPath().path],
               let report = try? Data(contentsOf: prepared.appendingPathComponent("library-probe.md")) {
                try? report.write(to: space.contextURL.appendingPathComponent("library-probe.md"),
                                  options: .atomic)
            }
        }
        try? space.write(rubric: rubric.states)
        try? space.write(diff: Self.diff(mirror: mirror, work: work))
        prewarmDialogue(sessionID: restoredConfiguration.sessionID,
                        brief: restoredConfiguration.brief)
        beginWatching(source: source, mirror: mirror, work: work,
                      knownRevision: status.sourceRevision ?? "")
        beginTicking()
        scheduleWaveSteps()
        beginEditorObservation()
        return status
    }

    /// Ask the twin for one move, screen it, publish what survives.
    ///
    /// Three guards stand between the reply and the panel, and each exists
    /// because the alternative is visible to an interviewer: the revision fence
    /// drops an answer about code that has since changed, the pacing screen cuts
    /// anything larger than the current step, and the claim guard removes a file
    /// or command that does not exist.
    /// What the panel says while it works, in the candidate's terms.
    private func produceGuidance(statement: Statement, increment: CodingIncrement,
                                 intent: CodingIntent,
                                 priority: CodingMovePriority, requestID: UUID,
                                 recentContext: [Statement]) async {
        guard let configuration, workspace != nil, let flow = status.interviewFlow else { return }
        let sessionRoot = root.appendingPathComponent("active/\(configuration.sessionID)")
        let frame = CodingInterviewFlow.frame(state: flow, statement: statement,
                                              savedSource: savedSource(sessionRoot: sessionRoot))
        let started = Date()
        do {
            let draft: CodingMoveDraft
            /// Which model actually answered, when the router knows. The
            /// configured id is only what was asked for.
            var answeredBy: String?
            if let dialogueResponder { draft = try await dialogueResponder(frame) }
            else {
                // The contract names `say` and `dialogue`, so `ContractParser`
                // recovers the object out of whatever the model wrapped it in
                // and an incomplete reply is `.unparseable` — which the router
                // retries in place, inside the same budget, instead of it
                // surfacing as "repeat that point".
                let response = try await router.respond(to: .init(
                    task: CodingTasks.dialogue,
                    sessionKey: dialogueSessionKey(configuration.sessionID),
                    system: dialogueBlocks(brief: flow.brief),
                    input: frame,
                    priority: .urgent,
                    queuePolicy: .fifo))
                guard let payload = response.payload else { throw CodingAgyWorkerFailure.malformed }
                answeredBy = response.attribution.model
                draft = try Self.decodeDraft(payload, identifiedBy: flow)
            }
            guard !Task.isCancelled, guidanceID == requestID,
                  self.configuration?.sessionID == configuration.sessionID,
                  self.configuration?.generation == configuration.generation,
                  status.lifecycle.active, var current = status.interviewFlow,
                  current.sourceRevision == flow.sourceRevision,
                  current.requirementRevision == flow.requirementRevision,
                  current.taskRevision == flow.taskRevision else { return }
            guard let update = draft.dialogue else { throw CodingAgyWorkerFailure.malformed }
            if update.pending?.contains(where: { $0.completedEvidence != nil }) == true,
               let actualSource = capabilities[configuration.folderCapabilityID]?.source,
               (try? CodingShadowProject.inspect(source: actualSource).revision) != flow.sourceRevision {
                status.interviewFlow?.retry = "Your saved code changed. Rechecking this step."
                return
            }
            var saved: [String: String] = [:]
            for item in update.pending ?? [] {
                if let proof = item.completedEvidence,
                   (try? LiveCodingValidation.validate(relativePath: proof.path)) != nil {
                    let url = sessionRoot.appendingPathComponent("mirror/" + proof.path).resolvingSymlinksInPath()
                    guard url.path.hasPrefix(sessionRoot.appendingPathComponent("mirror").path + "/") else { continue }
                    saved[proof.path] = try? String(contentsOf: url, encoding: .utf8)
                }
            }
            guard CodingInterviewFlow.apply(update, to: &current, savedFiles: saved) else {
                status.interviewFlow?.retry = current.retry ?? "Please repeat or clarify that last point."
                persistActiveLedger(); return
            }
            status.interviewFlow = current; status.phase = current.phase
            dialogueAnchor = verifiedAnchor(draft.file, sessionRoot: sessionRoot)
            status.failure = nil
            status.attribution = CodingAttribution(provider: configuration.provider,
                model: answeredBy ?? configuration.profile.move.modelID,
                latencyMilliseconds: Int(Date().timeIntervalSince(started) * 1000), lane: "coding.dialogue")
            if current.requirementRevision != flow.requirementRevision || current.taskRevision != flow.taskRevision || current.pending != flow.pending {
                scheduleWaveSteps()
            }
            if let question = update.questionToAssistant, current.clarification?.asked == nil {
                await routeQuestion(question.quote, anchor: question)
            } else if current.authorizedStage == nil && current.retry == nil {
                publishFlowPointer()
            }
            publishPreparedIfAuthorized()
            refreshFacts(); persistActiveLedger()
            setActivity(.listening, attributionSummary())
        } catch {
            guard !Task.isCancelled, guidanceID == requestID,
                  self.configuration?.sessionID == configuration.sessionID,
                  self.configuration?.generation == configuration.generation,
                  status.lifecycle.active else { return }
            status.interviewFlow?.retry = "Please repeat that point to retry."
            let failure = CodingFailure(code: "coding_dialogue_failed",
                                        message: Self.describe(error),
                                        recovery: status.interviewFlow?.retry)
            status.failure = failure; emit(kind: .failure, failure: failure)
            setActivity(.blocked, "Conversation paused; repeat to retry")
        }
    }

    /// What actually went wrong, in terms a log can be searched on.
    ///
    /// `DecodingError.localizedDescription` is "The data couldn't be read
    /// because it is missing", which names neither the field nor the reply it
    /// came from and cost a session to diagnose.
    static func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return error.localizedDescription }
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map(\.stringValue).joined(separator: ".")
        }
        switch decoding {
        case let .keyNotFound(key, context):
            let field = [path(context), key.stringValue]
                .filter { !$0.isEmpty }.joined(separator: ".")
            return "The reply left out " + field + "."
        case let .valueNotFound(_, context):
            return "The reply left \(path(context)) empty."
        case let .typeMismatch(type, context):
            return "The reply gave \(path(context)) as something other than \(type)."
        case let .dataCorrupted(context):
            let where_ = path(context)
            return where_.isEmpty ? "The reply was not readable JSON."
                : "The reply's \(where_) was not readable."
        @unknown default: return error.localizedDescription
        }
    }

    /// Decode one reply, with the engine's own identity stamped into it.
    ///
    /// The five identity values are the only non-optional fields on
    /// `CodingDialogueUpdate`, and under `--json-schema` the model was *forced*
    /// to echo them. On the resident host there is no schema — `agentapi` takes
    /// no such flag — so a reply that omitted one failed to decode entirely and
    /// the panel said "Please repeat that point to retry" with a perfectly good
    /// answer in hand.
    ///
    /// Asking for the echo was always redundant. It exists to fence a reply
    /// against a state that has moved on, and the engine does that itself: it
    /// captured `flow` when it built the request and compares it to the current
    /// state before applying anything. Stamping from that same captured `flow`
    /// yields exactly the comparison `apply` already performs, so the fence is
    /// unchanged — a stale reply is still refused — and the model no longer has
    /// to reproduce five values byte-for-byte to be understood.
    static func decodeDraft(_ payload: Data, identifiedBy flow: CodingInterviewFlowState) throws
        -> CodingMoveDraft {
        guard var object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw CodingAgyWorkerFailure.malformed
        }
        if var dialogue = object["dialogue"] as? [String: Any] {
            dialogue["sessionID"] = flow.sessionID
            dialogue["generation"] = flow.generation
            dialogue["sourceRevision"] = flow.sourceRevision
            dialogue["requirementRevision"] = flow.requirementRevision
            dialogue["taskRevision"] = flow.taskRevision
            // Identity was only the first required field the model dropped;
            // there are more at five further levels. Repair anchors from the
            // recorded transcript and drop what still cannot be read, so one
            // malformed item costs that item and not the turn.
            object["dialogue"] = CodingDialogueRepair.repair(dialogue: dialogue,
                                                             transcript: flow.transcript)
        }
        let stamped = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(CodingMoveDraft.self, from: stamped)
    }

    /// An anchor the panel may print, or nothing.
    ///
    /// Three ways to fail: an unsafe or absolute path, a path that is not in
    /// the engine's own mirror, and a line number past the end of it. Each of
    /// them would put a filename on screen that the candidate would then look
    /// for and not find.
    private func verifiedAnchor(_ anchor: CodingFileAnchor?, sessionRoot: URL) -> CodingFileAnchor? {
        guard let anchor, (try? LiveCodingValidation.validate(relativePath: anchor.path)) != nil
        else { return nil }
        let mirror = sessionRoot.appendingPathComponent("mirror")
        let url = mirror.appendingPathComponent(anchor.path).resolvingSymlinksInPath()
        guard url.path.hasPrefix(mirror.resolvingSymlinksInPath().path + "/"),
              fileManager.fileExists(atPath: url.path) else { return nil }
        var verified = anchor
        if let line = anchor.line {
            let lines = (try? String(contentsOf: url, encoding: .utf8))?
                .split(whereSeparator: \.isNewline).count ?? 0
            if line < 1 || line > lines { verified.line = nil }
        }
        return verified
    }

    /// The candidate's saved code, as the dialogue lane now has to receive it.
    ///
    /// Only files whose digest differs from the baseline this session started
    /// from. An interview edits one or two files, and sending an untouched
    /// project would spend most of the prompt on code nobody wrote. Bounded by
    /// `CodingInterviewFlow.maximumSavedSourceBytes`, because the frame is
    /// re-sent in full on every turn.
    ///
    /// This reads the engine's own mirror, never the selected folder, and it is
    /// the same bytes `apply(_:to:savedFiles:)` verifies a completion excerpt
    /// against afterwards — so the lane can assess saved work without a file
    /// tool, and still cannot claim work that is not on disk.
    private func savedSource(sessionRoot: URL) -> String {
        let mirror = sessionRoot.appendingPathComponent("mirror")
        guard let saved = try? CodingShadowProject.inspect(source: mirror) else { return "" }
        let baseline = (try? CodingShadowProject.inspect(
            source: sessionRoot.appendingPathComponent("baseline")))?.entries ?? []
        var original: [String: String] = [:]
        for entry in baseline { original[entry.path] = entry.digest }
        var out = ""
        for entry in saved.entries.sorted() where original[entry.path] != entry.digest {
            guard out.utf8.count < CodingInterviewFlow.maximumSavedSourceBytes else { break }
            let url = mirror.appendingPathComponent(entry.path)
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            out += "#### \(entry.path)\n```\n\(text)\n```\n\n"
        }
        return out
    }

    /// Difference between two engine-owned snapshots, never a selected-folder mutation.
    private static func diff(mirror: URL, work: URL) -> String {
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["diff", "--no-index", "--no-ext-diff", "--", mirror.path, work.path]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data.prefix(LiveCodingContract.maximumTextBytes), as: UTF8.self)
            .replacingOccurrences(of: mirror.path + "/", with: "a/")
            .replacingOccurrences(of: work.path + "/", with: "b/")
    }

    private static func recoverAbandonedSessions(root: URL, fileManager: FileManager,
                                                historyKeyProvider: @escaping @Sendable () throws -> SymmetricKey) {
        let activeRoot = root.appendingPathComponent("active", isDirectory: true)
        guard let directories = try? fileManager.contentsOfDirectory(
            at: activeRoot, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        let vault = CodingSessionVault(keyProvider: historyKeyProvider, root: root, fileManager: fileManager)
        for directory in directories {
            let ledgerURL = directory.appendingPathComponent("coding-ledger.json")
            guard let data = try? Data(contentsOf: ledgerURL),
                  let ledger = try? JSONDecoder().decode(ActiveLedger.self, from: data) else { continue }
            var snapshot = ledger.snapshot
            snapshot.lifecycle = .interrupted
            try? fileManager.removeItem(at: directory.appendingPathComponent("agy-home"))
            try? vault.seal(active: directory, configuration: ledger.configuration,
                            snapshot: snapshot, events: ledger.events,
                            preflight: ledger.preflight, bookmark: ledger.bookmark,
                            startedAt: ledger.startedAt)
        }
    }

    private static func gitFacts(at source: URL) -> (branch: String?, dirty: Bool) {
        func run(_ arguments: [String]) -> String? {
            let process = Process(); let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", source.path] + arguments
            process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            process.waitUntilExit(); guard process.terminationStatus == 0 else { return nil }
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (run(["branch", "--show-current"]), !(run(["status", "--porcelain=v1"]) ?? "").isEmpty)
    }
}

actor CodingShadowRunner {
    private let work: URL
    private let isolatedHome: URL
    private let temporary: URL
    private let networkEnabled: Bool
    private var process: Process?
    private var processGroup: pid_t?

    init(work: URL, isolatedHome: URL, temporary: URL, networkEnabled: Bool) {
        self.work = work; self.isolatedHome = isolatedHome
        self.temporary = temporary; self.networkEnabled = networkEnabled
    }

    func run(plan: CodingRunPlan, evidenceRevision: String) async -> CodingRun {
        let started = Date()
        do {
            let cwd = try CodingCommandPolicy.validate(
                command: plan.displayedCommand, relativeCWD: plan.relativeCWD, work: work)
            for directory in [isolatedHome, temporary] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            }
            let child = Process(); let output = Pipe()
            let sandbox = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            if FileManager.default.isExecutableFile(atPath: sandbox.path) {
                let launch = ProcessTether.tethered(sandbox.path, ["-p", profile(), "/bin/zsh", "-lc", plan.displayedCommand])
                child.executableURL = URL(fileURLWithPath: launch.executable)
                child.arguments = launch.arguments
            } else {
                throw CodingSessionCoreFailure.commandDenied("The shadow command sandbox is unavailable")
            }
            child.currentDirectoryURL = cwd
            child.standardOutput = output; child.standardError = output
            child.standardInput = FileHandle.nullDevice
            child.environment = [
                "HOME": isolatedHome.path, "TMPDIR": temporary.path,
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
                "CI": "1", "TERM": "dumb"
            ]
            try child.run(); process = child
            if setpgid(child.processIdentifier, child.processIdentifier) == 0 {
                processGroup = child.processIdentifier
            }
            let outputTask = Task.detached { () -> (Data, Bool) in
                var data = Data(); var truncated = false
                while true {
                    let chunk = output.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    let remaining = max(0, LiveCodingContract.maximumOutputBytes - data.count)
                    data.append(chunk.prefix(remaining))
                    if chunk.count > remaining { truncated = true }
                }
                return (data, truncated)
            }
            let timeout = Task { try? await Task.sleep(for: .seconds(120)); return true }
            let finished = Task.detached { child.waitUntilExit(); return true }
            while child.isRunning, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                if timeout.isCancelled { break }
                if Date().timeIntervalSince(started) >= 120 { cancel(); break }
            }
            if Task.isCancelled { cancel() }
            _ = await finished.value; timeout.cancel(); process = nil; processGroup = nil
            let (capped, truncated) = await outputTask.value
            let lifecycle: CodingRunLifecycle
            if Task.isCancelled { lifecycle = .cancelled }
            else if Date().timeIntervalSince(started) >= 120 { lifecycle = .timedOut }
            else { lifecycle = child.terminationStatus == 0 ? .passed : .failed }
            return CodingRun(
                id: plan.id, relativeCWD: plan.relativeCWD, displayedCommand: plan.displayedCommand,
                lifecycle: lifecycle, exitCode: child.terminationStatus,
                durationMilliseconds: Int(Date().timeIntervalSince(started) * 1_000),
                outputSummary: String(decoding: capped, as: UTF8.self),
                outputTruncated: truncated, evidenceRevision: evidenceRevision,
                startedAt: started, endedAt: Date())
        } catch {
            return CodingRun(id: plan.id, relativeCWD: plan.relativeCWD,
                             displayedCommand: plan.displayedCommand, lifecycle: .environmentFailure,
                             durationMilliseconds: Int(Date().timeIntervalSince(started) * 1_000),
                             outputSummary: error.localizedDescription, evidenceRevision: evidenceRevision,
                             startedAt: started, endedAt: Date())
        }
    }

    func cancel() {
        guard let process, process.isRunning else { return }
        let pid = process.processIdentifier
        let group = processGroup
        if let group { kill(-group, SIGINT) } else { process.interrupt() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            if process.isRunning {
                if let group { kill(-group, SIGKILL) }
                else { kill(pid, SIGKILL) }
            }
        }
    }

    private func profile() -> String {
        func escaped(_ value: String) -> String { value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let network = networkEnabled ? "(allow network*)" : ""
        let readable = ["/System", "/Library", "/usr", "/bin", "/sbin", "/opt/homebrew", "/usr/local", "/Applications/Xcode.app", work.path, isolatedHome.path, temporary.path]
            .map { "(allow file-read* (subpath \"\(escaped($0))\"))" }.joined(separator: "\n")
        return """
        (version 1)
        (deny default)
        (allow process*)
        \(network)
        \(readable)
        (allow file-write* (subpath "\(escaped(work.path))"))
        (allow file-write* (subpath "\(escaped(isolatedHome.path))"))
        (allow file-write* (subpath "\(escaped(temporary.path))"))
        (allow file-read-metadata)
        (allow sysctl-read)
        (allow mach-lookup)
        (deny appleevent-send)
        (deny mach-lookup (global-name-regex #".*([Ss]ecurity|appleevent|AppleEvent).*"))
        """
    }
}
