//
//  AdvancedPane.swift
//  boringNotch
//

import Defaults
import SwiftUI

/// The settings that change how the window sits against the rest of the system.
///
/// Accent colour used to lead this pane. It moved to Appearance, where the thing
/// it colours is configured.
struct Advanced: View {
    @Default(.extendHoverArea) var extendHoverArea
    @Default(.showOnLockScreen) var showOnLockScreen

    @Default(.enableShadow) private var enableShadow
    @Default(.cornerRadiusScaling) private var cornerRadiusScaling
    @Default(.hideTitleBar) private var hideTitleBar

    var body: some View {
        SettingsPane(SettingsPage.advanced) {
            SettingCard("Shape") {
                VStack(spacing: 12) {
                    SettingRow("Window shadow") {
                        Toggle("", isOn: $enableShadow).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow("Scale corner radius",
                               detail: "Rounds the notch's corners in proportion to its height.") {
                        Toggle("", isOn: $cornerRadiusScaling).labelsHidden().toggleStyle(.switch)
                    }
                }
            }

            SettingCard("Behaviour") {
                VStack(spacing: 12) {
                    SettingRow("Extend hover area",
                               detail: "Makes the notch easier to hit without aiming for it.") {
                        Toggle("", isOn: $extendHoverArea).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow("Hide title bar") {
                        Toggle("", isOn: $hideTitleBar).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow("Show on the lock screen") {
                        Toggle("", isOn: $showOnLockScreen).labelsHidden().toggleStyle(.switch)
                    }
                }
            }
        }
    }
}
