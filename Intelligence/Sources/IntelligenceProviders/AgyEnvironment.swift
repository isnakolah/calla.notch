import Darwin
import Foundation

/// Where `agy` keeps its state, and the environment every spawn of it needs.
///
/// This exists because of a bug that presents as a lie: Settings says "signed in"
/// while a call pops a browser asking the user to sign in again.
///
/// `agy` stores credentials under `$HOME/.gemini`. The app is sandboxed, so in it
/// `NSHomeDirectory()` is the container (`~/Library/Containers/…/Data`), not the
/// user's home — and passing that as `HOME` to a child points it at a `.gemini`
/// that does not exist, so it starts a fresh OAuth flow. Meanwhile whichever
/// process happened to be unsandboxed reported the real credentials as present.
/// Two answers to one question.
///
/// `getpwuid` is the fix: the sandbox redirects `NSHomeDirectory()` but not the
/// passwd database, so every process in the app — sandboxed or not — resolves the
/// same home and therefore the same credentials.
public enum AgyEnvironment {
    /// The user's real home directory, whatever the caller's sandbox says.
    public static let userHome: String = {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            let path = String(cString: dir)
            if !path.isEmpty { return path }
        }
        // Only reachable if the passwd entry is unreadable, in which case the
        // container path is no worse than nothing.
        return NSHomeDirectory()
    }()

    public static var configDirectory: URL {
        URL(fileURLWithPath: userHome).appendingPathComponent(".gemini")
    }

    public static var credentialsFile: URL {
        configDirectory.appendingPathComponent("oauth_creds.json")
    }

    public static var accountsFile: URL {
        configDirectory.appendingPathComponent("google_accounts.json")
    }

    /// AGY 1.1.x refreshes its active CLI credential here. Copying only the
    /// legacy oauth_creds.json into an isolated worker HOME makes the parent
    /// authenticate successfully while every Quiz child reports "authentication
    /// required". This file is short-lived inside each private worker HOME.
    public static var cliOAuthTokenFile: URL {
        configDirectory.appendingPathComponent("antigravity-cli/antigravity-oauth-token")
    }

    /// Every file that can hold a usable AGY credential, newest format first.
    ///
    /// This exists so nothing has to keep its own list. `CallaEngine` did,
    /// naming only `oauth_creds.json`, and on an AGY 1.1.x install that made a
    /// successful sign-in invisible: `agy` authenticated through the keyring and
    /// wrote `antigravity-oauth-token`, while the engine polled the path that no
    /// longer gets written and held the sign-in TUI open until it timed out.
    public static var credentialLocations: [URL] {
        [cliOAuthTokenFile, credentialsFile]
    }

    /// What `agy` keeps in `antigravity-oauth-token`, as much of it as anything
    /// here needs to know.
    ///
    /// The shape is `{"auth_method": …, "token": {access_token, refresh_token,
    /// token_type, expiry}}`, and `expiry` is RFC 3339 with microseconds and an
    /// offset. Only the two tokens' presence and the expiry matter: this exists
    /// to answer "is this blob usable, and is it newer than the one we have".
    public struct AgyStoredToken: Sendable, Equatable {
        public let expiry: Date
        public let hasAccessToken: Bool
        public let hasRefreshToken: Bool

        /// A blob with an empty token in it is worse than no blob at all — it
        /// authenticates as nobody, and it does so silently.
        public var isUsable: Bool { hasAccessToken && hasRefreshToken }
    }

    public static func storedToken(at url: URL) -> AgyStoredToken? {
        guard let data = FileManager.default.contents(atPath: url.path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = root["token"] as? [String: Any],
              let expiry = (token["expiry"] as? String).flatMap(parseExpiry)
        else { return nil }
        return AgyStoredToken(
            expiry: expiry,
            hasAccessToken: !((token["access_token"] as? String) ?? "").isEmpty,
            hasRefreshToken: !((token["refresh_token"] as? String) ?? "").isEmpty)
    }

    /// `2026-08-31T01:53:05.729239+03:00`.
    ///
    /// Six fractional digits, which `ISO8601DateFormatter` will not always take,
    /// so the fraction is dropped on the second attempt rather than the whole
    /// token being treated as unreadable.
    private static func parseExpiry(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }
        guard let dot = text.firstIndex(of: "."),
              let offset = text[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" })
        else { return nil }
        return plain.date(from: String(text[text.startIndex ..< dot] + text[offset...]))
    }

    /// Moves a token an isolated worker refreshed back to the real one.
    ///
    /// `agy` keeps the credential in the keychain *and* in this file, and on this
    /// machine the keychain read fails non-interactively (`exit status 36`) and
    /// it falls back to the file every time — so the file is the only credential
    /// the app actually has. Workers run against a copy of it in a private HOME;
    /// the access token lasts an hour, so a worker routinely refreshes, and that
    /// refreshed token used to be deleted along with the worker's directory.
    /// App use could therefore only ever consume the freshness of the last time
    /// somebody ran `agy` by hand, and eventually demanded a fresh sign-in.
    ///
    /// Guarded in both directions: the worker's blob must parse and hold both
    /// tokens, and must be strictly newer. A bad file is worse than no file.
    @discardableResult
    public static func promoteRefreshedToken(from workerHome: URL) -> Bool {
        promoteRefreshedToken(from: workerHome, into: cliOAuthTokenFile)
    }

    /// Split out so it can be tested without writing into the real `~/.gemini`.
    @discardableResult
    static func promoteRefreshedToken(from workerHome: URL, into destination: URL) -> Bool {
        let source = workerHome
            .appendingPathComponent(".gemini/antigravity-cli")
            .appendingPathComponent(cliOAuthTokenFile.lastPathComponent)
        guard let refreshed = storedToken(at: source), refreshed.isUsable else { return false }
        if let current = storedToken(at: destination), refreshed.expiry <= current.expiry {
            return false
        }
        guard let data = FileManager.default.contents(atPath: source.path) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: destination.path)
        } catch {
            return false
        }
        return true
    }

    public static var conversationsDirectory: URL {
        configDirectory.appendingPathComponent("antigravity-cli/conversations")
    }

    public static var brainDirectory: URL {
        configDirectory.appendingPathComponent("antigravity-cli/brain")
    }

    /// Environment for a spawned `agy`, with `HOME` pinned to the real one so the
    /// child reads the same credentials the app reports on.
    ///
    /// A GUI app also inherits a minimal `PATH`, so the usual install locations
    /// are added — `agy` shells out to `git` and friends.
    public static func processEnvironment(
        adding extra: [String: String] = [:]
    ) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["AGY_CLI_DISABLE_AUTO_UPDATE"] = "1"
        // Background hosts and probes must never start an interactive login.
        environment["AGY_CLI_NONINTERACTIVE_HEADLESS"] = "1"
        environment["BROWSER"] = "/usr/bin/true"
        environment["HOME"] = userHome
        let path = environment["PATH"] ?? ""
        let needed = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let missing = needed.filter { !path.split(separator: ":").map(String.init).contains($0) }
        if !missing.isEmpty {
            environment["PATH"] = (path.isEmpty ? "" : path + ":") + missing.joined(separator: ":")
        }
        for (key, value) in extra { environment[key] = value }
        return environment
    }
}
