//
//  boringNotchApp.swift
//  boringNotchApp
//
//  Created by Harsh Vardhan  Goswami  on 02/08/24.
//

import AVFoundation
import Combine
import CallaContracts
import Defaults
import KeyboardShortcuts
import LaunchAtLogin
import Sparkle
import SwiftUI

@main
struct DynamicNotchApp: App {
    private static let pomodoroShortcutMigrationKey = "didMigratePomodoroStartPauseShortcutToT"
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Default(.menubarIcon) var showMenuBarIcon
    @Default(.pomodoroShowInMenuBar) var showPomodoroInMenuBar
    @ObservedObject var pomodoro = PomodoroManager.shared
    @Environment(\.openWindow) var openWindow

    let updaterController: SPUStandardUpdaterController

    init() {
        Self.migratePomodoroStartPauseShortcut()
        NotchHeaderItem.migrateRemovedItems()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: !PrivateDistribution.enabled, updaterDelegate: nil, userDriverDelegate: nil)

        // Initialize the settings window controller with the updater controller
        SettingsWindowController.shared.setUpdaterController(updaterController)

        // SwiftUI constructs App before AppDelegate receives launch callbacks.
        // Start long-lived services early instead of depending on a particular
        // notch surface to appear. The side usage badges may render cached data
        // before their view lifecycle starts, so their monitor owns refreshes
        // from app launch onward.
        DispatchQueue.main.async {
            // The disk-image copy only installs; the installed app runs these.
            guard !PrivateDistribution.isInstallerCopy else { return }
            _ = UsageMonitorManager.shared
            guard Defaults[.callaCopilotEnabled] else { return }
            CallaEngineClient.shared.start()
            CallaEngineClient.shared.applyCurrentPreferences()
        }
    }

    /// Existing installs persist the former Cmd+Shift+P default. Move that
    /// exact default once, while leaving any user-chosen binding alone.
    private static func migratePomodoroStartPauseShortcut() {
        guard !UserDefaults.standard.bool(forKey: Self.pomodoroShortcutMigrationKey) else { return }
        defer { UserDefaults.standard.set(true, forKey: Self.pomodoroShortcutMigrationKey) }

        let formerDefault = KeyboardShortcuts.Shortcut(.p, modifiers: [.command, .shift])
        let newDefault = KeyboardShortcuts.Shortcut(.t, modifiers: [.command, .shift])
        if KeyboardShortcuts.getShortcut(for: .pomodoroStartPause) == formerDefault {
            KeyboardShortcuts.setShortcut(newDefault, for: .pomodoroStartPause)
        }
    }

    var body: some Scene {
        MenuBarExtra(isInserted: Binding(
            get: { showMenuBarIcon && !PrivateDistribution.isInstallerCopy },
            set: { showMenuBarIcon = $0 })) {
            if pomodoro.isActive {
                Button(pomodoro.isRunning ? "Pause timer" : "Resume timer") {
                    pomodoro.toggle()
                }
                Button("Skip to next block") { pomodoro.skip() }
                Button("Stop timer") { pomodoro.stop() }
                Divider()
            } else if Defaults[.pomodoroTab] {
                Button("Start focus timer") {
                    pomodoro.start(preset: pomodoro.selectedPreset)
                }
                Divider()
            }
            Button("Settings…") {
                DispatchQueue.main.async {
                    SettingsWindowController.shared.showWindow()
                }
            }
            .keyboardShortcut(KeyEquivalent(","), modifiers: .command)
            CheckForUpdatesView(updater: updaterController.updater)
            Divider()
            Button("Restart Boring Notch") {
                ApplicationRelauncher.restart()
            }
            Button("Quit", role: .destructive) {
                NSApplication.shared.terminate(self)
            }
            .keyboardShortcut(KeyEquivalent("Q"), modifiers: .command)
        } label: {
            // A running session takes over the menu bar title so the countdown
            // is readable without opening anything.
            if showPomodoroInMenuBar && pomodoro.isActive {
                Image(systemName: pomodoro.statusIcon)
                Text(twoUnitString(pomodoro.remaining))
                    .monospacedDigit()
            } else {
                Image(systemName: "sparkle")
            }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    /// SwiftUI may install a forwarding application-delegate proxy. Keep the
    /// concrete delegate available to app-owned coordinators that need windows.
    static weak var shared: AppDelegate?

    /// Fresh installs should keep the notch available after a reboot. Record the
    /// initial registration so a later user choice in Settings remains respected.
    private static let didConfigureLaunchAtLoginKey = "didConfigureLaunchAtLogin"

    var windows: [String: NSWindow] = [:] // UUID -> NSWindow
    var viewModels: [String: BoringViewModel] = [:] // UUID -> BoringViewModel
    var window: NSWindow?
    let vm: BoringViewModel = .init()
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    // Shelf transport creates/reads its KDE identity from Keychain. Construct
    // it lazily in Shelf views; doing it during delegate construction can block
    // the main thread before Calla's embedded engine gets its launch callback.
    var whatsNewWindow: NSWindow?
    var timer: Timer?
    var closeNotchTask: Task<Void, Never>?
    private var previousScreens: [NSScreen]?
    private var onboardingWindowController: NSWindowController?
    private var screenLockedObserver: Any?
    private var screenUnlockedObserver: Any?
    private var isScreenLocked: Bool = false
    private var windowScreenDidChangeObserver: Any?
    private var dragDetectors: [String: DragDetector] = [:] // UUID -> DragDetector

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !PrivateDistribution.isInstallerCopy else { return }
        NotificationCenter.default.removeObserver(self)
        if let observer = screenLockedObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            screenLockedObserver = nil
        }
        if let observer = screenUnlockedObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            screenUnlockedObserver = nil
        }
        MusicManager.shared.destroy()
        cleanupDragDetectors()
        cleanupWindows()
        XPCHelperClient.shared.stopMonitoringAccessibilityAuthorization()
        // Quitting the notch takes its helpers with it: the capture host holding the
        // microphone and any resident `agy` language server.
        // Otherwise they are reparented to launchd and survive until a restart.
        CallaEngineClient.shared.shutdownAndWait()
    }

    @MainActor
    func onScreenLocked(_ notification: Notification) {
        isScreenLocked = true
        if !Defaults[.showOnLockScreen] {
            cleanupWindows()
        } else {
            enableSkyLightOnAllWindows()
        }
    }

    @MainActor
    func onScreenUnlocked(_ notification: Notification) {
        isScreenLocked = false
        if !Defaults[.showOnLockScreen] {
            adjustWindowPosition(changeAlpha: true)
        } else {
            disableSkyLightOnAllWindows()
        }
    }
    
    @MainActor
    private func enableSkyLightOnAllWindows() {
        if Defaults[.showOnAllDisplays] {
            windows.values.forEach { window in
                if let skyWindow = window as? BoringNotchSkyLightWindow {
                    skyWindow.enableSkyLight()
                }
            }
        } else {
            if let skyWindow = window as? BoringNotchSkyLightWindow {
                skyWindow.enableSkyLight()
            }
        }
    }
    
    @MainActor
    private func disableSkyLightOnAllWindows() {
        // Delay disabling SkyLight to avoid flicker during unlock transition
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            await MainActor.run {
                if Defaults[.showOnAllDisplays] {
                    self.windows.values.forEach { window in
                        if let skyWindow = window as? BoringNotchSkyLightWindow {
                            skyWindow.disableSkyLight()
                        }
                    }
                } else {
                    if let skyWindow = self.window as? BoringNotchSkyLightWindow {
                        skyWindow.disableSkyLight()
                    }
                }
            }
        }
    }

    private func cleanupWindows(shouldInvert: Bool = false) {
        let shouldCleanupMulti = shouldInvert ? !Defaults[.showOnAllDisplays] : Defaults[.showOnAllDisplays]
        
        if shouldCleanupMulti {
            windows.values.forEach { window in
                window.close()
                NotchSpaceManager.shared.notchSpace.windows.remove(window)
            }
            windows.removeAll()
            viewModels.removeAll()
        } else if let window = window {
            window.close()
            NotchSpaceManager.shared.notchSpace.windows.remove(window)
            if let obs = windowScreenDidChangeObserver {
                NotificationCenter.default.removeObserver(obs)
                windowScreenDidChangeObserver = nil
            }
            self.window = nil
        }
    }

    private func cleanupDragDetectors() {
        dragDetectors.values.forEach { detector in
            detector.stopMonitoring()
        }
        dragDetectors.removeAll()
    }

    private func setupDragDetectors() {
        cleanupDragDetectors()

        guard Defaults[.expandedDragDetection] else { return }

        if Defaults[.showOnAllDisplays] {
            for screen in NSScreen.screens {
                setupDragDetectorForScreen(screen)
            }
        } else {
            let preferredScreen: NSScreen? = window?.screen
                ?? NSScreen.screen(withUUID: coordinator.selectedScreenUUID)
                ?? NSScreen.main

            if let screen = preferredScreen {
                setupDragDetectorForScreen(screen)
            }
        }
    }

    private func setupDragDetectorForScreen(_ screen: NSScreen) {
        guard let uuid = screen.displayUUID else { return }
        
        // The backing window is much larger than the visible notch. Re-evaluate
        // its visible bounds during the drag, including after it opens.
        let detector = DragDetector(notchRegion: { [weak self] in
            guard let self, Defaults[.boringShelf] else { return .zero }
            let model = Defaults[.showOnAllDisplays] ? self.viewModels[uuid] : self.vm
            guard let model, Defaults[.showOnAllDisplays] || self.window?.screen == screen,
                  !model.hideOnClosed || model.notchState == .open else { return .zero }
            let size = model.notchState == .open ? model.notchSize : model.closedNotchSize
            return CGRect(x: screen.frame.midX - size.width / 2,
                          y: screen.frame.maxY - size.height,
                          width: size.width, height: size.height)
        })

        detector.onDragEntersNotchRegion = { [weak self] in
            Task { @MainActor in
                self?.handleDragEntersNotchRegion(onScreen: screen)
            }
        }
        
        dragDetectors[uuid] = detector
        detector.startMonitoring()
    }

    private func handleDragEntersNotchRegion(onScreen screen: NSScreen) {
        guard !NotchResizeSession.shared.isEditing else { return }
        guard let uuid = screen.displayUUID else { return }

        // This runs off a global mouse monitor, outside every drop target, and
        // it used to hard-code the Shelf. That answered the Send/Remember
        // question on the reader's behalf — and re-answered it every time the
        // pointer crossed back into the region, wiping the chooser mid-drag.
        guard !NotchDropRouter.shared.ownsCurrentView else { return }
        let destination: NotchViews
        if NotchDropRouter.shared.isSplitAvailable {
            NotchDropRouter.shared.beginChoosing()
            destination = .dropChooser
        } else {
            destination = .shelf
        }

        if Defaults[.showOnAllDisplays], let viewModel = viewModels[uuid] {
            viewModel.open()
            coordinator.currentView = destination
        } else if !Defaults[.showOnAllDisplays], let windowScreen = window?.screen, screen == windowScreen {
            vm.open()
            coordinator.currentView = destination
        }
    }

    private func createBoringNotchWindow(for screen: NSScreen, with viewModel: BoringViewModel) -> NSWindow {
        let rect = NSRect(x: 0, y: 0, width: windowSize.width, height: windowSize.height)
        let styleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow]
        
        let window = BoringNotchSkyLightWindow(contentRect: rect, styleMask: styleMask, backing: .buffered, defer: false)
        
        // Enable SkyLight only when screen is locked
        if isScreenLocked {
            window.enableSkyLight()
        } else {
            window.disableSkyLight()
        }

        window.contentView = NSHostingView(
            rootView: ContentView()
                .environmentObject(viewModel)
        )

        window.orderFrontRegardless()
        NotchSpaceManager.shared.notchSpace.windows.insert(window)

        // Observe when the window's screen changes so we can update drag detectors
        windowScreenDidChangeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: window,
            queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.setupDragDetectors()
                }
        }
        return window
    }

    /// Resolves only target notch in all-display mode. With one notch, move that
    /// notch beside Settings for edit session and restore preferred display later.
    @MainActor
    func prepareNotchResizeTarget(on screen: NSScreen) -> BoringViewModel? {
        guard let uuid = screen.displayUUID else { return nil }
        if Defaults[.showOnAllDisplays] {
            return viewModels[uuid] ?? viewModels.values.first
        }
        vm.screenUUID = uuid
        if let window {
            positionWindow(window, on: screen)
        }
        return vm
    }

    @MainActor
    func finishNotchResizeTarget() {
        guard !Defaults[.showOnAllDisplays] else { return }
        adjustWindowPosition()
    }

    @MainActor
    private func positionWindow(_ window: NSWindow, on screen: NSScreen, changeAlpha: Bool = false) {
        if changeAlpha {
            window.alphaValue = 0
        }

        let screenFrame = screen.frame
        window.setFrameOrigin(
            NSPoint(
                x: screenFrame.origin.x + (screenFrame.width / 2) - window.frame.width / 2,
                y: screenFrame.origin.y + screenFrame.height - window.frame.height
            ))
        window.alphaValue = 1
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { PrivateDistribution.handle(url) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if PrivateDistribution.enabled && sender.isActive { PrivateDistribution.openSetup() }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        TerminationSignals.install()
        PrivateDistribution.prepareFirstLaunch()
        // A second notch from the disk image beside the installed one is the
        // most confusing thing a new Mac can show. The installer copy is a
        // setup window and nothing more.
        if PrivateDistribution.isInstallerCopy { return }

        CallaCopilotSettings.migrate()

        configureLaunchAtLoginIfNeeded()
        if Defaults[.callaCopilotEnabled] {
            // Touching the session here builds its status bridge before the first
            // poll. Starting capture remains an explicit user action. One XPC
            // connection is kept for the app's lifetime.
            _ = CopilotLiveSession.shared
            CallaEngineClient.shared.start()
            CallaEngineClient.shared.applyCurrentPreferences()
            CallaEngineClient.shared.startMonitoring()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigurationDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            forName: Notification.Name.selectedScreenChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.adjustWindowPosition(changeAlpha: true)
                self?.setupDragDetectors()
            }
        }

        NotificationCenter.default.addObserver(
            forName: Notification.Name.notchHeightChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.adjustWindowPosition()
                self?.setupDragDetectors()
            }
        }

        NotificationCenter.default.addObserver(
            forName: Notification.Name.automaticallySwitchDisplayChanged, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self = self, let window = self.window else { return }
            Task { @MainActor in
                window.alphaValue = self.coordinator.selectedScreenUUID == self.coordinator.preferredScreenUUID ? 1 : 0
            }
        }

        NotificationCenter.default.addObserver(
            forName: Notification.Name.showOnAllDisplaysChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.cleanupWindows(shouldInvert: true)
                self.adjustWindowPosition(changeAlpha: true)
                self.setupDragDetectors()
            }
        }

        NotificationCenter.default.addObserver(
            forName: Notification.Name.expandedDragDetectionChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.setupDragDetectors()
            }
        }

        // Use closure-based observers for DistributedNotificationCenter and keep tokens for removal
        screenLockedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(rawValue: "com.apple.screenIsLocked"),
            object: nil, queue: .main) { [weak self] notification in
                Task { @MainActor in
                    self?.onScreenLocked(notification)
                }
        }

        screenUnlockedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(rawValue: "com.apple.screenIsUnlocked"),
            object: nil, queue: .main) { [weak self] notification in
                Task { @MainActor in
                    self?.onScreenUnlocked(notification)
                }
        }

        KeyboardShortcuts.onKeyDown(for: .pomodoroStartPause) {
            Task { @MainActor in PomodoroManager.shared.toggle() }
        }

        KeyboardShortcuts.onKeyDown(for: .pomodoroSkipPhase) {
            Task { @MainActor in PomodoroManager.shared.skip() }
        }

        KeyboardShortcuts.onKeyDown(for: .pomodoroStopTimer) {
            Task { @MainActor in PomodoroManager.shared.stop() }
        }

        KeyboardShortcuts.onKeyDown(for: .toggleSneakPeek) { [weak self] in
            guard let self = self else { return }
            if Defaults[.sneakPeekStyles] == .inline {
                let newStatus = !self.coordinator.expandingView.show
                self.coordinator.toggleExpandingView(status: newStatus, type: .music)
            } else {
                self.coordinator.toggleSneakPeek(
                    status: !self.coordinator.sneakPeek.show,
                    type: .music,
                    duration: 3.0
                )
            }
        }

        KeyboardShortcuts.onKeyDown(for: .toggleNotchOpen) { [weak self] in
            Task { [weak self] in
                guard let self = self else { return }

                let mouseLocation = NSEvent.mouseLocation

                var viewModel = self.vm

                if Defaults[.showOnAllDisplays] {
                    for screen in NSScreen.screens {
                        if screen.frame.contains(mouseLocation) {
                            if let uuid = screen.displayUUID, let screenViewModel = self.viewModels[uuid] {
                                viewModel = screenViewModel
                                break
                            }
                        }
                    }
                }

                self.closeNotchTask?.cancel()
                self.closeNotchTask = nil

                switch viewModel.notchState {
                case .closed:
                    await MainActor.run {
                        viewModel.open()
                    }

                    let task = Task { [weak viewModel] in
                        do {
                            try await Task.sleep(for: .seconds(3))
                            await MainActor.run {
                                viewModel?.close()
                            }
                        } catch { }
                    }
                    self.closeNotchTask = task
                case .open:
                    await MainActor.run {
                        viewModel.close()
                    }
                }
            }
        }

        // KeyboardShortcuts registers a Carbon global hotkey, so this callback
        // arrives even while another application is active. Resolve the notch
        // under the pointer here and mutate it directly; a session-owned state
        // object cannot represent pinning Home, Shelf, or Pomodoro.
        KeyboardShortcuts.onKeyDown(for: .copilotTogglePin) { [weak self] in
            Task { @MainActor in
                self?.toggleUniversalNotchPin()
            }
        }

        KeyboardShortcuts.onKeyDown(for: .copilotToggleCall) { [weak self] in
            Task { @MainActor in
                let engine = CallaEngineClient.shared
                guard Defaults[.callaCopilotEnabled] else { return }
                switch CallaMode.resolved(Defaults[.callaCopilotMode],
                    quiz: Defaults[.callaQuizEnabled]).rawValue {
                case "quiz" where Defaults[.callaQuizEnabled]:
                    if let sessionID = engine.status.quiz.sessionID,
                       engine.status.quiz.active {
                        engine.sendQuiz(.init(sessionID: sessionID, command: .stop))
                    } else {
                        BoringViewCoordinator.shared.currentView = .copilot
                        NotificationCenter.default.post(name: .callaQuizWantsNotch, object: nil)
                    }
                default:
                    guard engine.status.copilot.available else { return }
                    if engine.status.copilot.running {
                        engine.endCall()
                    } else {
                        engine.startCall(persona: Defaults[.callaCopilotPersona], model: Defaults[.callaCopilotLiveModel])
                    }
                }
            }
        }

        KeyboardShortcuts.onKeyDown(for: .copilotToggleLayout) {
            Task { @MainActor in
                CopilotLiveSession.shared.toggleLayout()
            }
        }

        // One registration for every live-session key. Which surface a press
        // belongs to is decided when it happens, by `NotchSessionRouter`, rather
        // than by which of three near-identical shortcut names was bound.
        NotchSessionShortcuts.install()

        // Carries a pre-modes Quiz setup into the per-mode councils, once.
        QuizProfileStore.migrateIfNeeded()

        KeyboardShortcuts.onKeyDown(for: .quizToggleWrap) {
            NotificationCenter.default.post(name: .callaQuizToggleWrap, object: nil)
        }

        KeyboardShortcuts.onKeyDown(for: .copilotDismiss) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let viewModel = self.notchViewModel(at: NSEvent.mouseLocation)
                viewModel.setPinned(false)
                CopilotLiveSession.shared.dismiss()
                viewModel.close()
            }
        }

        if !Defaults[.showOnAllDisplays] {
            let viewModel = self.vm
            let window = createBoringNotchWindow(
                for: NSScreen.main ?? NSScreen.screens.first!, with: viewModel)
            self.window = window
            adjustWindowPosition(changeAlpha: true)
        } else {
            adjustWindowPosition(changeAlpha: true)
        }

        setupDragDetectors()

        if PrivateDistribution.enabled {
            // The dedicated setup window owns first run, including permissions.
        } else if coordinator.firstLaunch {
            DispatchQueue.main.async {
                self.showOnboardingWindow()
            }
            playWelcomeSound()
        } else if MusicManager.shared.isNowPlayingDeprecated
            && Defaults[.mediaController] == .nowPlaying
        {
            DispatchQueue.main.async {
                self.showOnboardingWindow(step: .musicPermission)
            }
        }

        previousScreens = NSScreen.screens
    }

    private func configureLaunchAtLoginIfNeeded() {
        guard !PrivateDistribution.enabled else { return }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.didConfigureLaunchAtLoginKey) else { return }

        LaunchAtLogin.isEnabled = true
        if LaunchAtLogin.isEnabled {
            defaults.set(true, forKey: Self.didConfigureLaunchAtLoginKey)
        }
    }

    /// Toggles the notch-level pin from either the global shortcut or an
    /// in-panel pin button.
    ///
    /// Call and Quiz also acquire a temporary session pin. Turning the pin off
    /// clears both reasons, otherwise the notch would appear to ignore the
    /// universal shortcut until capture ended.
    @MainActor
    func toggleUniversalNotchPin(for requestedViewModel: BoringViewModel? = nil) {
        let viewModel = requestedViewModel ?? notchViewModel(at: NSEvent.mouseLocation)
        let session = CopilotLiveSession.shared
        let isEffectivelyPinned = viewModel.isPinned || session.pinsNotchOpen

        closeNotchTask?.cancel()
        closeNotchTask = nil

        if isEffectivelyPinned {
            viewModel.setPinned(false)
            if session.pinsNotchOpen {
                session.dismiss()
            }
            viewModel.close()
        } else {
            viewModel.setPinned(true)
            viewModel.open()
        }
    }

    @MainActor
    private func notchViewModel(at pointerLocation: NSPoint) -> BoringViewModel {
        guard Defaults[.showOnAllDisplays] else { return vm }
        for screen in NSScreen.screens where screen.frame.contains(pointerLocation) {
            if let uuid = screen.displayUUID, let viewModel = viewModels[uuid] {
                return viewModel
            }
        }
        return viewModels.values.first ?? vm
    }

    func playWelcomeSound() {
        let audioPlayer = AudioPlayer()
        audioPlayer.play(fileName: "boring", fileExtension: "m4a")
    }

    func deviceHasNotch() -> Bool {
        if #available(macOS 12.0, *) {
            for screen in NSScreen.screens {
                if screen.safeAreaInsets.top > 0 {
                    return true
                }
            }
        }
        return false
    }

    @objc func screenConfigurationDidChange() {
        let currentScreens = NSScreen.screens

        let screensChanged =
            currentScreens.count != previousScreens?.count
            || Set(currentScreens.compactMap { $0.displayUUID })
                != Set(previousScreens?.compactMap { $0.displayUUID } ?? [])
            || Set(currentScreens.map { $0.frame }) != Set(previousScreens?.map { $0.frame } ?? [])

        previousScreens = currentScreens

        if screensChanged {
            DispatchQueue.main.async { [weak self] in
                self?.cleanupWindows()
                self?.adjustWindowPosition()
                self?.setupDragDetectors()
            }
        }
    }

    @objc func adjustWindowPosition(changeAlpha: Bool = false) {
        if Defaults[.showOnAllDisplays] {
            let currentScreenUUIDs = Set(NSScreen.screens.compactMap { $0.displayUUID })

            // Remove windows for screens that no longer exist
            for uuid in windows.keys where !currentScreenUUIDs.contains(uuid) {
                if let window = windows[uuid] {
                    window.close()
                    NotchSpaceManager.shared.notchSpace.windows.remove(window)
                    windows.removeValue(forKey: uuid)
                    viewModels.removeValue(forKey: uuid)
                }
            }

            // Create or update windows for all screens
            for screen in NSScreen.screens {
                guard let uuid = screen.displayUUID else { continue }
                
                if windows[uuid] == nil {
                    let viewModel = BoringViewModel(screenUUID: uuid)
                    let window = createBoringNotchWindow(for: screen, with: viewModel)

                    windows[uuid] = window
                    viewModels[uuid] = viewModel
                }

                if let window = windows[uuid], let viewModel = viewModels[uuid] {
                    positionWindow(window, on: screen, changeAlpha: changeAlpha)

                    if viewModel.notchState == .closed {
                        viewModel.close()
                    }
                }
            }
        } else {
            let selectedScreen: NSScreen

            if let preferredScreen = NSScreen.screen(withUUID: coordinator.preferredScreenUUID ?? "") {
                coordinator.selectedScreenUUID = coordinator.preferredScreenUUID ?? ""
                selectedScreen = preferredScreen
            } else if Defaults[.automaticallySwitchDisplay], let mainScreen = NSScreen.main,
                      let mainUUID = mainScreen.displayUUID {
                coordinator.selectedScreenUUID = mainUUID
                selectedScreen = mainScreen
            } else {
                if let window = window {
                    window.alphaValue = 0
                }
                return
            }

            vm.screenUUID = selectedScreen.displayUUID
            vm.notchSize = getClosedNotchSize(screenUUID: selectedScreen.displayUUID)

            if window == nil {
                window = createBoringNotchWindow(for: selectedScreen, with: vm)
            }

            if let window = window {
                positionWindow(window, on: selectedScreen, changeAlpha: changeAlpha)

                if vm.notchState == .closed {
                    vm.close()
                }
            }
        }
    }

    @objc func togglePopover(_ sender: Any?) {
        if window?.isVisible == true {
            window?.orderOut(nil)
        } else {
            window?.orderFrontRegardless()
        }
    }

    @objc func quitAction() {
        NSApplication.shared.terminate(self)
    }

    func showOnboardingWindow(step: OnboardingStep = .welcome) {
        if onboardingWindowController == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
                styleMask: [.titled, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.center()
            window.title = "Onboarding"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.contentView = NSHostingView(
                rootView: OnboardingView(
                    step: step,
                    onFinish: {
                        window.orderOut(nil)
//                        NSApp.setActivationPolicy(.accessory)
                        window.close()
                        NSApp.deactivate()
                    },
                    onOpenSettings: {
                        window.close()
                        SettingsWindowController.shared.showWindow()
                    }
                ))
            window.isRestorable = false
            window.identifier = NSUserInterfaceItemIdentifier("OnboardingWindow")

            onboardingWindowController = NSWindowController(window: window)
        }

//        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindowController?.window?.makeKeyAndOrderFront(nil)
        onboardingWindowController?.window?.orderFrontRegardless()
    }
}

extension Notification.Name {
    static let selectedScreenChanged = Notification.Name("SelectedScreenChanged")
    static let notchHeightChanged = Notification.Name("NotchHeightChanged")
    static let showOnAllDisplaysChanged = Notification.Name("showOnAllDisplaysChanged")
    static let automaticallySwitchDisplayChanged = Notification.Name("automaticallySwitchDisplayChanged")
    static let expandedDragDetectionChanged = Notification.Name("expandedDragDetectionChanged")
}

extension CGRect: @retroactive Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(origin.x)
        hasher.combine(origin.y)
        hasher.combine(size.width)
        hasher.combine(size.height)
    }

    public static func == (lhs: CGRect, rhs: CGRect) -> Bool {
        return lhs.origin == rhs.origin && lhs.size == rhs.size
    }
}

/// Makes `kill`, `killall` and Ctrl-C quit the app.
///
/// `MediaRemoteAdapter.framework` installs SIGINT and SIGTERM handlers from a
/// load-time constructor. They exist for the `perl` adapter process, which
/// loads the same framework, but they run in this process too, and all they do
/// here is cancel a stream the app never starts. Every polite kill was being
/// swallowed, so the only way to stop the notch was SIGKILL, which skips the
/// shutdown that takes the call host and `agy` down with it.
///
/// So the signals are taken back: the first one quits normally, through
/// `applicationWillTerminate`; a second, or a quit that hangs, exits outright.
enum TerminationSignals {
    // Only touched on the main queue.
    nonisolated(unsafe) private static var sources: [DispatchSourceSignal] = []
    nonisolated(unsafe) private static var requested = false

    @MainActor
    static func install() {
        guard sources.isEmpty else { return }
        sources = [SIGTERM, SIGINT, SIGHUP].map { code in
            signal(code, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: code, queue: .main)
            source.setEventHandler {
                if requested { exit(0) }
                requested = true
                // `applicationWillTerminate` waits up to 2.5s for the engine;
                // anything past that is a hang, not a shutdown.
                DispatchQueue.global().asyncAfter(deadline: .now() + 6) { exit(0) }
                MainActor.assumeIsolated { NSApplication.shared.terminate(nil) }
            }
            source.resume()
            return source
        }
    }
}
