//
//  UsageMonitorView.swift
//  callaNotch
//
//  Notch tab showing Claude + Codex CLI usage (session + weekly), fed by the
//  non-sandboxed XPC helper via UsageMonitorManager. Fits whatever width the
//  notch is sized to (the Normal profile, 512pt and up) without resizing it.
//

import AppKit
import Defaults
import SwiftUI

// MARK: - Root

struct UsageMonitorView: View {
    @ObservedObject private var manager = UsageMonitorManager.shared
    @Default(.usageMonitorRefreshInterval) private var refreshInterval

    @State private var page = 0
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if page == 0 { providerPage } else { agyPage }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 25).onEnded { value in
                if value.translation.width < -40 { page = 1 }
                if value.translation.width > 40 { page = 0 }
            })
            pageSwitcher
        }
        .padding(.horizontal, 6)
        .padding(.top, 2)
        // Take the width the notch gives, never the width the content asks for.
        .frame(maxWidth: .infinity)
        .clipped()
        .onAppear { manager.loadProfiles(); manager.refreshIfStale(); startPolling() }
        .onDisappear { pollTask?.cancel(); pollTask = nil }
    }

    /// Labeled pills instead of a bare "1 / 2" so it's obvious which page is
    /// which (and that AGY lives on the second one).
    private var pageSwitcher: some View {
        HStack(spacing: 2) {
            pagePill("Claude · Codex", index: 0)
            pagePill("AGY", index: 1)
        }
        .padding(.horizontal, 2)
        .frame(height: 24)
        .background(Capsule().fill(Color.white.opacity(0.08)))
    }

    private func pagePill(_ title: String, index: Int) -> some View {
        let selected = page == index
        return Button { withAnimation(.easeInOut(duration: 0.15)) { page = index } } label: {
            Text(title)
                .font(.system(size: 11, weight: selected ? .bold : .semibold))
                .foregroundStyle(selected ? NotchInk.primary : Color.white.opacity(0.75))
                .padding(.horizontal, 12)
                .frame(height: 20)
                .background(Capsule().fill(selected ? Color.white.opacity(0.16) : .clear))
                .frame(height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) usage")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var providerPage: some View {
        HStack(spacing: 0) {
            ProviderUsageColumn(provider: .claude, state: manager.claude,
                profileID: manager.selectedProfile(for: "claude") ?? "personal",
                profiles: manager.profiles(for: "claude"),
                onSelect: { manager.selectProfile($0, for: "claude") },
                onRefresh: { manager.refreshProvider("claude") })
                .frame(maxWidth: .infinity)
            divider
            ProviderUsageColumn(provider: .codex, state: manager.codex,
                profileID: manager.selectedProfile(for: "codex") ?? "work",
                profiles: manager.profiles(for: "codex"),
                onSelect: { manager.selectProfile($0, for: "codex") },
                onRefresh: { manager.refreshProvider("codex") })
                .frame(maxWidth: .infinity)
        }
        .modifier(UsagePageChrome())
    }

    private var agyPage: some View {
        HStack(spacing: 0) {
            AGYGroupColumn(title: "Gemini models", group: manager.agy.report?.gemini,
                           state: manager.agy, onRefresh: { manager.refreshProvider("agy") })
                .frame(maxWidth: .infinity)
            divider
            AGYGroupColumn(title: "Claude/GPT models", group: manager.agy.report?.claudeGPT,
                           state: manager.agy, onRefresh: { manager.refreshProvider("agy") })
                .frame(maxWidth: .infinity)
        }
        .modifier(UsagePageChrome())
    }

    private var divider: some View {
        Rectangle().fill(NotchInk.hairline)
            .frame(width: 1).padding(.vertical, 4)
    }

    /// Re-polls only while the tab is visible. Cache lives in the manager; the
    /// helper is stateless/on-demand.
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

private struct UsagePageChrome: ViewModifier {
    func body(content: Content) -> some View {
        // Straight on the notch, like every other tab: the notch is the card.
        content.padding(.vertical, 2)
    }
}

private struct AGYGroupColumn: View {
    let title: String
    let group: UsageReportDTO.QuotaGroup?
    let state: ProviderUsageState
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(NotchAccent.quiz)
                    .frame(width: 20, height: 20)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(NotchAccent.quiz.opacity(NotchAccent.strongFill)))
                NotchCaps(title, tint: QuotaDisplayStatus.worstColor(
                    group?.session?.percentRemaining, group?.weekly?.percentRemaining) ?? NotchInk.secondary)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                CallaHeaderGlyphButton(symbol: "arrow.clockwise", help: "Refresh AGY usage", action: onRefresh)
            }
            .frame(height: 26)
            if let report = state.report, report.status == .ok {
                HStack(spacing: 10) {
                    // Weekly at zero blocks the 5-hour bucket too, so it is the only number that matters.
                    if let weekly = group?.weekly, weekly.percentRemaining <= 0 {
                        UsageQuotaTile(quota: weekly, isWeekly: true)
                    } else {
                        UsageQuotaTile(quota: group?.session, isWeekly: false)
                        UsageQuotaTile(quota: group?.weekly, isWeekly: true)
                    }
                }
            } else {
                MessageView(icon: "exclamationmark.triangle",
                            text: state.report?.errorDescription ?? "Checking AGY usage…")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
    }
}

// MARK: - Provider brand

/// Brand identity for the two supported CLIs — drives the header icon badge.
private enum UsageProvider {
    case claude
    case codex

    var name: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }

    /// Candidate desktop-app bundle IDs, tried in order for the real app icon.
    var appBundleIDs: [String] {
        switch self {
        case .claude: ["com.anthropic.claudefordesktop", "com.anthropic.claude"]
        case .codex: ["com.openai.chat", "com.openai.codex", "com.openai.ChatGPT"]
        }
    }

    /// Rounded-square tint behind the fallback glyph.
    var badgeBackground: Color {
        switch self {
        case .claude: NotchAccent.home.opacity(NotchAccent.strongFill)
        case .codex: NotchAccent.call.opacity(NotchAccent.strongFill)
        }
    }

    var glyphColor: Color {
        switch self {
        case .claude: NotchAccent.home
        case .codex: NotchAccent.call
        }
    }

    /// The real desktop-app icon, if that app is installed.
    var appIcon: NSImage? {
        let ws = NSWorkspace.shared
        for id in appBundleIDs {
            if let url = ws.urlForApplication(withBundleIdentifier: id) {
                return ws.icon(forFile: url.path)
            }
        }
        return nil
    }
}

/// Rounded-square brand badge sitting left of the provider name. Prefers the
/// installed desktop app's real icon; falls back to a drawn glyph.
private struct ProviderIconBadge: View {
    let provider: UsageProvider

    var body: some View {
        if let icon = provider.appIcon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 20, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(provider.badgeBackground)
                .frame(width: 20, height: 20)
                .overlay(glyph)
        }
    }

    @ViewBuilder
    private var glyph: some View {
        switch provider {
        case .claude:
            Image(systemName: "asterisk")
                .font(NotchGlassType.glyph)
                .foregroundStyle(provider.glyphColor)
        case .codex:
            Text(">_")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(provider.glyphColor)
        }
    }
}

// MARK: - Provider Column

private struct ProviderUsageColumn: View {
    let provider: UsageProvider
    let state: ProviderUsageState
    let profileID: String
    let profiles: [UsageProfileOption]
    let onSelect: (String) -> Void
    var onRefresh: (() -> Void)? = nil

    private var providerName: String { provider.name }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header.frame(height: 26)
            content
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
    }

    /// Two of these sit side by side in whatever width the notch was given,
    /// and at the default 512pt that is ~220pt each. Every piece here used to
    /// be `fixedSize`, so the pair needed ~480pt, could not shrink, and the
    /// page ran past the notch's edges. Now the less useful pieces go first:
    /// the capture age, then the provider name (the badge still says which).
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            headerRow(showsName: true, showsAge: true)
            headerRow(showsName: true, showsAge: false)
            headerRow(showsName: false, showsAge: false)
        }
    }

    private func headerRow(showsName: Bool, showsAge: Bool) -> some View {
        HStack(spacing: 7) {
            ProviderIconBadge(provider: provider)
                .help(providerName)

            if showsName {
                NotchCaps(providerName, tint: QuotaDisplayStatus.worstColor(
                    state.report?.effectiveSession?.percentRemaining,
                    state.report?.weekly?.percentRemaining) ?? NotchInk.secondary)
                    .fixedSize()
            }

            if state.isSyncing {
                ProgressView()
                    .controlSize(.mini)
            }

            Spacer(minLength: 0)

            Menu {
                if profiles.isEmpty {
                    Text("No Tangit profiles found")
                }
                ForEach(profiles) { option in
                    Button { onSelect(option.id) } label: {
                        if option.id == profileID {
                            Label("\(option.id)\(option.identity.map { " · " + $0 } ?? "")", systemImage: "checkmark")
                        } else {
                            Text("\(option.id)\(option.identity.map { " · " + $0 } ?? "")")
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(profileID)
                        .font(NotchGlassType.caption.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 72)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .foregroundStyle(Color.white.opacity(0.86))
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Capsule().fill(Color.white.opacity(0.08)))
                .contentShape(Capsule())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("\(providerName) profile: \(profileID)")

            if showsAge, let report = state.report {
                Text(capturedAgo(report.capturedAt))
                    .font(NotchGlassType.caption)
                    .foregroundStyle(NotchInk.tertiary)
                    .lineLimit(1)
                    .fixedSize()
            }

            if let onRefresh {
                CallaHeaderGlyphButton(symbol: "arrow.clockwise", help: "Refresh \(providerName) usage", action: onRefresh)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let report = state.report {
            switch report.status {
            case .ok:
                quotaTiles(for: report)
            case .cliNotInstalled:
                MessageView(icon: "wrench.and.screwdriver",
                            text: "\(providerName.lowercased()) CLI not found")
            case .notLoggedIn:
                MessageView(icon: "person.crop.circle.badge.exclamationmark",
                            text: "Signed out · run tangit login \(profileID) \(providerName.lowercased())")
            case .error:
                MessageView(icon: "exclamationmark.triangle",
                            text: report.errorDescription ?? "Unavailable")
            }
        } else {
            // First load — no cached report yet.
            MessageView(icon: nil, text: "Checking usage…", showSpinner: true)
        }
    }

    @ViewBuilder
    private func quotaTiles(for report: UsageReportDTO) -> some View {
        let quotas = availableQuotas(for: report)

        if quotas.isEmpty {
            UsageQuotaTile(quota: nil, isWeekly: false)
        } else {
            HStack(spacing: 10) {
                ForEach(quotas) { quota in
                    UsageQuotaTile(
                        quota: quota.value,
                        isWeekly: quota.isWeekly
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func availableQuotas(for report: UsageReportDTO) -> [AvailableQuota] {
        if report.weeklyExhausted, let weekly = report.weekly {
            return [AvailableQuota(value: weekly, isWeekly: true)]
        }
        return [
            report.effectiveSession.map { AvailableQuota(value: $0, isWeekly: false) },
            report.weekly.map { AvailableQuota(value: $0, isWeekly: true) }
        ]
        .compactMap { $0 }
    }

    private func capturedAgo(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        return "\(hours)h"
    }
}

private struct AvailableQuota: Identifiable {
    let value: UsageReportDTO.Quota
    let isWeekly: Bool

    var id: String { isWeekly ? "weekly" : "session" }
}

// MARK: - Quota Tile

/// A ring per quota, the way Focus draws its countdown: what is left as the
/// arc and the figure inside it, the window and when it comes back beside it.
private struct UsageQuotaTile: View {
    let quota: UsageReportDTO.Quota?
    let isWeekly: Bool

    var body: some View {
        HStack(spacing: 7) {
            ring
            VStack(alignment: .leading, spacing: 2) {
                NotchCaps(isWeekly ? "Week" : "5 hours")
                if let quota { resetLabel(quota) }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 50)
        .accessibilityElement(children: .combine)
    }

    private var ring: some View {
        let percent = quota?.percentRemaining
        let tint = percent.map { QuotaDisplayStatus.from(percentRemaining: $0).color } ?? NotchInk.tertiary
        return ZStack {
            Circle().stroke(NotchInk.hairline, lineWidth: 4)
            if let percent {
                Circle()
                    .trim(from: 0, to: max(0.001, min(1, percent / 100)))
                    .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Text(percent.map { "\(Int($0.rounded()))" } ?? "—")
                .font(.system(size: 14, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(percent == nil ? NotchInk.tertiary : tint)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 6)
        }
        .frame(width: 44, height: 44)
        .accessibilityLabel(percent.map { "\(Int($0.rounded())) percent left" } ?? "No data")
    }

    @ViewBuilder
    private func resetLabel(_ quota: UsageReportDTO.Quota) -> some View {
        if let resetsAt = quota.resetsAt {
            // Just the clock time (session) or date+time (weekly) it comes back —
            // no "Resets in" wording. Refreshed each minute.
            TimelineView(.periodic(from: .now, by: 60)) { _ in
                Text(Self.resetString(for: resetsAt, isWeekly: isWeekly))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(NotchInk.secondary)
                    .lineLimit(1)
            }
        } else if let resetText = quota.resetText {
            // Fallback string (e.g. Codex TTY path) — strip the "Resets in/…" prefix.
            Text(Self.stripResetPrefix(resetText))
                .font(.system(size: 11))
                .foregroundStyle(NotchInk.secondary)
                .lineLimit(1)
        } else {
            EmptyView()
        }
    }

    /// Session → time of day ("03:59"); weekly → day + time, using a relative
    /// day word for today/tomorrow ("Today at 16:59", "Tmrw at 16:59") and
    /// the date otherwise ("Jul 18 at 16:59").
    private static func resetString(for date: Date, isWeekly: Bool) -> String {
        let time = timeFormatter.string(from: date)
        guard isWeekly else { return time }

        let cal = Calendar.current
        let day: String
        if cal.isDateInToday(date) {
            day = "Today"
        } else if cal.isDateInTomorrow(date) {
            day = "Tmrw"
        } else {
            day = dateFormatter.string(from: date)
        }
        return "\(day) \(time)"
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static func stripResetPrefix(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"^\s*resets?(\s+in)?\s*"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }
}

// MARK: - Message / Status helpers

private struct MessageView: View {
    let icon: String?
    let text: String
    var showSpinner: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            if showSpinner {
                ProgressView().controlSize(.small)
            } else if let icon {
                Image(systemName: icon)
                    .font(NotchGlassType.glyph)
                    .foregroundStyle(NotchInk.tertiary)
            }
            Text(text)
                .font(NotchGlassType.detail)
                .foregroundStyle(NotchInk.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 50, alignment: .center)
    }
}

/// Threshold-based display status for a quota's remaining percentage.
enum QuotaDisplayStatus {
    case healthy    // > 50
    case warning    // 20...50
    case critical   // 0 < x < 20
    case depleted   // <= 0

    static func from(percentRemaining: Double) -> QuotaDisplayStatus {
        // The low mark is the reader's, not a guess baked in here. Warning
        // starts at twice it, so the ramp keeps its shape wherever they put it.
        let low = Defaults[.usageLowThreshold]
        return switch percentRemaining {
        case let x where x > low * 2.5: .healthy
        case let x where x >= low: .warning
        case let x where x > 0: .critical
        default: .depleted
        }
    }

    /// Color of the worst (lowest-remaining) quota among the given values — used
    /// to tint a provider's name by its most-depleted metric. `nil` when no quota
    /// data is available, so callers keep their default tint.
    static func worstColor(_ percents: Double?...) -> Color? {
        guard let worst = percents.compactMap({ $0 }).min() else { return nil }
        return from(percentRemaining: worst).color
    }

    var color: Color {
        switch self {
        case .healthy: NotchAccent.call
        case .warning: NotchAccent.attention
        case .critical: NotchAccent.stop
        case .depleted: NotchAccent.stop.opacity(0.6)
        }
    }
}
