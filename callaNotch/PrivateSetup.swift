import AppKit
import CallaContracts
import Defaults
import LaunchAtLogin
import SwiftUI
import CallaNotchSetupUI

@MainActor
enum PrivateDistribution {
    static var enabled: Bool { Bundle.main.object(forInfoDictionaryKey: "CallaPrivateDistribution") as? Bool == true }
    static let installedPath = CallaBrand.installedApp.path
    /// The copy opened from the disk image (or translocated by Gatekeeper). It
    /// exists only to install the real app, so it shows the setup window and
    /// nothing else — no notch, no menu bar item, no engine services.
    static var isInstallerCopy: Bool {
        enabled && Bundle.main.bundleURL.resolvingSymlinksInPath().path != installedPath
    }
    private static var loginWindow: NSWindowController?
    private static var receivedBridgeRequest = false
    private static var setupWindow: SetupWindowController?
    private static var didCompleteSetup: Bool { UserDefaults.standard.bool(forKey: "didCompletePrivateSetup") }

    static func prepareFirstLaunch() {
        guard enabled else { return }
        CallaViewCoordinator.shared.firstLaunch = false
        // The disk-image copy installed this app and quit; carry on at once.
        if CommandLine.arguments.contains("--continue-setup") {
            openSetup(autoStart: true)
            return
        }
        if isInstallerCopy { openSetup(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard !receivedBridgeRequest, !didCompleteSetup else { return }
            let request = try? JSONSerialization.data(withJSONObject: ["uiCommand": "isSetupRunning"])
            guard let request else { return }
            CallaEngineClient.shared.performPrivateSetup(request) { result in
                guard result["running"] as? Bool != true, !receivedBridgeRequest else { return }
                openSetup()
            }
        }
    }

    static func openSetup(autoStart: Bool = false) {
        if setupWindow == nil {
            setupWindow = SetupWindowController(package: Bundle.main.bundleURL, autoStart: autoStart,
                                                alreadySetUp: didCompleteSetup && !isInstallerCopy) { request, completion in
                guard let data = try? JSONSerialization.data(withJSONObject: request) else {
                    completion(["error": "Could not prepare the setup request."]); return
                }
                CallaEngineClient.shared.performPrivateSetup(data, completion: completion)
            }
        }
        setupWindow?.present()
    }

    /// First-run defaults for a private Mac. Applied once, so later choices in
    /// Settings are never overwritten by a repair.
    private static func applyMeetingDefaults() {
        guard !UserDefaults.standard.bool(forKey: "didConfigurePrivateMeetingSetup") else { return }
        Defaults[.callaCopilotEnabled] = true
        Defaults[.callaCopilotMode] = "call"
        Defaults[.callaCopilotPersona] = "generic"
        Defaults[.callaCopilotLiveModel] = "whisper-small-en"
        Defaults[.callaIntelligenceProvider] = "local"
        Defaults[.callaIntelligenceLiveTier] = "balanced"
        Defaults[.callaIntelligenceFallback] = false
        Defaults[.callaGatewayStandby] = "off"
        Defaults[.callaCopilotAutoStartOnMeeting] = false
        // Home is Now Playing beside the calendar. Public builds turn the
        // calendar on in onboarding, which private builds replace with setup.
        Defaults[.showCalendar] = true
        UserDefaults.standard.set(true, forKey: "didConfigurePrivateMeetingSetup")
    }

    static func handle(_ url: URL) {
        guard enabled, url.scheme == CallaBrand.setupScheme, let action = url.host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let session = components.queryItems?.first(where: { $0.name == "session" })?.value,
              UUID(uuidString: session) != nil else { return }
        receivedBridgeRequest = true
        var approved = false
        if action == "test-start" {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Run the meeting setup test?"
            alert.informativeText = "calla.notch will briefly record your microphone and system audio, save a test call in History, and send its transcript to your AI account. The test stops automatically after 100 seconds."
            alert.addButton(withTitle: "Run test")
            alert.addButton(withTitle: "Cancel")
            approved = alert.runModal() == .alertFirstButtonReturn
        }
        let request: [String: Any] = ["session": session, "action": action, "approved": approved,
            "uiState": ["archive": Defaults[.callaCopilotArchiveRetranscribe], "launchAtLogin": LaunchAtLogin.isEnabled]]
        guard let data = try? JSONSerialization.data(withJSONObject: request) else { return }
        CallaEngineClient.shared.performPrivateSetup(data) { result in
            guard result["action"] as? String == action, result["error"] == nil else { return }
            let options = result["options"] as? [String: Bool] ?? [:]
            switch action {
            case "configure":
                if options["meetings"] == true { applyMeetingDefaults() }
                if let gateway = options["gateway"] {
                    Defaults[.callaIntelligenceFallback] = gateway
                    Defaults[.callaGatewayStandby] = gateway ? "on-failure" : "off"
                }
                if let archive = options["archive"] { Defaults[.callaCopilotArchiveRetranscribe] = archive }
                if let login = options["launchAtLogin"] {
                    LaunchAtLogin.isEnabled = login
                    UserDefaults.standard.set(true, forKey: "didConfigureLaunchAtLogin")
                }
                CallaEngineClient.shared.applyCurrentPreferences()
                CallaEngineClient.shared.setIntelligence(provider: Defaults[.callaIntelligenceProvider],
                    tier: Defaults[.callaIntelligenceLiveTier], fallback: Defaults[.callaIntelligenceFallback],
                    gatewayStandby: Defaults[.callaGatewayStandby])
            case "calls-folder":
                // The engine created the folder; macOS asks on the app's behalf.
                NSApp.activate(ignoringOtherApps: true)
            case "calendar":
                Defaults[.showCalendar] = true
                NSApp.activate(ignoringOtherApps: true)
                Task { await CalendarManager.shared.checkCalendarAuthorization() }
            case "login":
                if loginWindow == nil {
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 280),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
                    window.title = "calla.notch — Google sign-in"
                    window.contentView = NSHostingView(rootView: CallaCopilotSignInView().padding(20))
                    window.center()
                    loginWindow = NSWindowController(window: window)
                }
                loginWindow?.showWindow(nil)
                loginWindow?.window?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            case "integrations":
                SettingsWindowController.shared.showWindow()
                SettingsWindowController.shared.show(route: SettingsRoute(.permissions))
            case "finish":
                UserDefaults.standard.set(true, forKey: "didCompletePrivateSetup")
                CallaViewCoordinator.shared.firstLaunch = false
                loginWindow?.close(); loginWindow = nil
            default: break
            }
        }
    }
}

/// Carries this Mac's settings to another one.
///
/// Every setting lives in the app's own defaults domain, inside its sandbox
/// container. The container is privacy-protected, so nothing outside the app
/// can read it, not even a script. The app exports the domain itself, the
/// engine writes it to Downloads, and the private package can embed that file
/// (`package-private.sh --settings`) so the installed app applies it once on
/// first launch.
enum SettingsTransfer {
    static let bundledPath = "PrivateSetup/settings.plist"
    private static let appliedKey = "appliedBundledSettingsID"

    /// Keys that describe this Mac or this install rather than a choice:
    /// - whether setup has run (it must run again: permissions and sign-in
    ///   happen there);
    /// - this Mac's display and window ids;
    /// - the LocalSend and KDE device identities, which two Macs must not share
    ///   on one network;
    /// - cached usage reports, which are data, not settings;
    /// - window frames and Sparkle state.
    private static let excludedKeys: Set<String> = [
        "didCompletePrivateSetup", appliedKey, "preferred_screen_uuid", "callaQuizTargetWindowID",
        "kdeConnectDeviceID", "localSendIdentity", "cachedClaudeUsage", "cachedCodexUsage",
    ]
    private static let excludedPrefixes = ["NSWindow Frame", "NSStatusItem", "NSNav", "NSSplitView",
                                           "NSToolbar", "NSOSPLast", "SU", "Apple", "com.apple.", "_",
                                           "usage.report."]

    static func snapshot() -> Data? {
        guard let domain = Bundle.main.bundleIdentifier,
              let settings = UserDefaults.standard.persistentDomain(forName: domain) else { return nil }
        let kept = settings.filter { key, _ in
            !excludedKeys.contains(key) && !excludedPrefixes.contains(where: key.hasPrefix)
        }
        let envelope: [String: Any] = [
            "format": 1,
            "id": UUID().uuidString,
            "exportedAt": Date(),
            "sourceVersion": Bundle.main.releaseVersionNumber ?? "",
            "settings": kept,
        ]
        return try? PropertyListSerialization.data(fromPropertyList: envelope, format: .binary, options: 0)
    }

    @MainActor
    static func export() {
        guard let data = snapshot() else {
            CallaEngineClient.shared.reportLocalFailure("Could not read settings to export"); return
        }
        CallaEngineClient.shared.saveSettingsSnapshot(data)
    }

    /// Applies the snapshot shipped inside a private package, once per
    /// snapshot. Runs before anything reads its settings.
    static func applyBundledIfNeeded() {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent(bundledPath),
              let data = try? Data(contentsOf: url),
              let envelope = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              envelope["format"] as? Int == 1,
              let id = envelope["id"] as? String,
              let settings = envelope["settings"] as? [String: Any] else { return }
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: appliedKey) != id else { return }
        for (key, value) in settings
        where !excludedKeys.contains(key) && !excludedPrefixes.contains(where: key.hasPrefix) {
            defaults.set(value, forKey: key)
        }
        // These are the choices; setup's first-run defaults must not replace them.
        defaults.set(true, forKey: "didConfigurePrivateMeetingSetup")
        defaults.set(id, forKey: appliedKey)
        NSLog("[Settings] applied %d bundled settings", settings.count)
    }
}
