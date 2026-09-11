//
//  IceMenuBarController.swift
//  boringNotch
//
//  Derived from Ice at 11edd39115f3f43a83ae114b5348df6a0e1741cf.
//  Copyright (c) Jordan Baird. SPDX-License-Identifier: GPL-3.0-or-later.
//

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine

/// Boring-owned menu-bar runtime. It discovers only status-level windows and
/// never asks macOS for permission itself; Settings owns that explicit action.
@MainActor
final class IceMenuBarController: NSObject, ObservableObject {
    static let shared = IceMenuBarController()

    @Published private(set) var state: IceRuntimeState = .stopped
    @Published private(set) var items: [IceMenuBarItem] = []
    @Published private(set) var configuration: IceConfiguration

    private var controlItem: NSStatusItem?
    private var hiddenDivider: NSStatusItem?
    private var hiddenSpacer: NSStatusItem?
    private var alwaysHiddenDivider: NSStatusItem?
    private var alwaysHiddenSpacer: NSStatusItem?
    private var rehideTimer: Timer?
    private var eventMonitors: [Any] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private let hotkeys = IceHotkeyRegistry()
    private var appearancePanels: [NSPanel] = []
    private var standaloneWaitTask: Task<Void, Never>?
    private static let collapsedDividerLength: CGFloat = 10_000
    private var sectionState = IceSectionStateMachine()
    private var dragRevealActive = false

    override init() {
        IceMigration.migrateIfNeeded()
        configuration = IceConfigurationStore.load()
        super.init()
    }

    // AppDelegate calls `stop()` on termination while still on main actor.

    func start() {
        guard configuration.enabled else { stop(); return }
        guard AXIsProcessTrusted() else {
            state = IceStartupGate.state(enabled: configuration.enabled, accessibilityGranted: false,
                                         standaloneIceRunning: false, itemCount: items.count)
            return
        }
        guard requestStandaloneIceTermination() else { return }
        installControlItems()
        refreshItems()
        installEvents()
        registerHotkeys()
        updateAppearance()
        state = IceStartupGate.state(enabled: configuration.enabled, accessibilityGranted: true,
                                     standaloneIceRunning: false, itemCount: items.count)
        applyDividerState(showing: nil)
    }

    func stop() {
        standaloneWaitTask?.cancel()
        standaloneWaitTask = nil
        rehideTimer?.invalidate()
        rehideTimer = nil
        eventMonitors.forEach { NSEvent.removeMonitor($0) }
        eventMonitors.removeAll()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        hotkeys.unregisterAll()
        clearAppearance()
        for item in [controlItem, hiddenDivider, hiddenSpacer, alwaysHiddenDivider, alwaysHiddenSpacer].compactMap({ $0 }) {
            NSStatusBar.system.removeStatusItem(item)
        }
        controlItem = nil
        hiddenDivider = nil
        hiddenSpacer = nil
        alwaysHiddenDivider = nil
        alwaysHiddenSpacer = nil
        if case .waitingForAccessibility = state { return }
        state = .stopped
    }

    func updateConfiguration(_ mutate: (inout IceConfiguration) -> Void) {
        var next = configuration
        mutate(&next)
        next.sanitize()
        configuration = next
        IceConfigurationStore.save(next)
        start()
    }

    func refreshItems() {
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]) ?? []
        items = IceItemClassifier.ordered(list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == Int(kCGStatusWindowLevel),
                  let windowID = info[kCGWindowNumber as String] as? NSNumber,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
            let owner = (info[kCGWindowOwnerName as String] as? String) ?? "Unknown"
            let title = (info[kCGWindowName as String] as? String) ?? ""
            guard owner != "Boring Notch" else { return nil }
            let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            let namespace = NSRunningApplication(processIdentifier: pid ?? 0)?.bundleIdentifier ?? owner
            let identity = IceItemIdentity(namespace: namespace, title: title, ownerPID: pid)
            return IceMenuBarItem(identity: identity, windowID: windowID.uint32Value,
                                  displayName: title.isEmpty ? owner : "\(owner) · \(title)",
                                  frameX: Double(bounds["X"] ?? 0),
                                  frameY: Double(bounds["Y"] ?? 0),
                                  frameWidth: Double(bounds["Width"] ?? 0),
                                  frameHeight: Double(bounds["Height"] ?? 0))
        })
    }

    func assign(_ item: IceItemIdentity, to section: IceSection) {
        guard let menuBarItem = items.first(where: { $0.identity == item }) else { return }
        configuration.assignments[item.id] = section
        IceConfigurationStore.save(configuration)

        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else { return }
            guard self.move(menuBarItem, to: section) else {
                self.state = .failed("Could not reposition this menu-bar item. Keep Accessibility enabled, then try again.")
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self.refreshItems()
            self.state = .running(itemCount: self.items.count)
        }
    }

    func show(_ section: IceSection) {
        guard case .waitingForAccessibility = state else {
            guard configuration.enabled else { return }
            sectionState.reveal(section, configuration: configuration)
            guard let shown = sectionState.shown else { return }
            state = .showing(shown)
            applyDividerState(showing: shown)
            scheduleRehide(for: shown)
            return
        }
    }

    func hideSections() {
        rehideTimer?.invalidate()
        rehideTimer = nil
        sectionState.rehide()
        state = .running(itemCount: items.count)
        applyDividerState(showing: nil)
    }

    func showSearch() {
        guard AXIsProcessTrusted() else { state = .waitingForAccessibility; return }
        IceSearchPanel.shared.show(items: items) { [weak self] selected in
            self?.temporarilyReveal(selected)
        }
    }

    func requestAccessibilityFromSettings() {
        XPCHelperClient.shared.requestAccessibilityAuthorization()
    }

    private func temporarilyReveal(_ item: IceMenuBarItem) {
        show(configuration.section(for: item.identity))
    }

    private func installControlItems() {
        guard controlItem == nil else { return }
        let control = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        control.autosaveName = "BoringIceControl"
        control.button?.image = NSImage(systemSymbolName: "snowflake", accessibilityDescription: "Ice menu bar controls")
        control.button?.target = self
        control.button?.action = #selector(toggleHidden)
        control.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        controlItem = control

        // Keep icon and spacer separate. A collapsed spacer is intentionally
        // huge, so using it as a divider makes its icon disappear off-screen.
        let alwaysSpacer = NSStatusBar.system.statusItem(withLength: 0)
        alwaysSpacer.autosaveName = "BoringIceAlwaysHiddenSpacer"
        alwaysHiddenSpacer = alwaysSpacer

        let alwaysDivider = makeDivider(
            autosaveName: "BoringIceAlwaysHiddenDivider",
            description: "Show always hidden menu bar items",
            action: #selector(toggleAlwaysHidden)
        )
        alwaysHiddenDivider = alwaysDivider

        let hiddenSpacer = NSStatusBar.system.statusItem(withLength: 0)
        hiddenSpacer.autosaveName = "BoringIceHiddenSpacer"
        self.hiddenSpacer = hiddenSpacer

        let hiddenDivider = makeDivider(
            autosaveName: "BoringIceHiddenDivider",
            description: "Show hidden menu bar items",
            action: #selector(toggleHidden)
        )
        self.hiddenDivider = hiddenDivider
        updateControlVisibility()
    }

    private func makeDivider(autosaveName: String, description: String, action: Selector) -> NSStatusItem {
        let divider = NSStatusBar.system.statusItem(withLength: 12)
        divider.autosaveName = autosaveName
        divider.button?.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: description)
        divider.button?.imagePosition = .imageOnly
        divider.button?.contentTintColor = .secondaryLabelColor
        divider.button?.toolTip = description
        divider.button?.target = self
        divider.button?.action = action
        divider.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        return divider
    }

    private func updateControlVisibility() {
        controlItem?.length = configuration.showControlItem ? NSStatusItem.variableLength : 0
        applyDividerState(showing: nil)
    }

    /// Expanded spacers push extras beyond available menu-bar width. Fixed dot
    /// controls remain visible beside every section, so people can Command-drag
    /// menu extras to a real, discoverable boundary.
    private func applyDividerState(showing section: IceSection?) {
        let dividerWidth: CGFloat = configuration.showSectionDividers ? 12 : 0
        let hiddenIsShown = section == .hidden || section == .alwaysHidden
        let alwaysIsShown = section == .alwaysHidden
        hiddenDivider?.length = dividerWidth
        hiddenSpacer?.length = hiddenIsShown ? 0 : Self.collapsedDividerLength
        alwaysHiddenDivider?.length = configuration.enableAlwaysHidden ? dividerWidth : 0
        alwaysHiddenSpacer?.length = configuration.enableAlwaysHidden
            ? (alwaysIsShown ? 0 : Self.collapsedDividerLength)
            : 0
    }

    /// macOS exposes status-item ordering through the same Command-drag gesture
    /// users use in the menu bar. We synthesize that public gesture only after
    /// Accessibility has been granted, rather than changing another process or
    /// relying on private menu-bar APIs.
    private func move(_ item: IceMenuBarItem, to section: IceSection) -> Bool {
        guard AXIsProcessTrusted(),
              let source = CGEventSource(stateID: .combinedSessionState) else { return false }

        // Collapsed dividers are intentionally huge, so reveal compact anchors
        // while placing. They return to their configured state immediately after.
        hiddenDivider?.length = 12
        hiddenSpacer?.length = 0
        alwaysHiddenDivider?.length = configuration.enableAlwaysHidden ? 12 : 0
        alwaysHiddenSpacer?.length = 0

        guard let destination = placementPoint(for: section) else {
            applyDividerState(showing: sectionState.shown)
            return false
        }

        let start = CGPoint(
            x: item.frameX + item.frameWidth / 2,
            y: item.frameY + item.frameHeight / 2
        )
        let modifier: CGEventFlags = .maskCommand
        let events: [(CGEventType, CGPoint)] = [
            (.leftMouseDown, start),
            (.leftMouseDragged, destination),
            (.leftMouseUp, destination)
        ]
        for (type, position) in events {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                      mouseCursorPosition: position, mouseButton: .left) else {
                applyDividerState(showing: sectionState.shown)
                return false
            }
            event.flags = modifier
            event.post(tap: .cghidEventTap)
        }
        applyDividerState(showing: sectionState.shown)
        return true
    }

    private func placementPoint(for section: IceSection) -> CGPoint? {
        let divider: NSStatusItem?
        let xOffset: CGFloat
        switch section {
        case .visible:
            divider = hiddenDivider
            xOffset = 4
        case .hidden:
            divider = hiddenDivider
            xOffset = -4
        case .alwaysHidden:
            divider = alwaysHiddenDivider
            xOffset = -4
        }
        guard let frame = divider?.button?.window?.frame else { return nil }
        return quartzPoint(CGPoint(x: frame.midX + xOffset, y: frame.midY))
    }

    private func quartzPoint(_ appKitPoint: CGPoint) -> CGPoint {
        let desktopTop = NSScreen.screens.map(\.frame.maxY).max() ?? appKitPoint.y
        return CGPoint(x: appKitPoint.x, y: desktopTop - appKitPoint.y)
    }

    @objc private func toggleHidden() {
        if case .showing = state { hideSections() } else { show(.hidden) }
    }

    @objc private func toggleAlwaysHidden() {
        if case .showing(.alwaysHidden) = state {
            hideSections()
        } else {
            show(.alwaysHidden)
        }
    }

    private func installEvents() {
        guard eventMonitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.scrollWheel, .leftMouseDown, .leftMouseUp, .mouseMoved]
        let local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleMenuBarEvent(event)
            return event
        }
        if let local { eventMonitors.append(local) }
        let global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor in self?.handleMenuBarEvent(event) }
        }
        if let global { eventMonitors.append(global) }
        let frontmost = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.configuration.rehideStrategy == .focusedApp else { return }
                self.hideSections()
            }
        }
        workspaceObservers.append(frontmost)
    }

    private func handleMenuBarEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown where configuration.showAllSectionsOnDrag
            && event.modifierFlags.contains(.command) && isInMenuBar(event):
            revealAllForDrag()
        case .leftMouseUp where dragRevealActive:
            dragRevealActive = false
            hideSections()
        case .scrollWheel where configuration.showOnScroll && isInMenuBar(event):
            show(.hidden)
        case .leftMouseDown where configuration.showOnClick && isInMenuBar(event):
            show(.hidden)
        case .mouseMoved where configuration.showOnHover && isInMenuBar(event):
            DispatchQueue.main.asyncAfter(deadline: .now() + configuration.hoverDelay) { [weak self] in self?.show(.hidden) }
        default: break
        }
    }

    private func revealAllForDrag() {
        dragRevealActive = true
        rehideTimer?.invalidate()
        hiddenSpacer?.length = 0
        alwaysHiddenSpacer?.length = 0
        hiddenDivider?.length = configuration.showSectionDividers ? 12 : 0
        alwaysHiddenDivider?.length = configuration.enableAlwaysHidden && configuration.showSectionDividers ? 12 : 0
        state = .showing(.hidden)
    }

    private func isInMenuBar(_ event: NSEvent) -> Bool {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(event.locationInWindow) }) ?? NSScreen.main else { return false }
        return event.locationInWindow.y >= screen.frame.maxY - screen.frame.height + screen.visibleFrame.height
    }

    private func scheduleRehide(for section: IceSection) {
        rehideTimer?.invalidate()
        guard sectionState.shouldRehide(configuration: configuration) else { return }
        guard configuration.rehideStrategy == .timed || configuration.rehideStrategy == .smart else { return }
        rehideTimer = Timer.scheduledTimer(withTimeInterval: configuration.rehideInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.hideSections() }
        }
    }

    private func registerHotkeys() {
        hotkeys.unregisterAll()
        for action in IceHotkeyAction.allCases {
            guard let hotkey = configuration.hotkeys[action], hotkey.keyCode != nil else { continue }
            hotkeys.register(hotkey, action: action) { [weak self] action in
                switch action {
                case .toggleHidden: self?.toggleHidden()
                case .toggleAlwaysHidden: self?.show(.alwaysHidden)
                case .search: self?.showSearch()
                }
            }
        }
    }

    private func requestStandaloneIceTermination() -> Bool {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: IceMigration.standaloneDomain)
        guard !running.isEmpty else { return true }
        running.forEach { $0.terminate() }
        state = .waitingForStandaloneIce
        standaloneWaitTask?.cancel()
        standaloneWaitTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            if NSRunningApplication.runningApplications(withBundleIdentifier: IceMigration.standaloneDomain).isEmpty {
                self.start()
            } else {
                self.state = .failed("Standalone Ice still running. Quit it to enable Boring Ice.")
            }
        }
        return false
    }

    private func updateAppearance() {
        clearAppearance()
        guard configuration.appearanceEnabled else { return }
        for screen in NSScreen.screens {
            let height = screen.frame.height - screen.visibleFrame.height
            let panel = NSPanel(contentRect: NSRect(x: screen.frame.minX, y: screen.frame.maxY - height,
                                                     width: screen.frame.width, height: height),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.isOpaque = false
            panel.backgroundColor = (configuration.appearanceDark ? NSColor.black : NSColor.white)
                .withAlphaComponent(CGFloat(configuration.appearanceOpacity))
            panel.ignoresMouseEvents = true
            panel.orderFrontRegardless()
            appearancePanels.append(panel)
        }
    }

    private func clearAppearance() {
        appearancePanels.forEach { $0.orderOut(nil) }
        appearancePanels.removeAll()
    }
}

/// Global monitor uses only Boring-configured combinations. Kept separate so
/// tests can assert registration without touching app state.
@MainActor
final class IceHotkeyRegistry {
    private var monitors: [Any] = []

    func register(_ hotkey: IceHotkey, action: IceHotkeyAction, handler: @escaping (IceHotkeyAction) -> Void) {
        guard let keyCode = hotkey.keyCode else { return }
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == keyCode, UInt(event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue) == hotkey.modifiers else { return }
            Task { @MainActor in handler(action) }
        }
        if let monitor { monitors.append(monitor) }
    }

    func unregisterAll() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }
}

@MainActor
private final class IceSearchPanel: NSPanel, NSSearchFieldDelegate {
    static let shared = IceSearchPanel()
    private let field = NSSearchField(frame: .zero)
    private let results = NSPopUpButton(frame: .zero, pullsDown: false)
    private var allItems: [IceMenuBarItem] = []
    private var select: ((IceMenuBarItem) -> Void)?

    private init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 74),
                   styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        title = "Search Menu Bar"
        isReleasedWhenClosed = false
        let stack = NSStackView(views: [field, results])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        contentView = stack
        field.delegate = self
        results.target = self
        results.action = #selector(choose)
    }

    func show(items: [IceMenuBarItem], select: @escaping (IceMenuBarItem) -> Void) {
        allItems = items
        self.select = select
        field.stringValue = ""
        rebuild()
        center()
        makeKeyAndOrderFront(nil)
        makeFirstResponder(field)
    }

    func controlTextDidChange(_ obj: Notification) { rebuild() }

    private func rebuild() {
        let query = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matched = query.isEmpty ? allItems : allItems.filter { $0.displayName.lowercased().contains(query) }
        results.removeAllItems()
        results.addItems(withTitles: matched.map(\.displayName))
    }

    @objc private func choose() {
        let query = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matched = query.isEmpty ? allItems : allItems.filter { $0.displayName.lowercased().contains(query) }
        guard results.indexOfSelectedItem >= 0, matched.indices.contains(results.indexOfSelectedItem) else { return }
        select?(matched[results.indexOfSelectedItem])
        orderOut(nil)
    }
}
