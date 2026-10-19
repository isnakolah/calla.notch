import Foundation
import IntelligenceStore

/// What the notch shows about the archive, folded into the engine's `Status`.
struct CallaBackendStatus: Codable, Equatable {
    var enabled = true
    var signedIn = false
    var deviceName: String? = nil
    var url: String? = nil
    var syncing: String? = nil
    var pendingCalls = 0
    var syncedCalls = 0
    var lastSyncAt: Date? = nil
    var lastError: String? = nil
    var inboxConnected = false
    /// The latest `notify` push, shown once by the app.
    var notice: Notice? = nil
    var restore: String? = nil

    struct Notice: Codable, Equatable {
        var id: Int64
        var title: String
        var body: String?
    }
}

/// Uploads every finished call, whole, to the backend: the raw call directory
/// (audio as 24-bit FLAC), the readable copy in ~/Documents/Calls, and every
/// store row the call owns. Also uploads the device-wide snapshot. The backend
/// keeps all of it, so a reinstalled Mac can be rebuilt from there.
///
/// Work is idempotent end to end. A call's manifest is compared with what was
/// last committed and skipped when equal; blobs the server already has are
/// never sent again; a big file resumes where the last attempt stopped.
actor CallaBackendSync {
    struct Paths {
        var copilotRoot: URL
        var callsRoot: URL { copilotRoot.appendingPathComponent("calls", isDirectory: true) }
        var engineRoot: URL
        var callFoldersRoot: URL
        var stagingRoot: URL { copilotRoot.appendingPathComponent("backend-staging", isDirectory: true) }
        var appPreferences: URL
    }

    let paths: Paths
    let store: CallaStore
    let appVersion: String
    private let onStatus: @Sendable (CallaBackendStatus) -> Void
    private let fileManager = FileManager.default

    private(set) var status = CallaBackendStatus()
    private var queue: [String] = []
    private var queued = Set<String>()
    private var draining = false
    private var lastEnrollAttempt: Date?
    private var signInError: String?
    private var lastDeviceSnapshot: Date?

    init(paths: Paths, store: CallaStore, appVersion: String, onStatus: @escaping @Sendable (CallaBackendStatus) -> Void) {
        self.paths = paths
        self.store = store
        self.appVersion = appVersion
        self.onStatus = onStatus
        if let credential = CallaBackendCredentialStore.load() {
            status.signedIn = true
            status.deviceName = credential.name
            status.url = credential.url.absoluteString
        }
    }

    private func publish() { onStatus(status) }

    func setEnabled(_ enabled: Bool) {
        status.enabled = enabled
        publish()
        if enabled { Task { await self.drain() } }
    }

    func setNotice(_ notice: CallaBackendStatus.Notice?) { status.notice = notice; publish() }
    func setInboxConnected(_ connected: Bool) {
        guard status.inboxConnected != connected else { return }
        status.inboxConnected = connected
        publish()
    }
    func setRestore(_ text: String?) { status.restore = text; publish() }

    // MARK: Credential

    /// The signed-in credential, enrolling over HTTPS when there is none. Enrollment is retried at most every ten minutes.
    func credential(forceReenroll: Bool = false) async -> CallaBackendCredential? {
        if !forceReenroll, let existing = CallaBackendCredentialStore.load() { return existing }
        if let last = lastEnrollAttempt, Date().timeIntervalSince(last) < 600, !forceReenroll { return nil }
        lastEnrollAttempt = Date()
        let previous = CallaBackendCredentialStore.load()?.deviceID
        do {
            let credential = try await CallaBackendEnrollment.enroll(existingDeviceID: previous)
            status.signedIn = true
            status.deviceName = credential.name
            status.url = credential.url.absoluteString
            status.lastError = nil
            signInError = nil
            CallaBackendLog.write("signed in as \(credential.deviceID) (\(credential.name))")
            publish()
            return credential
        } catch {
            status.signedIn = false
            status.lastError = error.localizedDescription
            signInError = error.localizedDescription
            CallaBackendLog.write("sign-in failed: \(error.localizedDescription)")
            publish()
            return nil
        }
    }

    func client() async -> CallaBackendClient? {
        guard let credential = await credential() else { return nil }
        return CallaBackendClient(credential: credential)
    }

    /// A 401 means the token was revoked or the server was rebuilt without it.
    /// Re-enroll once, keeping the device id, and let the caller retry.
    private func handleAuthFailure(_ error: Error) async -> Bool {
        guard let http = error as? CallaBackendClient.HTTPFailure, http.isAuth else { return false }
        return await credential(forceReenroll: true) != nil
    }

    // MARK: Queue

    func enqueue(_ callID: String) {
        if queued.insert(callID).inserted {
            queue.append(callID)
            status.pendingCalls = queue.count
        }
        // Always kick: a drain that stopped on a network error left work queued.
        Task { await self.drain() }
    }

    /// Queues every call directory on disk, oldest first. The first run after
    /// install is the backfill; later runs only re-send what changed.
    func enqueueAll() {
        let ids = ((try? fileManager.contentsOfDirectory(at: paths.callsRoot, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("call-") }
            .sorted { modified($0) < modified($1) }
            .map(\.lastPathComponent)
        for id in ids { enqueue(id) }
    }

    /// Queues calls whose files changed since their last commit, or that were
    /// never sent. Only reads modification dates, so it is cheap to run often.
    func enqueueStale() {
        let dirs = ((try? fileManager.contentsOfDirectory(at: paths.callsRoot, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("call-") }
            .sorted { modified($0) < modified($1) }
        for dir in dirs {
            let state = dir.appendingPathComponent("backend.json")
            guard fileManager.fileExists(atPath: state.path) else { enqueue(dir.lastPathComponent); continue }
            let synced = modified(state)
            let newest = (fileManager.enumerator(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])?
                .compactMap { ($0 as? URL).flatMap { $0.lastPathComponent == "backend.json" ? nil : modified($0) } }.max()) ?? .distantPast
            if newest > synced { enqueue(dir.lastPathComponent) }
        }
    }

    private var retryScheduled = false

    /// Tries again a minute after a network failure, then backs off to the
    /// periodic sweep if it keeps failing.
    private func scheduleRetry() {
        guard !retryScheduled else { return }
        retryScheduled = true
        Task {
            try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            self.retryScheduled = false
            await self.drain()
        }
    }

    private func drain() async {
        guard !draining, status.enabled else { return }
        draining = true
        defer {
            draining = false
            status.syncing = nil
            status.pendingCalls = queue.count
            publish()
        }
        while status.enabled {
            if queue.isEmpty {
                // Calls queued while this ran are picked up by the loop, not
                // by a second drain that would have returned at the guard.
                try? await syncDeviceIfDue()
                if queue.isEmpty { break }
                continue
            }
            let callID = queue.removeFirst()
            queued.remove(callID)
            status.pendingCalls = queue.count
            status.syncing = callID
            publish()
            do {
                if try await syncCall(callID) { status.syncedCalls += 1 }
                status.lastSyncAt = Date()
                status.lastError = nil
            } catch is CancellationError {
                return
            } catch {
                status.lastError = "\(callID): \(error.localizedDescription)"
                CallaBackendLog.write("\(callID) not synced: \(error.localizedDescription)")
                // Offline, server trouble or not signed in: stop here and let
                // the next sweep retry, rather than failing every call in turn.
                if (error as? URLError) != nil || error is CallaBackendEnrollment.Failure {
                    queue.insert(callID, at: 0); queued.insert(callID)
                    scheduleRetry()
                    return
                }
            }
        }
    }

    // MARK: Call upload

    /// Per-call record of what was last committed, beside the call's files.
    private struct CallState: Codable {
        var digest: String
        var version: Int
        var syncedAt: Date
        var hashes: [String: CachedHash]
        /// The call's files were removed from this Mac once the backend held
        /// them; only this file and the store rows remain here.
        var offloaded: Bool? = nil
        var offloadedAt: Date? = nil
        /// Whether the offloaded call had audio, for History.
        var hadAudio: Bool? = nil
    }

    /// Engine-readable view of a call's offload state, without the actor.
    struct OffloadState {
        var offloaded: Bool
        var hadAudio: Bool
    }

    static func offloadState(callsRoot: URL, callID: String) -> OffloadState? {
        let url = callsRoot.appendingPathComponent(callID).appendingPathComponent("backend.json")
        guard let data = try? Data(contentsOf: url),
              let state = try? CallaBackendWire.decoder().decode(CallState.self, from: data),
              state.offloaded == true else { return nil }
        return OffloadState(offloaded: true, hadAudio: state.hadAudio ?? false)
    }

    /// After files come back (restore or hydrate), the call is a normal local
    /// call again; it is offloaded anew by the next sweep.
    static func markHydrated(directory: URL) {
        let url = directory.appendingPathComponent("backend.json")
        guard let data = try? Data(contentsOf: url),
              var state = try? CallaBackendWire.decoder().decode(CallState.self, from: data),
              state.offloaded == true else { return }
        state.offloaded = nil
        state.offloadedAt = nil
        try? CallaBackendWire.encoder().encode(state).write(to: url, options: .atomic)
    }

    private func saveState(_ state: CallState, _ callID: String) throws {
        try CallaBackendWire.encoder().encode(state).write(to: stateURL(callID), options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL(callID).path)
    }

    struct CachedHash: Codable {
        var size: Int64
        var mtime: Double
        var sha256: String
        /// For a derived file (FLAC from WAV): the derived file's size.
        var outputSize: Int64?
    }

    private struct Entry: @unchecked Sendable {
        var file: CallaBackendWire.File
        var cacheKey: String? = nil
        var source: URL?          // on-disk file to upload
        var data: Data?           // or bytes generated here
        var derive: (@Sendable () throws -> URL)? // or a file made on demand (FLAC)
    }

    /// Runs blocking file work (hashing, afconvert) off the actor, so the
    /// inbox and status updates are never stuck behind a long encode.
    private func offActor<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .utility) { try body() }.value
    }

    private func stateURL(_ callID: String) -> URL {
        paths.callsRoot.appendingPathComponent(callID).appendingPathComponent("backend.json")
    }

    private func loadState(_ callID: String) -> CallState? {
        guard let data = try? Data(contentsOf: stateURL(callID)) else { return nil }
        return try? CallaBackendWire.decoder().decode(CallState.self, from: data)
    }

    /// Returns true when something new was committed.
    @discardableResult
    func syncCall(_ callID: String) async throws -> Bool {
        guard callID.range(of: "^call-[A-Za-z0-9-]{8,72}$", options: .regularExpression) != nil else { return false }
        let directory = paths.callsRoot.appendingPathComponent(callID, isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path) else { return false }
        guard try await isSettled(callID, directory: directory) else {
            CallaBackendLog.write("\(callID): not settled yet")
            return false
        }
        guard var client = await client() else {
            throw CallaBackendEnrollment.Failure(message: "not signed in" + (signInError.map { ": \($0)" } ?? ""))
        }

        let previous = loadState(callID)
        if let previous, previous.offloaded == true {
            return try await syncOffloaded(callID, state: previous, client: client)
        }
        var hashes = previous?.hashes ?? [:]
        var entries = try await buildEntries(callID: callID, directory: directory, hashes: &hashes)
        // A call that never captured anything leaves an empty directory.
        guard !entries.isEmpty else { return false }
        let manifest = try await buildManifest(callID: callID, directory: directory, entries: entries)
        let digest = CallaBackendHashing.sha256(of: try CallaBackendWire.encoder().encode(manifest))
        if previous?.digest == digest { return false }
        CallaBackendLog.write("\(callID): sending \(entries.count) files")

        do {
            try await upload(&entries, client: client, hashes: &hashes)
        } catch {
            guard await handleAuthFailure(error), let retry = await self.client() else { throw error }
            client = retry
            try await upload(&entries, client: client, hashes: &hashes)
        }
        // A re-derived file may have a new digest; rebuild with what was sent.
        let final = try await buildManifest(callID: callID, directory: directory, entries: entries)
        struct Committed: Decodable { let version: Int }
        let committed = try await client.json("POST", "v1/calls/\(callID)/commit", body: final, as: Committed.self)
        let finalDigest = CallaBackendHashing.sha256(of: try CallaBackendWire.encoder().encode(final))
        let state = CallState(digest: finalDigest, version: committed.version, syncedAt: Date(), hashes: hashes)
        try saveState(state, callID)
        try? fileManager.removeItem(at: paths.stagingRoot.appendingPathComponent(callID))
        CallaBackendLog.write("\(callID): committed v\(committed.version)")
        return true
    }

    /// An offloaded call whose store rows changed (an inbox edit, a rename):
    /// send the backend's newest files again with fresh store rows, so its
    /// latest version stays complete.
    private func syncOffloaded(_ callID: String, state: CallState, client: CallaBackendClient) async throws -> Bool {
        var manifest = try await client.json("GET", "v1/calls/\(callID)/manifest", as: CallaBackendWire.CallManifest.self)
        let rows = try await store.backupRows(forCall: callID)
        var files = manifest.files.filter { !$0.path.hasPrefix("store/") }
        var blobs: [(CallaBackendWire.File, Data)] = []
        for (table, data) in rows.tables.sorted(by: { $0.key < $1.key }) {
            let file = CallaBackendWire.File(path: "store/\(table).jsonl", sha256: CallaBackendHashing.sha256(of: data),
                                             size: Int64(data.count), type: "application/x-ndjson")
            files.append(file)
            blobs.append((file, data))
        }
        manifest.files = files.sorted { $0.path < $1.path }
        manifest.deviceID = nil
        manifest.version = nil
        manifest.appVersion = appVersion
        manifest.schemaVersion = await store.schemaVersion
        manifest.flags.speakers = !((try? await store.speakers(forCall: callID)) ?? []).isEmpty
        manifest.flags.recap = (try? await store.recapDraft(forCall: callID)) != nil
        let digest = CallaBackendHashing.sha256(of: try CallaBackendWire.encoder().encode(manifest))
        if digest == state.digest { return false }
        let missing = try await client.missing(blobs.map(\.0.sha256))
        try fileManager.createDirectory(at: paths.stagingRoot, withIntermediateDirectories: true)
        for (file, data) in blobs where missing.contains(file.sha256) {
            let staged = paths.stagingRoot.appendingPathComponent(UUID().uuidString)
            try data.write(to: staged)
            defer { try? fileManager.removeItem(at: staged) }
            try await client.upload(file: staged, sha256: file.sha256, size: file.size)
        }
        struct Committed: Decodable { let version: Int }
        let committed = try await client.json("POST", "v1/calls/\(callID)/commit", body: manifest, as: Committed.self)
        var next = state
        next.digest = digest
        next.version = committed.version
        next.syncedAt = Date()
        try saveState(next, callID)
        CallaBackendLog.write("\(callID): offloaded call re-sent with fresh store rows, v\(committed.version)")
        return true
    }

    // MARK: Offload

    /// Removes the files of every call the backend holds in full, keeping only
    /// its store rows (and `backend.json`) here. `busy` are calls the engine is
    /// still working on: the live call and any queued archive pass.
    ///
    /// A call goes only when all of these hold:
    /// - it ended at least an hour ago (recap, speakers and folder have landed);
    /// - its archive pass has run, or it ended over three days ago;
    /// - this Mac has nothing newer to send for it;
    /// - the backend's newest manifest is the version this Mac committed, lists
    ///   every local file with the same digest, and reports no blob missing.
    func offloadEligible(excluding busy: Set<String>) async {
        guard status.enabled, let client = await client() else { return }
        let ids = ((try? fileManager.contentsOfDirectory(atPath: paths.callsRoot.path)) ?? [])
            .filter { $0.hasPrefix("call-") && !busy.contains($0) }.sorted()
        var freed: Int64 = 0, count = 0
        for callID in ids {
            guard let state = loadState(callID), state.offloaded != true else { continue }
            do {
                if let bytes = try await offload(callID, client: client) {
                    freed += bytes; count += 1
                }
            } catch {
                CallaBackendLog.write("\(callID): kept on this Mac: \(error.localizedDescription)")
                if (error as? URLError) != nil { break }
            }
        }
        if count > 0 {
            CallaBackendLog.write("offloaded \(count) calls, freed \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file))")
        }
    }

    private func offload(_ callID: String, client: CallaBackendClient) async throws -> Int64? {
        let directory = paths.callsRoot.appendingPathComponent(callID, isDirectory: true)
        let call = try? await store.call(id: callID)
        let ended = call?.endedAt ?? newestModification(in: directory)
        guard Date().timeIntervalSince(ended) > 3600 else { return nil }
        let hasArchive = fileManager.fileExists(atPath: directory.appendingPathComponent("transcript-archive.jsonl").path)
        let hasAudio = ((try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []).contains { $0.hasSuffix(".wav") }
        guard hasArchive || !hasAudio || Date().timeIntervalSince(ended) > 3 * 86400 else { return nil }

        // Anything new goes up first; then the state names what the server has.
        _ = try await syncCall(callID)
        guard var state = loadState(callID) else { return nil }
        var hashes = state.hashes
        let local = try await buildEntries(callID: callID, directory: directory, hashes: &hashes)
        let mine = try await buildManifest(callID: callID, directory: directory, entries: local)
        guard CallaBackendHashing.sha256(of: try CallaBackendWire.encoder().encode(mine)) == state.digest else {
            return nil // changed since the last commit; the next sync sends it
        }
        let server = try await client.json("GET", "v1/calls/\(callID)/manifest", as: CallaBackendWire.CallManifest.self)
        guard server.version == state.version else { return nil }
        let held = Dictionary(server.files.map { ($0.path, $0.sha256) }, uniquingKeysWith: { a, _ in a })
        for file in mine.files where held[file.path] != file.sha256 {
            throw CallaBackendEnrollment.Failure(message: "server copy differs at \(file.path)")
        }
        let missing = try await client.missing(server.files.map(\.sha256))
        guard missing.isEmpty else {
            throw CallaBackendEnrollment.Failure(message: "server is missing \(missing.count) blobs")
        }

        // Safe. The readable folder first: only files the server holds with the
        // same digest, so anything added there by hand stays.
        var freed: Int64 = 0
        let exportFiles = server.files.filter { $0.path.hasPrefix("export/") }
        if let data = try? Data(contentsOf: directory.appendingPathComponent("export.json")),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let relative = object["path"] as? String, !relative.contains("..") {
            let folder = paths.callFoldersRoot.appendingPathComponent(relative, isDirectory: true)
            for file in exportFiles {
                let url = folder.appendingPathComponent(String(file.path.dropFirst(7)))
                guard let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value,
                      (try? CallaBackendHashing.sha256(of: url)) == file.sha256 else { continue }
                try fileManager.removeItem(at: url)
                freed += size
            }
            Self.removeEmptyDirectories(folder, stopAt: paths.callFoldersRoot)
        }
        for url in Self.regularFiles(under: directory) where url.lastPathComponent != "backend.json" {
            freed += (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            try fileManager.removeItem(at: url)
        }
        Self.removeEmptyDirectories(directory, stopAt: directory, keepRoot: true)
        try? fileManager.removeItem(at: paths.stagingRoot.appendingPathComponent(callID))

        state.offloaded = true
        state.offloadedAt = Date()
        state.hadAudio = hasAudio || server.flags.audio
        state.hashes = [:]
        try saveState(state, callID)
        CallaBackendLog.write("\(callID): offloaded (\(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)))")
        return freed
    }

    /// Brings an offloaded call's raw files back from the backend, for a
    /// re-transcription or a speaker pass.
    func hydrate(_ callID: String) async throws {
        guard let client = await client() else { throw CallaBackendEnrollment.Failure(message: "not signed in") }
        let manifest = try await client.json("GET", "v1/calls/\(callID)/manifest", as: CallaBackendWire.CallManifest.self)
        let directory = paths.callsRoot.appendingPathComponent(callID, isDirectory: true)
        let staging = paths.stagingRoot.appendingPathComponent("hydrate-\(callID)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        let count = try await CallaBackendRestore.restoreRawFiles(manifest, client: client, directory: directory, staging: staging)
        Self.markHydrated(directory: directory)
        CallaBackendLog.write("\(callID): fetched \(count) files back from the archive")
    }

    private func newestModification(in directory: URL) -> Date {
        (fileManager.enumerator(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])?
            .compactMap { ($0 as? URL).map(modified) }.max()) ?? .distantPast
    }

    private static func removeEmptyDirectories(_ root: URL, stopAt: URL, keepRoot: Bool = false) {
        let fm = FileManager.default
        let dirs = (fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])?.compactMap { $0 as? URL } ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.path.count > $1.path.count }
        for dir in dirs where (try? fm.contentsOfDirectory(atPath: dir.path))?.allSatisfy({ $0 == ".DS_Store" }) == true {
            try? fm.removeItem(at: dir)
        }
        if !keepRoot, root.standardizedFileURL != stopAt.standardizedFileURL,
           (try? fm.contentsOfDirectory(atPath: root.path))?.allSatisfy({ $0 == ".DS_Store" }) == true {
            try? fm.removeItem(at: root)
            // Its parent (the call type folder) too, once it is empty.
            let parent = root.deletingLastPathComponent()
            if parent.standardizedFileURL != stopAt.standardizedFileURL,
               (try? fm.contentsOfDirectory(atPath: parent.path))?.allSatisfy({ $0 == ".DS_Store" }) == true {
                try? fm.removeItem(at: parent)
            }
        }
    }

    /// A call is ready once it has ended, or, for one whose host died before
    /// writing its end, once nothing has touched it for half an hour.
    private func isSettled(_ callID: String, directory: URL) async throws -> Bool {
        if let active = try? Data(contentsOf: paths.copilotRoot.appendingPathComponent("active-call.json")),
           let object = try? JSONSerialization.jsonObject(with: active) as? [String: Any],
           (object["call_id"] as? String ?? object["callID"] as? String) == callID {
            return false
        }
        if let call = try? await store.call(id: callID), call.endedAt != nil { return true }
        let newest = (fileManager.enumerator(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])?
            .compactMap { ($0 as? URL).map(modified) }.max()) ?? .distantPast
        return Date().timeIntervalSince(newest) > 1800
    }

    private static let skipped: Set<String> = ["backend.json", "export.json", ".DS_Store"]

    private func buildEntries(callID: String, directory: URL, hashes: inout [String: CachedHash]) async throws -> [Entry] {
        let (scanned, updated) = try await offActor { [hashes, paths] in
            var h = hashes
            let found = try Self.scanFiles(callID: callID, directory: directory, paths: paths, hashes: &h)
            return (found, h)
        }
        hashes = updated
        var entries = scanned

        // store/: every row this call owns.
        let rows = try await store.backupRows(forCall: callID)
        for (table, data) in rows.tables.sorted(by: { $0.key < $1.key }) {
            entries.append(Entry(file: .init(path: "store/\(table).jsonl", sha256: CallaBackendHashing.sha256(of: data),
                                             size: Int64(data.count), type: "application/x-ndjson"), data: data))
        }
        return entries
    }

    private static func scanFiles(callID: String, directory: URL, paths: Paths, hashes: inout [String: CachedHash]) throws -> [Entry] {
        var entries: [Entry] = []

        // raw/: the call directory as the host wrote it.
        for url in regularFiles(under: directory) {
            let relative = String(url.path.dropFirst(directory.path.count + 1))
            let name = url.lastPathComponent
            if Self.skipped.contains(name) || name.hasPrefix(".") || name.hasSuffix(".partial") { continue }
            if url.pathExtension == "wav" {
                entries.append(try audioEntry(wav: url, relative: relative, callID: callID, stagingRoot: paths.stagingRoot, hashes: &hashes))
                continue
            }
            entries.append(try fileEntry(url, path: "raw/" + relative, key: "raw:" + relative, hashes: &hashes))
        }

        // export/: the readable folder, if the call has one.
        if let data = try? Data(contentsOf: directory.appendingPathComponent("export.json")),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let relative = object["path"] as? String, !relative.contains("..") {
            let folder = paths.callFoldersRoot.appendingPathComponent(relative, isDirectory: true)
            for url in regularFiles(under: folder) where !url.lastPathComponent.hasPrefix(".") {
                let inner = String(url.path.dropFirst(folder.path.count + 1))
                entries.append(try fileEntry(url, path: "export/" + inner, key: "export:" + inner, hashes: &hashes))
            }
        }
        return entries
    }

    private static func fileEntry(_ url: URL, path: String, key: String, hashes: inout [String: CachedHash]) throws -> Entry {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let sha: String
        if let cached = hashes[key], cached.size == size, cached.mtime == mtime, cached.outputSize == nil {
            sha = cached.sha256
        } else {
            sha = try CallaBackendHashing.sha256(of: url)
            hashes[key] = CachedHash(size: size, mtime: mtime, sha256: sha)
        }
        return Entry(file: .init(path: path, sha256: sha, size: size, type: Self.contentType(url)), source: url)
    }

    /// WAV becomes FLAC: lossless at the 24-bit depth `afconvert` picks for
    /// float input, and about a third of the size. A WAV whose header was never
    /// finalized (a host that died mid-call) is repaired first; one that still
    /// will not convert is sent as it is.
    private static func audioEntry(wav: URL, relative: String, callID: String, stagingRoot: URL,
                                   hashes: inout [String: CachedHash]) throws -> Entry {
        let attributes = try FileManager.default.attributesOfItem(atPath: wav.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "flac:" + relative
        let path = "raw/" + (relative as NSString).deletingPathExtension + ".flac"
        let stagingDir = stagingRoot.appendingPathComponent(callID, isDirectory: true)
        let staging = stagingDir.appendingPathComponent(UUID().uuidString + ".flac")
        let derive: @Sendable () throws -> URL = {
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            try Self.convertToFLAC(wav, output: staging)
            return staging
        }
        if let cached = hashes[key], cached.size == size, cached.mtime == mtime, let outputSize = cached.outputSize {
            return Entry(file: .init(path: path, sha256: cached.sha256, size: outputSize, type: "audio/flac"),
                         cacheKey: key, derive: derive)
        }
        do {
            let output = try derive()
            let sha = try CallaBackendHashing.sha256(of: output)
            let outSize = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.int64Value ?? 0
            hashes[key] = CachedHash(size: size, mtime: mtime, sha256: sha, outputSize: outSize)
            return Entry(file: .init(path: path, sha256: sha, size: outSize, type: "audio/flac"), cacheKey: key, source: output)
        } catch {
            CallaBackendLog.write("\(relative) kept as WAV: \(error.localizedDescription)")
            return try fileEntry(wav, path: "raw/" + relative, key: "raw:" + relative, hashes: &hashes)
        }
    }

    static func convertToFLAC(_ wav: URL, output: URL) throws {
        let input = CallaBackendAudio.repairedWAV(wav) ?? wav
        defer { if input != wav { try? FileManager.default.removeItem(at: input) } }
        try? FileManager.default.removeItem(at: output)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = ["-f", "flac", "-d", "flac", input.path, output.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let produced = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.intValue ?? 0
        guard process.terminationStatus == 0, produced > 1024 else {
            try? FileManager.default.removeItem(at: output)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "afconvert could not encode \(wav.lastPathComponent)"])
        }
    }

    private func upload(_ entries: inout [Entry], client: CallaBackendClient, hashes: inout [String: CachedHash]) async throws {
        let missing = try await client.missing(Array(Set(entries.map(\.file.sha256))))
        var sent = Set<String>()
        for index in entries.indices where missing.contains(entries[index].file.sha256) {
            try Task.checkCancellation()
            var entry = entries[index]
            guard !sent.contains(entry.file.sha256) else { continue }
            if let data = entry.data {
                let staged = paths.stagingRoot.appendingPathComponent(UUID().uuidString)
                try fileManager.createDirectory(at: paths.stagingRoot, withIntermediateDirectories: true)
                try data.write(to: staged)
                defer { try? fileManager.removeItem(at: staged) }
                try await client.upload(file: staged, sha256: entry.file.sha256, size: entry.file.size)
            } else {
                let fresh = entry.source == nil
                let url: URL
                if let source = entry.source { url = source } else { url = try await offActor(entry.derive!) }
                if fresh {
                    // Re-derived for upload; record what this encode produced.
                    let sha = try await offActor { try CallaBackendHashing.sha256(of: url) }
                    let size = (try fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
                    if let key = entry.cacheKey {
                        hashes[key]?.sha256 = sha
                        hashes[key]?.outputSize = size
                    }
                    entry.file.sha256 = sha
                    entry.file.size = size
                    entry.source = url
                    entries[index] = entry
                }
                try await client.upload(file: url, sha256: entry.file.sha256, size: entry.file.size)
            }
            sent.insert(entry.file.sha256)
            if let source = entry.source, source.path.hasPrefix(paths.stagingRoot.path) {
                try? fileManager.removeItem(at: source)
            }
        }
    }

    private func buildManifest(callID: String, directory: URL, entries: [Entry]) async throws -> CallaBackendWire.CallManifest {
        let call = try? await store.call(id: callID)
        let recap = try? await store.recapDraft(forCall: callID)
        let speakers = (try? await store.speakers(forCall: callID)) ?? []
        let paths = Set(entries.map(\.file.path))
        var title: String? = nil
        if let entry = entries.first(where: { $0.file.path == "export/call.json" }), let source = entry.source,
           let object = try? JSONSerialization.jsonObject(with: Data(contentsOf: source)) as? [String: Any] {
            title = object["title"] as? String
        }
        let started = call?.startedAt ?? (try? fileManager.attributesOfItem(atPath: directory.path)[.creationDate] as? Date)
        return CallaBackendWire.CallManifest(
            callID: callID, appVersion: appVersion, schemaVersion: await store.schemaVersion,
            flags: .init(accurateTranscript: paths.contains("raw/transcript-archive.jsonl"),
                         recap: recap != nil, speakers: !speakers.isEmpty,
                         audio: paths.contains { $0.hasSuffix(".flac") || $0.hasSuffix(".wav") }),
            call: .init(persona: call?.persona, title: title ?? call?.eventTitle, startedAt: started,
                        endedAt: call?.endedAt, eventID: call?.eventID, seriesID: call?.seriesID),
            files: entries.map(\.file).sorted { $0.path < $1.path })
    }

    // MARK: Device snapshot

    /// Voiceprints, knowledge, tutor state, store meta and settings. Sent when
    /// it changed, at most every 30 minutes.
    func syncDeviceIfDue(force: Bool = false) async throws {
        if !force, let last = lastDeviceSnapshot, Date().timeIntervalSince(last) < 1800 { return }
        guard let client = await client() else { return }
        lastDeviceSnapshot = Date()
        var files: [(CallaBackendWire.File, Data)] = []
        let rows = try await store.backupDeviceRows()
        for (table, data) in rows.tables {
            files.append((.init(path: "store/\(table).jsonl", sha256: CallaBackendHashing.sha256(of: data),
                                size: Int64(data.count), type: "application/x-ndjson"), data))
        }
        for (path, url) in [("settings/app-preferences.plist", paths.appPreferences),
                            ("settings/engine-preferences.json", paths.engineRoot.appendingPathComponent("engine-preferences.json"))] {
            if let data = try? Data(contentsOf: url) {
                files.append((.init(path: path, sha256: CallaBackendHashing.sha256(of: data), size: Int64(data.count)), data))
            }
        }
        guard !files.isEmpty else { return }
        let manifest = CallaBackendWire.DeviceManifest(
            appVersion: appVersion, schemaVersion: rows.schemaVersion,
            hardware: Host.current().localizedName, files: files.map(\.0).sorted { $0.path < $1.path })
        let missing = try await client.missing(files.map(\.0.sha256))
        try fileManager.createDirectory(at: paths.stagingRoot, withIntermediateDirectories: true)
        for (file, data) in files where missing.contains(file.sha256) {
            let staged = paths.stagingRoot.appendingPathComponent(UUID().uuidString)
            try data.write(to: staged)
            defer { try? fileManager.removeItem(at: staged) }
            try await client.upload(file: staged, sha256: file.sha256, size: file.size)
        }
        struct Committed: Decodable { let version: Int }
        _ = try await client.json("POST", "v1/device/snapshot", body: manifest, as: Committed.self)
    }

    // MARK: Helpers

    private static func regularFiles(under root: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                                  options: [.skipsHiddenFiles]) else { return [] }
        return walker.compactMap { item -> URL? in
            guard let url = item as? URL,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            return url.resolvingSymlinksInPath()
        }.sorted { $0.path < $1.path }
    }

    private nonisolated func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func contentType(_ url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "json": "application/json"
        case "jsonl": "application/x-ndjson"
        case "md": "text/markdown"
        case "txt": "text/plain"
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        case "m4a": "audio/mp4"
        case "wav": "audio/wav"
        case "flac": "audio/flac"
        default: nil
        }
    }
}

/// `Calla/logs/backend.log`: what the archive did, readable without Console.
/// NSLog from this service is redacted in the unified log.
enum CallaBackendLog {
    private static let lock = NSLock()
    nonisolated(unsafe) static var url: URL?

    static func write(_ line: String) {
        guard let url else { return }
        lock.lock(); defer { lock.unlock() }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) \(line)\n".utf8)
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue, size > 4 << 20 {
            try? FileManager.default.removeItem(at: url.appendingPathExtension("1"))
            try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("1"))
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}

enum CallaBackendAudio {
    /// A copy of `url` with RIFF and data sizes matching the file, or nil when
    /// the header is already right (or not a WAV). Same repair the call-folder
    /// export applies before encoding m4a.
    static func repairedWAV(_ url: URL) -> URL? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 4096), header.count >= 44,
              header.prefix(4) == Data("RIFF".utf8),
              let length = try? handle.seekToEnd(), length > 44,
              let dataTag = header.range(of: Data("data".utf8)) else { return nil }
        let dataSizeOffset = dataTag.upperBound - header.startIndex
        let stored = header[header.startIndex + dataSizeOffset ..< header.startIndex + dataSizeOffset + 4]
            .enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }
        let actual = UInt32(clamping: length - UInt64(dataSizeOffset + 4))
        guard stored != actual else { return nil }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        do {
            try FileManager.default.copyItem(at: url, to: copy)
            let writer = try FileHandle(forWritingTo: copy)
            defer { try? writer.close() }
            func write(_ value: UInt32, at offset: UInt64) throws {
                try writer.seek(toOffset: offset)
                try writer.write(contentsOf: withUnsafeBytes(of: value.littleEndian) { Data($0) })
            }
            try write(UInt32(clamping: length - 8), at: 4)
            try write(actual, at: UInt64(dataSizeOffset))
            return copy
        } catch {
            try? FileManager.default.removeItem(at: copy)
            return nil
        }
    }
}
