import DistributionCore
import Foundation

enum TangitSetup {
    static let marker = "# Managed by Boring Notch private setup"
    static var environment: [String: String] {
        let providers = Layout.app.appendingPathComponent("Contents/Resources/Tangit/Providers").path
        return ["PATH": providers + "/codex/bin:" + providers + "/codex/codex-path:"
                + providers + "/claude/bin:" + Layout.home.appendingPathComponent(".local/bin").path
                + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "")
                + ":/usr/bin:/bin:/usr/sbin:/sbin", "DISABLE_AUTOUPDATER": "1"]
    }

    static func installCommands() throws {
        let directory = Layout.home.appendingPathComponent(".local/bin")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["tangit", "codex", "claude", "agy"] {
            let destination = directory.appendingPathComponent(name)
            let target = name == "tangit" ? Layout.tangit : name == "agy" ? Layout.agy : Layout.provider(name)
            let link = try? fm.destinationOfSymbolicLink(atPath: destination.path)
            if fm.fileExists(atPath: destination.path) || link != nil {
                let handle = try? FileHandle(forReadingFrom: destination)
                let prefix = try? handle?.read(upToCount: 256)
                try? handle?.close()
                let owned = link == target.path || String(decoding: prefix ?? Data(), as: UTF8.self).contains(marker)
                guard owned else {
                    print("Keeping existing ~/.local/bin/\(name). The bundled copy is available through boring-notch tangit and the app's Tangit launcher.")
                    continue
                }
                try fm.removeItem(at: destination)
            }
            let paths = environment["PATH"]!
            let script = "#!/bin/sh\n\(marker)\nexport PATH=\(Commands.shellQuote(paths))\nexport DISABLE_AUTOUPDATER=1\nexec \(Commands.shellQuote(target.path)) \"$@\"\n"
            try script.write(to: destination, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        }
    }

    static func gitReady() -> Bool {
        // /usr/bin/git is only an installer shim on a blank Mac. Check for a
        // developer directory before invoking it so doctor never opens a prompt.
        guard let developer = try? Commands.run("/usr/bin/xcode-select", ["-p"], check: false), developer.status == 0 else { return false }
        return (try? Commands.run("/usr/bin/git", ["--version"], check: false).status) == 0
    }

    static func prerequisites() throws {
        SetupInterface.activity("Linking the tangit, codex, claude and agy commands…")
        try installCommands()
        SetupInterface.activity("Checking the bundled Codex and Claude tools…")
        for name in ["codex", "claude"] {
            let version = try Commands.run(Layout.provider(name).path, ["--version"], environment: environment).output
            print(version.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if !gitReady() {
            print("Git is needed for coding projects and Tangit worktrees. macOS supplies it with Apple's Command Line Tools; no full Xcode app is needed.")
            SetupInterface.activity("Waiting for Apple's Command Line Tools installer (adds Git)…")
            try Commands.run("/usr/bin/xcode-select", ["--install"], inherit: true, check: false)
            while !gitReady() {
                try pause("Approve Install in Apple's dialog and let the download finish. It may take several minutes and additional disk space. Return here after installation completes.")
            }
        }
        SetupInterface.activity("Tangit, Codex, Claude and Git are ready.")
    }

    static func setup() throws {
        let state = ProcessInfo.processInfo.environment["TANGIT_HOME"].map { URL(fileURLWithPath: $0) }
            ?? Layout.home.appendingPathComponent("Library/Application Support/tangit")
        let registry = state.appendingPathComponent("profiles.json")
        let existing = (try? Data(contentsOf: registry)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let hasProfiles = !(existing?["profiles"] as? [[String: Any]] ?? []).isEmpty
        print("\nTangit keeps separate Codex and Claude accounts per profile. Codex uses a device code: open the displayed link and enter the code; no localhost redirect. Enable device code login in your ChatGPT security settings if requested.")
        print("Claude currently offers provider browser login or an API key stored in macOS Keychain. Select an API key to avoid its browser login.")
        if hasProfiles {
            print("Existing Tangit profiles are preserved.")
            try Commands.run(Layout.tangit.path, ["profile", "list"], inherit: true, environment: environment)
            if !ask("Create an additional Tangit profile now?", defaultYes: false) { return }
        }
        print("Follow Tangit's setup. Choose Return to installer on the final screen when finished. You can also sign in later from Profile settings.")
        if SetupInterface.graphical {
            try pause("Tangit opens its profile wizard in Terminal. Choose your profile and provider, then sign in. Codex displays a device code. Choose Return to installer / finish on its final screen; this setup window will stay open.")
            try SetupInterface.tangitInTerminal(setup: true)
            return
        }
        try Commands.run(Layout.tangit.path, ["setup"], inherit: true, environment: environment, timeout: 21600)
    }

    static func launch() throws {
        if SetupInterface.graphical { try SetupInterface.tangitInTerminal(setup: false); return }
        try Commands.run(Layout.tangit.path, [], inherit: true, environment: environment, timeout: 86400)
    }

    static func report() -> Bool {
        let version = try? Commands.run(Layout.tangit.path, ["version"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        print("Tangit: \(version ?? "missing — run repair")")
        var ready = version != nil
        for name in ["codex", "claude"] {
            let result = try? Commands.run(Layout.provider(name).path, ["--version"], environment: environment)
            print("\(name): \(result?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? "missing — run repair")")
            ready = ready && result?.status == 0
        }
        let git = gitReady()
        print("Git: \(git ? "ready" : "install Apple's Command Line Tools through repair")")
        print("Tangit accounts: check Profile settings in Tangit; tool availability does not confirm account access.")
        return ready && git
    }
}
