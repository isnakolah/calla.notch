//
//  BoringNotchSkyLightWindow.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-20.
//

import Cocoa
import SkyLightWindow
import Defaults
import Combine
import UniformTypeIdentifiers

extension SkyLightOperator {
    func undelegateWindow(_ window: NSWindow) {
        typealias F_SLSRemoveWindowsFromSpaces = @convention(c) (Int32, CFArray, CFArray) -> Int32
        
        let handler = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW)
        guard let SLSRemoveWindowsFromSpaces = unsafeBitCast(
            dlsym(handler, "SLSRemoveWindowsFromSpaces"),
            to: F_SLSRemoveWindowsFromSpaces?.self
        ) else {
            return
        }
        
        // Remove the window from the SkyLight space
        _ = SLSRemoveWindowsFromSpaces(
            connection,
            [window.windowNumber] as CFArray,
            [space] as CFArray
        )
    }
}

class BoringNotchSkyLightWindow: NSPanel {
    private var isSkyLightEnabled: Bool = false
    
    override init(
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask,
        backing: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: backing,
            defer: flag
        )
        
        configureWindow()
        setupObservers()
        startTrackingPointer()
    }

    deinit {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        buttonPollTimer?.invalidate()
        editorPointerPollTimer?.invalidate()
        if let editorKeyMonitor { NSEvent.removeMonitor(editorKeyMonitor) }
    }
    
    private func configureWindow() {
        isFloatingPanel = true
        isOpaque = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .clear
        isMovable = false
        level = .mainMenu + 3
        hasShadow = false
        isReleasedWhenClosed = false
        
        // Force dark appearance regardless of system setting
        appearance = NSAppearance(named: .darkAqua)
        
        collectionBehavior = [
            .fullScreenAuxiliary,
            .stationary,
            .canJoinAllSpaces,
            .ignoresCycle,
        ]
        
        // Apply initial sharing type setting
        updateSharingType()
    }
    
    private func setupObservers() {
        // Listen for changes to the hideFromScreenRecording setting
        Defaults.publisher(.hideFromScreenRecording)
            .sink { [weak self] _ in
                self?.updateSharingType()
            }
            .store(in: &observers)

        // Global mouse monitors may be unavailable without Accessibility
        // permission. Resize editor must still recover from click-through as
        // pointer enters its detached controls, so poll pointer only while
        // editor exists. This uses public mouse location and needs no grant.
        NotchResizeSession.shared.$isEditing
            .removeDuplicates()
            .sink { [weak self] editing in
                if editing {
                    self?.startEditorPointerPolling()
                } else {
                    self?.stopEditorPointerPolling()
                }
            }
            .store(in: &observers)
    }

    // MARK: - Click-through

    /// One painted island of the panel, tracked by the view that draws it.
    ///
    /// Rects are read from the view at the moment they are needed rather than
    /// pushed in when SwiftUI lays out. A pushed rect goes stale the instant an
    /// animation moves the view without re-running its body — which is exactly
    /// what a profile switch does to the editor bar — and a stale rect means the
    /// panel stops taking clicks over the one control that could end the
    /// session. That was unrecoverable: no click landed, so nothing re-rendered,
    /// so the rect never corrected itself.
    private final class InteractiveIsland {
        weak var view: NSView?
        var padding: CGFloat
        /// Highest wins when islands overlap. The grip sits on top of the notch.
        var priority: Int
        var cursor: NSCursor?

        init(view: NSView, padding: CGFloat, priority: Int, cursor: NSCursor?) {
            self.view = view
            self.padding = padding
            self.priority = priority
            self.cursor = cursor
        }

        func rect(in window: NSWindow) -> CGRect? {
            guard let view, view.window === window, view.superview != nil,
                  !view.isHiddenOrHasHiddenAncestor else { return nil }
            let rect = view.convert(view.bounds, to: nil)
            guard !rect.isEmpty else { return nil }
            return rect.insetBy(dx: -padding, dy: -padding)
        }
    }

    private var interactiveIslands: [String: InteractiveIsland] = [:]

    private var mouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var editorKeyMonitor: Any?

    /// Runs only while a mouse button is held, and only to watch for a drag.
    ///
    /// A drag is tracked inside the *source* app's own drag loop, so the events
    /// a global monitor sees during one are not something to rely on. Polling
    /// the pressed buttons and the drag pasteboard is; it stops on mouse-up, so
    /// an idle Mac pays nothing for it.
    private var buttonPollTimer: Timer?
    private var editorPointerPollTimer: Timer?

    private let dragPasteboard = NSPasteboard(name: .drag)
    private var dragPasteboardChangeCount = -1

    /// A drag carrying something droppable is in flight somewhere on screen.
    ///
    /// Click-through is suspended for its whole duration. Proximity is not
    /// enough here: AppKit decides which windows are drag destinations as the
    /// session runs, and a panel that was ignoring mouse events when the drag
    /// reached it is simply not one — the notch never sees the drag, so it
    /// never opens. The window has to be droppable *before* the pointer
    /// arrives, which means before we know where the pointer is headed.
    private var dragSessionActive = false {
        didSet {
            guard dragSessionActive != oldValue else { return }
            applyClickThrough()
        }
    }

    /// How far outside an island still counts as a hit.
    ///
    /// The flag is flipped from a mouse-moved monitor, so it is always at least
    /// one event behind the pointer. The ring absorbs that lag: a click landing
    /// inside it hits the panel and is handled normally, where the same click a
    /// frame earlier would have fallen through to the desktop.
    private let hitSlack: CGFloat = 12

    /// Hands every click outside the notch to whatever is underneath.
    ///
    /// The panel is built once at `windowSize` and never resized — the notch is
    /// only ever a fraction of it, and the rest is transparent. But the window
    /// server does not hit-test by pixel: every click inside those points lands
    /// on this window, and a transparent SwiftUI region drops it rather than
    /// forwarding it. That is the dead strip under the notch. Without this the
    /// strip is as tall as the tallest mode the panel can ever open to, whether
    /// or not it is open.
    func registerInteractiveView(
        _ view: NSView,
        id: String,
        padding: CGFloat,
        priority: Int,
        cursor: NSCursor?
    ) {
        if let existing = interactiveIslands[id], existing.view === view {
            existing.padding = padding
            existing.priority = priority
            existing.cursor = cursor
        } else {
            interactiveIslands[id] = InteractiveIsland(
                view: view, padding: padding, priority: priority, cursor: cursor
            )
        }
        applyClickThrough()
    }

    func unregisterInteractiveView(id: String, view: NSView) {
        guard let island = interactiveIslands[id], island.view === view || island.view == nil else {
            return
        }
        interactiveIslands.removeValue(forKey: id)
        applyClickThrough()
    }

    private func startTrackingPointer() {
        guard mouseMonitor == nil else { return }
        let events: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged,
            .leftMouseDown, .leftMouseUp,
        ]

        // Global monitors omit events delivered to this process. Pair one with
        // local monitor so grip press and release cannot fall between them.
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            MainActor.assumeIsolated {
                self?.observePointer(event)
            }
            return event
        }
        // A *global* monitor, because once the window ignores mouse events it
        // stops receiving the very move that would hand them back.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
            MainActor.assumeIsolated {
                self?.observePointer(event)
            }
        }
        applyClickThrough()
    }

    private func observePointer(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            // Recorded before any drag begins: the pasteboard advancing past
            // this is what tells us one did.
            dragPasteboardChangeCount = dragPasteboard.changeCount
            startButtonPolling()
        } else if event.type == .leftMouseUp,
                  NotchResizeSession.shared.isDragging {
            // SwiftUI normally ends gesture. This closes session drag state if
            // mouse-up arrived after pointer crossed a moving window boundary.
            NotchResizeSession.shared.endDrag()
        }
        updateDragSession()
        applyClickThrough()
    }

    private func startButtonPolling() {
        guard buttonPollTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateDragSession()
                self.applyClickThrough()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        buttonPollTimer = timer
    }

    private func stopButtonPolling() {
        buttonPollTimer?.invalidate()
        buttonPollTimer = nil
    }

    private func startEditorPointerPolling() {
        guard editorPointerPollTimer == nil else { return }
        // AppKit resets the cursor on every move over a view that claims one.
        // The editor owns the pointer for the length of the session, so it takes
        // the cursor off AppKit rather than fighting it every frame.
        disableCursorRects()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyClickThrough()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        editorPointerPollTimer = timer
        startEditorKeyMonitor()
        applyClickThrough()
    }

    private func stopEditorPointerPolling() {
        editorPointerPollTimer?.invalidate()
        editorPointerPollTimer = nil
        stopEditorKeyMonitor()
        enableCursorRects()
        releaseManagedCursor()
        NotchResizeSession.shared.hoveredControl = nil
        applyClickThrough()
    }

    /// The way out that does not depend on a click landing.
    ///
    /// The panel cannot take key focus during a resize, so the Done button's
    /// `.defaultAction` shortcut never fires. Escape and Return end the session
    /// from wherever the keyboard is, and the arrow keys resize by hand when the
    /// corner is somewhere awkward.
    private func startEditorKeyMonitor() {
        guard editorKeyMonitor == nil else { return }
        editorKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = event.keyCode
            let coarse = event.modifierFlags.contains(.shift)
            let handled = MainActor.assumeIsolated { () -> Bool in
                let session = NotchResizeSession.shared
                guard session.isEditing else { return false }
                // Never take a key out of a field. Settings has a search box and
                // several text inputs, and the resize session does not own them.
                if NSApp.keyWindow?.firstResponder is NSText { return false }
                let step: CGFloat = coarse ? 16 : 4
                switch keyCode {
                case 53, 36, 76:
                    session.finish()
                case 123: session.nudge(width: -step, height: 0)
                case 124: session.nudge(width: step, height: 0)
                case 125: session.nudge(width: 0, height: step)
                case 126: session.nudge(width: 0, height: -step)
                default: return false
                }
                return true
            }
            return handled ? nil : event
        }
    }

    private func stopEditorKeyMonitor() {
        if let editorKeyMonitor { NSEvent.removeMonitor(editorKeyMonitor) }
        editorKeyMonitor = nil
    }

    private func updateDragSession() {
        guard NSEvent.pressedMouseButtons != 0 else {
            if NotchResizeSession.shared.isDragging {
                NotchResizeSession.shared.endDrag()
            }
            dragSessionActive = false
            dragPasteboardChangeCount = -1
            stopButtonPolling()
            return
        }
        guard !dragSessionActive,
              dragPasteboard.changeCount != dragPasteboardChangeCount,
              hasDroppableDragContent else { return }
        dragSessionActive = true
    }

    /// Only content the notch has somewhere to put counts. A window drag or a
    /// text selection should still fall straight through.
    private var hasDroppableDragContent: Bool {
        let droppable: [NSPasteboard.PasteboardType] = [
            .fileURL,
            NSPasteboard.PasteboardType(UTType.url.identifier),
            .string
        ]
        return dragPasteboard.types?.contains(where: droppable.contains) ?? false
    }

    /// The cursor this window is currently asserting, if any.
    private var managedCursor: NSCursor?

    private func applyClickThrough() {
        let editing = NotchResizeSession.shared.isEditing

        // Once SwiftUI has accepted grip drag, never turn mouse handling off
        // underneath that same pointer. Layout can trail live geometry by a
        // frame; toggling here used to cancel some drags.
        if NotchResizeSession.shared.isDragging {
            ignoresMouseEvents = false
            assertCursor(interactiveIslands["resize-grip"]?.cursor)
            return
        }
        guard !dragSessionActive else {
            ignoresMouseEvents = false
            return
        }

        var hitID: String?
        var hitCursor: NSCursor?
        var hitPriority = Int.min
        var hasIsland = false
        let local = convertPoint(fromScreen: NSEvent.mouseLocation)

        for (id, island) in interactiveIslands {
            guard let rect = island.rect(in: self) else { continue }
            hasIsland = true
            guard rect.insetBy(dx: -hitSlack, dy: -hitSlack).contains(local) else { continue }
            guard island.priority > hitPriority else { continue }
            hitPriority = island.priority
            hitID = id
            hitCursor = island.cursor
        }

        // Nothing has reported itself yet. Taking every click is the old
        // behaviour, and the safe way to be wrong.
        guard hasIsland else {
            ignoresMouseEvents = false
            return
        }

        ignoresMouseEvents = hitID == nil

        guard editing else {
            releaseManagedCursor()
            return
        }
        if NotchResizeSession.shared.hoveredControl != hitID {
            NotchResizeSession.shared.hoveredControl = hitID
        }
        assertCursor(hitCursor)
    }

    /// Re-set every tick while a non-default cursor is wanted. One `set()` does
    /// not survive the pointer crossing another view, and the pointer crosses
    /// the notch's own subviews constantly while the editor is open.
    private func assertCursor(_ cursor: NSCursor?) {
        guard let cursor else {
            releaseManagedCursor()
            return
        }
        managedCursor = cursor
        cursor.set()
    }

    private func releaseManagedCursor() {
        guard managedCursor != nil else { return }
        managedCursor = nil
        NSCursor.arrow.set()
    }

    private func updateSharingType() {
        // One switch decides this, including during a live call. Hiding the
        // panel from captures is exactly what someone on a call wants, but it
        // also hides it from the user's own recordings and screenshots, so it
        // stays theirs to set rather than being forced on for the call.
        if Defaults[.hideFromScreenRecording] {
            sharingType = .none
        } else {
            sharingType = .readWrite
        }
    }
    
    func enableSkyLight() {
        if !isSkyLightEnabled {
            SkyLightOperator.shared.delegateWindow(self)
            isSkyLightEnabled = true
        }
    }
    
    func disableSkyLight() {
        if isSkyLightEnabled {
            SkyLightOperator.shared.undelegateWindow(self)
            isSkyLightEnabled = false
        }
    }
    
    private var observers: Set<AnyCancellable> = []
    
    /// Text fields in the notch (the Pomodoro session title) need the panel to
    /// take key focus, but only while it is open — a closed notch stealing key
    /// would pull the caret out of whatever the user is typing in.
    nonisolated(unsafe) static var acceptsKeyFocus = false

    override var canBecomeKey: Bool { Self.acceptsKeyFocus }
    override var canBecomeMain: Bool { false }
}
