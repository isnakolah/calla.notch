import AppKit
import Darwin
import DistributionCore
import Foundation

let fm = FileManager.default
let receiptURL = Layout.setup.appendingPathComponent("progress.json")

func ask(_ message: String, defaultYes: Bool = true) -> Bool {
    SetupInterface.event("prompt", ["kind": "choice", "message": message, "defaultYes": defaultYes])
    print("\(message) \(defaultYes ? "[Y/n]" : "[y/N]") ", terminator: "")
    fflush(stdout)
    guard let input = readLine() else { return false }
    let answer = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return answer.isEmpty ? defaultYes : ["y", "yes"].contains(answer)
}

func pause(_ message: String) throws {
    SetupInterface.event("prompt", ["kind": "continue", "message": message])
    print("\n\(message)\nPress Return when ready, or Ctrl-C to stop. Your progress is saved.")
    guard readLine() != nil else { throw SetupFailure("Reopen the Boring Notch app to continue setup.") }
}

func enclosingApp() -> URL? {
    var candidate = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
    while candidate.path != "/" {
        if candidate.pathExtension == "app" { return candidate }
        candidate.deleteLastPathComponent()
    }
    return nil
}

func appleScript(_ source: String) throws {
    try Commands.run("/usr/bin/osascript", ["-e", source], inherit: true, timeout: 600)
}

func admin(_ script: String) throws {
    let literal = script.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
    try appleScript("do shell script \"\(literal)\" with administrator privileges")
}

func install(_ source: URL) throws -> ReleaseManifest {
    let manifest = try PackageInstaller.validate(source)
    let alreadyInstalled = source.standardizedFileURL.resolvingSymlinksInPath() == Layout.app.resolvingSymlinksInPath()
    try PackageInstaller.checkUpdate(source: source, installed: Layout.app)
    if fm.fileExists(atPath: Layout.app.path) {
        let processes = try Commands.run("/bin/ps", ["-axo", "command="]).output.split(separator: "\n")
        let activeTangit = processes.contains { line in
            let command = line.trimmingCharacters(in: .whitespaces)
            return command == Layout.tangit.path || command.hasPrefix(Layout.tangit.path + " ")
                || command.hasPrefix(Layout.app.path + "/Contents/Resources/Tangit/Providers/")
        }
        guard !activeTangit else { throw SetupFailure("Tangit or one of its bundled providers is running. End its sessions and quit Tangit before replacing this app, then rerun setup.") }
        if let current = try? AppBridge.request("status"), current["busy"] as? Bool == true {
            throw SetupFailure("A call, recording, or finishing pass is active. End it and let it finish before updating.")
        }
        // Older builds do not have the setup bridge. A live owned host still
        // must prevent replacement; checking its executable avoids trusting a
        // stale PID receipt left by an unrelated process.
        let pidFile = Layout.support.appendingPathComponent("Calla/callhost.pid")
        if let pid = try? String(contentsOf: pidFile).trimmingCharacters(in: .whitespacesAndNewlines),
           Int32(pid) != nil, let process = try? Commands.run("/bin/ps", ["-p", pid, "-o", "command="], check: false),
           process.output.contains(Layout.app.path + "/" + Layout.callHost) {
            throw SetupFailure("The installed capture host is active. End the call before updating.")
        }
        // A first install may be running its setup window from the DMG. Quit
        // only the copy being replaced, never the app hosting that window.
        func installedProcesses() -> [NSRunningApplication] {
            NSRunningApplication.runningApplications(withBundleIdentifier: "theboringteam.boringnotch").filter {
                $0.bundleURL?.resolvingSymlinksInPath() == Layout.app.resolvingSymlinksInPath()
            }
        }
        if !alreadyInstalled { for application in installedProcesses() { application.terminate() } }
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if alreadyInstalled || !installedProcesses().contains(where: { !$0.isTerminated }) { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        guard alreadyInstalled || installedProcesses().allSatisfy(\.isTerminated) else {
            throw SetupFailure("The app has not quit. Finish any active work, quit Boring Notch, and retry.")
        }
    }
    if alreadyInstalled {
        // Installs made by earlier packages kept the disk image's quarantine
        // flag. Clearing it here is what stops repeated Open Anyway prompts.
        _ = try? Commands.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", Layout.app.path], check: false)
        return manifest
    }
    let script = PackageInstaller.transactionScript(source: source, destination: Layout.app)
    if fm.isWritableFile(atPath: "/Applications") { try Commands.run("/bin/sh", ["-c", script], inherit: true) }
    else { print("macOS will ask for permission to install in Applications."); try admin(script) }
    _ = try PackageInstaller.validate(Layout.app)
    return manifest
}

func installCommand() throws {
    let directory = Layout.home.appendingPathComponent(".local/bin")
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    let destination = directory.appendingPathComponent("boring-notch")
    if fm.fileExists(atPath: destination.path) || (try? fm.destinationOfSymbolicLink(atPath: destination.path)) != nil {
        let existing = try? fm.destinationOfSymbolicLink(atPath: destination.path)
        guard existing == Layout.app.appendingPathComponent("Contents/Helpers/boring-notch").path else {
            print("An unrelated ~/.local/bin/boring-notch already exists; preserving it. Use the setup launcher in the app instead.")
            return
        }
        try fm.removeItem(at: destination)
    }
    try fm.createSymbolicLink(at: destination, withDestinationURL: Layout.app.appendingPathComponent("Contents/Helpers/boring-notch"))
    let profile = Layout.home.appendingPathComponent(".zprofile")
    let line = "export PATH=\"$HOME/.local/bin:$PATH\""
    let text = (try? String(contentsOf: profile)) ?? ""
    if !text.contains(line) {
        try (text + "\n# Boring Notch setup command\n" + line + "\n").write(to: profile, atomically: true, encoding: .utf8)
    }
}

func configure(_ options: [String: Any]) throws { _ = try AppBridge.request("configure", options: options) }

/// Lists models with the saved account. A token file alone is not enough: it
/// may be expired, revoked, or have no usable models.
func verifyModelCatalog() throws {
    let models = try Commands.run(Layout.agy.path, ["models"], timeout: 90)
    guard !models.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw SetupFailure("AGY signed in but returned no model catalog. Check your account access and retry.")
    }
}

func login() throws {
    // Resuming must never reopen Google sign-in for an account that works.
    if try AppBridge.request("status")["signedIn"] as? Bool == true {
        SetupInterface.activity("Checking your saved Google sign-in…")
        if (try? verifyModelCatalog()) != nil {
            SetupInterface.activity("Already signed in. Your account and models are reachable.")
            return
        }
        guard ask("Your saved sign-in could not reach the model catalog. This is usually the internet connection; an expired sign-in needs a new one. Sign in again?", defaultYes: false) else {
            throw SetupFailure("Could not reach the model catalog. Check the internet connection, then retry this step.")
        }
    }
    print("AGY will use your Google account. Model requests use the account's service and quota; audio transcription stays on the Mac.")
    SetupInterface.activity("Opening the Google sign-in panel in Boring Notch…")
    _ = try AppBridge.request("login")
    try pause("Follow the sign-in panel in Boring Notch and approve access in your browser. If asked for an authorization code, paste it into the sign-in panel. Choose Continue when the panel says you're signed in.")
    var status = try AppBridge.request("status")
    while status["signedIn"] as? Bool != true {
        SetupInterface.activity("Sign-in is not complete yet.")
        guard ask("Sign-in isn't finished. Keep waiting?") else { throw SetupFailure("Sign-in is incomplete. Choose Resume setup to continue.") }
        try pause("Finish signing in, then choose Continue.")
        status = try AppBridge.request("status")
    }
    SetupInterface.activity("Checking your account with the model catalog…")
    try verifyModelCatalog()
    SetupInterface.activity("Signed in. Your account and models are reachable.")
}

func models(archive: Bool) throws {
    // Each model is taken from wherever it already is before anything is
    // downloaded; see ComponentSetup.installModel.
    try ComponentSetup.installModel(.live)
    if archive { try ComponentSetup.installModel(.archive) }
    try ComponentSetup.migrateLegacy()
    // The call host confirms it can see them where it looks.
    SetupInterface.activity("Confirming the call host can load the speech models…")
    let host = Layout.app.appendingPathComponent(Layout.callHost)
    let environment = ["CALLA_RUNTIME_ROOT": Layout.support.appendingPathComponent("Calla").path]
    try Commands.run(host.path, ["models", "--model", ModelSpec.live.name], environment: environment, timeout: 600)
    if archive { try Commands.run(host.path, ["models", "--archive"], environment: environment, timeout: 600) }
    SetupInterface.activity("Speech models are verified and ready.")
}

func permissions() throws {
    SetupInterface.activity("Checking microphone and system audio access…")
    var state = try AppBridge.request("permissions-check")
    func granted() -> Bool { state["microphone"] as? Bool == true && state["systemAudio"] as? Bool == true }
    if granted() { SetupInterface.activity("Microphone and system audio are already allowed."); return }
    print("Microphone hears your side. Screen & System Audio Recording hears the other participant. macOS requires you to approve these yourself.")
    SetupInterface.activity("Asking macOS for microphone and system audio access…")
    _ = try AppBridge.request("permissions")
    try pause("Approve the macOS prompts for Boring Notch. If you missed one, open System Settings → Privacy & Security → Microphone, and Screen & System Audio Recording, and switch Boring Notch on. Choose Continue when done.")
    state = try AppBridge.request("permissions-check")
    while !granted() {
        let mic = state["microphone"] as? Bool == true ? "allowed" : "needs approval"
        let audio = state["systemAudio"] as? Bool == true ? "allowed" : "needs approval"
        SetupInterface.activity("Microphone: \(mic) · System audio: \(audio)")
        guard ask("Check again after changing permissions?") else { throw SetupFailure("Meeting permissions are incomplete. Choose Resume setup after granting them.") }
        try pause("Finish changing permissions. If macOS asks to quit and reopen Boring Notch, choose Later, then Continue here.")
        state = try AppBridge.request("permissions-check")
    }
    SetupInterface.activity("Microphone and system audio are allowed.")
}

/// The Home tab's calendar needs both the setting and macOS access. Public
/// builds get them from onboarding, which private builds replace with setup.
func calendar() throws {
    SetupInterface.activity("Turning on the Home calendar and asking macOS for calendar access…")
    _ = try AppBridge.request("calendar")
    try pause("Allow calendar access in the macOS prompt so Home can show today's meetings. Choose Continue when done.")
    SetupInterface.activity("Home will show your calendar next to Now Playing.")
}

/// Each finished call is saved to Documents › Calls. Creating it now puts the
/// one-time Documents prompt here, in setup, instead of after the first call.
func callsFolder() throws {
    SetupInterface.activity("Creating Documents › Calls, where each call is saved…")
    _ = try AppBridge.request("calls-folder")
    SetupInterface.activity("Calls will be saved to Documents › Calls, grouped by meeting type.")
}

func gateway(_ dependency: ReleaseManifest.Dependency) throws {
    let tailscale = URL(fileURLWithPath: "/Applications/Tailscale.app/Contents/MacOS/Tailscale")
    if !fm.isExecutableFile(atPath: tailscale.path) {
        SetupInterface.activity("Downloading Tailscale…")
        let pkg = try ComponentSetup.fetch(dependency, name: "tailscale", title: "Tailscale")
        let signature = try Commands.run("/usr/sbin/pkgutil", ["--check-signature", pkg.path], captureStderr: true).output
        guard signature.contains("Developer ID Installer: Tailscale") else {
            throw SetupFailure("Tailscale installer signature is unexpected. Installation stopped.")
        }
        print("macOS will request administrator permission to install Tailscale.")
        try admin("/usr/sbin/installer -pkg " + Commands.shellQuote(pkg.path) + " -target /")
    }
    try Commands.run("/usr/bin/open", ["-a", "/Applications/Tailscale.app"])
    try pause("In Tailscale, approve the VPN configuration and sign in to your existing tailnet. Finish any device approval in the Tailscale admin console.")
    let result = try Commands.run(tailscale.path, ["status", "--json"], timeout: 20)
    guard let data = result.output.data(using: .utf8),
          let status = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          status["BackendState"] as? String == "Running" else {
        throw SetupFailure("Tailscale is not connected. Finish its login, then run repair.")
    }
    print("Connecting to your existing Gateway over Tailscale SSH. Approve the browser identity check if requested.")
    // The Tailscale client establishes trusted host keys from the tailnet;
    // the subsequent ordinary SSH relays can then run in BatchMode.
    try Commands.run(tailscale.path, ["ssh", "isnakolah@nomonhomelab", "true"], inherit: true, timeout: 180)
    let helper = Layout.app.appendingPathComponent("Contents/Helpers/calla-gateway")
    let health = try Commands.run(helper.path, ["check", "--setup"], timeout: 60)
    guard let data = health.output.data(using: .utf8),
          let state = try JSONSerialization.jsonObject(with: data) as? [String: Any], state["ok"] as? Bool == true else {
        throw SetupFailure("Tailscale connected, but the Gateway service is not running. Local meetings remain usable. Retry once the Gateway is up.")
    }
    try configure(["gateway": true])
    print("Gateway connection ready. Local AGY remains the primary meeting provider.")
}

func meetingTest() throws -> Bool {
    print("This test briefly captures your microphone and system audio, saves a test call in History, and sends its transcript to AGY. You can delete the test call in History afterward.")
    guard ask("Run the meeting test now?") else { return false }
    _ = try AppBridge.request("test-start")
    print("Approve the test in the app. Speak a sentence, then play a short spoken clip in Safari or another meeting app. Headphones help separate the two sides.")
    let started = Date(); let limit: TimeInterval = 90
    var heardMic = false; var heardSystem = false; var transcribed = false
    while Date().timeIntervalSince(started) < limit {
        let state = try AppBridge.request("status")
        heardMic = heardMic || state["microphoneTranscribed"] as? Bool == true
        heardSystem = heardSystem || state["systemAudioTranscribed"] as? Bool == true
        transcribed = transcribed || (state["turnCount"] as? Int ?? 0) > 0
        if heardMic && heardSystem && transcribed { break }
        let left = Int(limit - Date().timeIntervalSince(started))
        SetupInterface.activity("Listening — your voice \(heardMic ? "✓" : "…")  ·  other side \(heardSystem ? "✓" : "…")  ·  \(left)s left")
        SetupInterface.progress(Date().timeIntervalSince(started) / limit)
        Thread.sleep(forTimeInterval: 2)
    }
    SetupInterface.progress(nil)
    _ = try AppBridge.request("test-stop")
    SetupInterface.activity("Checking the AI connection…")
    print("Microphone capture: \(heardMic ? "passed" : "not confirmed"); system-audio capture: \(heardSystem ? "passed" : "not confirmed"); transcription: \(transcribed ? "passed" : "not confirmed").")
    // An explicit synthetic request verifies inference even when the spoken
    // clip contains no question for the live question detector to answer.
    let reply = try Commands.run(Layout.agy.path,
        ["-p", "Reply with exactly READY. Do not use tools.", "--output-format", "json", "--print-timeout", "60s"], timeout: 90)
    guard Readiness.aiResponded(Data(reply.output.utf8)) else {
        throw SetupFailure("The AI readiness request did not return the expected response. Retry after checking AGY login and quota.")
    }
    print("AI response: passed.")
    return heardMic && heardSystem && transcribed
}

@discardableResult
func doctor() throws -> Bool {
    print("\nBoring Notch readiness\n")
    guard fm.fileExists(atPath: Layout.app.path) else { print("App: missing — run setup from the private DMG."); return false }
    let release = try PackageInstaller.validate(Layout.app)
    print("App: \(release.version) (\(release.build)), signature verified")
    print("Components: \(ComponentSetup.display(ComponentLayout.root))")
    let version = ComponentSetup.version(of: Layout.agy)
    let agyOK = version == release.agy.version
    print("AGY: \(version ?? "missing")\(agyOK ? "" : " — run repair")")
    let tangitOK = release.tangit == nil ? true : TangitSetup.report()
    let model = ComponentLayout.models.appendingPathComponent(ModelSpec.live.file)
    let speechOK = Transfer.verify(model, sha256: ModelSpec.live.sha256, size: ModelSpec.live.size,
                                   name: ModelSpec.live.title) { _ in }
    print("Speech model: \(speechOK ? "verified" : "missing or damaged — run repair")")
    let state = try AppBridge.request("permissions-check")
    let signedIn = state["signedIn"] as? Bool == true
    let mic = state["microphone"] as? Bool == true
    let screen = state["systemAudio"] as? Bool == true
    let engine = state["engineReady"] as? Bool == true
    print("Engine: \(engine ? "ready" : "needs attention")")
    print("Account: \(signedIn ? "credential present (setup verifies online access)" : "sign in required")")
    print("Microphone: \(mic ? "granted" : "grant in Privacy & Security")")
    print("System audio: \(screen ? "granted" : "grant Screen & System Audio Recording")")
    let progress = Progress.read(receiptURL)
    print("Meeting test: \(progress.meetingTestPassed ? "passed during setup" : "not confirmed — run repair")")
    print("Gateway: \(state["gatewayEnabled"] as? Bool == true ? (state["gatewayReachable"] as? Bool == true ? "reachable" : "enabled, currently unavailable") : "skipped / disabled")")
    let ready = agyOK && speechOK && signedIn && mic && screen && engine && tangitOK
    print(ready ? "\nMeeting prerequisites are ready. Start a call manually in the notch." : "\nSetup needs attention. Run boring-notch repair to continue.")
    return ready
}

func wizard(source: URL, repair: Bool) throws {
    guard isatty(STDIN_FILENO) == 1 || (SetupInterface.graphical && !SetupInterface.token.isEmpty) else {
        throw SetupFailure("Open Boring Notch.app to use the setup window, or run the command in Terminal.")
    }
    try Layout.privateDirectory(Layout.setup)
    let lock = open(Layout.setup.appendingPathComponent("setup.lock").path, O_CREAT | O_RDWR, 0o600)
    guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw SetupFailure("Another setup is running. Finish it before opening a second setup.") }
    defer { flock(lock, LOCK_UN); close(lock) }
    var progress = Progress.read(receiptURL)
    let wasConfigured = progress.completed.contains("settings")
    // Resume shows earlier work as done; repair asks every question again.
    SetupInterface.event("restore", ["completed": repair ? [] : Array(progress.completed).sorted(),
                                     "skipped": repair ? [] : Array(progress.skipped).sorted()])
    func decided(_ name: String) -> Bool { !repair && (progress.completed.contains(name) || progress.skipped.contains(name)) }
    func record(_ name: String, skipped: Bool = false) throws {
        if skipped { progress.skipped.insert(name); progress.completed.remove(name) }
        else { progress.completed.insert(name); progress.skipped.remove(name) }
        SetupInterface.event("checkpoint", ["name": name, "skipped": skipped])
        try progress.write(receiptURL)
    }
    func step(_ name: String, optional: Bool = false, _ body: () throws -> Void) throws {
        while true {
            do {
                try body(); SetupInterface.progress(nil); try record(name); return
            } catch {
                print("\n\(error.localizedDescription)")
                SetupInterface.progress(nil)
                SetupInterface.event("error", ["message": error.localizedDescription])
                if ask(optional ? "Try this step again? Choose No to skip it for now." : "Try this step again?") { continue }
                if optional { try record(name, skipped: true); return }
                throw SetupFailure("Setup paused. Choose Resume setup to continue from this step; finished steps are kept.")
            }
        }
    }
    print("\nBoring Notch — setup for this Mac\n")
    SetupInterface.activity("Checking this Mac…")
    guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15,
          try Commands.run("/usr/bin/uname", ["-m"]).output.trimmingCharacters(in: .whitespacesAndNewlines) == "arm64"
    else {
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 15 {
            _ = try? Commands.run("/usr/bin/open", ["x-apple.systempreferences:com.apple.Software-Update-Settings.extension"])
        }
        throw SetupFailure("This private package requires an Apple Silicon Mac running macOS 15 or later (the bundled media adapter needs macOS 15). Update macOS in Software Update, then reopen Boring Notch.")
    }
    SetupInterface.activity("Verifying the package signature…")
    let manifest = try PackageInstaller.validate(source)
    print("Package: \(manifest.version) (\(manifest.build))\nDestination: /Applications/boringNotch.app\nTools and models: \(ComponentSetup.display(ComponentLayout.root))\nIncluded in the package: Tangit, Codex, Claude and AGY — no download needed.\nAccounts: Google for meetings; ChatGPT or Claude for Tangit; Tailscale only if you select Gateway.\n")
    // Say up front what is already here, so a second run or a carried folder
    // visibly saves the work.
    SetupInterface.activity("Looking for files already on this Mac…")
    let inventory = ComponentSetup.inventory(manifest)
    for (name, present) in inventory { print("  \(present ? "✓ in place" : "· to install"): \(name)") }
    let carried = ComponentSetup.carryFolders
    for folder in carried { print("  Found \(ComponentLayout.carryName) at \(ComponentSetup.display(folder)); setup will copy from it instead of downloading.") }
    let liveModelPresent = inventory.first { $0.0 == ModelSpec.live.title }?.1 == true
    if !liveModelPresent && carried.isEmpty {
        let values = try Layout.home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard (values.volumeAvailableCapacityForImportantUsage ?? 0) >= 3_000_000_000 else {
            throw SetupFailure("Free at least 3 GB before installing, for the tools, the speech model and Apple's Git tools. Archive transcription needs about 3 GB more.")
        }
    }
    // The window's Begin button is the confirmation; Terminal asks here.
    if !SetupInterface.graphical {
        guard ask("Install or repair this private app and its managed dependencies?") else { return }
    }

    SetupInterface.step(1, "Install Boring Notch")
    SetupInterface.activity(source.resolvingSymlinksInPath() == Layout.app.resolvingSymlinksInPath()
        ? "Checking the installed app…" : "Copying Boring Notch to Applications and verifying its signature…")
    try step("app") { _ = try install(source); try installCommand() }
    // Everything after this runs in the installed copy, so macOS permission
    // prompts, the sign-in window and Terminal all belong to one app — and the
    // disk image copy never runs a second notch beside it.
    if SetupInterface.graphical, source.resolvingSymlinksInPath() != Layout.app.resolvingSymlinksInPath() {
        SetupInterface.activity("Installed. Continuing in Boring Notch from Applications…")
        SetupInterface.event("handoff")
        return
    }

    SetupInterface.step(2, "Install AGY, Codex and Claude")
    SetupInterface.activity("Checking Components for tools already installed…")
    try step("agy") {
        try ComponentSetup.migrateLegacy()
        try ComponentSetup.installTool("agy", manifest.agy, package: source)
    }
    if manifest.tangit != nil {
        try step("tangit-tools") {
            if let codex = manifest.codex { try ComponentSetup.installTool("codex", codex, package: source) }
            if let claude = manifest.claude { try ComponentSetup.installTool("claude", claude, package: source) }
            ComponentSetup.clearQuarantine()
            try TangitSetup.prerequisites()
        }
    }

    SetupInterface.step(3, "Prepare meeting settings")
    SetupInterface.activity("Turning on calls with the team-ceremony personas…")
    try step("settings") { try configure(["meetings": true]) }

    SetupInterface.step(4, "Sign in to AGY")
    try step("login") { try login() }

    SetupInterface.step(5, "Download speech models")
    let settings = try AppBridge.request("status")
    let archive = decided("models") ? settings["archiveEnabled"] as? Bool ?? false
        : ask("Also download the higher-quality after-call transcription model? Adds about 2.8 GB.", defaultYes: settings["archiveEnabled"] as? Bool ?? false)
    if archive {
        let space = try Layout.home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard (space.volumeAvailableCapacityForImportantUsage ?? 0) >= 4_000_000_000 || !ComponentSetup.carryFolders.isEmpty else {
            throw SetupFailure("Archive models need 4 GB free for downloading and unpacking. Free some space, or rerun setup and leave archive transcription off.")
        }
    }
    try step("models") { try models(archive: archive); try configure(["archive": archive]) }

    SetupInterface.step(6, "Meeting permissions")
    try step("permissions") { try permissions() }
    if !decided("calendar") { try step("calendar", optional: true) { try calendar() } }
    if !decided("calls-folder") { try step("calls-folder", optional: true) { try callsFolder() } }
    if !decided("launch-at-login") {
        let loginDefault = wasConfigured ? (settings["launchAtLogin"] as? Bool ?? true) : true
        try configure(["launchAtLogin": ask("Start Boring Notch when you log in?", defaultYes: loginDefault)])
        try record("launch-at-login")
    }

    SetupInterface.step(7, "Optional private Gateway")
    if decided("gateway") {
        SetupInterface.activity(progress.completed.contains("gateway") ? "Gateway was connected earlier." : "Gateway was skipped earlier. Choose Check & repair later to add it.")
    } else if ask("Connect this Mac to your existing Calla Gateway with Tailscale? Local meetings work without it.", defaultYes: settings["gatewayEnabled"] as? Bool ?? false) {
        try configure(["gateway": false])
        try step("gateway", optional: true) { try gateway(manifest.tailscale) }
    } else {
        try configure(["gateway": false]); try record("gateway", skipped: true)
    }

    SetupInterface.step(8, "Meeting readiness test")
    if !repair && progress.meetingTestPassed {
        SetupInterface.activity("The meeting test passed earlier.")
    } else {
        try step("meeting-test", optional: true) {
            progress.meetingTestPassed = try meetingTest()
            if !progress.meetingTestPassed { throw SetupFailure("Meeting capture was not fully confirmed. Check the audio source and permissions, then retry or skip for now.") }
        }
        try progress.write(receiptURL)
    }

    if manifest.tangit != nil {
        SetupInterface.step(9, "Tangit profile and device sign-in")
        if decided("tangit-profile") { SetupInterface.activity("Your Tangit profile was set up earlier.") }
        else { try step("tangit-profile", optional: true) { try TangitSetup.setup() } }
    }
    SetupInterface.activity("Running final readiness checks…")
    _ = try AppBridge.request("finish")
    let ready = try doctor()
    print("\nUpdates: open the next private DMG and its setup runs again, or use boring-notch update /path/to/package.dmg. Accounts, settings, history and downloaded models are preserved.\nRepair: boring-notch repair\nCheck: boring-notch doctor")
    if manifest.tangit != nil {
        print("Tangit: choose Open Tangit in setup, or run tangit / boring-notch tangit in Terminal.")
        if !SetupInterface.graphical, ask("Setup finished. Open Tangit now?") { try TangitSetup.launch() }
    }
    SetupInterface.event("complete", ["meetingReady": ready, "skipped": Array(progress.skipped).sorted()])
}

func update(_ image: URL) throws {
    guard image.pathExtension.lowercased() == "dmg", fm.fileExists(atPath: image.path) else { throw SetupFailure("Choose a downloaded private .dmg package.") }
    let result = try Commands.run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-plist", image.path])
    guard let data = result.output.data(using: .utf8),
          let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let entities = plist["system-entities"] as? [[String: Any]],
          let mount = entities.compactMap({ $0["mount-point"] as? String }).first else {
        throw SetupFailure("Could not mount the update image.")
    }
    defer { _ = try? Commands.run("/usr/bin/hdiutil", ["detach", mount]) }
    let root = URL(fileURLWithPath: mount)
    let candidates = ["Boring Notch.app", "Boring Notch.app/Contents/Resources/boringNotch.app",
                      "Boring Notch Setup.app/Contents/Resources/boringNotch.app", "boringNotch.app"]
    guard let source = candidates.map({ root.appendingPathComponent($0) }).first(where: { fm.fileExists(atPath: $0.path) })
    else { throw SetupFailure("This disk image does not contain the private Boring Notch app.") }
    try PackageInstaller.checkUpdate(source: source, installed: Layout.app)
    try Commands.run(source.appendingPathComponent("Contents/Helpers/boring-notch").path,
                     ["setup", "--package", source.path], inherit: true, timeout: 21600)
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    let command = args.first ?? "menu"
    switch command {
    case "tangit":
        guard fm.isExecutableFile(atPath: Layout.tangit.path) else { throw SetupFailure("Install the app with the setup launcher first.") }
        if args.count > 1 {
            try Commands.run(Layout.tangit.path, Array(args.dropFirst()), inherit: true, environment: TangitSetup.environment, timeout: 86400)
        } else { try TangitSetup.launch() }
    case "validate-package":
        guard args.count == 2 else { throw SetupFailure("Usage: boring-notch validate-package <app>") }
        let release = try PackageInstaller.validate(URL(fileURLWithPath: args[1]))
        print("Verified private package \(release.version) (\(release.build))")
    case "doctor": exit(try doctor() ? 0 : 1)
    case "components":
        // Installs or checks every tool and model in Components without the
        // rest of setup. Safe to repeat: whatever is in place is kept.
        var package = enclosingApp() ?? Layout.app
        if let index = args.firstIndex(of: "--package"), args.indices.contains(index + 1) { package = URL(fileURLWithPath: args[index + 1]) }
        let release = try PackageInstaller.validate(package)
        try ComponentSetup.migrateLegacy()
        try ComponentSetup.installTool("agy", release.agy, package: package)
        if let codex = release.codex { try ComponentSetup.installTool("codex", codex, package: package) }
        if let claude = release.claude { try ComponentSetup.installTool("claude", claude, package: package) }
        try ComponentSetup.installModel(.live)
        if args.contains("--archive") { try ComponentSetup.installModel(.archive) }
        ComponentSetup.clearQuarantine()
        for (name, present) in ComponentSetup.inventory(release) { print("\(present ? "✓" : "·") \(name)") }
    case "export-components":
        let folder = args.count > 1 ? URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath)
            : Layout.home.appendingPathComponent("Downloads/\(ComponentLayout.carryName)")
        try ComponentSetup.export(to: folder)
    case "update":
        guard args.count == 2 else { throw SetupFailure("Usage: boring-notch update /path/to/private-package.dmg") }
        try update(URL(fileURLWithPath: args[1]).standardizedFileURL)
    case "setup", "repair":
        let source: URL
        if let index = args.firstIndex(of: "--package"), args.indices.contains(index + 1) { source = URL(fileURLWithPath: args[index + 1]) }
        else { source = enclosingApp() ?? Layout.app }
        try wizard(source: source, repair: command == "repair" || args.contains("--repair"))
    case "menu":
        print("\nBoring Notch\n1. Set up or repair\n2. Check readiness\n3. Install an update\n4. Quit\nChoose [1]: ", terminator: "")
        switch readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "4" {
        case "", "1": try wizard(source: enclosingApp() ?? Layout.app, repair: false)
        case "2": _ = try doctor()
        case "3":
            print("Path to the downloaded .dmg (paste the path without surrounding quotes): ", terminator: "")
            if let path = readLine(), !path.isEmpty { try update(URL(fileURLWithPath: (path as NSString).expandingTildeInPath)) }
        default: break
        }
    case "--help", "-h", "help":
        print("boring-notch setup | repair | doctor | tangit [ARGS...] | update <package.dmg> | components [--archive] | export-components [folder]\nsetup and repair guide installation, AGY login, models, permissions, optional Gateway, meeting test and Tangit device sign-in.\ndoctor checks readiness without changing settings.\ntangit opens the bundled profile manager.\nupdate installs a private DMG while preserving your data.\nexport-components writes this Mac's speech models to a folder setup on another Mac copies from instead of downloading.")
    default: throw SetupFailure("Unknown command. Run boring-notch --help.")
    }
} catch {
    SetupInterface.event("fatal", ["message": error.localizedDescription])
    fputs("\nSetup: \(error.localizedDescription)\n", stderr)
    exit(1)
}
