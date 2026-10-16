import AppKit
import Defaults
import LaunchAtLogin
import SwiftUI
import BoringNotchSetupUI

@MainActor
enum PrivateDistribution {
    static var enabled: Bool { Bundle.main.object(forInfoDictionaryKey: "BoringPrivateDistribution") as? Bool == true }
    static let installedPath = "/Applications/boringNotch.app"
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
        // The old notch greeting is transient; setup belongs in its own window.
        BoringViewCoordinator.shared.helloAnimationRunning = false
        BoringViewCoordinator.shared.firstLaunch = false
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
        Defaults[.callaPlainCallEnabled] = true
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
        guard enabled, url.scheme == "boringnotch-setup", let action = url.host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let session = components.queryItems?.first(where: { $0.name == "session" })?.value,
              UUID(uuidString: session) != nil else { return }
        receivedBridgeRequest = true
        var approved = false
        if action == "test-start" {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Run the meeting setup test?"
            alert.informativeText = "Boring Notch will briefly record your microphone and system audio, save a test call in History, and send its transcript to your AI account. The test stops automatically after 100 seconds."
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
                    window.title = "Boring Notch — Google sign-in"
                    window.contentView = NSHostingView(rootView: CallaCopilotSignInView().padding(20))
                    window.center()
                    loginWindow = NSWindowController(window: window)
                }
                loginWindow?.showWindow(nil)
                loginWindow?.window?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            case "integrations":
                SettingsWindowController.shared.showWindow()
                SettingsWindowController.shared.show(route: SettingsRoute(.privacy))
            case "finish":
                UserDefaults.standard.set(true, forKey: "didCompletePrivateSetup")
                BoringViewCoordinator.shared.firstLaunch = false
                loginWindow?.close(); loginWindow = nil
            default: break
            }
        }
    }
}
