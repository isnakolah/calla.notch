//
//  UsageNotchBadge.swift
//  callaNotch
//
//  Always-on CLI usage badges shown beside the physical notch (Claude on the
//  left, Codex on the right). Each badge shows only quotas reported by its CLI,
//  with each number colored by its own QuotaDisplayStatus threshold.
//  Fed by UsageMonitorManager; polls while visible.
//

import Defaults
import SwiftUI

/// Lays out both provider badges around the physical notch gap and owns the
/// refresh polling while the closed notch is showing them.
struct UsageNotchBadges: View {
    let notchWidth: CGFloat
    let height: CGFloat
    /// Called when a side badge is hovered — opens the notch to the usage tab.
    /// Only the badges trigger this; hovering the center notch keeps normal flow.
    var onBadgeHover: (() -> Void)? = nil

    @ObservedObject private var manager = UsageMonitorManager.shared
    @Default(.usageMonitorRefreshInterval) private var refreshInterval
    @Default(.usageShowClaude) private var showClaude
    @Default(.usageShowCodex) private var showCodex
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 0) {
            // Only the CLIs being read. Showing a permanently empty badge for a
            // tool you do not use is worse than showing nothing.
            if showClaude {
                UsageNotchBadge(provider: "CLAUDE", state: manager.claude,
                                alignment: .trailing)
                    .frame(width: 55, alignment: .trailing)
                    .padding(.trailing, 10)
                    .onHover { if $0 { onBadgeHover?() } }
            }

            Rectangle()
                .fill(.black)
                .frame(width: notchWidth)

            if showCodex {
                UsageNotchBadge(provider: "CODEX", state: manager.codex, alignment: .leading)
                    .frame(width: 55, alignment: .leading)
                    .padding(.leading, 10)
                    .onHover { if $0 { onBadgeHover?() } }
            }
        }
        // Clearance at the outer ends, so the numbers do not touch the edge of
        // the black behind them.
        .padding(.horizontal, 10)
        // Size to content so the black notch background hugs the badges (extends
        // only to where the usage numbers reach) instead of ballooning to the
        // 512pt window cap. Mirrors the sneak-peek closed content's .fixedSize().
        .fixedSize()
        .frame(height: height, alignment: .center)
        .background(alignment: .top) {
            // The notch's own black, extended under the badges.
            //
            // The panel's slab is pinned to the physical notch width when
            // closed — it has to be, or its rounded shape balloons into the menu
            // bar either side of the real cutout — so anything drawn *beside*
            // the notch has nothing behind it and the numbers sit straight on
            // the wallpaper. This is the ground that went missing with that
            // pinning: square where it meets the notch, rounded where it ends,
            // so the badges read as the notch reaching out rather than as text
            // floating in the menu bar.
            UnevenRoundedRectangle(
                bottomLeadingRadius: 10,
                bottomTrailingRadius: 10,
                style: .continuous
            )
            .fill(.black)
            .frame(height: height)
        }
        .onAppear {
            manager.refreshIfStale()
            startPolling()
        }
        .onDisappear {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(max(30, refreshInterval)))
                if Task.isCancelled { break }
                await MainActor.run { manager.refreshIfStale() }
            }
        }
    }
}

/// A single provider badge: a small label over its available quota values.
struct UsageNotchBadge: View {
    let provider: String
    let state: ProviderUsageState
    let alignment: HorizontalAlignment

    var body: some View {
        VStack(alignment: alignment, spacing: 0) {
            Text(provider)
                .font(NotchGlassType.badgeLabel)
                .foregroundStyle(QuotaDisplayStatus.worstColor(session, weekly) ?? NotchInk.tertiary)
                .tracking(0.4)

            HStack(spacing: 1) {
                ForEach(Array(availablePercents.enumerated()), id: \.offset) { index, percent in
                    number(for: percent)
                    if index < availablePercents.count - 1 {
                        Text("|")
                            .foregroundStyle(NotchInk.tertiary)
                    }
                }

                if availablePercents.isEmpty {
                    Text("—")
                        .foregroundStyle(NotchInk.tertiary)
                }
            }
            .font(NotchGlassType.badgeFigure)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityReadout)
    }

    private var accessibilityReadout: String {
        guard !availablePercents.isEmpty else { return "\(provider) usage unavailable" }
        let parts = availablePercents.map { "\(Int($0.rounded())) percent" }
        return "\(provider), \(parts.joined(separator: ", ")) remaining"
    }

    // MARK: - Data

    private var session: Double? { state.report?.effectiveSession?.percentRemaining }
    private var weekly: Double? { state.report?.weekly?.percentRemaining }
    private var availablePercents: [Double] {
        if state.report?.weeklyExhausted == true { return [0] }
        return [session, weekly].compactMap { $0 }
    }

    private func number(for percent: Double) -> some View {
        // Keep a full quota from advertising literal 100 in the compact menubar
        // surface. The expanded usage tab still shows the exact value.
        Text("\(min(99, Int(percent.rounded())))")
            .foregroundStyle(QuotaDisplayStatus.from(percentRemaining: percent).color)
    }
}
