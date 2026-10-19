import DistributionCore
import Foundation

enum TangitSetup {
    static let marker = "# Managed by calla.notch private setup"
    /// Builds from before the rename wrote this marker. Their launchers point
    /// into /Applications/boringNotch.app, which an update removes, so they
    /// are ours to replace — not a user's own command to preserve.
    static let legacyMarkers = ["# Managed by Boring Notch private setup"]
    static func isOwnLauncher(_ head: Data) -> Bool {
        let text = String(decoding: head, as: UTF8.self)
        return ([marker] + legacyMarkers).contains { text.contains($0) }
    }
    /// The installed tool, or the package's own copy before setup has run.
    static func tool(_ name: String) -> URL {
        let installed = ComponentLayout.binary(name)
        return fm.isExecutableFile(atPath: installed.path) ? installed : Layout.provider(name)
    }

    /// `codex` and `claude` as Tangit and Terminal see them: the Components
    /// copy for everything except `update`, which updates that copy.
    static let shims = ComponentLayout.root.appendingPathComponent("bin")

    static func installShims() throws {
        try fm.createDirectory(at: shims, withIntermediateDirectories: true)
        let helper = Layout.app.appendingPathComponent("Contents/Helpers/calla-notch")
        for name in ["codex", "claude"] {
            let script = "#!/bin/sh\n\(marker)\nif [ \"${1:-}\" = update ]; then exec \(Commands.shellQuote(helper.path)) update-tool \(name); fi\nexec \(Commands.shellQuote(ComponentLayout.binary(name).path)) \"$@\"\n"
            let destination = shims.appendingPathComponent(name)
            try script.write(to: destination, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        }
    }

    static var environment: [String: String] {
        let codex = tool("codex").deletingLastPathComponent().deletingLastPathComponent().path
        let claude = tool("claude").deletingLastPathComponent().path
        return ["PATH": shims.path + ":" + codex + "/bin:" + codex + "/codex-path:"
                + claude + ":" + Layout.home.appendingPathComponent(".local/bin").path
                + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "")
                + ":/usr/bin:/bin:/usr/sbin:/sbin", "DISABLE_AUTOUPDATER": "1"]
    }

    static func installCommands() throws {
        let directory = Layout.home.appendingPathComponent(".local/bin")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try installShims()
        for name in ["tangit", "codex", "claude", "agy"] {
            let destination = directory.appendingPathComponent(name)
            let target = name == "tangit" ? Layout.tangit : name == "agy" ? Layout.agy : shims.appendingPathComponent(name)
            let link = try? fm.destinationOfSymbolicLink(atPath: destination.path)
            if fm.fileExists(atPath: destination.path) || link != nil {
                let handle = try? FileHandle(forReadingFrom: destination)
                let prefix = try? handle?.read(upToCount: 256)
                try? handle?.close()
                let owned = link == target.path || isOwnLauncher(prefix ?? Data())
                guard owned else {
                    print("Keeping existing ~/.local/bin/\(name). The bundled copy is available through calla-notch tangit and the app's Tangit launcher.")
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
        SetupInterface.activity("Checking Codex and Claude…")
        for name in ["codex", "claude"] {
            let version = try Commands.run(tool(name).path, ["--version"], environment: environment).output
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

    static let wizardGuide = """
        Tangit keeps each account in its own profile. Make one profile per account, for example “work” for your work ChatGPT (Codex) and “personal” for Claude. You can add more profiles afterwards.

        Terminal asks four things:
        1. Profile name — a short lowercase name such as work or personal.
        2. Provider — codex for a ChatGPT account, claude for a Claude account.
        3. Authentication — Codex: Device code login, then open the link it shows and enter the code. Claude: Provider login opens the browser, or choose API key. Sign in later is fine too.
        4. Review — choose Create profile, then Return to installer / finish.

        Use the arrow keys and Return to choose; Esc goes back.
        """

    static func profileNames() -> [String] {
        let state = ProcessInfo.processInfo.environment["TANGIT_HOME"].map { URL(fileURLWithPath: $0) }
            ?? Layout.home.appendingPathComponent("Library/Application Support/tangit")
        let registry = state.appendingPathComponent("profiles.json")
        let existing = (try? Data(contentsOf: registry)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return (existing?["profiles"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }

    static func setup() throws {
        var profiles = profileNames()
        if !profiles.isEmpty {
            SetupInterface.activity("Tangit profiles on this Mac: \(profiles.joined(separator: ", ")). They are kept.")
            if !ask("Tangit already has profiles: \(profiles.joined(separator: ", ")). Create another one now?", defaultYes: false) { return }
        }
        while true {
            print("\n" + wizardGuide)
            if SetupInterface.graphical {
                try pause(wizardGuide + "\n\nChoose Continue to open Tangit in Terminal. This window waits until you finish there.")
                SetupInterface.activity("Waiting for Tangit’s wizard in Terminal…")
                try SetupInterface.tangitInTerminal(setup: true)
            } else {
                try Commands.run(Layout.tangit.path, ["setup"], inherit: true, environment: environment, timeout: 21600)
            }
            profiles = profileNames()
            guard !profiles.isEmpty else {
                throw SetupFailure("No Tangit profile was created. Retry to open the wizard again, or skip and run tangit setup later.")
            }
            SetupInterface.activity("Tangit profiles: \(profiles.joined(separator: ", ")).")
            if !ask("Tangit profiles: \(profiles.joined(separator: ", ")). Add another profile, for example one for your other Codex or Claude account?", defaultYes: false) { return }
        }
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
            let result = try? Commands.run(tool(name).path, ["--version"], environment: environment)
            print("\(name): \(result?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? "missing — run repair")")
            ready = ready && result?.status == 0
        }
        let git = gitReady()
        print("Git: \(git ? "ready" : "install Apple's Command Line Tools through repair")")
        print("Tangit accounts: check Profile settings in Tangit; tool availability does not confirm account access.")
        return ready && git
    }
}
