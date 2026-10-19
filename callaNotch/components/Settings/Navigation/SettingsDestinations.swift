//
//  SettingsDestinations.swift
//  callaNotch
//

import Sparkle
import SwiftUI

/// What each sidebar row draws, in one place.
extension SettingsSection {
    @ViewBuilder var page: some View {
        switch self {
        case .home: HomePane()
        case .appearance: AppearancePane()
        case .music: Media()
        case .calendar: CalendarSettings()
        case .shelf: Shelf()
        case .focus: PomodoroSettings()
        case .usage: UsageMonitorSettings()
        case .copilot: CopilotPane()
        case .models: CopilotModelsPane()
        case .persona: CopilotPromptsPane()
        case .knowledge: CopilotKnowledgePane()
        case .history: CopilotHistoryPane()
        case .quiz: CopilotQuizPane()
        case .general: GeneralSettings()
        case .permissions: PermissionsPane()
        case .about: AboutPaneHost()
        }
    }
}

extension SettingsPage {
    /// The only records that are pushed over their page.
    @ViewBuilder var view: some View {
        switch self {
        case let .copilotKnowledgeDetail(route): CopilotKnowledgeDetailPane(route: route)
        default: section.page
        }
    }
}

/// About needs a Sparkle updater and the window controller injects one late, so
/// this reads the one the shell put in the environment.
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
