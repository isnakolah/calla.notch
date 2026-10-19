import AppKit
import DistributionCore
import Foundation

enum AppBridge {
    /// The URL carries no credentials or filesystem paths. An unpredictable
    /// session names an owner-only request; the unsandboxed engine validates
    /// that request before the app performs an operation.
    static func request(_ action: String, options: [String: Any] = [:]) throws -> [String: Any] {
        try Layout.privateDirectory(Layout.sessions)
        let session = UUID().uuidString
        let request = Layout.sessions.appendingPathComponent(session + ".request.json")
        let response = Layout.sessions.appendingPathComponent(session + ".response.json")
        defer {
            try? FileManager.default.removeItem(at: request)
            try? FileManager.default.removeItem(at: response)
        }
        let payload: [String: Any] = ["schema": 1, "session": session, "action": action,
                                      "createdAt": Date().timeIntervalSince1970, "options": options]
        try JSONSerialization.data(withJSONObject: payload).write(to: request, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: request.path)
        // open -a fixes the application identity; URL-handler defaults cannot
        // redirect setup into an unrelated application claiming this scheme.
        let installedIsRunning = NSRunningApplication.runningApplications(withBundleIdentifier: "org.calla.notch").contains {
            $0.bundleURL?.resolvingSymlinksInPath() == Layout.app.resolvingSymlinksInPath() && !$0.isTerminated
        }
        if !installedIsRunning { try Commands.run("/usr/bin/open", ["-n", "-g", "-a", Layout.app.path]) }
        try Commands.run("/usr/bin/open", ["-g", "-a", Layout.app.path,
                        "callanotch-setup://\(action)?session=\(session)"])
        let deadline = Date().addingTimeInterval(35)
        while Date() < deadline {
            if let data = try? Data(contentsOf: response),
               let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               object["session"] as? String == session {
                if let error = object["error"] as? String { throw SetupFailure(error) }
                return object
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw SetupFailure("The app did not respond. Approve its first launch in System Settings → Privacy & Security → Open Anyway, then rerun setup.")
    }
}
