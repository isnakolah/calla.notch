import CallaContracts
import CryptoKit
import Foundation
import IntelligenceCore
import IntelligenceProviders
import IntelligenceStore

actor QuizEngineController {
    private let root: URL
    private let hostExecutable: @Sendable () -> URL?
    private let fileManager: FileManager
    private var store: QuizStore?
    private var pool: QuizAgyWorkerPool?
    private var configuration: QuizSessionConfiguration?
    private var status = QuizSessionSnapshot()
    private var watcher: Task<Void, Never>?
    private var solver: Task<Void, Never>?
    /// In-flight capture commit for the current question. Awaited before an
    /// answer is published, not before the council is asked.
    private var persistence: Task<Void, Error>?
    private var captureGeneration = 0
    /// Stable-frame detection, questionID and generation all live here now.
    ///
    /// This file used to reimplement the whole thing inline with hardcoded
    /// thresholds, while the tested version sat in `QuizQuestionDetector` used
    /// only by its own tests. The inline copy also lacked the `.ignoredAnimation`
    /// case, so a spinner or a caret counted as the screen changing.
    private var detector = QuizQuestionDetector()
    /// Enforces one question's frames per submission; the manual array it
    /// replaces leaked the previous question's viewports into the next one.
    private var collector = QuizViewportCollector()
    private var currentQuestion: QuizStableQuestion?
    /// When the current question settled. The panel's clock runs from here, not
    /// from the start of the session.
    private var questionStartedAt: Date?
    private var cache: [String: QuizFinalAnswer] = [:]
    /// Insertion order for `cache`, oldest first, so it can be bounded.
    private var cacheOrder: [String] = []
    /// Consecutive capture failures. A single transient one used to end the
    /// session; only a sustained run means the window is really gone.
    private var captureFailures = 0
    /// Set when a question was in flight and unanswered at the moment of a
    /// pause, so `.resume` can re-ask instead of stalling.
    private var pausedQuestionPending = false
    /// Answers published this session, oldest first, bounded by the contract.
    /// The panel steps through these; previously each answer was lost to the
    /// next question.
    private var sessionAnswers: [QuizFinalAnswer] = []
    /// Built once per session from graded history. Empty until the reader has
    /// graded enough answers, in which case `display` returns raw confidence —
    /// the same behaviour as before, but now by measurement rather than by
    /// never having been wired up.
    private var calibration = QuizConfidenceCalibration()
    /// The `agy` this session runs. Held so a council built mid-session does not
    /// have to locate it again.
    private var agyBinary: String?
    /// Which mode the resident pool was built for, so a question of the same mode
    /// reuses it instead of respawning.
    private var warmedMode: QuizMode?
    /// The council actually resident, so an equivalent profile reuses it.
    private var warmedProfile: QuizModeProfile?
    private var prewarm: Task<Void, Never>?
    private var prewarmingMode: QuizMode?
    private var refinement: Task<Void, Never>?
    private var idlePermissions = QuizPermissionReadiness(screenRecording: false, accessibility: false)
    private var idleModelsReady = false
    private var idleAuthenticated = false
    private var authenticationCheckedAt: Date?
    private var permissionsCheckedAt: Date?
    private var permissionRefresh: Task<Void, Never>?
    /// The host's own last complaint, so a failure names a cause instead of an
    /// exit status.
    private var lastHostDiagnostic: String?
    private lazy var flow = QuizFlowLog(directory: root)
    private lazy var readinessCache = QuizReadinessCache(directory: root)
    /// Mirror of `readiness.json`, so a status tick never touches the disk.
    private lazy var readiness: QuizReadiness = readinessCache.load()
    private var readinessRefresh: Task<Void, Never>?
    /// The council coming up for this session. Held rather than awaited, so the
    /// watcher can start while `agy` is still handshaking; `council(for:)` joins
    /// it before dispatching a question.
    private var poolPreparation: Task<Void, Never>?
    /// A council brought up while the preflight was on screen, before Start.
    private var warmBench: (pool: QuizAgyWorkerPool, profile: QuizModeProfile)?
    private var warmBenchPreparation: Task<Void, Never>?
    private var warmBenchExpiry: Task<Void, Never>?
    /// stdin of the live `quiz-watch` process, when one is running. Solve frames
    /// are requested over it rather than by spawning a second host.
    private var watchInput: FileHandle?
    /// Waiting for the frame the council will answer.
    private var pendingSolve: CheckedContinuation<QuizHostFrame, Never>?
    /// A solve frame fetched while the screen was still settling, before the
    /// question was accepted.
    private var speculativeFrame: Task<QuizHostFrame?, Never>?

    init(root: URL, hostExecutable: @escaping @Sendable () -> URL?,
         fileManager: FileManager = .default) {
        self.root = root.standardizedFileURL
        self.hostExecutable = hostExecutable
        self.fileManager = fileManager
        Self.cleanupWorkerRoots(root: self.root, fileManager: fileManager)
    }

    func snapshot() async -> QuizSessionSnapshot {
        if status.sessionID == nil {
            refreshIdlePermissionsIfStale()
            return QuizSessionSnapshot(
                state: .finished,
                screenRecordingReady: idlePermissions.screenRecording,
                accessibilityReady: idlePermissions.accessibility,
                agyAuthenticated: idleAuthenticated,
                modelsReady: idleModelsReady,
                workersReady: false,
                failure: status.failure)
        }
        return status
    }

    func listWindows() async throws -> [QuizWindowTarget] {
        guard let executable = hostExecutable() else { throw QuizControllerFailure.hostUnavailable }
        let data = try await QuizHostRunner.run(executable: executable, arguments: ["quiz-windows"])
        return try JSONDecoder().decode([QuizWindowTarget].self, from: data)
    }

    func listModels() async throws -> [String] {
        guard let binary = AgyLocator.locate(), AgyLocator.hasCredentials() else {
            idleModelsReady = false
            throw QuizControllerFailure.authenticationRequired
        }
        let models = try await QuizAgyModelCatalog.live(binary: binary)
        recordModels(models, binary: binary)
        // Listing is read-only; start/readiness validates authentication separately.
        return models
    }

    func requestPermissions() async -> QuizPermissionReadiness? {
        let readiness = try? await permissionReadiness(checkOnly: false)
        if let readiness { idlePermissions = readiness }
        return readiness
    }

    func start(_ proposed: QuizSessionConfiguration) async throws -> QuizSessionSnapshot {
        let began = Date()
        await flow.record("start.begin")
        guard status.sessionID == nil else { throw QuizControllerFailure.alreadyRunning }
        try QuizContractValidation.validate(proposed)
        guard let executable = hostExecutable() else { throw QuizControllerFailure.hostUnavailable }
        guard AgyLocator.hasCredentials(), let binary = AgyLocator.locate() else {
            throw QuizControllerFailure.authenticationRequired
        }
        await flow.record("start.locate")

        // Three unrelated questions, previously asked one after another: is the
        // screen readable, what can this `agy` run, and is the archive open.
        // Only the first gates the capture probe below; the rest merely has to be
        // answered before the session is declared started.
        let permissionCheck = Task { try await self.permissionReadiness(checkOnly: true) }
        let catalogue = Task { try await self.readinessModels(binary: binary) }
        let opening = Task.detached(priority: .userInitiated) { [root] in
            try Self.makeStore(root: root)
        }

        let permissions = try await permissionCheck.value
        guard permissions.screenRecording, permissions.accessibility else {
            opening.cancel()
            throw QuizControllerFailure.permissionsRequired
        }
        idlePermissions = permissions
        await flow.record("start.permissions")

        let models = try await catalogue.value
        let requested = proposed.referencedModelIDs
        guard requested.isSubset(of: Set(models)) else {
            opening.cancel()
            throw QuizControllerFailure.missingModels(Array(requested.subtracting(models)).sorted())
        }
        await flow.record("start.models")
        guard await readinessAuthenticated(binary: binary, models: models) else {
            opening.cancel()
            throw QuizControllerFailure.authenticationRequired
        }
        await flow.record("start.auth")

        configuration = proposed
        status = QuizSessionSnapshot(
            sessionID: proposed.sessionID, state: .starting, target: proposed.target,
            screenRecordingReady: true, accessibilityReady: true, agyAuthenticated: true,
            modelsReady: true, workersReady: false)
        let store: QuizStore
        do {
            store = adopt(store: try await opening.value)
            // A probe, not a solve frame. This only has to prove the window is
            // still there, and `.solve` — which is what omitting `detail` meant —
            // spent a JPEG encode, two accurate OCR passes and a multi-megabyte
            // pipe payload on a frame that is decoded and thrown away.
            async let calibrating = store.calibrationSamples()
            _ = try await capture(target: proposed.target, executable: executable,
                                  resolution: proposed.effectiveCaptureResolution,
                                  detail: .probe)
            guard configuration?.sessionID == proposed.sessionID else {
                throw QuizControllerFailure.startupCancelled
            }
            await flow.record("start.captureProbe")
            try await store.begin(proposed)
            calibration = QuizCalibrationBuilder.build(from: (try? await calibrating) ?? [])
            guard configuration?.sessionID == proposed.sessionID else {
                throw QuizControllerFailure.startupCancelled
            }
        } catch {
            if configuration?.sessionID == proposed.sessionID {
                configuration = nil
                status = QuizSessionSnapshot(
                    state: .failed, screenRecordingReady: true, accessibilityReady: true,
                    agyAuthenticated: true, modelsReady: true, workersReady: false,
                    failure: "Quiz startup failed: \(error.localizedDescription)")
            }
            throw error
        }
        await flow.record("start.store")
        status = QuizSessionSnapshot(
            sessionID: proposed.sessionID, state: .preparingWorkers, target: proposed.target,
            screenRecordingReady: true, accessibilityReady: true, agyAuthenticated: true,
            modelsReady: true, workersReady: false)

        agyBinary = binary
        // Only the nominated mode's council is warmed. Warming every mode would
        // mean holding one ~190 MB `agy` child per voter per mode resident; the
        // rest are spawned when a question of their mode first appears, which
        // overlaps the dwell and the solve-frame fetch.
        let warm = proposed.effectiveWarmMode
        let warmProfile = proposed.profile(for: warm)
        let adopted = takeWarmBench(matching: warmProfile)
        if adopted == nil { await tearDownWarmBench() }
        await flow.record("start.bench", ["source": adopted == nil ? "fresh" : "warm"])
        let pool = try adopted?.pool ?? makePool(for: warmProfile)
        let warming = adopted?.preparation
        self.pool = pool
        warmedMode = warm
        warmedProfile = warmProfile
        // Bringing the council up no longer gates the watcher. Every `agy` child
        // spends seconds handshaking with Google before it can answer anything,
        // and nothing about capturing the screen needs it — so the dwell on the
        // first question is paid concurrently with the spawn rather than after
        // it. `council(for:)` joins this task before dispatching, so a question
        // can never outrun the bench.
        poolPreparation = Task { [weak self] in
            // Join a bench the preflight already started rather than racing it.
            // `prepare()` is idempotent, so the call below is free when the warm
            // one succeeded and a retry for any slot where it did not.
            await warming?.value
            do { try await pool.prepare() } catch {
                await self?.notePoolFailure(sessionID: proposed.sessionID)
                return
            }
            await self?.notePoolReady(sessionID: proposed.sessionID)
        }
        status = QuizSessionSnapshot(
            sessionID: proposed.sessionID, state: .watching, target: proposed.target,
            screenRecordingReady: true, accessibilityReady: true, agyAuthenticated: true,
            modelsReady: true, workersReady: false)
        try await store.update(sessionID: proposed.sessionID, state: .watching)
        startWatcher()
        await flow.record("start.watching",
                          ["totalMs": "\(Int(Date().timeIntervalSince(began) * 1_000))"])
        return status
    }

    /// The council has finished coming up. Only a status field changes: the
    /// session has been watching since `start()` returned.
    private func notePoolReady(sessionID: String) async {
        poolPreparation = nil
        guard configuration?.sessionID == sessionID, status.sessionID == sessionID else { return }
        status = replacing(workersReady: true)
        await flow.record("start.poolReady")
    }

    /// A council that never came up is a dead session, and it has to say so.
    ///
    /// This used to be a `throw` out of `start()`, which the panel rendered as
    /// "Could not prepare reasoners". The session is already watching by the time
    /// this can happen now, so it ends the session instead of failing the launch.
    private func notePoolFailure(sessionID: String) async {
        poolPreparation = nil
        guard configuration?.sessionID == sessionID else { return }
        await flow.record("start.poolFailed")
        await stop(failure: "Could not prepare reasoners")
    }

    /// Waits for a council that is still spawning, if one is.
    private func joinPoolPreparation() async {
        guard let poolPreparation else { return }
        _ = await poolPreparation.value
        self.poolPreparation = nil
    }

    /// Brings a council up before there is a session.
    ///
    /// Called when the preflight has a target chosen and nothing standing in the
    /// way, which is typically several seconds before Start is pressed — and an
    /// `agy` child spends most of that spawning. Silent by design: warming is an
    /// optimisation, so every reason not to is a reason to do nothing rather than
    /// to report something the reader did not ask for. Start still checks
    /// everything itself.
    func warm(_ request: QuizWarmRequest) async {
        guard status.sessionID == nil else { return }
        guard (try? QuizContractValidation.validate(request)) != nil else { return }
        guard AgyLocator.hasCredentials(), let binary = AgyLocator.locate() else { return }
        // Only on a machine that has already proved it can answer. Warming
        // against unknown permissions or an unproven credential would spend
        // several ~190 MB processes on failing.
        guard idlePermissions.screenRecording, idlePermissions.accessibility,
              readiness.matches(binary: binary), readiness.authenticated,
              !readiness.models.isEmpty else { return }
        var wanted = Set(request.profile.voters.map(\.modelID))
        if let arbiter = request.profile.arbiter { wanted.insert(arbiter.modelID) }
        if let refiner = request.profile.refiner { wanted.insert(refiner.modelID) }
        guard wanted.isSubset(of: Set(readiness.models)) else { return }

        if warmBench?.profile == request.profile {
            scheduleWarmBenchExpiry()
            return
        }
        await tearDownWarmBench()
        agyBinary = binary
        guard let pool = try? makePool(for: request.profile) else { return }
        warmBench = (pool, request.profile)
        await flow.record("warm.begin", ["mode": request.mode.rawValue,
                                         "voters": "\(request.profile.voters.count)"])
        warmBenchPreparation = Task { [weak self] in
            try? await pool.prepare()
            await self?.noteWarmBenchReady()
        }
        scheduleWarmBenchExpiry()
    }

    func cancelWarm() async {
        await tearDownWarmBench()
    }

    /// How long a bench nobody has started may hold its processes.
    private static let warmBenchLifetime: TimeInterval = 120

    private func noteWarmBenchReady() async {
        guard warmBench != nil else { return }
        await flow.record("warm.ready")
    }

    private func scheduleWarmBenchExpiry() {
        warmBenchExpiry?.cancel()
        warmBenchExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.warmBenchLifetime))
            guard !Task.isCancelled else { return }
            await self?.expireWarmBench()
        }
    }

    /// A preflight left open is not a reason to hold a council for ever.
    private func expireWarmBench() async {
        guard status.sessionID == nil, warmBench != nil else { return }
        await flow.record("warm.expired")
        await tearDownWarmBench()
    }

    /// Hands the bench to a starting session, leaving its processes alive.
    private func takeWarmBench(matching profile: QuizModeProfile)
        -> (pool: QuizAgyWorkerPool, preparation: Task<Void, Never>?)? {
        guard let bench = warmBench, bench.profile == profile else { return nil }
        let preparation = warmBenchPreparation
        warmBench = nil
        warmBenchPreparation = nil
        warmBenchExpiry?.cancel(); warmBenchExpiry = nil
        return (bench.pool, preparation)
    }

    private func tearDownWarmBench() async {
        warmBenchExpiry?.cancel(); warmBenchExpiry = nil
        warmBenchPreparation?.cancel(); warmBenchPreparation = nil
        guard let bench = warmBench else { return }
        warmBench = nil
        await flow.record("warm.released")
        // Tearing a council down kills processes and waits on them, and nobody
        // here is waiting for that.
        Task.detached { await bench.pool.stop() }
    }

    func send(_ command: QuizCommand) async throws -> QuizSessionSnapshot {
        guard let configuration else { throw QuizControllerFailure.notRunning }
        try QuizContractValidation.validate(command, activeSessionID: configuration.sessionID)
        switch command.command {
        case .stop:
            await stop(failure: nil)
        case .pause:
            watcher?.cancel(); watcher = nil
            await pool?.cancelActive()
            solver?.cancel(); solver = nil
            // Remember that this question never got an answer. Without it,
            // resuming left `currentStableFrame` matching the unchanged screen,
            // so `observe` short-circuited and the question was never re-asked —
            // the session sat in `.watching` until the user scrolled.
            pausedQuestionPending = currentQuestion != nil && status.answer == nil
            status = replacing(state: .paused)
            try? await store?.update(sessionID: configuration.sessionID, state: .paused)
        case .resume:
            captureFailures = 0
            status = replacing(state: .watching, failure: .clear)
            try? await store?.update(sessionID: configuration.sessionID, state: .watching)
            if pausedQuestionPending, currentQuestion != nil, !collector.frames.isEmpty {
                pausedQuestionPending = false
                let stableAt = collector.frames.last?.capturedAt ?? Date()
                await beginSolve(stableAt: stableAt, persistFrames: false)
            } else if pausedQuestionPending {
                // Nothing left to re-ask from, so let the watcher rediscover the
                // screen rather than treat it as already seen.
                pausedQuestionPending = false
                detector.resetForRetarget()
            }
            startWatcher()
        case .retarget:
            guard let target = command.target, let executable = hostExecutable() else {
                throw QuizControllerFailure.invalidTarget
            }
            _ = try await capture(target: target, executable: executable,
                                  resolution: configuration.effectiveCaptureResolution,
                                  detail: .probe)
            await cancelQuestion()
            clearCache()
            captureFailures = 0
            self.configuration = QuizSessionConfiguration(
                sessionID: configuration.sessionID, target: target,
                eventID: configuration.eventID, eventLabel: configuration.eventLabel,
                context: configuration.context, excludedContextIDs: configuration.excludedContextIDs,
                voters: configuration.voters, arbiter: configuration.arbiter,
                captureResolution: configuration.captureResolution)
            status = replacing(state: .watching, target: target, answer: .clear, failure: .clear)
        case .scrollUp, .scrollDown:
            guard let executable = hostExecutable() else { throw QuizControllerFailure.hostUnavailable }
            let hostCommand = QuizCommand(sessionID: configuration.sessionID,
                                          command: command.command, target: configuration.target)
            let input = try JSONEncoder().encode(hostCommand)
            _ = try await QuizHostRunner.run(executable: executable,
                                             arguments: ["quiz-scroll"], input: input)
            detector.markScrollRequested()
            status = replacing(state: .collecting, scrollPrompt: .clear)
        }
        return status
    }

    func history() async -> [QuizHistorySession] {
        (try? await resolveStore().history()) ?? []
    }

    func reveal(captureID: String) async -> Data {
        (try? await resolveStore().reveal(captureID: captureID)) ?? Data()
    }

    func grade(answerID: String, grade: QuizAnswerGrade) async throws {
        let store = try resolveStore()
        try await store.grade(answerID: answerID, grade)
        // Fold the new sample in immediately, so grading during a session
        // affects the answers that follow it.
        calibration = QuizCalibrationBuilder.build(
            from: (try? await store.calibrationSamples()) ?? [])
    }

    func delete(sessionID: String) async throws {
        guard configuration?.sessionID != sessionID else { throw QuizControllerFailure.alreadyRunning }
        try await resolveStore().delete(sessionID: sessionID)
    }

    func deleteAll() async throws {
        guard configuration == nil else { throw QuizControllerFailure.alreadyRunning }
        if let store { _ = try await store.deleteAll() }
        store = nil
        _ = try QuizHistoryKey.rotate()
        store = try resolveStore()
    }

    func shutdown() async {
        permissionRefresh?.cancel(); permissionRefresh = nil
        readinessRefresh?.cancel(); readinessRefresh = nil
        await tearDownWarmBench()
        await stop(failure: "engine_stopped")
    }

    private func startWatcher() {
        watcher?.cancel()
        watcher = Task { [weak self] in
            // One long-lived host process streaming frames. Falls back to the
            // spawn-per-frame poll if the stream cannot be opened at all, so a
            // host that predates `quiz-watch` still works.
            let streamed = await self?.runFrameStream() ?? false
            guard !streamed, !Task.isCancelled else { return }
            await self?.flow.record("watch.fallbackToPolling")
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// Reads NDJSON frames from a single `quiz-watch` process.
    ///
    /// Returns true once the stream has been running, so the caller does not then
    /// fall back to polling; false means it never started.
    private func runFrameStream() async -> Bool {
        guard let configuration, let executable = hostExecutable() else { return false }
        let target = configuration.target
        let resolution = configuration.effectiveCaptureResolution
        guard let input = try? JSONEncoder().encode(target) else { return false }

        let process = Process()
        let stdout = Pipe(); let stdin = Pipe(); let stderr = Pipe()
        process.executableURL = executable
        process.arguments = ["quiz-watch", "--resolution", resolution.rawValue,
                             "--interval-ms", "500"]
        process.standardOutput = stdout
        process.standardInput = stdin
        process.standardError = stderr
        do { try process.run() }
        catch {
            await flow.record("watch.spawnFailed", ["error": error.localizedDescription])
            return false
        }
        await flow.record("watch.spawned", ["resolution": resolution.rawValue])
        defer {
            if process.isRunning { process.terminate() }
        }
        // Newline-terminated: the host reads one line for the target and leaves
        // the pipe open for solve requests.
        try? stdin.fileHandleForWriting.write(contentsOf: input + Data("\n".utf8))
        watchInput = stdin.fileHandleForWriting
        defer {
            try? watchInput?.close()
            watchInput = nil
            resumeSolve(nil)
        }

        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var started = false
        var pending = Data()
        let handle = stdout.fileHandleForReading
        // A host that produces nothing must not take the session with it. Without
        // this, one bug in the watcher — a deadlock reading its own stdin, say —
        // hung the read forever, so the fallback poll never ran and Quiz showed
        // nothing at all rather than degrading.
        let startup = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.watchStartupTimeout))
            await self?.abandonSilentWatcher(process)
        }
        // Drained as it arrives: the host's own account of why it is quiet is
        // useless if it is only read after the process has been killed.
        let errors = stderr.fileHandleForReading
        let diagnostics = Task { [weak self] in
            while !Task.isCancelled {
                let chunk = await Self.read(errors)
                guard !chunk.isEmpty else { return }
                let text = String(decoding: chunk, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                await self?.noteHostDiagnostic(text)
            }
        }
        defer { diagnostics.cancel() }
        defer { startup.cancel() }
        while !Task.isCancelled {
            // The read blocks, so it runs off the cooperative pool.
            let chunk = await Self.read(handle)
            guard !chunk.isEmpty else { break }
            if !started { startup.cancel() }
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[..<newline]
                pending.removeSubrange(...newline)
                guard !line.isEmpty,
                      let frame = try? decoder.decode(QuizHostFrame.self, from: Data(line)),
                      frame.isBounded, frame.target.id == target.id else { continue }
                started = true
                captureFailures = 0
                // A frame carrying a JPEG is one the engine asked for; a probe
                // never has one.
                if !frame.jpeg.isEmpty {
                    await flow.record("solveFrame.arrived", ["bytes": "\(frame.jpeg.count)"])
                    resumeSolve(frame)
                    continue
                }
                guard status.state != .paused else { continue }
                await observe(frame)
            }
        }
        if process.isRunning { process.terminate() }
        guard started else {
            // Never produced a usable frame: report why, using the host's own
            // diagnostics rather than a bare exit status.
            let detail = String(decoding: stderr.fileHandleForReading.availableData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !detail.isEmpty { lastHostDiagnostic = detail }
            await flow.record("watch.noFrames", ["stderr": String(detail.prefix(200))])
            return false
        }
        await flow.record("watch.streamEnded")
        // The stream ended while the session was still running: the window is
        // gone, or the host died. Treat it the way a failed capture is treated.
        if !Task.isCancelled, configuration.sessionID == self.configuration?.sessionID {
            await cancelQuestion()
            status = replacing(state: .paused,
                               failure: .set(lastHostDiagnostic.map { "\($0); Retarget required" }
                                             ?? "Target window unavailable; Retarget required"))
            try? await store?.update(sessionID: configuration.sessionID, state: .paused,
                                     failure: "target_lost")
        }
        return true
    }

    /// Asks the running watcher for the frame the council will answer, falling
    /// back to a one-shot capture when no watcher is up.
    ///
    /// The fallback is the path the probe/solve split originally used, and it
    /// spawns a whole second host per question. Over the open channel the host
    /// already has the image, so answering costs one analysis.
    private func requestSolveFrame(configuration: QuizSessionConfiguration)
    async -> QuizHostFrame? {
        await flow.record("solveFrame.requested",
                          ["over": watchInput == nil ? "spawn" : "stream"])
        guard let watchInput else {
            guard let executable = hostExecutable() else { return nil }
            return try? await capture(
                target: configuration.target, executable: executable,
                resolution: configuration.effectiveCaptureResolution, detail: .solve)
        }

        // Handing the continuation to another task to install created a race it
        // could not survive: if the deadline fired first, `resumeSolve` found
        // nothing pending, and the continuation was then stored with no one left
        // to resume it — so the question waited for ever and the panel sat on
        // "Reasoning…". The waiter is now registered *before* anything can
        // complete it, and every exit resumes exactly once.
        resumeSolve(nil)
        guard (try? watchInput.write(contentsOf: Data("{\"request\":\"solve\"}\n".utf8))) != nil
        else {
            await flow.record("solveFrame.writeFailed")
            return nil
        }
        let deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.solveFrameTimeout))
            guard !Task.isCancelled else { return }
            await self?.timeOutSolveFrame()
        }
        let frame = await withCheckedContinuation { (continuation: CheckedContinuation<QuizHostFrame, Never>) in
            pendingSolve = continuation
        }
        deadline.cancel()
        return frame.jpeg.isEmpty ? nil : frame
    }

    private static let solveFrameTimeout: TimeInterval = 12

    /// How long a `quiz-watch` process gets to produce its first frame before it
    /// is treated as broken and the spawn-per-frame poll takes over.
    /// A stream that has not produced a frame by now is not going to.
    ///
    /// Twenty seconds of it, and on this machine it expires every single time:
    /// `quiz-watch` reports the stream started and then delivers nothing, so a
    /// session spent its first twenty seconds watching nothing at all before
    /// polling took over. Three is long enough for a stream that works and short
    /// enough that the fallback is not the whole start.
    private static let watchStartupTimeout: TimeInterval = 3

    private func noteHostDiagnostic(_ text: String) async {
        lastHostDiagnostic = text
        await flow.record("watch.host", ["said": String(text.prefix(240))])
    }

    private func abandonSilentWatcher(_ process: Process) {
        guard process.isRunning else { return }
        lastHostDiagnostic = "Capture stream did not start"
        // Terminating closes the pipe, which unblocks the read and lets
        // `runFrameStream` return false so polling takes over.
        process.terminate()
    }

    /// Starts fetching the frame this settling screen will need, if it turns out
    /// to be a question. Fire and forget, and at most one at a time.
    private func speculateSolveFrame(session: QuizSessionConfiguration) {
        guard session.speculativeSpawn else { return }
        // Only over the live stream, where a solve frame costs an analysis of an
        // image the host already holds. When `quiz-watch` has fallen back to
        // spawn-per-frame polling, the same request is a whole `CallaCallHost`
        // process doing a JPEG encode and two accurate OCR passes — and it would
        // be started on every settling frame, competing with the poll that is
        // already spawning one twice a second. Speculating there costs more than
        // it saves.
        guard watchInput != nil else { return }
        guard speculativeFrame == nil, pendingSolve == nil else { return }
        speculativeFrame = Task { [weak self] in
            await self?.requestSolveFrame(configuration: session) ?? nil
        }
    }

    private func takeSpeculativeFrame() async -> QuizHostFrame? {
        guard let speculativeFrame else { return nil }
        self.speculativeFrame = nil
        return await speculativeFrame.value
    }

    /// Lets go of a speculative fetch without waiting for it.
    ///
    /// Deliberately not awaited: `requestSolveFrame` parks on a continuation that
    /// only the host or the 12-second deadline resumes, so waiting here would
    /// make cancelling a question take as long as the frame it no longer wants.
    /// The next real request resumes any waiter it finds before installing its
    /// own, so an abandoned one is released rather than stranded.
    private func discardSpeculativeFrame() {
        speculativeFrame?.cancel()
        speculativeFrame = nil
    }

    private func timeOutSolveFrame() async {
        guard pendingSolve != nil else { return }
        await flow.record("solveFrame.timedOut")
        resumeSolve(nil)
    }

    private func resumeSolve(_ frame: QuizHostFrame?) {
        guard let pendingSolve else { return }
        self.pendingSolve = nil
        pendingSolve.resume(returning: frame ?? Self.emptyFrame(for: configuration?.target))
    }

    /// A frame that carries nothing, used to release a waiter that will never be
    /// answered. The caller treats an empty JPEG as "no solve frame".
    private static func emptyFrame(for target: QuizWindowTarget?) -> QuizHostFrame {
        QuizHostFrame(
            target: target ?? QuizWindowTarget(
                processID: 1, windowID: 1, bundleID: "com.invalid.none",
                applicationName: "", windowTitle: "", pixelWidth: 1, pixelHeight: 1),
            captureGeneration: 0, width: 0, height: 0, jpeg: Data(),
            normalizedOCR: "", tileHashes: [], visualHash: 0, anchors: [])
    }

    private nonisolated static func read(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: handle.availableData)
            }
        }
    }

    private func poll() async {
        guard let configuration, status.state != .paused, let executable = hostExecutable() else { return }
        do {
            let frame = try await capture(target: configuration.target, executable: executable,
                                          resolution: configuration.effectiveCaptureResolution,
                                          detail: .probe)
            captureFailures = 0
            await observe(frame)
        } catch {
            // A capture can fail for reasons that have nothing to do with the
            // window going away: a host timeout, a decode blip, a frame arriving
            // mid-resize. Treating the first one as fatal ended sessions that
            // would have recovered on the next tick.
            captureFailures += 1
            guard captureFailures >= Self.captureFailureTolerance else { return }
            watcher?.cancel(); watcher = nil
            await cancelQuestion()
            status = replacing(state: .paused,
                               failure: .set(Self.targetLostMessage(error)))
            try? await store?.update(sessionID: configuration.sessionID, state: .paused,
                                     failure: "target_lost")
        }
    }

    private func capture(target: QuizWindowTarget, executable: URL,
                         resolution: QuizCaptureResolution,
                         detail: QuizCaptureDetail = .solve) async throws -> QuizHostFrame {
        captureGeneration += 1
        let input = try JSONEncoder().encode(target)
        let data = try await QuizHostRunner.run(
            executable: executable,
            arguments: ["quiz-capture", "--generation", "\(captureGeneration)",
                        "--resolution", resolution.rawValue,
                        "--detail", detail.rawValue],
            input: input, timeout: 15)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let frame = try decoder.decode(QuizHostFrame.self, from: data)
        guard frame.isBounded, frame.target.id == target.id else { throw QuizControllerFailure.invalidTarget }
        return frame
    }

    private func observe(_ frame: QuizHostFrame) async {
        // `poll` guards this too, but it binds a local copy before awaiting the
        // capture. The actor is reentrant across that suspension, so `stop()`
        // can null the property before this runs — which is how three
        // `configuration!` force unwraps here could crash the XPC service.
        guard let configuration else { return }
        let observation = QuizFrameObservation(
            capturedAt: frame.capturedAt, captureGeneration: frame.captureGeneration,
            normalizedOCR: frame.normalizedOCR, tileHashes: frame.tileHashes,
            visualHash: frame.visualHash, anchors: frame.anchors)

        let verdict = detector.observe(observation)
        switch verdict {
        case .stabilizing:
            // The screen is settling on something new. The council for its mode
            // can start spawning now rather than after the dwell — that spawn is
            // otherwise the first thing on the answer's critical path, and it is
            // the cost of making councils per-mode in the first place.
            await flow.record("frame.stabilizing", ["capture": "\(frame.captureGeneration)"])
            prewarmCouncil(for: observation, session: configuration)
            speculateSolveFrame(session: configuration)
            return
        case .ignoredAnimation:
            await flow.record("frame.ignoredAnimation")
            return
        case .unchanged:
            return
        case .continuation(let question):
            guard collector.frames.count < QuizContract.maximumViewports else { return }
            guard let solved = await solveFrame(matching: frame, configuration: configuration)
            else {
                // No frame, so nothing to ask about. Say so in the log and hand
                // the notch back rather than leaving the question in limbo.
                await flow.record("question.abandonedNoFrame")
                status = replacing(state: .watching)
                return
            }
            currentQuestion = question
            let capture = QuizCaptureFrame(
                sessionID: configuration.sessionID, questionID: question.questionID,
                questionGeneration: question.generation,
                captureGeneration: solved.captureGeneration,
                viewportIndex: collector.frames.count, capturedAt: solved.capturedAt,
                width: solved.width, height: solved.height, jpeg: solved.jpeg,
                normalizedOCR: solved.normalizedOCR, fingerprint: question.fingerprint, headlines: solved.headlines)
            await beginSolve(adding: capture, stableAt: frame.capturedAt)
        case .newQuestion(let question):
            await flow.beginQuestion(question.questionID, generation: question.generation)
            // A cheap local gate first, so a settings screen or a results page
            // never costs three model calls.
            switch QuizQuestionGate.classify(ocr: frame.normalizedOCR, anchors: frame.anchors) {
            case .notQuestion:
                // A rejection with no evidence is unarguable, and this is the one
                // decision that can silently end a question's life before any
                // model sees it. The excerpt is bounded and stays in the local
                // 0600 flow log, beside OCR the archive already keeps.
                await flow.record("gate.notQuestion", [
                    "words": "\(frame.normalizedOCR.split(separator: " ").count)",
                    "anchors": frame.anchors.prefix(3).joined(separator: " / "),
                    "ocr": String(frame.normalizedOCR.prefix(160)),
                ])
                await cancelQuestion(resetDetector: false)
                // Keep whatever is on screen: scrolling past a page of prose
                // should not take the last answer with it.
                status = replacing(state: .watching, scrollPrompt: .clear)
                return
            case .question, .uncertain:
                break
            }
            guard let solved = await solveFrame(matching: frame, configuration: configuration)
            else {
                // No frame, so nothing to ask about. Say so in the log and hand
                // the notch back rather than leaving the question in limbo.
                await flow.record("question.abandonedNoFrame")
                status = replacing(state: .watching)
                return
            }
            currentQuestion = question
            let capture = QuizCaptureFrame(
                sessionID: configuration.sessionID, questionID: question.questionID,
                questionGeneration: question.generation,
                captureGeneration: solved.captureGeneration,
                viewportIndex: 0, capturedAt: solved.capturedAt,
                width: solved.width, height: solved.height, jpeg: solved.jpeg,
                normalizedOCR: solved.normalizedOCR, fingerprint: question.fingerprint, headlines: solved.headlines)
            // Already answered this session? Then answer it again for free.
            // Keyed on the question's words rather than on the frame's pixels,
            // so scrolling back to it, or the page redrawing it, is a hit.
            if let cached = cache[question.answerKey] {
                collector = QuizViewportCollector()
                try? collector.append(capture)
                do { _ = try await store?.persist(capture) }
                catch {
                    status = replacing(state: .failed,
                                       failure: .set("Capture encryption or commit failed"))
                    return
                }
                let answer = QuizFinalAnswer(
                    sessionID: configuration.sessionID, questionID: question.questionID,
                    questionGeneration: question.generation, kind: cached.kind,
                    answer: cached.answer, confidence: cached.confidence,
                    verified: cached.verified)
                recordAnswer(answer)
                status = replacing(state: .answered, answer: .set(answer), failure: .clear)
                try? await store?.record(final: answer)
                return
            }
            await beginSolve(replacingWith: capture, stableAt: frame.capturedAt)
        }
    }

    /// A probe carries no JPEG and only coarse OCR, so the one frame per question
    /// that actually reaches the council is captured here — after the screen has
    /// already been judged stable, and once, rather than on every poll.
    ///
    /// If the screen moved between the probe and this capture, the question that
    /// was accepted is no longer what is on screen. Answering the newer frame
    /// under the older frame's identity is how a stale answer gets published, so
    /// this hands the new frame back to candidate tracking instead.
    private func solveFrame(matching probe: QuizHostFrame,
                            configuration: QuizSessionConfiguration) async -> QuizHostFrame? {
        // The dwell is dead time that the frame fetch can be hidden inside.
        //
        // A question is only accepted after two matching frames 0.75s apart, and
        // the first of them already looks exactly like the one the council will
        // be shown. So the fetch starts at `.stabilizing` and is usually already
        // in hand here — a whole JPEG encode and two accurate OCR passes off the
        // answer's critical path. It is only *used* if the screen has not moved
        // since, which is the same check the fresh path makes below, so nothing
        // rests on the guess being right.
        if let speculative = await takeSpeculativeFrame(), !speculative.jpeg.isEmpty,
           Self.framesVisuallyStable(probe, speculative) {
            await flow.record("solveFrame.speculativeHit")
            return speculative
        }
        guard let solved = await requestSolveFrame(configuration: configuration) else {
            return nil
        }
        guard Self.framesVisuallyStable(probe, solved) else {
            // The screen moved between accepting the question and capturing the
            // frame to answer. Make the detector settle again rather than answer
            // a frame the reader has already scrolled past.
            detector.resetForRetarget()
            return nil
        }
        return solved
    }

    private func beginSolve(replacingWith frame: QuizCaptureFrame? = nil,
                            adding: QuizCaptureFrame? = nil, stableAt: Date,
                            persistFrames: Bool = true) async {
        await pool?.cancelActive()
        solver?.cancel()
        if let frame {
            collector = QuizViewportCollector()
            try? collector.append(frame)
        }
        // The collector rejects a frame belonging to a different question rather
        // than appending it to the previous question's viewports.
        if let adding { try? collector.append(adding) }
        guard let configuration, let question = currentQuestion else { return }
        let questionID = question.questionID
        // Sealing a capture is an AES-GCM pass over up to 3 MiB plus a file write
        // plus a SQLite transaction, and it used to run to completion before the
        // first voter was dispatched. It now runs alongside them.
        //
        // The invariant it was protecting still holds: `publish` waits on this
        // before an answer is shown, so no answer ever reaches the reader without
        // its capture committed. Only the waiting moved.
        let pending = persistFrames
            ? Array(collector.frames.suffix(frame == nil ? 1 : collector.frames.count))
            : []
        persistence?.cancel()
        persistence = pending.isEmpty ? nil : Task { [store] in
            for frame in pending {
                _ = try await store?.persist(frame)
            }
        }
        questionStartedAt = stableAt
        status = replacing(state: .solving, answer: .clear, scrollPrompt: .clear, failure: .clear)
        try? await store?.update(sessionID: configuration.sessionID, state: .solving)
        let generation = question.generation
        let frames = collector.frames
        solver = Task { [weak self] in
            await self?.solve(session: configuration, questionID: questionID,
                              generation: generation, frames: frames, stableAt: stableAt)
            // Every early return in `solve` used to leave the panel spinning on
            // `.solving` with nothing behind it — a council that could not be
            // spawned, a timeout, a guard that failed. The reader saw "Reasoning…"
            // for ever and read it as Quiz never having seen the question.
            await self?.failIfStillUnanswered(sessionID: configuration.sessionID,
                                              questionID: questionID, generation: generation)
        }
    }

    /// Directories alternate between two per slot, and the reason is that a
    /// slot's next child is spawned *while* the current one is still answering.
    ///
    /// With one directory per slot they overlap: the finishing child's cleanup
    /// deletes the conversation state out from under its live replacement, and
    /// the replacement's `prepareWorkspace` rewrites the settings and agent files
    /// under the running one. Two is enough, because a slot never has more than
    /// an active child and its warming successor at the same time — so the pair
    /// alternates, each child owns its directory outright, and every other
    /// question still reuses a HOME with `agy`'s caches already in it.
    private nonisolated static func factory(binary: String, workersRoot: URL,
                                            bench: String,
                                            turn: @escaping @Sendable (Int) -> Int)
    -> QuizAgyChildFactory {
        { slot, role, selection in
            let lane = turn(slot) % 2 == 0 ? "a" : "b"
            let workspace = workersRoot.appendingPathComponent("worker-\(bench)-\(slot)\(lane)")
            let home = workersRoot.appendingPathComponent("home-\(bench)-\(slot)\(lane)")
            let logs = workersRoot.appendingPathComponent("logs", isDirectory: true)
            try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            return try QuizAgyProcessChild(configuration: .init(
                binary: binary, workspace: workspace, isolatedHome: home,
                slot: slot, role: role, selection: selection,
                logFile: logs.appendingPathComponent("\(bench)-\(slot)\(lane).log")))
        }
    }

    /// A council, and the directories its slots will keep.
    ///
    /// One directory per slot *per bench*, rather than per child. A child answers
    /// one question and is replaced, so per-child directories meant every child
    /// started against an empty HOME and paid `agy`'s cold handshake in full; per
    /// slot, a replacement reuses a warm one. It cannot be per slot *alone*,
    /// because `prewarmCouncil` builds a second council while the resident one is
    /// still answering, and both would write into `worker-0` at once.
    private func makePool(for profile: QuizModeProfile) throws -> QuizAgyWorkerPool {
        guard let agyBinary else { throw QuizControllerFailure.hostUnavailable }
        let bench = String(UUID().uuidString.lowercased().prefix(8))
        let lanes = QuizWorkerLanes()
        let factory = Self.factory(
            binary: agyBinary,
            workersRoot: root.appendingPathComponent("workers", isDirectory: true),
            bench: bench,
            turn: { lanes.next(slot: $0) })
        return try QuizAgyWorkerPool(voters: profile.voters, arbiter: profile.arbiter,
                                     refiner: profile.refiner, factory: factory)
    }

    /// Starts spawning the council a settling screen is going to need.
    ///
    /// Fire and forget: if the screen turns out not to be a question, or turns
    /// into a different kind of one, the worst case is a warm council that goes
    /// unused until the session ends. Guarded so it runs once per candidate.
    private func prewarmCouncil(for observation: QuizFrameObservation,
                                session: QuizSessionConfiguration) {
        guard session.speculativeSpawn else { return }
        // An unreadable frame classifies as `.image`, which is the Visual mode,
        // which is a different council. A screen part-way through drawing reads
        // as unreadable, so acting on it spawned a whole Visual bench and tore
        // down the warm one — and then the text arrived a second later and it all
        // happened again in reverse. A frame with nothing on it yet is not
        // evidence of anything.
        guard !observation.normalizedOCR.isEmpty else { return }
        switch QuizQuestionGate.classify(ocr: observation.normalizedOCR,
                                         anchors: observation.anchors) {
        case .notQuestion: return
        case .question, .uncertain: break
        }
        let kind = QuizKindClassifier.classify(ocr: observation.normalizedOCR)
        let mode = QuizMode.mode(for: kind)
        guard mode != warmedMode, mode != prewarmingMode, prewarm == nil else { return }
        prewarmingMode = mode
        prewarm = Task { [weak self] in
            _ = await self?.council(for: kind, session: session)
            await self?.finishPrewarm()
        }
    }

    /// Backstop for a question whose solve returned without publishing anything.
    private func failIfStillUnanswered(sessionID: String, questionID: String,
                                       generation: Int) async {
        guard accepts(sessionID: sessionID, questionID: questionID, generation: generation) else {
            return
        }
        guard status.answer?.questionID != questionID else { return }
        guard [.solving, .arbitrating, .retrying].contains(status.state) else { return }
        await flow.record("answer.abandoned", ["reason": lastHostDiagnostic ?? "unknown"])
        await publishFailure(kind: .unknown, sessionID: sessionID, questionID: questionID,
                             generation: generation,
                             summary: lastHostDiagnostic)
    }

    /// How long a council gets to come up before the question gives up on it.
    private static let councilSpawnTimeout: TimeInterval = 45

    /// Runs `work`, reporting whether it finished inside the budget.
    private nonisolated static func withTimeout(
        seconds: TimeInterval, _ work: @escaping @Sendable () async -> Void
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await work(); return true }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    private func finishPrewarm() {
        prewarm = nil
        prewarmingMode = nil
    }

    /// The council for this question's mode, reusing the resident one when the
    /// mode matches and building a fresh one when it does not.
    ///
    /// Replacing the pool tears the previous mode's children down, so a session
    /// that alternates modes pays a spawn each time it switches. That is the
    /// trade for bounded memory, and `warmMode` is what a user sets to make the
    /// common case free.
    private func council(for kind: QuizQuestionKind,
                         session: QuizSessionConfiguration) async -> (QuizAgyWorkerPool,
                                                                      QuizModeProfile)? {
        let mode = QuizMode.mode(for: kind)
        let profile = session.profile(for: mode)
        // Modes are not the unit that matters — councils are. Two modes
        // configured the same way share a bench, so a question whose kind flips
        // between, say, numeric and singleChoice does not tear down four `agy`
        // children and spawn four more for no change at all.
        if let pool, profile == warmedProfile {
            await joinPoolPreparation()
            await flow.record("council.reused", ["mode": mode.rawValue])
            return (pool, profile)
        }
        if mode == warmedMode, let pool {
            await joinPoolPreparation()
            await flow.record("council.reused", ["mode": mode.rawValue])
            return (pool, profile)
        }
        // A bench still coming up for the wrong mode is about to be torn down;
        // nobody should wait for it to finish being built first.
        poolPreparation?.cancel()
        poolPreparation = nil
        await flow.record("council.spawning",
                          ["mode": mode.rawValue, "voters": "\(profile.voters.count)"])
        guard let replacement = try? makePool(for: profile) else {
            // Fall back to whatever is already resident rather than failing the
            // question outright.
            return pool.map { ($0, session.profile(for: warmedMode ?? .fallback)) }
        }
        // Tearing the previous council down must not be on this question's path:
        // it kills processes and waits on them, and none of that is work the
        // reader is waiting for.
        let previous = pool
        Task.detached { await previous?.stop() }
        pool = replacement
        warmedMode = mode
        warmedProfile = profile
        // Bounded, because bringing a council up means spawning `agy` children
        // and a spawn that never completes would otherwise wedge the question.
        let ready = await Self.withTimeout(seconds: Self.councilSpawnTimeout) {
            try? await replacement.prepare()
        }
        guard ready else {
            lastHostDiagnostic = "Reasoners did not start in time"
            await flow.record("council.spawnTimedOut", ["mode": mode.rawValue])
            return nil
        }
        await flow.record("council.ready", ["mode": mode.rawValue])
        return (replacement, profile)
    }

    /// Waits for the question's captures to be committed.
    ///
    /// Returns false when the seal or the write failed, which is a hard stop: an
    /// answer with no retained capture would break the promise the privacy copy
    /// makes about what Quiz keeps.
    private func awaitPersistence() async -> Bool {
        guard let persistence else { return true }
        do {
            try await persistence.value
            self.persistence = nil
            return true
        } catch {
            self.persistence = nil
            status = replacing(state: .failed,
                               failure: .set("Capture encryption or commit failed"))
            return false
        }
    }

    private func solve(session: QuizSessionConfiguration, questionID: String, generation: Int,
                       frames: [QuizCaptureFrame], stableAt: Date) async {
        let kind = QuizKindClassifier.classify(
            ocr: frames.map(\.normalizedOCR).joined(separator: "\n"))
        // The council is chosen by the question's mode, so a multiple choice can
        // be answered by one fast voter while a code exercise gets a deep bench.
        guard let (pool, profile) = await council(for: kind, session: session) else { return }
        guard accepts(sessionID: session.sessionID, questionID: questionID,
                      generation: generation) else { return }
        let context = session.context.filter { !session.excludedContextIDs.contains($0.id) }
            .map { "[\($0.scope.rawValue):\($0.title) revision=\($0.revision)]\n\($0.text)" }
            .joined(separator: "\n\n")
        let request = QuizAgyRequest(
            sessionID: session.sessionID, questionID: questionID,
            questionGeneration: generation, questionKind: kind,
            frozenContext: context,
            ocr: QuizViewportOCR.merged(frames.map(\.normalizedOCR)),
            viewportJPEGs: frames.map(\.jpeg))
        await flow.record("solve.begin", ["kind": kind.rawValue,
                                         "mode": QuizMode.mode(for: kind).rawValue,
                                         "viewports": "\(frames.count)"])
        let summary = QuizQuestionSummary.summarize(
            headlines: frames.compactMap(\.headlines).first,
            fallback: frames.first?.normalizedOCR ?? "", kind: kind)
        // Recorded at detection, not at publication: `quiz_question.kind` was
        // only ever written when an answer arrived, so every question that was
        // superseded or rejected stayed 'unknown' in the archive and there was no
        // way to tell what the classifier had actually decided.
        try? await store?.note(questionID: questionID, kind: kind, summary: summary)
        let voterDeadline = stableAt.addingTimeInterval(90)
        let totalDeadline = stableAt.addingTimeInterval(120)
        guard voterDeadline.timeIntervalSinceNow > 0 else {
            await publishFailure(kind: kind, sessionID: session.sessionID,
                                 questionID: questionID, generation: generation,
                                 summary: summary)
            return
        }
        // A kind that voter unanimity can never settle used to wait for all three
        // voters and only then start the arbiter — two serial model round-trips
        // for every text, code, image or diagram question, and empty OCR is
        // classified `.image`, so a screenshot-only question always paid it.
        // Dispatching the arbiter alongside the voters removes the second hop
        // from the common case, and an arbiter that has not been shown the votes
        // reasons without being anchored by them.
        let arbiterRunsConcurrently = profile.hasArbiter
            && !QuizEnsembleResolver.canPublishWithoutArbiter(kind: kind)
        let concurrentArbiter: Task<QuizAgyWorkerResult?, Never>? = arbiterRunsConcurrently
            ? Task { [weak self] in
                await pool.runArbiterRecovering(request, deadline: totalDeadline) {
                    await self?.markRetrying(sessionID: session.sessionID,
                                             questionID: questionID, generation: generation)
                }
            }
            : nil

        // Consume the voters as they land rather than waiting for the group.
        //
        // Collecting them all meant a council always cost the time of its
        // slowest member, even when the outcome was settled long before — under
        // unanimity, the instant two voters disagree or one fails. `earlyDecision`
        // answers "can the outstanding voters still change this", and the moment
        // they cannot, the stragglers are cancelled.
        let voterCount = await pool.voterCount
        var slots = [QuizVoteSlot](repeating: .pending, count: voterCount)
        var valid = [QuizAgyWorkerResult?](repeating: nil, count: voterCount)
        var decision: QuizEnsembleDecision?

        for await item in pool.streamVoters(request, deadline: voterDeadline, onRetry: { [weak self] in
            await self?.markRetrying(sessionID: session.sessionID,
                                     questionID: questionID, generation: generation)
        }) {
            guard accepts(sessionID: session.sessionID, questionID: questionID,
                          generation: generation) else {
                concurrentArbiter?.cancel()
                return
            }
            guard slots.indices.contains(item.slot) else { continue }
            if let result = item.result,
               let accepted = await acceptVote(result, pool: pool, sessionID: session.sessionID,
                                               questionID: questionID, generation: generation) {
                valid[item.slot] = accepted
                slots[item.slot] = .returned(accepted.output)
                await flow.record("vote.accepted", ["slot": "\(item.slot)"])
            } else {
                slots[item.slot] = .failed
                await flow.record("vote.failed", ["slot": "\(item.slot)"])
            }
            if let settled = QuizCouncil.earlyDecision(
                slots: slots, kind: kind, strategy: profile.strategy,
                hasArbiter: profile.hasArbiter, calibration: calibration) {
                decision = settled
                break
            }
        }
        await pool.cancelActive()
        guard accepts(sessionID: session.sessionID, questionID: questionID, generation: generation) else {
            concurrentArbiter?.cancel()
            return
        }
        // The stream can end without settling when every voter failed.
        let resolved = decision ?? QuizCouncil.earlyDecision(
            slots: slots.map { $0.isPending ? .failed : $0 }, kind: kind,
            strategy: profile.strategy, hasArbiter: profile.hasArbiter,
            calibration: calibration) ?? .arbitrate

        await flow.record("decision", ["value": "\(resolved)"])
        switch resolved {
        case .publish(let answer, let confidence):
            concurrentArbiter?.cancel()
            if let published = await publish(
                answer: answer, confidence: confidence, kind: kind,
                sessionID: session.sessionID, questionID: questionID, generation: generation,
                summary: summary) {
                refine(session: session, profile: profile, request: request,
                       published: published, kind: kind, pool: pool)
            }
            return
        case .scroll(let sentinel):
            // The council has been shown a partial question, so whatever the
            // concurrent arbiter is deciding is about the wrong thing.
            concurrentArbiter?.cancel()
            let direction: QuizCommandKind = sentinel == .needsScrollUp ? .scrollUp : .scrollDown
            status = replacing(state: .collecting, answer: .clear, scrollPrompt: .set(direction))
            return
        case .notAQuestion:
            // Back to watching, but the answer already on screen stays. Clearing
            // it meant one screen the council did not recognise wiped the answer
            // the reader was still reading.
            concurrentArbiter?.cancel()
            status = replacing(state: .watching)
            return
        case .arbitrate:
            break
        }

        guard profile.hasArbiter else {
            // A mode set to run without an arbiter says so rather than inventing
            // a fourth opinion.
            concurrentArbiter?.cancel()
            await publishFailure(kind: kind, sessionID: session.sessionID,
                                 questionID: questionID, generation: generation,
                                 summary: summary)
            return
        }
        status = replacing(state: .arbitrating, answer: .clear)
        guard totalDeadline.timeIntervalSinceNow > 0 else {
            concurrentArbiter?.cancel()
            await publishFailure(kind: kind, sessionID: session.sessionID,
                                 questionID: questionID, generation: generation,
                                 summary: summary)
            return
        }
        let candidate: QuizAgyWorkerResult?
        if let concurrentArbiter {
            // Already running since before the voters returned; by now it has
            // usually finished.
            candidate = await concurrentArbiter.value
        } else {
            let arbiterRequest = QuizAgyRequest(
                sessionID: session.sessionID, questionID: questionID,
                questionGeneration: generation, questionKind: kind,
                frozenContext: context, ocr: request.ocr, viewportJPEGs: request.viewportJPEGs,
                arbiterVotes: valid.compactMap { $0?.output },
                researchSources: valid.compactMap { $0 }.flatMap(\.sources))
            candidate = await pool.runArbiterRecovering(
                arbiterRequest, deadline: totalDeadline) { [weak self] in
                    await self?.markRetrying(sessionID: session.sessionID,
                                             questionID: questionID, generation: generation)
                }
        }
        let arbiter = await acceptedArbiter(from: candidate, pool: pool)
        guard accepts(sessionID: session.sessionID, questionID: questionID,
                      generation: generation) else { return }
        guard let arbiter,
              accepts(sessionID: session.sessionID, questionID: questionID,
                      generation: generation) else {
            await publishFailure(kind: kind, sessionID: session.sessionID,
                                 questionID: questionID, generation: generation,
                                 summary: summary)
            return
        }
        let vote = QuizVote(sessionID: session.sessionID, questionID: questionID,
                            questionGeneration: generation, answer: arbiter.output.answer,
                            confidence: arbiter.output.confidence, worker: arbiter.identity,
                            sources: arbiter.sources)
        try? await store?.record(vote: vote, isArbiter: true)
        guard let final = QuizEnsembleResolver.resolveArbiter(
            arbiter.output, votes: valid.map { $0?.output }, kind: kind,
            calibration: calibration) else {
            await publishFailure(kind: kind, sessionID: session.sessionID,
                                 questionID: questionID, generation: generation,
                                 summary: summary)
            return
        }
        if let published = await publish(
            answer: final.0, confidence: final.1, kind: kind,
            sessionID: session.sessionID, questionID: questionID, generation: generation,
            summary: summary) {
            refine(session: session, profile: profile, request: request,
                   published: published, kind: kind, pool: pool)
        }
    }

    /// Audits one voter's isolation and records its vote.
    ///
    /// Returns nil when the result cannot be trusted — a reused conversation or
    /// more than one turn — which the caller treats exactly like a failure, since
    /// an unaudited vote must not count towards agreement.
    private func acceptVote(_ result: QuizAgyWorkerResult, pool: QuizAgyWorkerPool,
                            sessionID: String, questionID: String,
                            generation: Int) async -> QuizAgyWorkerResult? {
        do {
            try await pool.acceptIsolation(result)
        } catch {
            return nil
        }
        let vote = QuizVote(sessionID: sessionID, questionID: questionID,
                            questionGeneration: generation, answer: result.output.answer,
                            confidence: result.output.confidence, worker: result.identity,
                            sources: result.sources)
        try? await store?.record(vote: vote)
        return result
    }

    private func acceptedArbiter(from candidate: QuizAgyWorkerResult?,
                                 pool: QuizAgyWorkerPool) async -> QuizAgyWorkerResult? {
        guard let candidate, (try? await pool.acceptIsolation(candidate)) != nil else { return nil }
        return candidate
    }

    private func markRetrying(sessionID: String, questionID: String, generation: Int) async {
        guard accepts(sessionID: sessionID, questionID: questionID, generation: generation),
              status.state != .retrying else { return }
        status = replacing(state: .retrying, answer: .clear)
        try? await store?.update(sessionID: sessionID, state: .retrying)
    }

    /// Runs the refinement pass, once the reader already has an answer.
    ///
    /// Deliberately after `publish`: the fast answer is the one that matters
    /// while the question is on screen, and a stronger model reasoning properly
    /// takes as long as it takes. Its result arrives as another revision of the
    /// same question, so nothing on screen is replaced — the reader steps to it.
    private func refine(session: QuizSessionConfiguration, profile: QuizModeProfile,
                        request: QuizAgyRequest, published: QuizFinalAnswer,
                        kind: QuizQuestionKind, pool: QuizAgyWorkerPool) {
        guard profile.hasRefiner, published.verified else { return }
        refinement?.cancel()
        let deadline = Date().addingTimeInterval(Self.refinementBudget)
        refinement = Task { [weak self] in
            let refinerRequest = QuizAgyRequest(
                sessionID: request.sessionID, questionID: request.questionID,
                questionGeneration: request.questionGeneration, questionKind: kind,
                frozenContext: request.frozenContext, ocr: request.ocr,
                viewportJPEGs: request.viewportJPEGs, priorAnswer: published.answer)
            guard let result = await pool.runRefiner(refinerRequest, deadline: deadline) else {
                return
            }
            await self?.acceptRefinement(result, published: published, kind: kind, pool: pool)
        }
    }

    /// A refinement pass gets longer than a question does: it runs behind an
    /// answer the reader already has.
    private static let refinementBudget: TimeInterval = 180

    private func acceptRefinement(_ result: QuizAgyWorkerResult, published: QuizFinalAnswer,
                                  kind: QuizQuestionKind, pool: QuizAgyWorkerPool) async {
        refinement = nil
        guard (try? await pool.acceptIsolation(result)) != nil else { return }
        guard configuration?.sessionID == published.sessionID else { return }
        let improved = QuizFinalAnswer(
            sessionID: published.sessionID, questionID: published.questionID,
            questionGeneration: published.questionGeneration, kind: kind,
            answer: result.output.answer, confidence: result.output.confidence,
            verified: true, revision: published.revision + 1,
            rationale: result.output.rationale, summary: published.summary,
            elapsed: Date().timeIntervalSince(published.answeredAt))
        // Recorded as a vote too, so the model and its conversation are auditable
        // exactly like every other worker's.
        let vote = QuizVote(sessionID: published.sessionID, questionID: published.questionID,
                            questionGeneration: published.questionGeneration,
                            answer: result.output.answer, confidence: result.output.confidence,
                            worker: result.identity, sources: result.sources)
        try? await store?.record(vote: vote)
        try? await store?.record(final: improved)
        recordAnswer(improved)
        // Only moves the panel if the reader is following the newest answer; if
        // they have stepped back, the panel tells them there is a newer one.
        status = replacing(state: .answered, answer: .set(improved), failure: .clear)
    }

    @discardableResult
    private func publish(answer: String, confidence: Int, kind: QuizQuestionKind,
                         sessionID: String, questionID: String,
                         generation: Int, summary: String? = nil) async -> QuizFinalAnswer? {
        let took = questionStartedAt.map { Date().timeIntervalSince($0) }
        guard accepts(sessionID: sessionID, questionID: questionID, generation: generation) else { return nil }
        guard await awaitPersistence() else { return nil }
        guard accepts(sessionID: sessionID, questionID: questionID, generation: generation) else { return nil }
        let final = QuizFinalAnswer(sessionID: sessionID, questionID: questionID,
                                    questionGeneration: generation, kind: kind,
                                    answer: answer, confidence: confidence, verified: true,
                                    summary: summary, elapsed: took)
        if let key = currentQuestion?.answerKey, !key.isEmpty { recordCache(key, final) }
        try? await store?.record(final: final)
        recordAnswer(final)
        status = replacing(state: .answered, answer: .set(final), failure: .clear)
        try? await store?.update(sessionID: sessionID, state: .answered)
        await flow.record("answer.published", ["confidence": "\(confidence)",
                                              "revision": "\(final.revision)"])
        return final
    }

    private func publishFailure(kind: QuizQuestionKind, sessionID: String,
                                questionID: String, generation: Int,
                                summary: String? = nil) async {
        guard accepts(sessionID: sessionID, questionID: questionID, generation: generation) else { return }
        var final = QuizFinalAnswer.unable(sessionID: sessionID, questionID: questionID,
                                           generation: generation, kind: kind)
        if let summary {
            final = QuizFinalAnswer(
                id: final.id, sessionID: sessionID, questionID: questionID,
                questionGeneration: generation, kind: kind, answer: final.answer,
                confidence: 0, verified: false, summary: summary,
                elapsed: questionStartedAt.map { Date().timeIntervalSince($0) })
        }
        try? await store?.record(final: final)
        recordAnswer(final)
        status = replacing(state: .answered, answer: .set(final), failure: .clear)
    }

    private func accepts(sessionID: String, questionID: String, generation: Int) -> Bool {
        configuration?.sessionID == sessionID && currentQuestion?.questionID == questionID
            && currentQuestion?.generation == generation && !(solver?.isCancelled ?? false)
    }

    /// `resetDetector` is false only when the screen the detector just settled on
    /// is still the screen: a non-question page should not be re-detected on the
    /// very next poll.
    private func cancelQuestion(resetDetector: Bool = true) async {
        solver?.cancel(); solver = nil
        persistence?.cancel(); persistence = nil
        refinement?.cancel(); refinement = nil
        prewarm?.cancel(); prewarm = nil; prewarmingMode = nil
        discardSpeculativeFrame()
        await pool?.cancelActive()
        currentQuestion = nil
        questionStartedAt = nil
        collector = QuizViewportCollector()
        if resetDetector { detector.resetForRetarget() }
    }

    /// Answers are cached by frame fingerprint so re-showing a question does not
    /// re-run the council. The cache is scoped to one target: after a retarget
    /// the same fingerprint can only be a coincidence, and republishing the old
    /// window's answer against the new one is worse than paying for the council.
    /// One entry per question. A question that gets re-asked — after a pause, or
    /// after a scroll adds a viewport — replaces its own entry rather than
    /// appearing twice in the history the user steps through.
    private func recordAnswer(_ answer: QuizFinalAnswer) {
        if let index = sessionAnswers.firstIndex(where: { $0.questionID == answer.questionID }) {
            sessionAnswers[index] = answer
        } else {
            sessionAnswers.append(answer)
        }
        if sessionAnswers.count > QuizContract.maximumAnswerHistory {
            sessionAnswers.removeFirst(sessionAnswers.count - QuizContract.maximumAnswerHistory)
        }
    }

    private func recordCache(_ fingerprint: String, _ answer: QuizFinalAnswer) {
        if cacheOrder.count >= 64, let oldest = cacheOrder.first {
            cacheOrder.removeFirst()
            cache[oldest] = nil
        }
        cacheOrder.removeAll { $0 == fingerprint }
        cacheOrder.append(fingerprint)
        cache[fingerprint] = answer
    }

    private func clearCache() {
        cache.removeAll()
        cacheOrder.removeAll()
    }

    private func stop(failure: String?) async {
        status = replacing(state: .stopping, failure: failure.map { Patch.set($0) } ?? .keep)
        watcher?.cancel(); watcher = nil
        poolPreparation?.cancel(); poolPreparation = nil
        await cancelQuestion()
        await pool?.stop(); pool = nil
        if let sessionID = configuration?.sessionID {
            try? await store?.update(sessionID: sessionID,
                                     state: failure == nil ? .finished : .failed,
                                     failure: failure, endedAt: Date())
        }
        configuration = nil
        clearCache()
        sessionAnswers.removeAll()
        status = QuizSessionSnapshot(state: failure == nil ? .finished : .failed, failure: failure)
        Self.cleanupWorkerRoots(root: root, fileManager: fileManager)
    }

    /// Keeps the idle readiness the preflight reads from going stale.
    ///
    /// These four flags were only ever written by a visit to the Settings pane,
    /// so the notch either showed nothing or showed what was true the last time
    /// someone opened Settings. The preflight needs them to be current *before*
    /// the reader presses Start — that is the whole point of showing them.
    ///
    /// Check-only, so it never raises a permission prompt on its own, and
    /// detached so a status tick is never waiting on a subprocess.
    private func refreshIdlePermissionsIfStale() {
        if let permissionsCheckedAt,
           Date().timeIntervalSince(permissionsCheckedAt) < Self.permissionRefreshInterval {
            return
        }
        guard permissionRefresh == nil else { return }
        permissionsCheckedAt = Date()
        permissionRefresh = Task { [weak self] in
            let permissions = try? await self?.permissionReadiness(checkOnly: true)
            await self?.applyIdlePermissions(permissions)
            await self?.seedIdleReadiness()
        }
    }

    /// Answers the preflight's `modelsReady` and `agyAuthenticated` from the
    /// readiness cache, and re-establishes either if it has gone stale.
    ///
    /// Those two flags used to be set only by `listModels()`, which only the
    /// Settings Quiz pane calls. On a machine where Settings had not been opened
    /// since the engine started — which is every machine after a deploy — the
    /// notch's Start button stayed disabled reading "Needs Reasoner models", with
    /// nothing on that panel able to change it. Runs on the same 20-second tick
    /// as the permission check, never on the status path itself.
    private func seedIdleReadiness() {
        guard AgyLocator.hasCredentials(), let binary = AgyLocator.locate() else {
            idleAuthenticated = false
            return
        }
        if readiness.matches(binary: binary) {
            if !readiness.models.isEmpty { idleModelsReady = true }
            if readiness.authenticated { idleAuthenticated = true }
        }
        refreshReadiness(binary: binary)
    }

    private func applyIdlePermissions(_ readiness: QuizPermissionReadiness?) {
        permissionRefresh = nil
        guard let readiness else { return }
        idlePermissions = readiness
    }

    /// `quiz-permissions --check` is a `CGPreflight` and an `AXIsProcessTrusted`
    /// — cheap, but still a process, so not on every status tick.
    private static let permissionRefreshInterval: TimeInterval = 20

    private func permissionReadiness(checkOnly: Bool) async throws -> QuizPermissionReadiness {
        guard let executable = hostExecutable() else { throw QuizControllerFailure.hostUnavailable }
        let arguments = checkOnly ? ["quiz-permissions", "--check"] : ["quiz-permissions"]
        let data = try await QuizHostRunner.run(executable: executable, arguments: arguments,
                                                allowFailure: true)
        return try JSONDecoder().decode(QuizPermissionReadiness.self, from: data)
    }

    private func verifyAuthentication(binary: String, models: [String], force: Bool) async -> Bool {
        if !force, idleAuthenticated,
           let checked = authenticationCheckedAt,
           Date().timeIntervalSince(checked) < 300 {
            return true
        }
        guard let probeModel = models.first(where: { $0.hasSuffix("-low") }) ?? models.first else {
            idleAuthenticated = false
            recordAuthentication(false, binary: binary)
            return false
        }
        let ready = await QuizAgyModelCatalog.authenticationReady(binary: binary, model: probeModel)
        idleAuthenticated = ready
        authenticationCheckedAt = Date()
        recordAuthentication(ready, binary: binary)
        return ready
    }

    // MARK: - Readiness

    /// What this `agy` can run, from the cache when the cache still means it.
    ///
    /// `agy models` is a whole process, and every `agy` process spends seconds
    /// on Google round-trips before it answers. The catalogue changes when AGY
    /// ships models, not while a reader is answering questions, so a stale
    /// answer is used and refreshed behind the start rather than waited for.
    /// Only a machine that has never had a catalogue pays for one here.
    private func readinessModels(binary: String) async throws -> [String] {
        if readiness.matches(binary: binary), !readiness.models.isEmpty {
            idleModelsReady = true
            if !readiness.modelsAreFresh() { refreshReadiness(binary: binary) }
            return readiness.models
        }
        let models = try await QuizAgyModelCatalog.live(binary: binary)
        recordModels(models, binary: binary)
        return models
    }

    /// Whether the credential still reaches AGY.
    ///
    /// The proof is a real model round-trip, so it is worth remembering across
    /// engine restarts — which happen on every deploy. A verdict that has gone
    /// stale is believed and re-proved behind the start; one that was never
    /// taken, or was negative, is taken now.
    private func readinessAuthenticated(binary: String, models: [String]) async -> Bool {
        if readiness.matches(binary: binary), readiness.authenticated {
            idleAuthenticated = true
            if !readiness.authIsFresh() { refreshReadiness(binary: binary) }
            return true
        }
        return await verifyAuthentication(binary: binary, models: models, force: true)
    }

    private func recordModels(_ models: [String], binary: String) {
        idleModelsReady = !models.isEmpty
        var record = readiness.matches(binary: binary) ? readiness : QuizReadiness()
        record.binaryPath = binary
        record.models = models
        record.modelsCheckedAt = Date()
        readiness = record
        readinessCache.save(record)
    }

    private func recordAuthentication(_ authenticated: Bool, binary: String) {
        var record = readiness.matches(binary: binary) ? readiness : QuizReadiness()
        record.binaryPath = binary
        record.authenticated = authenticated
        record.authCheckedAt = Date()
        readiness = record
        readinessCache.save(record)
    }

    /// Re-establishes a stale catalogue or verdict without anyone waiting on it.
    private func refreshReadiness(binary: String) {
        guard readinessRefresh == nil else { return }
        let needsModels = !readiness.modelsAreFresh()
        let needsAuth = !readiness.authIsFresh()
        guard needsModels || needsAuth else { return }
        readinessRefresh = Task { [weak self] in
            if needsModels, let models = try? await QuizAgyModelCatalog.live(binary: binary) {
                await self?.recordModels(models, binary: binary)
            }
            if needsAuth {
                let models = await self?.readiness.models ?? []
                _ = await self?.verifyAuthentication(binary: binary, models: models, force: true)
            }
            await self?.finishReadinessRefresh()
        }
    }

    private func finishReadinessRefresh() {
        readinessRefresh = nil
    }

    private func resolveStore() throws -> QuizStore {
        if let store { return store }
        let store = try Self.makeStore(root: root)
        self.store = store
        return store
    }

    /// Opening the archive is a Keychain lookup, a schema migration and an
    /// orphan sweep — all synchronous, and all of it used to run on this actor
    /// while three subprocess spawns waited their turn behind it. Building it
    /// off the actor is what lets `start()` overlap the two.
    private nonisolated static func makeStore(root: URL) throws -> QuizStore {
        try QuizStore(path: root.appendingPathComponent("quiz.sqlite"),
                      captureRoot: root.appendingPathComponent("captures"),
                      key: QuizHistoryKey.loadOrCreate())
    }

    /// Takes the store opened off-actor, unless one is already open — two
    /// callers racing must not end up with two handles on one database.
    private func adopt(store opened: QuizStore) -> QuizStore {
        if let store { return store }
        store = opened
        return opened
    }

    /// What a status update does to a field it does not mention.
    ///
    /// These three used to be plain optionals defaulting to `nil`, and were
    /// assigned unconditionally — so *not mentioning* a field erased it.
    /// `send(.pause)` wiped the answer the user was reading, and the target-lost
    /// path wiped it too. `.resume` passed `answer: status.answer` by hand,
    /// which is the tell that the default was wrong rather than intended.
    private enum Patch<Value> {
        case keep
        case set(Value)
        case clear

        func resolve(_ current: Value?) -> Value? {
            switch self {
            case .keep: current
            case .set(let value): value
            case .clear: nil
            }
        }
    }

    private func replacing(state: QuizSessionState? = nil, target: QuizWindowTarget? = nil,
                           workersReady: Bool? = nil,
                           answer: Patch<QuizFinalAnswer> = .keep,
                           scrollPrompt: Patch<QuizCommandKind> = .keep,
                           failure: Patch<String> = .keep) -> QuizSessionSnapshot {
        QuizSessionSnapshot(
            sessionID: status.sessionID, state: state ?? status.state,
            target: target ?? status.target,
            screenRecordingReady: status.screenRecordingReady,
            accessibilityReady: status.accessibilityReady,
            agyAuthenticated: status.agyAuthenticated,
            modelsReady: status.modelsReady,
            workersReady: workersReady ?? status.workersReady,
            answer: answer.resolve(status.answer),
            answers: sessionAnswers,
            scrollPrompt: scrollPrompt.resolve(status.scrollPrompt),
            failure: failure.resolve(status.failure),
            questionStartedAt: questionStartedAt)
    }

    nonisolated private static func cleanupWorkerRoots(root: URL, fileManager: FileManager) {
        let workers = root.appendingPathComponent("workers", isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(at: workers,
                                                                  includingPropertiesForKeys: nil) else { return }
        // `logs` is deliberately not swept with the benches: it is the only
        // record of what a worker's `agy` said about authentication, and it
        // outlives the session precisely so a failed one can be read afterwards.
        for entry in entries where entry.lastPathComponent.hasPrefix("worker-")
            || entry.lastPathComponent.hasPrefix("home-") {
            // A bench about to be deleted may hold a token it refreshed.
            if entry.lastPathComponent.hasPrefix("home-") {
                AgyEnvironment.promoteRefreshedToken(from: entry)
            }
            try? fileManager.removeItem(at: entry)
        }
        pruneWorkerLogs(in: workers.appendingPathComponent("logs", isDirectory: true),
                        fileManager: fileManager)
    }

    /// Keeps the most recent worker logs and drops the rest.
    ///
    /// One file per slot per bench, and a session can build several benches, so
    /// this is a directory that grows without a bound of its own. A dozen is
    /// more than enough to read the last failure out of.
    private static let retainedWorkerLogs = 12

    nonisolated private static func pruneWorkerLogs(in directory: URL, fileManager: FileManager) {
        guard let logs = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]),
            logs.count > retainedWorkerLogs
        else { return }
        let dated = logs.map { url -> (URL, Date) in
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return (url, modified)
        }.sorted { $0.1 > $1.1 }
        for (url, _) in dated.dropFirst(retainedWorkerLogs) {
            try? fileManager.removeItem(at: url)
        }
    }

    /// Three consecutive failures at a 500 ms cadence is ~1.5 s of nothing,
    /// which a real window closing will always exceed and a blip will not.
    private static let captureFailureTolerance = 3

    private static func targetLostMessage(_ error: Error) -> String {
        let detail = (error as? LocalizedError)?.errorDescription
            ?? (error as NSError).localizedDescription
        guard !detail.isEmpty else { return "Target window unavailable; Retarget required" }
        return "\(detail); Retarget required"
    }




    /// Stability between two frames captured at *different* detail levels.
    /// `framesStableMatch` cannot serve here: it requires 94% OCR word overlap,
    /// and a `.fast` probe never agrees that closely with an `.accurate` solve
    /// frame of the same pixels. Tiles and the average hash are OCR-independent.
    private static func framesVisuallyStable(_ lhs: QuizHostFrame, _ rhs: QuizHostFrame) -> Bool {
        tileDifference(lhs.tileHashes, rhs.tileHashes) <= 0.08
            && (lhs.visualHash ^ rhs.visualHash).nonzeroBitCount <= 6
    }


    private static func tileDifference(_ lhs: [UInt64], _ rhs: [UInt64]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return lhs == rhs ? 0 : 1 }
        let changed = zip(lhs, rhs).reduce(0) {
            $0 + (($1.0 ^ $1.1).nonzeroBitCount > 4 ? 1 : 0)
        }
        return Double(changed) / Double(lhs.count)
    }


}

enum QuizControllerFailure: Error, LocalizedError {
    case hostUnavailable, alreadyRunning, notRunning, authenticationRequired
    case permissionsRequired, missingModels([String]), invalidTarget, startupCancelled, hostCommand(String)
    var errorDescription: String? {
        switch self {
        case .hostUnavailable: "Quiz capture host is unavailable"
        case .alreadyRunning: "Another Quiz session is running"
        case .notRunning: "No Quiz session is running"
        case .authenticationRequired: "AGY sign-in expired. Open Settings → Call Copilot → Live Call → Quiz, then Sign in again."
        case .permissionsRequired: "Screen Recording and Accessibility are required"
        case .missingModels(let models): "Quiz models unavailable: \(models.joined(separator: ", "))"
        case .invalidTarget: "Quiz target window changed or disappeared"
        case .startupCancelled: "Quiz startup was stopped"
        case .hostCommand(let message): "Quiz capture host failed: \(message)"
        }
    }
}

