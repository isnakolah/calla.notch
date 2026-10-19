#!/usr/bin/env python3
"""Exercise the production native menu without recording or starting a call.

Contracts and theme dependencies are fixtures; menu construction/actions and
the rendered selector are extracted unchanged from the application source.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'callaNotch/components/Calla/CallaWindowTargetMenu.swift').read_text()
source = source.split("/// Code's catalog", 1)[0].replace('import CallaContracts\n', '')
fixture = r'''
struct QuizWindowTarget: Equatable {
    var id: String
    var applicationName: String
    var windowTitle: String
    var processID: Int32
    var windowID: UInt32
}
enum NotchGlassType {
    static let glyph = Font.system(size: 11, weight: .medium)
    static let chipLabel = Font.system(size: 11, weight: .medium)
    static let chevron = Font.system(size: 8, weight: .bold)
}
enum NotchGlassSpace { static let control: CGFloat = 30 }
enum NotchInk { static let primary = Color.white; static let secondary = Color.white.opacity(0.65) }
enum NotchTint { static let attention = Color.orange }
extension Color { static let effectiveAccent = Color.green }
struct NotchChipBackground: View {
    var hovering: Bool
    var tint: Color
    var body: some View { RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.08)) }
}
@main struct Probe {
    @MainActor static func main() {
        _ = NSApplication.shared
        let first = QuizWindowTarget(id: "11:1", applicationName: "Code", windowTitle: "Spreadsheet — Monday", processID: 11, windowID: 1)
        let second = QuizWindowTarget(id: "11:2", applicationName: "Code", windowTitle: "Another project", processID: 11, windowID: 2)
        var selected: [QuizWindowTarget?] = []
        var refreshes = 0
        let value = WindowMenuAnchor(target: first, windows: [first, second], allowsSavedFilesOnly: true,
            emptyMessage: "No windows", error: nil, clickRequest: 0, openRequest: 0,
            refresh: { refreshes += 1 }, select: { selected.append($0) })
        let coordinator = WindowMenuAnchor.Coordinator(value)
        let menu = coordinator.makeMenu()
        let windowItems = menu.items.filter { $0.representedObject is QuizWindowTarget }
        precondition(windowItems.count == 2)
        precondition(windowItems[0].state == .on && windowItems[1].state == .off)
        precondition(windowItems[0].title == "Code — Spreadsheet — Monday")
        precondition(selected.isEmpty, "Opening or cancelling must never choose a window")
        menu.performActionForItem(at: menu.index(of: windowItems[1]))
        precondition(selected.count == 1 && selected[0] == second, "Apply exact target directly")
        menu.performActionForItem(at: 0)
        precondition(selected.count == 2 && selected[1] == nil, "Saved files only detaches")
        menu.performActionForItem(at: menu.items.count - 1)
        precondition(refreshes == 1 && selected.count == 2, "Refresh is not selection")
        coordinator.value.windows = [second]
        let stale = coordinator.makeMenu()
        precondition(stale.items.contains { !$0.isEnabled && $0.title.hasPrefix("Unavailable:") })
        precondition(!stale.items.contains { $0.state == .on }, "Do not substitute a different window")
        coordinator.value.target = nil
        coordinator.value.windows = []
        coordinator.value.allowsSavedFilesOnly = false
        let quiz = coordinator.makeMenu()
        precondition(quiz.items.first?.title == "No windows" && quiz.items.first?.isEnabled == false)
        precondition(!quiz.items.contains { $0.title == "Saved files only" })
        precondition(selected.count == 2)

        let view = VStack(alignment: .leading, spacing: 18) {
            CallaWindowTargetMenu(target: nil, windows: [], shortcut: "⇧⌥⌘W", help: "Choose", refresh: {}, select: { _ in })
            CallaWindowTargetMenu(target: first, windows: [first], shortcut: "⇧⌥⌘W", help: "Choose", refresh: {}, select: { _ in })
            CallaWindowTargetMenu(target: first, windows: [first], compact: true, shortcut: "⇧⌥⌘W", help: "Choose", refresh: {}, select: { _ in })
        }.padding(24).frame(width: 350, height: 185, alignment: .leading).background(Color.black)
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 350, height: 185)
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/coding-window-menu-component.png"))
        print("PASS: direct exact selection, checkmarks, detach, refresh, stale/empty catalogs; component rendered")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='window-menu-probe-') as scratch:
    swift = Path(scratch) / 'probe.swift'
    swift.write_text(source + fixture)
    binary = Path(scratch) / 'probe'
    subprocess.run(['swiftc', '-parse-as-library', str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
