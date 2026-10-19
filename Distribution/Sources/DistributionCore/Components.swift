import CryptoKit
import Darwin
import Foundation

/// Everything setup installs outside the app lives in one folder:
///
///     ~/Library/Application Support/calla.notch/Components/
///       agy/<version>/agy            agy/current -> <version>
///       codex/<version>/bin/codex    codex/current -> <version>
///       claude/<version>/bin/claude  claude/current -> <version>
///       models/whisper-small-en.bin, whisper-large-v3-turbo.bin, …-encoder.mlmodelc
///       downloads/                   partial and cached downloads
///
/// The places older builds used (`Managed/agy`, `Calla/copilot/models`) become
/// links into it, so the engine and the call host find everything where they
/// always looked.
public enum ComponentLayout {
    public static let root = Layout.support.appendingPathComponent("Components")
    public static let models = root.appendingPathComponent("models")
    public static let downloads = root.appendingPathComponent("downloads")
    public static func tool(_ name: String) -> URL { root.appendingPathComponent(name) }
    /// The runnable binary of an installed tool, through its `current` link.
    public static func binary(_ name: String) -> URL {
        name == "agy" ? tool(name).appendingPathComponent("current/agy")
            : tool(name).appendingPathComponent("current/bin/\(name)")
    }
    /// Where older builds kept these. Each becomes a link to the new place.
    public static let legacyAgy = Layout.support.appendingPathComponent("Managed/agy")
    public static let legacyModels = Layout.support.appendingPathComponent("Calla/copilot/models")
    /// A folder carried from another Mac (USB drive, Downloads, beside the
    /// disk image). Setup checks it before downloading anything.
    public static let carryName = "calla.notch Components"
}

/// A speech model the call host needs, with the same pins the host uses.
public struct ModelSpec: Sendable {
    public let name: String
    public let title: String
    public let url: URL
    public let size: Int64
    public let sha256: String
    /// A zipped CoreML encoder that unpacks to `<name>-encoder.mlmodelc`.
    public let encoder: (url: URL, size: Int64, sha256: String)?
    public var file: String { name + ".bin" }
    /// The title as it reads mid-sentence: "the English speech model".
    public var phrase: String { title.prefix(1) == "E" ? "the " + title : "the " + title.prefix(1).lowercased() + title.dropFirst() }
    public var encoderDirectory: String { name + "-encoder.mlmodelc" }

    public static let live = ModelSpec(
        name: "whisper-small-en", title: "English speech model",
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin")!,
        size: 487_614_201, sha256: "c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d",
        encoder: nil)
    public static let archive = ModelSpec(
        name: "whisper-large-v3-turbo", title: "After-call transcription model",
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!,
        size: 1_624_555_275, sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69",
        encoder: (URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-encoder.mlmodelc.zip")!,
                  1_173_393_014, "84bedfe895bd7b5de6e8e89a0803dfc5addf8c0c5bc4c937451716bf7cf7988a"))
}

/// One moment of a copy, download or checksum, as the window shows it.
public struct TransferStatus: Sendable {
    public let verb: String
    public let name: String
    public let done: Int64
    public let total: Int64
    public let bytesPerSecond: Double

    public var fraction: Double? { total > 0 ? min(1, Double(done) / Double(total)) : nil }

    /// "120 MB of 488 MB · 8.1 MB/s · about 45 s left"
    public var summary: String {
        var parts = [total > 0 ? "\(Self.size(done)) of \(Self.size(total))" : Self.size(done)]
        if bytesPerSecond > 0 {
            parts.append(Self.size(Int64(bytesPerSecond)) + "/s")
            if total > done {
                parts.append("about " + Self.duration(Double(total - done) / bytesPerSecond) + " left")
            }
        }
        return parts.joined(separator: " · ")
    }

    public static func size(_ bytes: Int64) -> String {
        let value = Double(bytes)
        if value >= 1_000_000_000 { return String(format: "%.2f GB", value / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.0f MB", value / 1_000_000) }
        return String(format: "%.0f KB", value / 1_000)
    }

    public static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(max(s, 1)) s" }
        if s < 3600 { return "\(s / 60) min \(s % 60) s" }
        return "\(s / 3600) h \((s % 3600) / 60) min"
    }
}

/// Copies, downloads and checksums that report progress as they go.
public final class Transfer: @unchecked Sendable {
    public typealias Report = (TransferStatus) -> Void

    private let verb: String
    private let name: String
    private let total: Int64
    private let report: Report
    private var done: Int64 = 0
    private var lastReport = Date.distantPast
    private var lastReportedDone: Int64 = -1
    private var samples: [(Date, Int64)] = []

    public init(_ verb: String, _ name: String, total: Int64, report: @escaping Report) {
        self.verb = verb; self.name = name; self.total = total; self.report = report
    }

    /// Adds bytes. Reports at most four times a second, plus the last one.
    public func advance(_ bytes: Int64, force: Bool = false) {
        done += bytes
        let now = Date()
        guard force || now.timeIntervalSince(lastReport) >= 0.25 else { return }
        // Nothing new to say (a final report right after the last chunk).
        if bytes == 0, done == lastReportedDone { return }
        lastReportedDone = done
        lastReport = now
        samples.append((now, done))
        // Speed over the last five seconds, so a stall shows up quickly.
        samples.removeAll { now.timeIntervalSince($0.0) > 5 }
        var rate = 0.0
        if let first = samples.first, now.timeIntervalSince(first.0) > 0.5 {
            rate = Double(done - first.1) / now.timeIntervalSince(first.0)
        }
        report(TransferStatus(verb: verb, name: name, done: done, total: total, bytesPerSecond: rate))
    }

    public func finish() { advance(0, force: true) }

    // MARK: Checksums

    /// Streams a file through SHA-256 or SHA-512, reporting as it reads.
    public static func digest(_ url: URL, algorithm: String = "sha256", name: String,
                              report: @escaping Report) throws -> String {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)??.int64Value ?? 0
        let progress = Transfer("Checking", name, total: size, report: report)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var sha256 = SHA256(); var sha512 = SHA512()
        while let data = try handle.read(upToCount: 4 << 20), !data.isEmpty {
            if algorithm == "sha512" { sha512.update(data: data) } else { sha256.update(data: data) }
            progress.advance(Int64(data.count))
        }
        progress.finish()
        let bytes: [UInt8] = algorithm == "sha512" ? Array(sha512.finalize()) : Array(sha256.finalize())
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Whether `url` is the pinned file. A sidecar remembers a passing check
    /// by size and modification date, so resuming setup does not re-read
    /// gigabytes it has already verified.
    public static func verify(_ url: URL, sha256: String, size: Int64? = nil, name: String,
                              report: @escaping Report) -> Bool {
        let manager = FileManager.default
        guard let attributes = try? manager.attributesOfItem(atPath: url.path),
              let actualSize = (attributes[.size] as? NSNumber)?.int64Value else { return false }
        if let size, actualSize != size { return false }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let stamp = "\(sha256) \(actualSize) \(Int(modified))"
        let sidecar = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".verified")
        if (try? String(contentsOf: sidecar, encoding: .utf8)) == stamp { return true }
        guard (try? digest(url, name: name, report: report)) == sha256.lowercased() else { return false }
        try? stamp.write(to: sidecar, atomically: true, encoding: .utf8)
        return true
    }

    // MARK: Copies

    /// Copies a file or a folder, hard-linking files when they share a volume
    /// (instant, no extra space) and copying with progress when they do not.
    public static func copy(_ source: URL, to destination: URL, name: String, report: @escaping Report) throws {
        let manager = FileManager.default
        let source = source.resolvingSymlinksInPath()
        let files = try regularFiles(in: source)
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        let progress = Transfer("Copying", name, total: total, report: report)
        let stage = destination.deletingLastPathComponent()
            .appendingPathComponent(".copy-" + UUID().uuidString)
        try manager.createDirectory(at: stage.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: stage) }
        var isDirectory: ObjCBool = false
        manager.fileExists(atPath: source.path, isDirectory: &isDirectory)
        if isDirectory.boolValue { try manager.createDirectory(at: stage, withIntermediateDirectories: true) }
        for file in files {
            let target = isDirectory.boolValue ? stage.appendingPathComponent(file.relative) : stage
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? manager.linkItem(at: file.url, to: target)) != nil {
                progress.advance(file.size)
                continue
            }
            try copyFile(file.url, to: target, progress: progress)
            let mode = (try? manager.attributesOfItem(atPath: file.url.path)[.posixPermissions]) ?? 0o644
            try? manager.setAttributes([.posixPermissions: mode], ofItemAtPath: target.path)
        }
        // Symbolic links inside a tree (for example a tool's resources).
        if isDirectory.boolValue, let walker = manager.enumerator(atPath: source.path) {
            for case let relative as String in walker {
                let item = source.appendingPathComponent(relative)
                guard let link = try? manager.destinationOfSymbolicLink(atPath: item.path) else { continue }
                let target = stage.appendingPathComponent(relative)
                try? manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? manager.createSymbolicLink(atPath: target.path, withDestinationPath: link)
            }
        }
        progress.finish()
        if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
        try manager.moveItem(at: stage, to: destination)
    }

    private static func copyFile(_ source: URL, to target: URL, progress: Transfer) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: target.path, contents: nil)
        let output = try FileHandle(forWritingTo: target)
        defer { try? output.close() }
        while let data = try input.read(upToCount: 8 << 20), !data.isEmpty {
            try output.write(contentsOf: data)
            progress.advance(Int64(data.count))
        }
    }

    private static func regularFiles(in root: URL) throws -> [(url: URL, relative: String, size: Int64)] {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            throw SetupFailure("\(root.lastPathComponent) is missing.")
        }
        func size(_ url: URL) -> Int64 {
            ((try? manager.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
        }
        guard isDirectory.boolValue else { return [(root, root.lastPathComponent, size(root))] }
        var files: [(URL, String, Int64)] = []
        for case let relative as String in manager.enumerator(atPath: root.path) ?? NSEnumerator() {
            let url = root.appendingPathComponent(relative)
            guard let type = try? manager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType,
                  type == .typeRegular else { continue }
            files.append((url, relative, size(url)))
        }
        return files
    }

    // MARK: Downloads

    /// Downloads to `destination`, resuming a `.partial` file left by an
    /// interrupted attempt. Only https is followed, redirects included.
    public static func download(_ url: URL, to destination: URL, expectedSize: Int64?, name: String,
                                report: @escaping Report) throws {
        guard url.scheme == "https" else { throw SetupFailure("Refusing a download that is not https.") }
        let partial = destination.appendingPathExtension("partial")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let downloader = StreamingDownload(url: url, partial: partial, expectedSize: expectedSize, name: name, report: report)
        var attempts = 0
        while true {
            do { try downloader.run(); break }
            catch {
                attempts += 1
                // Network drops are common on a big model; pick up where it stopped.
                guard attempts < 4, downloader.isRetryable else { throw error }
                report(TransferStatus(verb: "Reconnecting", name: name, done: downloader.received, total: expectedSize ?? 0, bytesPerSecond: 0))
                Thread.sleep(forTimeInterval: Double(attempts * 2))
            }
        }
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: partial, to: destination)
    }
}

private final class StreamingDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let url: URL; let partial: URL; let expectedSize: Int64?; let name: String; let report: Transfer.Report
    private(set) var received: Int64 = 0
    private(set) var isRetryable = true
    private var handle: FileHandle?
    private var progress: Transfer?
    private var failure: Error?
    private let done = DispatchSemaphore(value: 0)

    init(url: URL, partial: URL, expectedSize: Int64?, name: String, report: @escaping Transfer.Report) {
        self.url = url; self.partial = partial; self.expectedSize = expectedSize; self.name = name; self.report = report
    }

    func run() throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: partial.path) { manager.createFile(atPath: partial.path, contents: nil) }
        received = (try? manager.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)??.int64Value ?? 0
        if let expectedSize, received >= expectedSize, expectedSize > 0 { return }
        var request = URLRequest(url: url, timeoutInterval: 60)
        if received > 0 { request.setValue("bytes=\(received)-", forHTTPHeaderField: "Range") }
        failure = nil
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        session.dataTask(with: request).resume()
        done.wait()
        try? handle?.close(); handle = nil
        if let failure { throw failure }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        do {
            switch http.statusCode {
            case 206: break
            case 200:
                // The server ignored the range; start over.
                received = 0
                try Data().write(to: partial)
            case 416:
                // The partial file is already complete.
                completionHandler(.cancel); return
            default:
                isRetryable = http.statusCode >= 500
                failure = SetupFailure("The download of \(name) failed (HTTP \(http.statusCode)). Check your internet connection and retry.")
                completionHandler(.cancel); return
            }
            let handle = try FileHandle(forWritingTo: partial)
            try handle.seekToEnd()
            self.handle = handle
            let length = http.expectedContentLength > 0 ? received + http.expectedContentLength : (expectedSize ?? 0)
            let progress = Transfer("Downloading", name, total: length, report: report)
            progress.advance(received, force: true)
            self.progress = progress
            completionHandler(.allow)
        } catch {
            failure = error; completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do { try handle?.write(contentsOf: data) } catch { failure = error; dataTask.cancel(); return }
        received += Int64(data.count)
        progress?.advance(Int64(data.count))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        progress?.finish()
        if failure == nil, let error, (error as NSError).code != NSURLErrorCancelled {
            let reason = error.localizedDescription.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            failure = SetupFailure("The download of \(name) stopped: \(reason). Retry to continue where it left off.")
        }
        done.signal()
    }
}
