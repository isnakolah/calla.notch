import CryptoKit
import Foundation

/// The call archive on nomonhomelab (`Backend/` in this repo). This Mac signs
/// in with its own device token: issued once over HTTPS and kept in a
/// 0600 file in the runtime directory, never in settings or the package.
///
/// A file rather than the Keychain: this service is re-signed on every local
/// build, and a file-based Keychain item then blocks on an access prompt — on
/// the engine's queue, which would stall calls behind a dialog. The file
/// survives deleting and reinstalling the app, so sign-in stays automatic, and
/// if it is ever lost, enrollment reuses this Mac's device by name.
struct CallaBackendCredential: Codable, Equatable {
    var url: URL
    var deviceID: String
    var token: String
    var name: String

    enum CodingKeys: String, CodingKey {
        case url, token, name
        case deviceID = "device_id"
    }
}

enum CallaBackendCredentialStore {
    nonisolated(unsafe) static var url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("calla.notch/Calla/backend/credential.json")

    static func load() -> CallaBackendCredential? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CallaBackendCredential.self, from: data)
    }

    static func save(_ credential: CallaBackendCredential) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // No .completeFileProtection: on macOS it fails the write with EPERM.
        try JSONEncoder().encode(credential).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Where and how this Mac enrolls: the archive URL and the enrollment secret
/// that `scripts/package-private.sh` bakes into the private package. A
/// development build reads the same JSON from beside the credential instead.
struct CallaBackendEnrollmentConfig: Codable {
    var url: URL
    var secret: String

    static let bundledPath = "PrivateSetup/archive-enrollment.json"

    static func load() -> CallaBackendEnrollmentConfig? {
        // The engine runs at App/Contents/XPCServices/Engine.xpc.
        let resources = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
        let candidates = [resources.appendingPathComponent(bundledPath),
                          CallaBackendCredentialStore.url.deletingLastPathComponent().appendingPathComponent("enrollment.json")]
        for url in candidates {
            if let data = try? Data(contentsOf: url),
               let config = try? JSONDecoder().decode(CallaBackendEnrollmentConfig.self, from: data),
               config.url.scheme == "https", !config.secret.isEmpty {
                return config
            }
        }
        return nil
    }
}

/// Issues this Mac a device token from the archive's `POST /v1/enroll`,
/// authorised by the enrollment secret in its private package.
enum CallaBackendEnrollment {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Enrolls, or rotates the token of `existingDeviceID` so a reinstalled Mac
    /// keeps its identity.
    static func enroll(existingDeviceID: String? = nil, session: URLSession = .shared) async throws -> CallaBackendCredential {
        guard let config = CallaBackendEnrollmentConfig.load() else {
            throw Failure(message: "This build has no call archive enrollment, so this Mac cannot sign in.")
        }
        let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        var body = ["name": name]
        // A Mac that lost its credential file gets its old identity back by name.
        if let id = existingDeviceID, id.range(of: "^dev_[0-9a-f]{16}$", options: .regularExpression) != nil {
            body["device_id"] = id
        }
        var request = URLRequest(url: config.url.appendingPathComponent("v1/enroll"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.secret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let said = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
                ?? String(decoding: data.prefix(200), as: UTF8.self)
            throw Failure(message: "Call archive sign-in failed (\(status))" + (said.isEmpty ? "." : ": \(said)"))
        }
        guard let credential = try? JSONDecoder().decode(CallaBackendCredential.self, from: data),
              credential.url.scheme == "https", credential.token.hasPrefix("cbk_") else {
            throw Failure(message: "Call archive sign-in returned an unexpected answer.")
        }
        try CallaBackendCredentialStore.save(credential)
        return credential
    }
}

/// Wire types shared with `Backend/internal/manifest`.
enum CallaBackendWire {
    struct File: Codable, Equatable {
        var path: String
        var sha256: String
        var size: Int64
        var type: String?
    }

    struct Flags: Codable, Equatable {
        var accurateTranscript: Bool
        var recap: Bool
        var speakers: Bool
        var audio: Bool

        enum CodingKeys: String, CodingKey {
            case recap, speakers, audio
            case accurateTranscript = "accurate_transcript"
        }
    }

    struct CallInfo: Codable, Equatable {
        var persona: String?
        var title: String?
        var startedAt: Date?
        var endedAt: Date?
        var eventID: String?
        var seriesID: String?

        enum CodingKeys: String, CodingKey {
            case persona, title
            case startedAt = "started_at", endedAt = "ended_at", eventID = "event_id", seriesID = "series_id"
        }
    }

    struct CallManifest: Codable, Equatable {
        var format = 1
        var callID: String
        var appVersion: String?
        var schemaVersion: Int?
        var flags: Flags
        var call: CallInfo
        var files: [File]
        var deviceID: String?
        var version: Int?

        enum CodingKeys: String, CodingKey {
            case format, flags, call, files, version
            case callID = "call_id", appVersion = "app_version", schemaVersion = "schema_version", deviceID = "device_id"
        }
    }

    struct DeviceManifest: Codable, Equatable {
        var format = 1
        var appVersion: String?
        var schemaVersion: Int?
        var hardware: String?
        var files: [File]
        var deviceID: String?
        var version: Int?

        enum CodingKeys: String, CodingKey {
            case format, hardware, files, version
            case appVersion = "app_version", schemaVersion = "schema_version", deviceID = "device_id"
        }
    }

    struct Bundle: Codable {
        var id: String
        var description: String?
        var files: [File]
    }

    struct Message: Codable {
        var id: Int64
        var kind: String
        var payload: JSONValue
    }

    struct Restore: Codable {
        var deviceID: String
        var deviceSnapshot: DeviceManifest?
        var calls: [CallManifest]

        enum CodingKeys: String, CodingKey {
            case calls
            case deviceID = "device_id", deviceSnapshot = "device_snapshot"
        }
    }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
                let f = ISO8601DateFormatter(); f.formatOptions = options
                if let date = f.date(from: text) { return date }
            }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(text)"))
        }
        return d
    }
}

/// Any JSON value, for inbox payloads whose shape depends on their kind.
enum JSONValue: Codable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case let .bool(v): try c.encode(v)
        case let .number(v): try c.encode(v)
        case let .string(v): try c.encode(v)
        case let .array(v): try c.encode(v)
        case let .object(v): try c.encode(v)
        }
    }

    subscript(key: String) -> JSONValue? {
        if case let .object(o) = self { return o[key] }
        return nil
    }

    var string: String? { if case let .string(s) = self { return s }; return nil }
    var number: Double? { if case let .number(n) = self { return n }; return nil }
    var array: [JSONValue]? { if case let .array(a) = self { return a }; return nil }

    /// Re-decodes this value as a typed payload.
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try CallaBackendWire.decoder().decode(T.self, from: JSONEncoder().encode(self))
    }
}

/// HTTP client for the backend. Stateless apart from the credential.
struct CallaBackendClient {
    let credential: CallaBackendCredential
    let session: URLSession

    /// Cloudflare refuses request bodies over 100 MB; stay well under it, and
    /// small enough that a stalled chunk costs little to resend.
    static let chunkSize: Int64 = 16 << 20

    struct HTTPFailure: LocalizedError {
        let status: Int
        let body: String
        var errorDescription: String? { "backend answered \(status): \(body.prefix(200))" }
        var isAuth: Bool { status == 401 }
    }

    init(credential: CallaBackendCredential, session: URLSession = .shared) {
        self.credential = credential
        self.session = session
    }

    private func request(_ method: String, _ path: String, query: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(url: credential.url.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120
        return request
    }

    private func check(_ data: Data, _ response: URLResponse, allow: Set<Int> = [200, 201]) throws -> Data {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard allow.contains(status) else {
            throw HTTPFailure(status: status, body: String(decoding: data, as: UTF8.self))
        }
        return data
    }

    func json<T: Decodable>(_ method: String, _ path: String, body: (some Encodable)? = Optional<Int>.none,
                            query: [URLQueryItem] = [], as: T.Type) async throws -> T {
        var req = request(method, path, query: query)
        if let body {
            req.httpBody = try CallaBackendWire.encoder().encode(body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: req)
        return try CallaBackendWire.decoder().decode(T.self, from: check(data, response))
    }

    struct Missing: Decodable { let missing: [String] }

    func missing(_ shas: [String]) async throws -> Set<String> {
        var out = Set<String>()
        for start in stride(from: 0, to: shas.count, by: 5_000) {
            let batch = Array(shas[start ..< min(start + 5_000, shas.count)])
            out.formUnion(try await json("POST", "v1/blobs/check", body: ["sha256": batch], as: Missing.self).missing)
        }
        return out
    }

    private struct ChunkAnswer: Decodable {
        let offset: Int64?
        let done: Bool?
    }

    /// Uploads one file under its digest, in resumable chunks when large.
    func upload(file url: URL, sha256: String, size: Int64) async throws {
        if size <= Self.chunkSize {
            var req = request("PUT", "v1/blobs/\(sha256)")
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 300
            let (data, response) = try await session.upload(for: req, fromFile: url)
            _ = try check(data, response)
            return
        }
        // Resume from wherever the server got to last time.
        var offset = try await json("GET", "v1/blobs/\(sha256)", query: [.init(name: "offset", value: "")], as: ChunkAnswer.self).offset ?? 0
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while offset < size {
            try handle.seek(toOffset: UInt64(offset))
            let chunk = try handle.read(upToCount: Int(min(Self.chunkSize, size - offset))) ?? Data()
            guard !chunk.isEmpty else { throw CocoaError(.fileReadUnknown) }
            var req = request("PUT", "v1/blobs/\(sha256)", query: [
                .init(name: "offset", value: String(offset)), .init(name: "total", value: String(size)),
            ])
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 300
            let (data, response) = try await session.upload(for: req, from: chunk)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let answer = try? JSONDecoder().decode(ChunkAnswer.self, from: data)
            if status == 409, let server = answer?.offset {
                offset = server // someone (an earlier attempt) got further, or less far
                continue
            }
            _ = try check(data, response)
            if answer?.done == true { return }
            offset = answer?.offset ?? (offset + Int64(chunk.count))
        }
    }

    /// Downloads a blob to `destination`, resuming a partial file and checking
    /// the digest before moving it into place.
    func download(sha256: String, to destination: URL) async throws {
        let partial = destination.appendingPathExtension("partial")
        let have = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? 0
        var req = request("GET", "v1/blobs/\(sha256)")
        if have > 0 { req.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }
        req.timeoutInterval = 600
        let (temp, response) = try await session.download(for: req)
        defer { try? FileManager.default.removeItem(at: temp) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 || status == 206 else {
            throw HTTPFailure(status: status, body: (try? String(contentsOf: temp, encoding: .utf8)) ?? "")
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if status == 206, FileManager.default.fileExists(atPath: partial.path) {
            let out = try FileHandle(forWritingTo: partial)
            try out.seekToEnd()
            try out.write(contentsOf: Data(contentsOf: temp, options: .alwaysMapped))
            try out.close()
        } else {
            try? FileManager.default.removeItem(at: partial)
            try FileManager.default.moveItem(at: temp, to: partial)
        }
        guard try CallaBackendHashing.sha256(of: partial) == sha256 else {
            try? FileManager.default.removeItem(at: partial)
            throw CocoaError(.fileReadCorruptFile)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
    }
}

enum CallaBackendHashing {
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
