//
//  IcePane.swift
//  boringNotch
//
//  Boring settings UI for owned Ice runtime. GPL-3.0-or-later; see Ice/NOTICE.md.
//

import AppKit
import SwiftUI

struct IcePane: View {
    @ObservedObject private var ice = IceMenuBarController.shared
    @Environment(\.settingsRouter) private var router

    var body: some View {
        SettingsPane(.ice) {
            SettingCard(tint: statusTint) {
                VStack(spacing: 12) {
                    SettingRow("Enable Ice",
                               detail: "Organizes menu bar extras. It waits for Accessibility access before controlling anything.") {
                        Toggle("", isOn: boolBinding(\.enabled)).labelsHidden().toggleStyle(.switch).controlSize(.large)
                    }
                    HStack(spacing: 8) {
                        SettingStatusIcon(ok: isRunning, failedTint: NotchTint.attention)
                        Text(ice.state.summary).font(NotchType.rowDetail).foregroundStyle(.secondary)
                        Spacer()
                        if !isAccessibilityGranted {
                            Button("Request Accessibility") { ice.requestAccessibilityFromSettings() }.controlSize(.small)
                        } else {
                            Button("Refresh") { ice.start() }.controlSize(.small)
                        }
                    }
                }
            }
            menuPreview
            if let router {
                SettingsTileGrid(columns: 5) {
                    tile(.iceGeneral, router)
                    tile(.iceLayout, router)
                    tile(.iceAppearance, router)
                    tile(.iceHotkeys, router)
                    tile(.iceAdvanced, router)
                }
            }
        }
        .task { ice.start() }
    }

    private var isAccessibilityGranted: Bool {
        if case .waitingForAccessibility = ice.state { return false }
        return true
    }

    private var isRunning: Bool {
        switch ice.state {
        case .running, .showing: true
        default: false
        }
    }

    private var statusTint: Color? { isRunning ? NotchTint.active : NotchTint.attention }

    private var menuPreview: some View {
        SettingCard("Menu bar preview", detail: "Ice control items stay separate from Boring's menu-bar extra.") {
            VStack(spacing: 8) {
                HStack(spacing: max(3, 7 + ice.configuration.spacingOffset)) {
                    Text("●").foregroundStyle(.white.opacity(0.5))
                    Text("⌁").foregroundStyle(.white.opacity(0.8))
                    if ice.configuration.showControlItem { Image(systemName: "snowflake").foregroundStyle(NotchTint.active) }
                    Text("Boring").foregroundStyle(.white.opacity(0.85))
                    Spacer()
                }
                .padding(12)
                .background(Color.black, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                SettingFact(title: "Discovered extras", value: "\(ice.items.count)")
            }
        }
    }

    private func tile(_ page: SettingsPage, _ router: SettingsRouter) -> some View {
        SettingsTile(symbol: page.symbol, title: String(localized: page.title), value: String(localized: page.detail ?? "")) {
            router.push(page)
        }
    }

    private func boolBinding(_ keyPath: WritableKeyPath<IceConfiguration, Bool>) -> Binding<Bool> {
        Binding(get: { ice.configuration[keyPath: keyPath] }, set: { value in ice.updateConfiguration { $0[keyPath: keyPath] = value } })
    }
}

struct IceGeneralPane: View {
    @ObservedObject private var ice = IceMenuBarController.shared

    var body: some View {
        SettingsPane(.iceGeneral) {
            SettingCard("Reveal") {
                VStack(spacing: 12) {
                    row("Show control item", "Snowflake status item that reveals hidden extras.", \.showControlItem)
                    row("Reveal on click", "Click empty menu bar space.", \.showOnClick)
                    row("Reveal on hover", "Hover empty menu bar space.", \.showOnHover)
                    row("Reveal on scroll", "Scroll over menu bar.", \.showOnScroll)
                    if ice.configuration.showOnHover {
                        SettingRow("Hover delay") { Slider(value: doubleBinding(\.hoverDelay), in: 0...1, step: 0.05).frame(width: 180) }
                    }
                }
            }
            SettingCard("Rehide") {
                VStack(spacing: 12) {
                    row("Automatically rehide", "Return transient items after reveal.", \.autoRehide)
                    SettingRow("Strategy") {
                        Picker("", selection: rehideStrategy) {
                            ForEach(IceRehideStrategy.allCases) { Text($0.rawValue).tag($0) }
                        }.labelsHidden().frame(width: 160)
                    }
                    if ice.configuration.autoRehide && ice.configuration.rehideStrategy == .timed {
                        SettingRow("Delay") { Slider(value: doubleBinding(\.rehideInterval), in: 1...60, step: 1).frame(width: 180) }
                    }
                }
            }
        }
    }

    private var rehideStrategy: Binding<IceRehideStrategy> {
        Binding(get: { ice.configuration.rehideStrategy }, set: { value in ice.updateConfiguration { $0.rehideStrategy = value } })
    }
    private func row(_ title: String, _ detail: String, _ key: WritableKeyPath<IceConfiguration, Bool>) -> some View {
        SettingRow(title, detail: detail) { Toggle("", isOn: boolBinding(key)).labelsHidden().toggleStyle(.switch) }
    }
    private func boolBinding(_ key: WritableKeyPath<IceConfiguration, Bool>) -> Binding<Bool> {
        Binding(get: { ice.configuration[keyPath: key] }, set: { value in ice.updateConfiguration { $0[keyPath: key] = value } })
    }
    private func doubleBinding(_ key: WritableKeyPath<IceConfiguration, Double>) -> Binding<Double> {
        Binding(get: { ice.configuration[keyPath: key] }, set: { value in ice.updateConfiguration { $0[keyPath: key] = value } })
    }
}

struct IceLayoutPane: View {
    @ObservedObject private var ice = IceMenuBarController.shared

    var body: some View {
        SettingsPane(.iceLayout) {
            SettingCard("Discovered menu bar extras", detail: "Choose section, or hold Command and drag an extra beside visible dot controls in menu bar. System-only extras remain visible when macOS prevents movement.") {
                if ice.items.isEmpty {
                    ContentUnavailableView("No extras found", systemImage: "menubar.rectangle", description: Text("Grant Accessibility, then refresh."))
                } else {
                    ForEach(ice.items) { item in
                        SettingRow(item.displayName) {
                            Picker("", selection: sectionBinding(item.identity)) {
                                ForEach(IceSection.allCases) { Text($0.title).tag($0) }
                            }.labelsHidden().frame(width: 150)
                        }
                    }
                }
            }
            SettingCard("Layout behavior") {
                VStack(spacing: 12) {
                    SettingRow("Section divider dots", detail: "Visible dots mark hidden and always-hidden section boundaries.") {
                        Toggle("", isOn: boolBinding(\.showSectionDividers)).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow("Show while dragging", detail: "Reveal sections while macOS rearranges an extra.") {
                        Toggle("", isOn: boolBinding(\.showAllSectionsOnDrag)).labelsHidden().toggleStyle(.switch)
                    }
                }
            }
        }
        .task { ice.refreshItems() }
    }

    private func sectionBinding(_ item: IceItemIdentity) -> Binding<IceSection> {
        Binding(get: { ice.configuration.section(for: item) }, set: { ice.assign(item, to: $0) })
    }
    private func boolBinding(_ key: WritableKeyPath<IceConfiguration, Bool>) -> Binding<Bool> {
        Binding(get: { ice.configuration[keyPath: key] }, set: { value in ice.updateConfiguration { $0[keyPath: key] = value } })
    }
}

struct IceAppearancePane: View {
    @ObservedObject private var ice = IceMenuBarController.shared

    var body: some View {
        SettingsPane(.iceAppearance) {
            SettingCard("Menu bar overlay", detail: "Boring-owned overlay. No screen capture used.") {
                VStack(spacing: 12) {
                    SettingRow("Enable overlay") { Toggle("", isOn: boolBinding(\.appearanceEnabled)).labelsHidden().toggleStyle(.switch) }
                    SettingRow("Appearance") {
                        Picker("", selection: boolBinding(\.appearanceDark)) {
                            Text("Dark").tag(true); Text("Light").tag(false)
                        }.labelsHidden().pickerStyle(.segmented).frame(width: 160)
                    }
                    SettingRow("Opacity") { Slider(value: doubleBinding(\.appearanceOpacity), in: 0...1, step: 0.05).frame(width: 180) }
                }
            }
        }
    }
    private func boolBinding(_ key: WritableKeyPath<IceConfiguration, Bool>) -> Binding<Bool> {
        Binding(get: { ice.configuration[keyPath: key] }, set: { value in ice.updateConfiguration { $0[keyPath: key] = value } })
    }
    private func doubleBinding(_ key: WritableKeyPath<IceConfiguration, Double>) -> Binding<Double> {
        Binding(get: { ice.configuration[keyPath: key] }, set: { value in ice.updateConfiguration { $0[keyPath: key] = value } })
    }
}

struct IceHotkeysPane: View {
    @ObservedObject private var ice = IceMenuBarController.shared
    @State private var recording: IceHotkeyAction?
    @State private var monitor: Any?

    var body: some View {
        SettingsPane(.iceHotkeys) {
            SettingCard("Global hotkeys", detail: "Press Clear, then use current action from Ice control item or reveal gesture. Recorded keys never replace Boring shortcuts.") {
                ForEach(IceHotkeyAction.allCases) { action in
                    SettingRow(action.title, detail: recording == action ? "Press key combination…" : hotkeyLabel(action)) {
                        HStack(spacing: 8) {
                            Button(recording == action ? "Recording…" : "Record") { beginRecording(action) }.controlSize(.small)
                            Button("Clear") { ice.updateConfiguration { $0.hotkeys[action] = IceHotkey.none } }.controlSize(.small)
                        }
                    }
                }
            }
        }
        .onDisappear { stopRecording() }
    }

    private func hotkeyLabel(_ action: IceHotkeyAction) -> String {
        guard let key = ice.configuration.hotkeys[action]?.keyCode else { return "Not set" }
        return "Key code \(key)"
    }

    private func beginRecording(_ action: IceHotkeyAction) {
        stopRecording()
        recording = action
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let independent = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard !independent.isEmpty else { return event }
            ice.updateConfiguration {
                $0.hotkeys[action] = IceHotkey(keyCode: event.keyCode, modifiers: UInt(independent.rawValue))
            }
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
    }
}

struct IceAdvancedPane: View {
    @ObservedObject private var ice = IceMenuBarController.shared

    var body: some View {
        SettingsPane(.iceAdvanced) {
            SettingCard("Always hidden") {
                VStack(spacing: 12) {
                    SettingRow("Enable always-hidden section", detail: "Items stay hidden until directly revealed.") {
                        Toggle("", isOn: boolBinding(\.enableAlwaysHidden)).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow("Option toggle", detail: "Allow Option-modified control gesture.") {
                        Toggle("", isOn: boolBinding(\.canToggleAlwaysHidden)).labelsHidden().toggleStyle(.switch)
                            .disabled(!ice.configuration.enableAlwaysHidden)
                    }
                }
            }
            SettingCard("Spacing & recovery") {
                VStack(spacing: 12) {
                    SettingRow("Extra spacing") { Slider(value: doubleBinding(\.spacingOffset), in: -8...16, step: 1).frame(width: 180) }
                    SettingRow("Hide application menus", detail: "Reserve room while revealing extras when macOS allows it.") {
                        Toggle("", isOn: boolBinding(\.hideApplicationMenus)).labelsHidden().toggleStyle(.switch)
                    }
                    Button("Reset Ice layout") { ice.updateConfiguration { $0.assignments = [:]; $0.spacingOffset = 0 } }
                        .controlSize(.small)
                }
            }
        }
    }
    private func boolBinding(_ key: WritableKeyPath<IceConfiguration, Bool>) -> Binding<Bool> {
        Binding(get: { ice.configuration[keyPath: key] }, set: { value in ice.updateConfiguration { $0[keyPath: key] = value } })
    }
    private func doubleBinding(_ key: WritableKeyPath<IceConfiguration, Double>) -> Binding<Double> {
        Binding(get: { ice.configuration[keyPath: key] }, set: { value in ice.updateConfiguration { $0[keyPath: key] = value } })
    }
}
