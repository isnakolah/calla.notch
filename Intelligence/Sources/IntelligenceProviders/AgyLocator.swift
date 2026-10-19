import Foundation

/// Finds the `agy` binary.
///
/// Internal only, never user-supplied — the same principle as the copilot's
/// fixed Gateway URL: a transcript must not be steerable to an arbitrary
/// executable. A GUI app inherits a minimal `PATH`, so the well-known install
/// locations are checked directly before falling back to a login shell.
public enum AgyLocator {
    public static var managedPath: String {
        AgyEnvironment.userHome + "/Library/Application Support/calla.notch/Managed/agy/current/agy"
    }
    public static let knownPaths = [
        "~/.local/bin/agy",
        "/opt/homebrew/bin/agy",
        "/usr/local/bin/agy",
    ]

    /// The oldest `agy` this code can actually drive.
    ///
    /// `--output-format` arrived in the 1.1 line. Without it neither transport
    /// works: the print path cannot ask for JSON and the fast path cannot read a
    /// reply. An older binary still *launches* and still answers `--version`, so it
    /// looks installed while every request fails — which is exactly how a call came
    /// out transcribed but silent.
    public static let minimumVersion = [1, 1, 0]

    public struct Installation: Sendable, Equatable {
        public let path: String
        public let version: String
        public var components: [Int] { AgyLocator.versionComponents(version) }
        public var isSupported: Bool {
            AgyLocator.compare(components, AgyLocator.minimumVersion) >= 0
        }
    }

    /// Every `agy` on this machine, newest first.
    ///
    /// Two installs is not hypothetical: a Homebrew cask (1.0.6) alongside the
    /// self-installed 1.1.13 is what shipped this bug. Taking the first path that
    /// exists picks by accident; this picks by version.
    public static func installations() -> [Installation] {
        let previous = memoized()
        let fingerprint = fingerprint(alsoWatching: previous?.installations.map(\.path) ?? [])
        if let previous, previous.fingerprint == fingerprint, !previous.installations.isEmpty {
            return previous.installations
        }
        let found = discover()
        memoLock.lock()
        memo = Memo(fingerprint: fingerprint, installations: found)
        memoLock.unlock()
        return found
    }

    /// The search itself: known paths, then a login shell, then `--version` per
    /// candidate.
    ///
    /// Four process spawns, one of them a *login* shell — and `start()` ran the
    /// whole thing on every launch to answer a question whose answer changes when
    /// the user installs or upgrades `agy`. `installations()` now runs this only
    /// when the binaries on disk have actually moved.
    private static func discover() -> [Installation] {
        var seen: Set<String> = []
        var found: [Installation] = []
        var candidates = [managedPath] + knownPaths.map { expand($0) }
        if let shellPath = viaLoginShell() { candidates.append(shellPath) }

        for path in candidates {
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            guard !seen.contains(resolved), FileManager.default.isExecutableFile(atPath: path) else { continue }
            seen.insert(resolved)
            guard let version = version(of: path) else { continue }
            found.append(Installation(path: path, version: version))
        }
        return found.sorted { compare($0.components, $1.components) > 0 }
    }

    private struct Memo: Sendable {
        let fingerprint: String
        let installations: [Installation]
    }

    private static let memoLock = NSLock()
    nonisolated(unsafe) private static var memo: Memo?

    private static func memoized() -> Memo? {
        memoLock.lock(); defer { memoLock.unlock() }
        return memo
    }

    /// Size and modification date of every path the last search cared about.
    ///
    /// Deliberately not a hash of the binaries: `agy` is ~180 MB and this is
    /// consulted on a poll. A reinstall changes both fields, and an install in a
    /// place only the login shell knows about is watched too, so an upgrade there
    /// invalidates this as well.
    private static func fingerprint(alsoWatching extra: [String]) -> String {
        let paths = Set([managedPath] + knownPaths.map { expand($0) } + extra).sorted()
        return paths.map { path in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attributes[.size] as? Int,
                  let modified = attributes[.modificationDate] as? Date
            else { return "\(path)=-" }
            return "\(path)=\(size)@\(Int(modified.timeIntervalSince1970))"
        }.joined(separator: "|")
    }

    /// Drops the memo, so the next lookup searches again. For tests and for the
    /// moment after a sign-in, when an install may have just appeared.
    public static func forgetInstallations() {
        memoLock.lock(); memo = nil; memoLock.unlock()
    }

    /// The newest install this code can drive, or nil.
    public static func bestInstallation() -> Installation? {
        selectInstallation(installations())
    }

    static func selectInstallation(_ found: [Installation]) -> Installation? {
        // A private package deliberately pins its own CLI. A newer unrelated
        // global install must not silently replace that tested dependency.
        return found.first(where: { $0.path == managedPath && $0.isSupported })
            ?? found.filter(\.isSupported).max { compare($0.components, $1.components) < 0 }
    }

    public static func locate() -> String? {
        bestInstallation()?.path
    }

    /// Tilde expanded from the passwd database, not `NSHomeDirectory()`.
    ///
    /// In a sandboxed process the latter is the container, so `~/.local/bin/agy`
    /// resolved to a path that does not exist and the search fell through to
    /// whatever else was lying around.
    private static func expand(_ candidate: String) -> String {
        guard candidate.hasPrefix("~/") else { return candidate }
        return AgyEnvironment.userHome + String(candidate.dropFirst(1))
    }

    static func versionComponents(_ version: String) -> [Int] {
        // `agy --version` prints a bare `1.1.13`, but tolerate a prefix.
        let scanned = version.split(whereSeparator: { !$0.isNumber && $0 != "." })
            .first(where: { $0.contains(".") }) ?? Substring(version)
        return scanned.split(separator: ".").compactMap { Int($0) }
    }

    static func compare(_ lhs: [Int], _ rhs: [Int]) -> Int {
        for index in 0 ..< max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left < right ? -1 : 1 }
        }
        return 0
    }

    /// Also consulted, so an install in a place we do not know about still counts.
    private static func viaLoginShell() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "command -v agy"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    /// `agy --version`, for the Settings row. Cheap, but still a process — the
    /// provider caches it.
    public static func version(of binary: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["--version"]
        process.environment = AgyEnvironment.processEnvironment()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Whether `agy` has OAuth credentials on disk.
    ///
    /// Checks `~/.gemini/oauth_creds.json` for a `refresh_token` key —
    /// the durable credential that survives access-token rotation. The access
    /// token itself expires every hour, so its presence alone is not meaningful.
    ///
    /// This is a file-existence check, not a validity check: a revoked token
    /// still passes. Full validation would need a network call, and this runs
    /// on a 2-second poll.
    public static func hasCredentials() -> Bool {
        if let current = FileManager.default.contents(atPath: AgyEnvironment.cliOAuthTokenFile.path),
           !current.isEmpty {
            return true
        }
        guard let data = FileManager.default.contents(atPath: AgyEnvironment.credentialsFile.path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let refreshToken = json["refresh_token"] as? String,
              !refreshToken.isEmpty
        else { return false }
        return true
    }

    /// The Google account `agy` is authenticated as, from
    /// `~/.gemini/google_accounts.json`.
    public static func activeAccount() -> String? {
        guard let data = FileManager.default.contents(atPath: AgyEnvironment.accountsFile.path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let active = json["active"] as? String,
              !active.isEmpty
        else { return nil }
        return active
    }
}
