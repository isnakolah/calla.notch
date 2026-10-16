//
//  NotchPane.swift
//  boringNotch
//

import Defaults
import SwiftUI

/// Everything that lives in the notch, as one list of switches.
///
/// Each feature is a row: on or off right here, everything else one click in.
/// What the notch looks like — its header, its size, its colour — sits under
/// the list, and only the colour is folded away.
struct NotchSettings: View {
    @ObservedObject private var coordinator = BoringViewCoordinator.shared
    @Default(.showCalendar) private var showCalendar
    @Default(.boringShelf) private var boringShelf
    @Default(.pomodoroTab) private var pomodoroTab
    @Default(.usageMonitorTab) private var usageMonitorTab
    @Default(.hudReplacement) private var hudReplacement

    var body: some View {
        SettingsPane(.notch) {
            SettingsList("In the notch") {
                SettingsFeatureRow(page: .media, isOn: $coordinator.musicLiveActivityEnabled)
                SettingsFeatureRow(page: .calendar, isOn: $showCalendar)
                SettingsFeatureRow(page: .shelf, isOn: $boringShelf)
                SettingsFeatureRow(page: .pomodoro, isOn: $pomodoroTab)
                SettingsFeatureRow(page: .usage, isOn: $usageMonitorTab)
                // Turning this on needs Accessibility, which the page asks for,
                // so the row reports rather than switches.
                SettingsFeatureRow(page: .huds,
                                   status: hudReplacement ? "On" : "Off",
                                   statusTint: hudReplacement ? NotchTint.healthy : nil)
            }

            SettingsList("Look") {
                SettingsFeatureRow(page: .headerLayout)
                SettingsFeatureRow(page: .notchSize)
            }

            SettingsAdvancedFold("notch") {
                SettingsList {
                    SettingsFeatureRow(page: .accent)
                }
            }
        }
    }
}
