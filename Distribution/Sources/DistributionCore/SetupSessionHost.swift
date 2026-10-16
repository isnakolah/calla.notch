import Darwin
import Foundation

/// Lives in the app's existing unsandboxed XPC service. The UI keeps its normal
/// sandbox and communicates only with this app-owned installation process.
public final class SetupSessionHost: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var token: String?
    private var output = Data()
    private var status: Int32?
    public init() {}

    public func handle(_ request: [String: Any], app: URL) -> [String: Any] {
        do {
            guard let command = request["uiCommand"] as? String else { throw SetupFailure("Invalid setup request.") }
            if command == "isSetupRunning" {
                let descriptor = Darwin.open(Layout.setup.appendingPathComponent("setup.lock").path, O_RDWR)
                guard descriptor >= 0 else { return ["running": false] }
                defer { close(descriptor) }
                if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                    flock(descriptor, LOCK_UN)
                    return ["running": false]
                }
                return ["running": true]
            }
            if command == "launchTangit" {
                try TerminalLauncher.open(executable: Layout.app.appendingPathComponent("Contents/Helpers/boring-notch"), arguments: ["tangit"])
                return ["ok": true]
            }
            guard let token = request["token"] as? String, UUID(uuidString: token) != nil else { throw SetupFailure("Invalid setup session.") }
            if command == "start" { return try start(app: app, token: token, repair: request["repair"] as? Bool == true) }
            lock.lock(); defer { lock.unlock() }
            guard self.token == token else { throw SetupFailure("Setup session ended. Reopen setup to continue.") }
            switch command {
            case "read":
                let bytes = output; output.removeAll(keepingCapacity: true)
                var result: [String: Any] = ["output": bytes.base64EncodedString(), "running": status == nil]
                if let status { result["status"] = Int(status) }
                return result
            case "input":
                guard let line = request["input"] as? String, ["y\n", "n\n", "\n"].contains(line), let input else {
                    throw SetupFailure("The setup process is no longer accepting input.")
                }
                try input.write(contentsOf: Data(line.utf8))
                return ["ok": true]
            case "stop":
                stopLocked()
                return ["ok": true]
            default: throw SetupFailure("Unknown setup action.")
            }
        } catch { return ["error": error.localizedDescription] }
    }

    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        stopLocked()
    }

    private func stopLocked() {
        try? input?.close()
        if let process, process.isRunning {
            Self.terminateChildren(process.processIdentifier)
            process.terminate()
        }
    }

    private func start(app: URL, token: String, repair: Bool) throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        guard process?.isRunning != true else { throw SetupFailure("Setup is already running. Finish or pause its current window first.") }
        _ = try PackageInstaller.validate(app)
        let process = Process()
        process.executableURL = app.appendingPathComponent("Contents/Helpers/boring-notch")
        process.arguments = ["setup", "--gui", "--package", app.path] + (repair ? ["--repair"] : [])
        process.currentDirectoryURL = Layout.home
        var environment = ProcessInfo.processInfo.environment
        environment["BORING_SETUP_EVENT_TOKEN"] = token
        environment["NSUnbufferedIO"] = "YES"
        process.environment = environment
        let stdout = Pipe(); let stdin = Pipe()
        process.standardOutput = stdout; process.standardError = stdout; process.standardInput = stdin
        try process.run()
        self.process = process; input = stdin.fileHandleForWriting; self.token = token
        output = Data(); status = nil
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            while true {
                let chunk = stdout.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                lock.lock()
                output.append(chunk)
                if output.count > 1_000_000 { output = Data(output.suffix(1_000_000)) }
                lock.unlock()
            }
            process.waitUntilExit()
            lock.lock(); status = process.terminationStatus; lock.unlock()
        }
        return ["ok": true]
    }

    private static func terminateChildren(_ pid: Int32) {
        guard let result = try? Commands.run("/usr/bin/pgrep", ["-P", String(pid)], check: false) else { return }
        for child in result.output.split(whereSeparator: { $0.isWhitespace }).compactMap({ Int32($0) }) {
            terminateChildren(child); kill(child, SIGTERM)
        }
    }
}
