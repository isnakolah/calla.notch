import CallaContracts
import Foundation
import IntelligenceCore

/// Each job gets its own conversation and proposal copy. No worker sees another
/// job's writable tree; results leave the pool with the input revision attached.
actor WaveWorkerPool {
    struct Result: Sendable {
        var job: WaveWorkerJob
        var draft: CodingMoveDraft
        var work: URL
    }
    private var admission = WaveWorkerAdmission()
    private var workers: [UUID: CodingAgyWorker] = [:]
    private var cancelled = false
    private let root: URL
    init(root: URL) { self.root = root }

    func respond(role: WaveWorkerRole, revision: WaveRevision, source: URL,
                 context: URL, selection: CodingModelSelection, prompt: String) async throws -> Result {
        guard !cancelled else { throw CancellationError() }
        let directory = root.appendingPathComponent(UUID().uuidString)
        let job = WaveWorkerJob(role: role, revision: revision, proposalDirectory: directory.path)
        guard admission.admit(job) else { throw CodingAgyWorkerFailure.busy }
        defer {
            admission.finish(job.id); workers.removeValue(forKey: job.id)
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("agy-home"))
        }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let space = CodingWorkspace(root: directory)
        try fm.createDirectory(at: space.workURL, withIntermediateDirectories: true)
        try CodingShadowProject.copy(manifest: CodingShadowProject.inspect(source: source), source: source,
                                     destination: space.workURL)
        // Every pool job owns a throwaway copy of the tree, so commands are safe
        // here and useful: a coder that can run the project's own tests against
        // its own edit is the point of a private proposal.
        try space.seed(brief: nil, persona: CodingSessionController.persona, pack: PromptPack(),
                       readOnly: role != .coder, allowsCommands: true)
        let frozen = space.contextURL.appendingPathComponent("snapshot")
        try fm.copyItem(at: context, to: frozen)
        // The worker sandbox denies all writes to context, including this frozen
        // copy. Keep engine-owned directory permissions so archive cleanup works.
        try JSONEncoder().encode(revision).write(to: space.contextURL.appendingPathComponent("revision.json"), options: .atomic)
        let worker = try CodingAgyWorker(workspace: space, isolatedHome: directory.appendingPathComponent("agy-home"),
                                         selection: selection, readOnly: role != .coder,
                                         allowsCommands: true)
        workers[job.id] = worker
        do {
            let draft = try await worker.respond(frame: "Read the frozen context/snapshot and actual work files; Wave materials apply only to a Wave profile. Role: \(role.rawValue).\n" + prompt, timeoutSeconds: role == .planner ? 45 : 90)
            await worker.stop()
            guard !cancelled, !Task.isCancelled else { throw CancellationError() }
            return Result(job: job, draft: draft, work: space.workURL)
        } catch { await worker.stop(); throw error }
    }
    func cancel() async {
        cancelled = true
        for worker in workers.values { await worker.stop() }
        workers.removeAll()
    }
}
