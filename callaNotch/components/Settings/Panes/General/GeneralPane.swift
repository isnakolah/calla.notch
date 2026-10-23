//
//  GeneralPane.swift
//  callaNotch
//

import Defaults
import LaunchAtLogin
import SwiftUI

/// How the app starts, how the notch opens, and where it lives. Displays,
/// gestures, window behaviour and shortcuts used to be pages behind this one;
/// they are groups on it now.
struct GeneralSettings: View {
    @ObservedObject var coordinator = CallaViewCoordinator.shared

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
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: SettingsMetrics.groupGap) {
                    SettingsList("Startup") {
                        SettingsListRow("Launch at login") {
                            LaunchAtLogin.Toggle("").labelsHidden().toggleStyle(.switch)
                                .accessibilityLabel(Text("Launch at login"))
                        }
                        SettingsToggleRow("Show menu bar icon", isOn: $menubarIcon)
                    }
                    .settingsAnchor("general.startup")

                    SettingsList("Privacy") {
                        SettingsToggleRow("Hide from screen recording",
                                          detail: "Keeps the notch out of captures and shared screens. A call is always hidden.",
                                          isOn: $hideFromScreenRecording)
                    }
                    .settingsAnchor("general.privacy")
                }
                .frame(maxWidth: .infinity, alignment: .top)

                SettingsList("Opening") {
                    SettingsToggleRow("Open on hover", detail: "Otherwise, click the notch.", isOn: $openNotchOnHover)
                    if openNotchOnHover {
                        NotchSlider(value: $minimumHoverDuration,
                                    range: 0...1,
                                    step: 0.1,
                                    label: "Hover delay",
                                    format: { $0 < 0.05 ? "Instant" : String(format: "%.1f s", $0) },
                                    ends: ("Instant", "1 s"))
                            .padding(.vertical, 10)
                    }
                    SettingsToggleRow("Remember the last tab", isOn: $coordinator.openLastTabByDefault)
                    SettingsToggleRow("Haptic feedback", isOn: $enableHaptics)
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .settingsAnchor("general.opening")
            }

            SettingsEmbedded(.displays) { DisplaysPane() }
            SettingsEmbedded(.gestures) { GesturesPane() }
            SettingsEmbedded(.advanced) { Advanced() }
            SettingsEmbedded(.shortcuts) { ShortcutsPane() }

            SettingsAdvancedFold("general", title: "Notch height") {
                SettingsList {
                    SettingsListRow("On displays with a notch") {
                        Picker("", selection: $notchHeightMode) {
                            Text("Match the real notch").tag(WindowHeightMode.matchRealNotchSize)
                            Text("Match the menu bar").tag(WindowHeightMode.matchMenuBar)
                            Text("Custom").tag(WindowHeightMode.custom)
                        }
                        .labelsHidden().fixedSize()
                    }
                    if notchHeightMode == .custom {
                        heightSlider(value: $notchHeight, range: 15...45).padding(.vertical, 10)
                    }
                    SettingsListRow("On displays without one") {
                        Picker("", selection: $nonNotchHeightMode) {
                            Text("Match the menu bar").tag(WindowHeightMode.matchMenuBar)
                            Text("Match a real notch").tag(WindowHeightMode.matchRealNotchSize)
                            Text("Custom").tag(WindowHeightMode.custom)
                        }
                        .labelsHidden().fixedSize()
                    }
                    if nonNotchHeightMode == .custom {
                        heightSlider(value: $nonNotchHeight, range: 0...40).padding(.vertical, 10)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Quit calla.notch") { NSApp.terminate(nil) }
            }
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
