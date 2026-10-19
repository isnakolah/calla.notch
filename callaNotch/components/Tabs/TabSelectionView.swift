//
//  TabSelectionView.swift
//  callaNotch
//
//  Created by Hugo Persson on 2024-08-25.
//

import Defaults
import SwiftUI

/// One side of the open notch's header, drawn from its three slots.
///
/// This replaces the old hand-rolled tab list plus the run of `if Defaults[...]`
/// buttons on the other side. Both sides are the same view now, so the two
/// halves cannot drift apart in spacing, tint or selection behaviour, and
/// neither can grow past three items.
struct TabSelectionView: View {
    let side: NotchHeaderSide

    @ObservedObject var coordinator = CallaViewCoordinator.shared
    @ObservedObject var callaEngine = CallaEngineClient.shared
    @StateObject var tvm = ShelfStateViewModel.shared
    @EnvironmentObject var vm: CallaViewModel

    @Default(.notchHeaderLeading) private var leading
    @Default(.notchHeaderTrailing) private var trailing
    @Default(.callaShelf) private var callaShelf
    @Default(.pomodoroTab) private var pomodoroTab
    @Default(.usageMonitorTab) private var usageMonitorTab
    @Default(.callaCopilotEnabled) private var callaCopilotEnabled
    @Namespace private var animation

    init(side: NotchHeaderSide) {
        self.side = side
    }

    /// Slots whose feature is on. Reading the `@Default` properties above rather
    /// than `NotchHeaderItem.isEnabled` is what makes the row live-update when a
    /// toggle changes in Settings.
    private var items: [NotchHeaderItem] {
        NotchHeaderLayout.padded(side == .leading ? leading : trailing)
            .filter { isVisible($0) }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.element) { index, item in
                // Settings is a control, not a place: a hairline keeps it from
                // reading as a fifth tab.
                if item == .settings, index > 0 {
                    Rectangle()
                        .fill(Color.white.opacity(0.14))
                        .frame(width: 1, height: 14)
                        .padding(.horizontal, 4)
                        .accessibilityHidden(true)
                }
                view(for: item)
            }
        }
        // Never squeezed: when the open-notch HUD takes the other side, a tab
        // compressing into its neighbour read as the header breaking.
        .fixedSize()
    }

    private func isVisible(_ item: NotchHeaderItem) -> Bool {
        switch item {
        case .none: return false
        case .home, .settings: return true
        case .pomodoro: return pomodoroTab
        case .usage: return usageMonitorTab
        // The shelf tab still hides itself while the shelf is empty unless the
        // reader asked for the tabs to stay put.
        case .shelf: return callaShelf && (!tvm.isEmpty || coordinator.alwaysShowTabs)
        case .copilot: return callaCopilotEnabled
        }
    }

    @ViewBuilder
    private func view(for item: NotchHeaderItem) -> some View {
        switch item {
        case .none:
            EmptyView()
        case .settings:
            circleButton(icon: item.icon, label: item.label) {
                DispatchQueue.main.async {
                    SettingsWindowController.shared.showWindow()
                }
            }
        default:
            if let destination = item.destination {
                tabButton(item, destination: destination)
            }
        }
    }

    private func tabButton(_ item: NotchHeaderItem, destination: NotchViews) -> some View {
        let selected = coordinator.currentView == destination
        let liveBehind = item == .copilot && callaEngine.status.copilot.running && !selected
        return TabButton(
            label: item.label, icon: item.icon, selected: selected,
            accent: item.accent,
            restingInk: liveBehind ? NotchAccent.call : NotchInk.tertiary,
            showsLiveDot: liveBehind
        ) {
            withAnimation(.smooth) {
                coordinator.currentView = destination
            }
        }
        .frame(height: 26)
        .background {
            if selected {
                Capsule()
                    .fill(item.accent.opacity(NotchAccent.fill))
                    .matchedGeometryEffect(id: "capsule", in: animation)
            }
        }
    }

    private func circleButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(NotchInk.tertiary)
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(PlainButtonStyle())
        .help(label)
        .accessibilityLabel(label)
    }
}

#Preview {
    CallaHeader().environmentObject(CallaViewModel())
}
