//
//  SettingsDestinations.swift
//  boringNotch
//

import Sparkle
import SwiftUI

/// What each route actually draws.
///
/// One file, so the answer to "what is behind this row" is in one place rather
/// than spread across a switch in the shell and a second switch in the sidebar.
extension SettingsSection {
    @ViewBuilder var landingPane: some View {
        switch self {
        case .general: GeneralSettings()
        case .notch: NotchSettings()
        case .calls: CopilotPane()
        case .about: AboutPaneHost()
        }
    }
}

extension SettingsPage {
    @ViewBuilder var view: some View {
        switch self {
        case .shortcuts: ShortcutsPane()
        case .privacy: PrivacyPane()
        case .displays: DisplaysPane()
        case .gestures: GesturesPane()
        case .advanced: Advanced()
        case .media: Media()
        case .controlSlots: MusicSlotConfigurationView()
        case .calendar: CalendarSettings()
        case .calendarSources: CalendarSourcesPane()
        case .shelf: Shelf()
        case .localSend: LocalSendPane()
        case .kdeConnect: KDEConnectPane()
        case .pomodoro: PomodoroSettings()
        case .usage: UsageMonitorSettings()
        case .huds: HUD()
        case .headerLayout: NotchLayoutPane()
        case .notchSize: NotchSizePane()
        case .accent: AccentPane()
        case .copilotCall: CopilotCallPane()
        case .copilotQuiz: CopilotQuizPane()
        case .copilotModels: CopilotModelsPane()
        case .copilotPrompts: CopilotPromptsPane()
        case .copilotKnowledge: CopilotKnowledgePane()
        case .copilotBackup: CopilotBackupPane()
        case .copilotHistory: CopilotHistoryPane()
        case let .copilotKnowledgeDetail(route): CopilotKnowledgeDetailPane(route: route)
        case let .copilotCallDetail(id): CopilotCallDetailPane(callID: id)
        }
    }
}

/// About needs a Sparkle updater and the window controller injects one late, so
/// this reads the one the shell put in the environment rather than manufacturing
/// a throwaway controller the way the old switch did.
struct AboutPaneHost: View {
    @Environment(\.sparkleUpdater) private var updater

    var body: some View {
        About(updaterController: updater)
    }
}

private struct SparkleUpdaterKey: EnvironmentKey {
    static let defaultValue = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
}

extension EnvironmentValues {
    var sparkleUpdater: SPUStandardUpdaterController {
        get { self[SparkleUpdaterKey.self] }
        set { self[SparkleUpdaterKey.self] = newValue }
    }
}
