import Foundation

/// Open Terminal on a command. Every argument is quoted; nothing downloaded is
/// executed. The script is written by this app-owned process, so it carries no
/// quarantine flag and needs neither Gatekeeper nor Automation approval.
public enum TerminalLauncher {
    public static func open(executable: URL, arguments: [String] = [], receipt: URL? = nil) throws {
        let command = ([executable.path] + arguments).map(Commands.shellQuote).joined(separator: " ")
        var script = "cd \"$HOME\"\n"
        if let receipt {
            script += """
            result=130
            finish() { /usr/bin/printf '%s' "$result" > \(Commands.shellQuote(receipt.path)); }
            trap finish EXIT
            trap 'result=130; exit 130' HUP INT TERM
            \(command)
            result=$?
            print '\\nReturn to the calla.notch setup window. You can close this Terminal window.'
            exit "$result"
            """
        } else { script += command }
        if (try? openScript(script)) != nil { return }
        try openWithAutomation(script)
    }

    private static func openScript(_ script: String) throws {
        let directory = Layout.setup.appendingPathComponent("terminal")
        try Layout.privateDirectory(directory)
        // Old launchers are single-use; Terminal has read them by the time a
        // second one is written.
        for old in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: old)
        }
        let file = directory.appendingPathComponent("calla-notch-\(UUID().uuidString.prefix(8)).command")
        try ("#!/bin/zsh\n" + script + "\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        let result = try Commands.run("/usr/bin/open", ["-a", "Terminal", file.path], timeout: 30, check: false)
        guard result.status == 0 else { throw SetupFailure("Terminal did not open.") }
    }

    private static func openWithAutomation(_ script: String) throws {
        let shell = "/bin/zsh -c " + Commands.shellQuote(script)
        let literal = shell.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let source = "tell application \"Terminal\"\nactivate\ndo script \"\(literal)\"\nend tell"
        let result = try Commands.run("/usr/bin/osascript", ["-e", source], timeout: 60, check: false)
        guard result.status == 0 else {
            throw SetupFailure("macOS could not open Terminal. Allow calla.notch to control Terminal when prompted, then retry. You can change this in System Settings → Privacy & Security → Automation.")
        }
    }
}
