//
//  HomePane.swift
//  callaNotch
//

import Defaults
import SwiftUI

/// What is in the notch right now, and anything that needs the reader.
///
/// The first page, so it answers the two questions people open Settings with:
/// is something broken, and is the thing I want switched on. A blocker leads
/// with the one button that fixes it; every feature is a tile with its switch,
/// so turning one on never needs its page.
struct HomePane: View {
    @ObservedObject private var coordinator = CallaViewCoordinator.shared
    @ObservedObject private var attention = SettingsAttention.shared
    @ObservedObject private var engine = CallaEngineClient.shared
    @Environment(\.settingsRouter) private var router

    @Default(.showCalendar) private var showCalendar
    @Default(.callaShelf) private var callaShelf
    @Default(.pomodoroTab) private var pomodoroTab
    @Default(.usageMonitorTab) private var usageMonitorTab
    @Default(.callaCopilotEnabled) private var copilotEnabled
    @Default(.enableSneakPeek) private var enableSneakPeek

    var body: some View {
        SettingsPane(.home) {
            NotchStage(caption: stageCaption) {
                NotchSlab(width: 290, height: 32) {
                    NotchMusicActivity(tint: Color(red: 1.0, green: 0.54, blue: 0.36),
                                       showsArtwork: coordinator.musicLiveActivityEnabled)
                }
            }
            .accessibilityLabel(Text("Preview of the notch as it is now"))

            ForEach(attention.blockers.prefix(2)) { blocker in
                blockerCard(blocker)
            }

            VStack(alignment: .leading, spacing: 8) {
                SettingsCaption(title: "In the notch")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                          spacing: 10) {
                    tile(.music, isOn: $coordinator.musicLiveActivityEnabled,
                         status: enableSneakPeek ? "Live activity and sneak peek on" : "Live activity on")
                    tile(.calendar, isOn: $showCalendar, status: "Next event beside the music")
                    tile(.shelf, isOn: $callaShelf, status: "Drop files on the notch")
                    tile(.focus, isOn: $pomodoroTab, status: "Focus blocks and breaks")
                    tile(.usage, isOn: $usageMonitorTab, status: "Claude and Codex allowance")
                    tile(.copilot, isOn: $copilotEnabled, status: copilotStatus)
                }
            }
        }
        .task { await attention.refresh() }
    }

    private var stageCaption: String {
        coordinator.musicLiveActivityEnabled
            ? "Closed notch · Music playing · hover to open"
            : "Closed notch · hover to open"
    }

    private var copilotStatus: String {
        let copilot = engine.status.copilot
        if !copilot.available { return "Not installed" }
        if copilot.isRecording { return "In a call" }
        if attention.blockers.contains(where: { $0.kind == .hostScreen }) { return "Ready · your microphone only" }
        return "Ready to listen"
    }

    // MARK: - Pieces

    private func blockerCard(_ blocker: SettingsBlocker) -> some View {
        HStack(spacing: 14) {
            SettingsIconTile(symbol: "exclamationmark.triangle.fill",
                             color: Color(red: 0.72, green: 0.43, blue: 0.0))
            VStack(alignment: .leading, spacing: 2) {
                Text(blocker.title).font(.system(size: 13, weight: .semibold))
                Text(blocker.detail)
                    .font(NotchType.rowDetail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let fix = blocker.fix {
                Button(blocker.fixTitle) { router?.go(fix) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .settingsCardSurface(tint: NotchTint.attention)
    }

    private func tile(_ section: SettingsSection, isOn: Binding<Bool>, status: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                SettingsIconTile(symbol: section.filledSymbol, color: section.tint)
                Button { router?.select(section) } label: {
                    Text(section.title)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open \(String(localized: section.title))")
                SettingsSwitch("\(String(localized: section.title)) in the notch", isOn: isOn.animation())
                    .controlSize(.small)
            }
            Text(isOn.wrappedValue ? status : "Off")
                .font(NotchType.rowDetail)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsCardSurface()
    }
}
