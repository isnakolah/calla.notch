import CallaContracts
import Foundation
import IntelligenceStore

/// The backend's way back to this Mac: a server-sent-event stream of messages
/// from a fixed allowlist (`Backend/internal/inbox`). Each is applied through
/// the store's own methods, then acked with the outcome. Nothing received here
/// is ever run as code, and a kind this build does not know is acked as an
/// error rather than guessed at.
actor CallaBackendInbox {
    let sync: CallaBackendSync
    let store: CallaStore
    let bundlesRoot: URL
    /// Re-export a call's folder after its rows changed. Called off the actor.
    let refreshCall: @Sendable (String) -> Void

    private var task: Task<Void, Never>?
    private var lastID: Int64 = 0

    init(sync: CallaBackendSync, store: CallaStore, bundlesRoot: URL, refreshCall: @escaping @Sendable (String) -> Void) {
        self.sync = sync
        self.store = store
        self.bundlesRoot = bundlesRoot
        self.refreshCall = refreshCall
    }

    func start() {
        guard task == nil else { return }
        task = Task { await self.run() }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func run() async {
        var backoff: UInt64 = 2
        while !Task.isCancelled {
            guard let client = await sync.client() else {
                try? await Task.sleep(nanoseconds: 600 * 1_000_000_000)
                continue
            }
            do {
                try await listen(client)
                backoff = 2
            } catch is CancellationError {
                break
            } catch {
                await sync.setInboxConnected(false)
                if let http = error as? CallaBackendClient.HTTPFailure, http.isAuth {
                    _ = await sync.credential(forceReenroll: true)
                }
            }
            try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
            backoff = min(backoff * 2, 300)
        }
        await sync.setInboxConnected(false)
    }

    /// One SSE connection. Returns when the server closes it.
    private func listen(_ client: CallaBackendClient) async throws {
        var components = URLComponents(url: client.credential.url.appendingPathComponent("v1/inbox/stream"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "after", value: String(lastID))]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(client.credential.token)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // The server pings every 25s; three missed pings means a dead stream.
        request.timeoutInterval = 90
        let (bytes, response) = try await client.session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw CallaBackendClient.HTTPFailure(status: status, body: "") }
        await sync.setInboxConnected(true)

        // `lines` drops the blank separators, and the server writes each
        // message as a single data line, so that line is the whole message.
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            guard let message = try? CallaBackendWire.decoder().decode(CallaBackendWire.Message.self,
                                                                       from: Data(line.dropFirst(6).utf8)) else { continue }
            lastID = max(lastID, message.id)
            let outcome: (ok: Bool, error: String?)
            do {
                try await apply(message, client: client)
                CallaBackendLog.write("inbox #\(message.id) \(message.kind) applied")
                outcome = (true, nil)
            } catch {
                outcome = (false, error.localizedDescription)
                CallaBackendLog.write("inbox #\(message.id) \(message.kind) failed: \(error.localizedDescription)")
            }
            struct Ack: Encodable { let ok: Bool; let error: String? }
            struct Acked: Decodable { let acked: Bool }
            _ = try? await client.json("POST", "v1/inbox/\(message.id)/ack", body: Ack(ok: outcome.ok, error: outcome.error), as: Acked.self)
        }
    }

    struct Refused: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    private static func callID(_ value: JSONValue?) throws -> String {
        guard let id = value?.string, id.range(of: "^call-[A-Za-z0-9-]{8,72}$", options: .regularExpression) != nil else {
            throw Refused(reason: "bad call_id")
        }
        return id
    }

    func apply(_ message: CallaBackendWire.Message, client: CallaBackendClient) async throws {
        let p = message.payload
        switch message.kind {
        case "notify":
            guard let title = p["title"]?.string, !title.isEmpty else { throw Refused(reason: "notify needs a title") }
            await sync.setNotice(.init(id: message.id, title: String(title.prefix(200)), body: p["body"]?.string.map { String($0.prefix(2000)) }))

        case "replace_turns":
            let callID = try Self.callID(p["call_id"])
            guard let revision = p["revision"]?.number.map(Int.init), revision >= 0,
                  let rows = p["turns"]?.array else { throw Refused(reason: "replace_turns needs revision and turns") }
            struct Turn: Decodable {
                let seq: Int; let source: String; let t0: Double; let t1: Double; let text: String
                let confidence: Double?; let speakerID: String?
                enum CodingKeys: String, CodingKey { case seq, source, t0, t1, text, confidence, speakerID = "speaker_id" }
            }
            let turns = try rows.map { try $0.decode(Turn.self) }
            guard turns.allSatisfy({ $0.source == "me" || $0.source == "them" }) else { throw Refused(reason: "source must be me or them") }
            guard try await store.call(id: callID) != nil else { throw Refused(reason: "unknown call \(callID)") }
            try await store.replace(turns: turns.map {
                StoredTurn(seq: $0.seq, source: $0.source, t0: $0.t0, t1: $0.t1, text: $0.text,
                           revision: revision, confidence: $0.confidence, speakerID: $0.speakerID)
            }, callID: callID, revision: revision)
            let assignment = Dictionary(turns.compactMap { t in t.speakerID.map { (t.seq, $0) } }, uniquingKeysWith: { a, _ in a })
            if !assignment.isEmpty { try await store.assignTurnSpeakers(assignment, callID: callID, revision: revision) }
            changed(callID)

        case "update_speakers":
            let callID = try Self.callID(p["call_id"])
            for item in p["speakers"]?.array ?? [] {
                guard let id = item["speaker_id"]?.string else { continue }
                if let into = item["merge_into"]?.string {
                    try await store.mergeSpeaker(callID: callID, from: id, into: into)
                } else if let name = item["name"]?.string, !name.isEmpty {
                    _ = try await store.nameSpeaker(callID: callID, speakerID: id, name: name)
                }
            }
            changed(callID)

        case "upsert_recap":
            let callID = try Self.callID(p["call_id"])
            guard let markdown = p["markdown"]?.string else { throw Refused(reason: "upsert_recap needs markdown") }
            let existing = try await store.recapDraft(forCall: callID)
            // Lands as pending: the backend proposes, the user still approves
            // before anything becomes knowledge.
            try await store.save(recapDraft: CallRecapDraft(
                callID: callID, overview: markdown, items: existing?.items ?? [],
                provider: "calla-backend", model: p["model"]?.string, reviewState: .pending,
                title: p["title"]?.string ?? existing?.title))
            changed(callID)

        case "upsert_context":
            guard let key = p["key"]?.string, key.range(of: "^[A-Za-z0-9._-]{1,80}$", options: .regularExpression) != nil,
                  let markdown = p["markdown"]?.string, let scopeText = p["scope"]?.string else {
                throw Refused(reason: "upsert_context needs key, scope and markdown")
            }
            let scope: KnowledgeScope
            let parts = scopeText.split(separator: ":", maxSplits: 1).map(String.init)
            switch (parts.first, parts.count == 2 ? parts[1] : nil) {
            case ("always", nil): scope = .always
            case ("persona", let v?): scope = .persona(v)
            case ("series", let v?): scope = .series(v)
            case ("event", let v?): scope = .event(v)
            default: throw Refused(reason: "scope must be always, persona:<id>, series:<id> or event:<id>")
            }
            _ = try await store.upsert(KnowledgeNote(id: "backend-" + key, title: p["title"]?.string ?? key,
                                                     body: markdown, source: .manual, scope: scope))

        case "pull_bundle":
            guard let id = p["bundle_id"]?.string, id.range(of: "^[a-z0-9][a-z0-9-]{1,63}$", options: .regularExpression) != nil,
                  let dest = p["dest"]?.string, dest == "context" || dest == "components" else {
                throw Refused(reason: "bad bundle_id or dest")
            }
            let bundle = try await client.json("GET", "v1/bundles/\(id)", as: CallaBackendWire.Bundle.self)
            let root = bundlesRoot.appendingPathComponent(dest, isDirectory: true).appendingPathComponent(id, isDirectory: true)
            let staging = bundlesRoot.appendingPathComponent(".incoming-\(id)", isDirectory: true)
            try? FileManager.default.removeItem(at: staging)
            for file in bundle.files {
                let target = staging.appendingPathComponent(file.path).standardizedFileURL
                guard target.path.hasPrefix(staging.standardizedFileURL.path + "/") else { throw Refused(reason: "bundle path escapes") }
                try await client.download(sha256: file.sha256, to: target)
            }
            // Swap in whole, so a reader never sees half a bundle.
            try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: root)
            try FileManager.default.moveItem(at: staging, to: root)
            await sync.setNotice(.init(id: message.id, title: "Received \(bundle.description ?? id)", body: nil))

        default:
            throw Refused(reason: "this calla.notch does not know \(message.kind)")
        }
    }

    /// A call's rows changed here: refresh its folder and send it back up, so
    /// the backend's copy always matches what this Mac has.
    private func changed(_ callID: String) {
        refreshCall(callID)
        Task { await sync.enqueue(callID) }
    }
}

/// Rebuilds this Mac from the backend: the device snapshot's store rows, then
/// every call's raw files and store rows. Never overwrites: files already
/// present are kept, and store rows go in with INSERT OR IGNORE. Readable
/// folders in ~/Documents/Calls are regenerated by the normal export pass.
enum CallaBackendRestore {
    struct Report {
        var calls = 0
        var files = 0
        var rows = 0
        var failures: [String] = []
    }

    static func run(client: CallaBackendClient, store: CallaStore, paths: CallaBackendSync.Paths,
                    fromDevice: String? = nil, onlyDevice: String? = nil,
                    progress: @Sendable (String) async -> Void) async throws -> Report {
        var query: [URLQueryItem] = []
        if let fromDevice { query.append(.init(name: "from", value: fromDevice)) }
        if let onlyDevice { query.append(.init(name: "device", value: onlyDevice)) }
        let plan = try await client.json("GET", "v1/restore", query: query, as: CallaBackendWire.Restore.self)
        var report = Report()
        let fm = FileManager.default
        let staging = paths.stagingRoot.appendingPathComponent("restore", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        func rows(from files: [CallaBackendWire.File], schema: Int?) async throws -> StoreBackupTables {
            var tables: [String: Data] = [:]
            for file in files where file.path.hasPrefix("store/") && file.path.hasSuffix(".jsonl") {
                let local = staging.appendingPathComponent(UUID().uuidString)
                try await client.download(sha256: file.sha256, to: local)
                tables[String(file.path.dropFirst(6).dropLast(6))] = try Data(contentsOf: local)
                try? fm.removeItem(at: local)
            }
            return StoreBackupTables(tables: tables, schemaVersion: schema ?? 0)
        }

        if let snapshot = plan.deviceSnapshot {
            await progress("Restoring knowledge and voices…")
            let inserted = try await store.restoreRows(rows(from: snapshot.files, schema: snapshot.schemaVersion))
            report.rows += inserted.values.reduce(0, +)
            for file in snapshot.files where file.path.hasPrefix("settings/") {
                // Kept beside the runtime for the app to offer; applying another
                // Mac's preferences silently would be a surprise.
                let target = paths.engineRoot.appendingPathComponent("backend/restored", isDirectory: true)
                    .appendingPathComponent((file.path as NSString).lastPathComponent)
                try? await client.download(sha256: file.sha256, to: target)
            }
        }

        let calls = plan.calls.sorted { ($0.call.startedAt ?? .distantPast) < ($1.call.startedAt ?? .distantPast) }
        for (index, manifest) in calls.enumerated() {
            try Task.checkCancellation()
            await progress("Restoring call \(index + 1) of \(calls.count)…")
            let directory = paths.callsRoot.appendingPathComponent(manifest.callID, isDirectory: true)
            do {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                report.files += try await restoreRawFiles(manifest, client: client, directory: directory, staging: staging)
                CallaBackendSync.markHydrated(directory: directory)
                let inserted = try await store.restoreRows(rows(from: manifest.files, schema: manifest.schemaVersion))
                report.rows += inserted.values.reduce(0, +)
                report.calls += 1
            } catch {
                report.failures.append("\(manifest.callID): \(error.localizedDescription)")
            }
        }
        return report
    }

    /// Downloads one call's `raw/` files into its directory, FLAC decoded back
    /// to WAV. Skips what is already there. Returns files written.
    static func restoreRawFiles(_ manifest: CallaBackendWire.CallManifest, client: CallaBackendClient,
                                directory: URL, staging: URL) async throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        var written = 0
        for file in manifest.files where file.path.hasPrefix("raw/") {
            let relative = String(file.path.dropFirst(4))
            let target = directory.appendingPathComponent(relative).standardizedFileURL
            guard target.path.hasPrefix(directory.standardizedFileURL.path + "/") else { continue }
            if relative.hasSuffix(".flac") {
                let wav = target.deletingPathExtension().appendingPathExtension("wav")
                guard !fm.fileExists(atPath: wav.path) else { continue }
                let flac = staging.appendingPathComponent(UUID().uuidString + ".flac")
                try await client.download(sha256: file.sha256, to: flac)
                try decodeFLAC(flac, to: wav)
                try? fm.removeItem(at: flac)
            } else {
                if let size = (try? fm.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value,
                   size == file.size { continue }
                try await client.download(sha256: file.sha256, to: target)
            }
            written += 1
        }
        return written
    }

    /// FLAC back to the float32 WAV the host writes, so the archive pass and
    /// speaker pass can re-run over a restored call.
    static func decodeFLAC(_ flac: URL, to wav: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = ["-f", "WAVE", "-d", "LEF32", flac.path, wav.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: wav)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "afconvert could not decode \(flac.lastPathComponent)"])
        }
    }
}
