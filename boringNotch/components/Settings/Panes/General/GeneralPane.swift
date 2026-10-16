//
//  GeneralPane.swift
//  boringNotch
//

import Defaults
import LaunchAtLogin
import SwiftUI

/// How the app starts and what opens the notch. Height, hover delay, displays,
/// gestures and window details are folded under Advanced.
struct GeneralSettings: View {
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Environment(\.settingsRouter) private var router

    @Default(.minimumHoverDuration) var minimumHoverDuration
    @Default(.nonNotchHeight) var nonNotchHeight
    @Default(.nonNotchHeightMode) var nonNotchHeightMode
    @Default(.notchHeight) var notchHeight
    @Default(.notchHeightMode) var notchHeightMode
    @Default(.openNotchOnHover) var openNotchOnHover
    @Default(.enableGestures) var enableGestures

    @Default(.menubarIcon) private var menubarIcon
    @Default(.enableHaptics) private var enableHaptics

    @Default(.hideFromScreenRecording) private var hideFromScreenRecording

    var body: some View {
        SettingsPane(.general) {
            SettingsList("Startup") {
                SettingsListRow("Launch at login") {
                    LaunchAtLogin.Toggle("").labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                SettingsListRow("Show menu bar icon") {
                    Toggle("", isOn: $menubarIcon).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }

            SettingsList("Opening") {
                SettingsListRow("Open on hover", detail: "Otherwise, click the notch.") {
                    Toggle("", isOn: $openNotchOnHover).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                SettingsListRow("Remember the last tab") {
                    Toggle("", isOn: $coordinator.openLastTabByDefault)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                SettingsListRow("Haptic feedback") {
                    Toggle("", isOn: $enableHaptics).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }

            SettingsList("Privacy") {
                SettingsListRow("Hide from screen recording",
                                detail: "Keeps the notch, and a live call, out of captures and shared screens.") {
                    Toggle("", isOn: $hideFromScreenRecording)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                SettingsFeatureRow(page: .privacy)
                SettingsFeatureRow(page: .shortcuts)
            }

            SettingsAdvancedFold("general") {
                SettingCard("Notch height") {
                    VStack(spacing: NotchSpace.row) {
                        SettingRow("On displays with a notch") {
                            Picker("", selection: $notchHeightMode) {
                                Text("Match the real notch").tag(WindowHeightMode.matchRealNotchSize)
                                Text("Match the menu bar").tag(WindowHeightMode.matchMenuBar)
                                Text("Custom").tag(WindowHeightMode.custom)
                            }
                            .labelsHidden().frame(width: 200)
                        }
                        if notchHeightMode == .custom {
                            heightSlider(value: $notchHeight, range: 15...45)
                        }
                        SettingRow("On displays without one") {
                            Picker("", selection: $nonNotchHeightMode) {
                                Text("Match the menu bar").tag(WindowHeightMode.matchMenuBar)
                                Text("Match a real notch").tag(WindowHeightMode.matchRealNotchSize)
                                Text("Custom").tag(WindowHeightMode.custom)
                            }
                            .labelsHidden().frame(width: 200)
                        }
                        if nonNotchHeightMode == .custom {
                            heightSlider(value: $nonNotchHeight, range: 0...40)
                        }
                    }
                }
                if openNotchOnHover {
                    SettingCard {
                        NotchSlider(value: $minimumHoverDuration,
                                    range: 0...1,
                                    step: 0.1,
                                    label: "Hover delay",
                                    format: { $0 < 0.05 ? "Instant" : String(format: "%.1f s", $0) },
                                    ends: ("Instant", "1 s"))
                    }
                }
                SettingsList {
                    SettingsFeatureRow(page: .displays)
                    SettingsFeatureRow(page: .gestures)
                    SettingsFeatureRow(page: .advanced)
                }
            }
        }
        .toolbar {
            Button("Quit app") { NSApp.terminate(self) }
        }
        .onChange(of: notchHeightMode) {
            switch notchHeightMode {
            case .matchRealNotchSize: notchHeight = 38
            case .matchMenuBar: notchHeight = 44
            case .custom: notchHeight = 38
            }
            NotificationCenter.default.post(name: Notification.Name.notchHeightChanged, object: nil)
        }
        .onChange(of: nonNotchHeightMode) {
            switch nonNotchHeightMode {
            case .matchMenuBar: nonNotchHeight = 24
            case .matchRealNotchSize: nonNotchHeight = 32
            case .custom: nonNotchHeight = 32
            }
            NotificationCenter.default.post(name: Notification.Name.notchHeightChanged, object: nil)
        }
        .onChange(of: notchHeight) {
            NotificationCenter.default.post(name: Notification.Name.notchHeightChanged, object: nil)
        }
        .onChange(of: nonNotchHeight) {
            NotificationCenter.default.post(name: Notification.Name.notchHeightChanged, object: nil)
        }
        .onChange(of: minimumHoverDuration) {
            NotificationCenter.default.post(name: Notification.Name.notchHeightChanged, object: nil)
        }
        .onChange(of: openNotchOnHover) {
            if !openNotchOnHover { enableGestures = true }
        }
    }

    /// The notch's own height, which is the one number in this window that
    /// changes the thing in the sidebar while you drag it — so the value belongs
    /// on the thumb rather than in a column to its right.
    private func heightSlider(value: Binding<CGFloat>, range: ClosedRange<CGFloat>) -> some View {
        NotchSlider(value: Binding(get: { Double(value.wrappedValue) },
                                   set: { value.wrappedValue = CGFloat($0) }),
                    range: Double(range.lowerBound)...Double(range.upperBound),
                    step: 1,
                    label: "Custom height",
                    format: { "\(Int($0)) pt" },
                    ends: ("\(Int(range.lowerBound)) pt", "\(Int(range.upperBound)) pt"))
    }
}
