import DistributionCore
import Foundation

/// The same installation engine serves Terminal and the native setup window.
/// Only this helper emits events; downloaded tools receive no event token.
enum SetupInterface {
    static let graphical = CommandLine.arguments.contains("--gui")
    static let token = ProcessInfo.processInfo.environment["BORING_SETUP_EVENT_TOKEN"] ?? ""

    static func event(_ type: String, _ values: [String: Any] = [:]) {
        guard graphical, !token.isEmpty else { return }
        var object = values
        object["type"] = type
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }
        // A leading newline separates events from curl's carriage-return output.
        print("\n\u{1e}BORING_SETUP:\(token):\(json)")
        fflush(stdout)
    }

    static func step(_ number: Int, _ title: String) {
        print("\n[\(number)/9] \(title)")
        event("step", ["number": number, "title": title])
    }

    /// What the current step is doing right now, in one human sentence. The
    /// window shows it under the step title, so long waits never look idle.
    static func activity(_ text: String) {
        print(text)
        event("activity", ["text": text])
    }

    /// A determinate fraction for the current step; nil returns to a spinner.
    static func progress(_ fraction: Double?) {
        event("progress", fraction.map { ["fraction": min(max($0, 0), 1)] } ?? [:])
    }

    /// Tangit is a terminal application. Give its own wizard a real Terminal
    /// while keeping the native installation window open and waiting for it.
    static func tangitInTerminal(setup: Bool) throws {
        if !setup {
            try TerminalLauncher.open(executable: Layout.app.appendingPathComponent("Contents/Helpers/boring-notch"), arguments: ["tangit"])
            return
        }
        let directory = Layout.setup.appendingPathComponent("terminal-" + UUID().uuidString)
        try Layout.privateDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let receipt = directory.appendingPathComponent("exit-status")
        let command = Layout.app.appendingPathComponent("Contents/Helpers/boring-notch")
        try TerminalLauncher.open(executable: command, arguments: ["tangit", "setup"], receipt: receipt)
        let deadline = Date().addingTimeInterval(21600)
        while Date() < deadline {
            if let result = try? String(contentsOf: receipt), let status = Int(result) {
                guard status == 0 else { throw SetupFailure("Tangit setup stopped. Your profile is kept; retry here or finish it later in Tangit.") }
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw SetupFailure("Tangit setup has not finished. Return to its Terminal window, or retry later.")
    }
}
