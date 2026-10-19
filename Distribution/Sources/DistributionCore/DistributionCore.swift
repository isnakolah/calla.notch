import CallaContracts
import CryptoKit
import Darwin
import Foundation

public struct SetupFailure: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum Layout {
    public static let home = URL(fileURLWithPath: String(cString: getpwuid(getuid()).pointee.pw_dir))
    public static let support = CallaBrand.support(in: home)
    public static let setup = support.appendingPathComponent("Setup")
    public static let sessions = support.appendingPathComponent("Calla/Setup/sessions")
    /// Installed into Components (see `ComponentLayout`); `Managed/agy` is a
    /// link to it for builds that still look there.
    public static let agy = support.appendingPathComponent("Components/agy/current/agy")
    public static let app = CallaBrand.installedApp
    public static let tangit = app.appendingPathComponent("Contents/Helpers/tangit")
    public static func provider(_ name: String, in app: URL = Layout.app) -> URL {
        app.appendingPathComponent("Contents/Resources/Tangit/Providers/\(name)/bin/\(name)")
    }
    public static let callHost = "Contents/XPCServices/CallaEngine.xpc/Contents/Resources/CallaRuntime/CallaCallHost.app/Contents/MacOS/CallaCallHost"
    public static func privateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}

public struct ReleaseManifest: Codable, Equatable {
    public var schema: Int
    public var version: String
    public var build: Int
    public var architecture: String
    public var minimumOS: String
    public var agy: Dependency
    public var tailscale: Dependency
    public var codex: Dependency?
    public var claude: Dependency?
    public var tangit: Tangit?
    public var graphicalSetup: Bool?
    public struct Tangit: Codable, Equatable {
        public var version: String
        public var sourceRevision: String
        public var sourceSHA256: String
        public var deviceLogin: Bool
    }
    public struct Dependency: Codable, Equatable {
        public var version: String
        public var url: URL
        public var algorithm: String
        public var checksum: String
        public init(version: String, url: URL, algorithm: String, checksum: String) {
            self.version = version; self.url = url; self.algorithm = algorithm; self.checksum = checksum
        }
        public func validate() throws {
            let hosts = ["storage.googleapis.com", "pkgs.tailscale.com", "github.com", "downloads.claude.ai"]
            guard url.scheme == "https", hosts.contains(url.host ?? ""),
                  ["sha256", "sha512"].contains(algorithm),
                  checksum.count == (algorithm == "sha512" ? 128 : 64),
                  checksum.allSatisfy({ $0.isHexDigit }),
                  version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil
            else { throw SetupFailure("Invalid dependency manifest; obtain a new private package.") }
        }
    }
    public init(version: String, build: Int, agy: Dependency, tailscale: Dependency) {
        schema = 1; self.version = version; self.build = build
        architecture = "arm64"; minimumOS = "15.0"; self.agy = agy; self.tailscale = tailscale
    }
    public func validate() throws {
        guard schema == 1, architecture == "arm64", minimumOS == "15.0", build > 0,
              version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil
        else { throw SetupFailure("Unsupported private package manifest.") }
        try agy.validate(); try tailscale.validate()
        if let tangit {
            guard tangit.deviceLogin, !tangit.version.isEmpty,
                  tangit.sourceSHA256.count == 64, tangit.sourceSHA256.allSatisfy({ $0.isHexDigit }),
                  codex != nil, claude != nil else { throw SetupFailure("Incomplete Tangit package manifest.") }
            try codex?.validate(); try claude?.validate()
        }
    }
}

public enum Checksums {
    public static func digest(_ url: URL, algorithm: String = "sha256") throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var sha256 = SHA256(); var sha512 = SHA512()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            if algorithm == "sha512" { sha512.update(data: data) } else { sha256.update(data: data) }
        }
        let bytes: [UInt8] = algorithm == "sha512" ? Array(sha512.finalize()) : Array(sha256.finalize())
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
    public static func verify(_ url: URL, dependency: ReleaseManifest.Dependency) throws {
        try dependency.validate()
        guard try digest(url, algorithm: dependency.algorithm) == dependency.checksum.lowercased()
        else { throw SetupFailure("Download checksum failed. The installed copy has been preserved. Retry the download.") }
    }
}

public struct CommandResult {
    public let status: Int32
    public let output: String
}

public enum Commands {
    /// No shell interpolation. Capture stdout to disk so a verbose child cannot
    /// block on a full pipe. All temporary files are private and removed.
    @discardableResult
    public static func run(_ executable: String, _ arguments: [String] = [],
                           input: Data? = nil, inherit: Bool = false,
                           captureStderr: Bool = false,
                           environment extra: [String: String] = [:],
                           timeout: TimeInterval = 120, check: Bool = true) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "CALLA_SETUP_EVENT_TOKEN")
        environment["AGY_CLI_DISABLE_AUTO_UPDATE"] = "1"
        environment["AGY_CLI_NONINTERACTIVE_HEADLESS"] = "1"
        environment["BROWSER"] = "/usr/bin/true"
        environment.merge(extra) { _, new in new }
        if inherit && input == nil {
            let status = try spawnInForeground(executable, arguments, environment: environment, timeout: timeout)
            if check && status != 0 {
                throw SetupFailure("\(URL(fileURLWithPath: executable).lastPathComponent) failed (\(status)). Retry this step; run doctor for readiness.")
            }
            return CommandResult(status: status, output: "")
        }
        process.environment = environment
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Layout.privateDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outURL = directory.appendingPathComponent("stdout")
        FileManager.default.createFile(atPath: outURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: outURL)
        defer { try? output.close() }
        if !inherit { process.standardOutput = output; process.standardError = captureStderr ? output : FileHandle.nullDevice }
        if let input {
            let inURL = directory.appendingPathComponent("stdin")
            try input.write(to: inURL)
            process.standardInput = try FileHandle(forReadingFrom: inURL)
        } else if !inherit { process.standardInput = FileHandle.nullDevice }
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.2)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw SetupFailure("\(URL(fileURLWithPath: executable).lastPathComponent) timed out; retry this step.")
        }
        process.waitUntilExit()
        try output.synchronize()
        let text = inherit ? "" : String(decoding: (try? Data(contentsOf: outURL)) ?? Data(), as: UTF8.self)
        if check && process.terminationStatus != 0 {
            throw SetupFailure("\(URL(fileURLWithPath: executable).lastPathComponent) failed (\(process.terminationStatus)). Retry this step; run doctor for readiness.")
        }
        return CommandResult(status: process.terminationStatus, output: text)
    }
    /// Process starts its child in a new process group. On a terminal that
    /// group is in the background, so an interactive tool such as Tangit's
    /// wizard is stopped by SIGTTIN/SIGTTOU the moment it touches the screen.
    /// posix_spawn without attributes keeps the child in the caller's group.
    private static func spawnInForeground(_ executable: String, _ arguments: [String],
                                          environment: [String: String], timeout: TimeInterval) throws -> Int32 {
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, executable, nil, nil, argv, envp)
        guard spawned == 0 else { throw SetupFailure("Could not start \(URL(fileURLWithPath: executable).lastPathComponent): \(String(cString: strerror(spawned)))") }
        let deadline = Date().addingTimeInterval(timeout)
        var status: Int32 = 0
        while true {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid { break }
            if result == -1 && errno != EINTR { throw SetupFailure("Lost track of \(URL(fileURLWithPath: executable).lastPathComponent).") }
            if Date() >= deadline {
                kill(pid, SIGTERM)
                Thread.sleep(forTimeInterval: 0.2)
                kill(pid, SIGKILL)
                waitpid(pid, &status, 0)
                throw SetupFailure("\(URL(fileURLWithPath: executable).lastPathComponent) timed out; retry this step.")
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        // WIFEXITED / WEXITSTATUS, which Swift does not import.
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }
    public static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

public struct Progress: Codable {
    public var completed: Set<String> = []
    public var skipped: Set<String> = []
    public var meetingTestPassed = false
    public init() {}
    public static func read(_ url: URL) -> Progress {
        (try? JSONDecoder().decode(Self.self, from: Data(contentsOf: url))) ?? Progress()
    }
    public func write(_ url: URL) throws {
        try Layout.privateDirectory(url.deletingLastPathComponent())
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public enum Readiness {
    public static func aiResponded(_ data: Data) -> Bool {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["status"] as? String == "SUCCESS",
              let response = value["response"] as? String else { return false }
        return response.trimmingCharacters(in: .whitespacesAndNewlines) == "READY"
    }
}
