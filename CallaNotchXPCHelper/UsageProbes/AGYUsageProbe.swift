import Foundation

/// AGY's documented standalone /usage command returns named quota groups in
/// the JSON command payload. It uses the existing shared ~/.gemini login.
enum AGYUsageProbe {
    static func fetchReport() async -> UsageReportDTO {
        let now = Date()
        func failure(_ status: UsageReportDTO.Status, _ message: String) -> UsageReportDTO {
            UsageReportDTO(provider: "agy", status: status, errorDescription: message,
                           session: nil, weekly: nil, capturedAt: now)
        }
        guard let binary = BinaryLocator.which("agy") else { return failure(.cliNotInstalled, "AGY CLI not found") }
        // Polling usage must not launch a fresh OAuth flow every time there is
        // no account. Use the real home even when this helper is sandboxed.
        guard let pw = getpwuid(getuid()), let directory = pw.pointee.pw_dir else {
            return failure(.notLoggedIn, "Sign in to AGY from calla.notch")
        }
        let home = String(cString: directory)
        let credentials = [".gemini/antigravity-cli/antigravity-oauth-token", ".gemini/oauth_creds.json"]
        let hasCredentials = credentials.contains { path in
            guard let data = FileManager.default.contents(atPath: home + "/" + path),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            let token = root["token"] as? [String: Any] ?? root
            return !(token["refresh_token"] as? String ?? "").isEmpty
        }
        guard hasCredentials else { return failure(.notLoggedIn, "Sign in to AGY from calla.notch") }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 6
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(from: URL(string: "https://accounts.google.com/.well-known/openid-configuration")!)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let metadata = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  metadata["issuer"] as? String == "https://accounts.google.com" else {
                return failure(.error, "AGY is offline or Google is unreachable. Your sign-in is unchanged.")
            }
        } catch { return failure(.error, "AGY is offline or Google is unreachable. Your sign-in is unchanged.") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        var environment = ProcessInfo.processInfo.environment
        environment["AGY_CLI_DISABLE_AUTO_UPDATE"] = "1"
        environment["AGY_CLI_NONINTERACTIVE_HEADLESS"] = "1"
        environment["BROWSER"] = "/usr/bin/true"
        environment["HOME"] = home
        process.environment = environment
        process.arguments = ["-p", "/usage", "--output-format", "json", "--print-timeout", "20s"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let command = root["command"] as? [String: Any],
                  command["name"] as? String == "usage",
                  let payload = command["data"] as? [String: Any],
                  let groups = payload["groups"] as? [[String: Any]] else {
                return failure(.error, "AGY usage is unavailable. Check your connection or sign-in from calla.notch; automatic login is disabled.")
            }
            func quota(_ bucket: [String: Any]) -> UsageReportDTO.Quota? {
                if bucket["disabled"] as? Bool == true { return nil }
                guard let fraction = bucket["remaining_fraction"] as? Double else { return nil }
                let date = (bucket["reset_time"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
                return .init(percentRemaining: max(0, min(100, fraction * 100)), resetText: nil, resetsAt: date)
            }
            func group(_ name: String) -> UsageReportDTO.QuotaGroup? {
                guard let object = groups.first(where: { ($0["name"] as? String)?.lowercased() == name }),
                      let buckets = object["buckets"] as? [[String: Any]] else { return nil }
                return .init(session: buckets.first(where: { $0["window"] as? String == "5h" }).flatMap(quota),
                             weekly: buckets.first(where: { $0["window"] as? String == "weekly" }).flatMap(quota))
            }
            let gemini = group("gemini models")
            let thirdParty = group("claude and gpt models")
            guard gemini != nil || thirdParty != nil else { return failure(.error, "AGY returned no model quotas") }
            return UsageReportDTO(provider: "agy", status: .ok, errorDescription: nil,
                                  session: nil, weekly: nil, capturedAt: Date(),
                                  gemini: gemini, claudeGPT: thirdParty)
        } catch {
            return failure(.error, error.localizedDescription)
        }
    }
}
