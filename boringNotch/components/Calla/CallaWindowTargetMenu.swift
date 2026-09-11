import AppKit
import CallaContracts
import SwiftUI

/// The same direct window menu on the Quiz and Code control rails. A native
/// anchor lets the global Code shortcut open precisely the menu used by clicks.
struct CallaWindowTargetMenu: View {
    var target: QuizWindowTarget?
    var windows: [QuizWindowTarget]
    var allowsSavedFilesOnly = false
    var compact = false
    var shortcut: String? = nil
    var openRequest = 0
    var error: String? = nil
    var emptyMessage = "No capturable windows"
    var help: String
    var refresh: () -> Void
    var select: (QuizWindowTarget?) -> Void
    @State private var clickRequest = 0

    var body: some View {
        Button { clickRequest += 1 } label: {
            HStack(spacing: compact ? 3 : 6) {
                if let target, let icon = NSRunningApplication(processIdentifier: target.processID)?.icon {
                    Image(nsImage: icon).resizable().frame(width: compact ? 12 : 14, height: compact ? 12 : 14)
                } else {
                    Image(systemName: "macwindow").font(NotchGlassType.glyph)
                }
                VStack(spacing: 0) {
                    Text(compact ? "Window" : target?.applicationName ?? "Choose window")
                        .font(compact ? .system(size: 9, weight: .medium) : NotchGlassType.chipLabel)
                        .lineLimit(1).truncationMode(.middle)
                    if compact, let shortcut {
                        Text(shortcut).font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(NotchInk.secondary)
                    }
                }
                if !compact, let shortcut {
                    Text(shortcut).font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(NotchInk.secondary)
                }
                Image(systemName: error == nil ? "chevron.down" : "exclamationmark.circle")
                    .font(NotchGlassType.chevron)
                    .foregroundStyle(error == nil ? NotchInk.primary : NotchTint.attention)
            }
            .foregroundStyle(NotchInk.primary)
            .padding(.horizontal, compact ? 3 : 11)
            .frame(height: compact ? 22 : NotchGlassSpace.control)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .background {
            if !compact { NotchChipBackground(hovering: false, tint: .effectiveAccent) }
        }
        .background(WindowMenuAnchor(target: target, windows: windows,
            allowsSavedFilesOnly: allowsSavedFilesOnly, emptyMessage: emptyMessage,
            error: error, clickRequest: clickRequest, openRequest: openRequest,
            refresh: refresh, select: select).allowsHitTesting(false))
        .help(error ?? target.map { "\($0.applicationName) — \($0.windowTitle)" } ?? help)
        .accessibilityLabel("Choose window" + (shortcut.map { ", \($0)" } ?? ""))
        .accessibilityValue(target.map { "\($0.applicationName) — \($0.windowTitle)" } ?? "Saved files only")
    }
}

private struct WindowMenuAnchor: NSViewRepresentable {
    var target: QuizWindowTarget?
    var windows: [QuizWindowTarget]
    var allowsSavedFilesOnly: Bool
    var emptyMessage: String
    var error: String?
    var clickRequest: Int
    var openRequest: Int
    var refresh: () -> Void
    var select: (QuizWindowTarget?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.setAccessibilityElement(false)
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        let requested = clickRequest != coordinator.value.clickRequest || openRequest != coordinator.value.openRequest
        coordinator.value = self
        guard requested else { return }
        DispatchQueue.main.async { [weak view, weak coordinator] in
            guard let view, view.window?.isVisible == true, let coordinator else { return }
            coordinator.present(in: view)
        }
    }

    @MainActor final class Coordinator: NSObject {
        var value: WindowMenuAnchor
        private var presenting = false
        init(_ value: WindowMenuAnchor) { self.value = value }

        func present(in view: NSView) {
            guard !presenting else { return }
            presenting = true
            defer { presenting = false }
            value.refresh()
            let menu = makeMenu()
            NSApp.activate(ignoringOtherApps: true)
            view.window?.makeKey()
            // AppKit handles arrows, type-to-select, Enter and Escape. Selection
            // is immediate; dismissing the menu never changes the target.
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: view)
        }

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            if let error = value.error { addDisabled(error, to: menu); menu.addItem(.separator()) }
            if value.allowsSavedFilesOnly {
                let item = NSMenuItem(title: "Saved files only", action: #selector(choose(_:)), keyEquivalent: "")
                item.target = self
                item.state = value.target == nil ? .on : .off
                menu.addItem(item)
                menu.addItem(.separator())
            }
            if let target = value.target, !value.windows.contains(where: { $0.id == target.id }) {
                addDisabled("Unavailable: \(target.applicationName) — \(target.windowTitle)", to: menu)
            }
            if value.windows.isEmpty { addDisabled(value.emptyMessage, to: menu) }
            for window in value.windows {
                let title = window.windowTitle.isEmpty ? "Window \(window.windowID)" : window.windowTitle
                let item = NSMenuItem(title: "\(window.applicationName) — \(title)", action: #selector(choose(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = window
                item.state = value.target?.id == window.id ? .on : .off
                if let icon = NSRunningApplication(processIdentifier: window.processID)?.icon?.copy() as? NSImage {
                    icon.size = NSSize(width: 16, height: 16)
                    item.image = icon
                }
                menu.addItem(item)
            }
            menu.addItem(.separator())
            let refresh = NSMenuItem(title: "Refresh windows", action: #selector(refreshWindows), keyEquivalent: "")
            refresh.target = self
            menu.addItem(refresh)
            return menu
        }

        private func addDisabled(_ title: String, to menu: NSMenu) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        @objc private func choose(_ item: NSMenuItem) { value.select(item.representedObject as? QuizWindowTarget) }
        @objc private func refreshWindows() { value.refresh() }
    }
}

/// Code's catalog is editor-only; selection itself remains explicit, including
/// when a window disappears or a refresh completes after a newer refresh.
struct CodingWindowTargetMenu: View {
    var target: QuizWindowTarget?
    var compact = false
    var shortcut: String
    var openRequest: Int
    var error: String? = nil
    var select: (QuizWindowTarget?) -> Void
    @State private var windows: [QuizWindowTarget] = []
    @State private var refreshGeneration = 0

    var body: some View {
        CallaWindowTargetMenu(target: target, windows: windows, allowsSavedFilesOnly: true,
            compact: compact, shortcut: shortcut, openRequest: openRequest, error: error,
            emptyMessage: "No VS Code windows found. Open your project, then refresh.",
            help: "Choose the VS Code window Live Coding reads", refresh: refresh, select: select)
        .task { refresh() }
    }
    private func refresh() {
        refreshGeneration += 1
        let generation = refreshGeneration
        CallaEngineClient.shared.listQuizWindows { values in
            guard generation == refreshGeneration else { return }
            windows = values.filter { ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"].contains($0.bundleID) }
        }
    }
}
