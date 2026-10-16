import CryptoKit
import Foundation

/// Mirrors a Tangit Claude profile's Keychain login into its `.credentials.json`.
///
/// `claude login` under `CLAUDE_CONFIG_DIR` stores the token in the Keychain as
/// `Claude Code-credentials-<first 8 hex of sha256(config dir)>`, not in a file.
/// The helper's `claude` subprocess cannot read the Keychain non-interactively,
/// so without this the probe authenticates as nobody. The file outranks the
/// Keychain, so a dead blob is deleted rather than left to shadow a good login.
enum ClaudeProfileCredentials {
    static func keychainService(for directory: URL) -> String {
        let path = directory.path.precomposedStringWithCanonicalMapping
        let digest = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-\(digest.prefix(8))"
    }

    /// Returns whether the profile ends up with a usable credential file.
    @discardableResult
    static func sync(directory: URL, securitySessionID: String?) -> Bool {
        let fileURL = directory.appendingPathComponent(".credentials.json")
        // Current Keychain login wins; then a file claude may have refreshed in
        // place; the pre-rename login only seeds a profile that has neither, so
        // its (rotated) refresh token never overwrites a newer one.
        if let raw = readKeychain(service: keychainService(for: directory), securitySessionID: securitySessionID), isUsable(raw) {
            return write(raw, to: fileURL)
        }
        if let existing = try? String(contentsOf: fileURL, encoding: .utf8), isUsable(existing) {
            return true
        }
        if let raw = legacyDirectories(for: directory).lazy
            .compactMap({ readKeychain(service: keychainService(for: $0), securitySessionID: securitySessionID) }).first(where: isUsable) {
            return write(raw, to: fileURL)
        }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.removeItem(at: fileURL)
            AppLog.probes.error("Removed unusable Claude credential file at \(fileURL.path, privacy: .public)")
        }
        return false
    }

    private static func write(_ raw: String, to fileURL: URL) -> Bool {
        do {
            try Data(raw.utf8).write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return true
        } catch {
            AppLog.probes.error("Claude profile credential mirror failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Tangit was previously `agent-profile`. Logins made before the rename sit
    /// under the old path's Keychain name, which claude no longer looks up.
    private static func legacyDirectories(for directory: URL) -> [URL] {
        let path = directory.path
        guard path.contains("/Application Support/tangit/profiles/") else { return [] }
        return [URL(fileURLWithPath: path.replacingOccurrences(
            of: "/Application Support/tangit/profiles/",
            with: "/Application Support/agent-profile/profiles/"), isDirectory: true)]
    }

    /// An XPC service is outside the login session, so `security` fails with
    /// errSecInteractionNotAllowed (exit 36) unless it is told which session to use.
    private static func readKeychain(service: String, securitySessionID: String?) -> String? {
        let process = Process()
        if let securitySessionID, !securitySessionID.isEmpty, securitySessionID.allSatisfy(\.isHexDigit) {
            var environment = ProcessInfo.processInfo.environment
            environment["SECURITYSESSIONID"] = securitySessionID
            process.environment = environment
        }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            AppLog.probes.debug("Keychain read of \(service, privacy: .public) exited \(process.terminationStatus, privacy: .public)")
            return nil
        }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A logged-out blob still contains the word `accessToken` (with `""`), so
    /// check the values: a non-empty access token that is unexpired or refreshable.
    static func isUsable(_ raw: String) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String, !accessToken.isEmpty else { return false }
        let refreshToken = oauth["refreshToken"] as? String ?? ""
        let expiresAt = (oauth["expiresAt"] as? Double) ?? 0
        return expiresAt > Date().timeIntervalSince1970 * 1000 || !refreshToken.isEmpty
    }
}
