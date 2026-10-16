//
//  UsageMonitorManager.swift
//  boringNotch
//
//  Owns cached CLI usage state for Claude + Codex and drives refreshes via the
//  non-sandboxed XPC helper. The helper is stateless/on-demand, so the cache
//  lives here.
//

import Defaults
import UserNotifications
import Foundation
import Security
import SwiftUI

/// Per-provider view state. Keeps the previously loaded report visible while a
/// re-sync is in flight so the UI never flashes an empty column.
enum ProviderUsageState {
    case idle
    case syncing(previous: UsageReportDTO?)
    case loaded(UsageReportDTO)

    /// The most recent report available, if any (loaded or carried through a sync).
    var report: UsageReportDTO? {
        let value: UsageReportDTO?
        switch self {
        case .idle: value = nil
        case .syncing(let previous): value = previous
        case .loaded(let dto): value = dto
        }
        guard let value else { return nil }
        if value.status == .ok && Date().timeIntervalSince(value.capturedAt) > 24 * 60 * 60 { return nil }
        return value
    }

    var isSyncing: Bool {
        if case .syncing = self { return true }
        return false
    }
}

@MainActor
final class UsageMonitorManager: ObservableObject {
    static let shared = UsageMonitorManager()
    /// A cached percentage is useful across a short CLI/network outage, but it
    /// must not be presented as a current quota for days or weeks.
    private static let maximumCacheAge: TimeInterval = 24 * 60 * 60

    @Published private(set) var claude: ProviderUsageState = .idle
    @Published private(set) var codex: ProviderUsageState = .idle
    @Published private(set) var agy: ProviderUsageState = .idle
    @Published private(set) var lastErrors: [String: String] = [:]
    @Published private(set) var profileOptions: [String: [UsageProfileOption]] = [:]

    private var inFlight: Set<String> = []
    /// Usage badges can be recreated as the notch opens and closes. Keep the
    /// refresh lifetime here instead of in a particular SwiftUI surface, so a
    /// visible stale badge is never left waiting for another `onAppear`.
    private var periodicRefreshTask: Task<Void, Never>?

    private init() {
        // Seed from the last successful reports so a fresh launch (or a launch
        // while Claude/Codex are unreachable) still shows the previous usage.
        if let cached = Self.loadCachedReport(for: "claude", profile: selectedProfile(for: "claude")), Self.isCurrentEnough(cached) {
            claude = .loaded(cached)
        }
        if let cached = Self.loadCachedReport(for: "codex", profile: selectedProfile(for: "codex")), Self.isCurrentEnough(cached) {
            codex = .loaded(cached)
        }
        if let cached = Self.loadCachedReport(for: "agy", profile: nil), Self.isCurrentEnough(cached) { agy = .loaded(cached) }
        if let error = Defaults[.usageLastClaudeError] { lastErrors["claude"] = error }
        if let error = Defaults[.usageLastCodexError] { lastErrors["codex"] = error }
        startPeriodicRefresh()
    }

    deinit {
        periodicRefreshTask?.cancel()
    }

    // MARK: - Running out

    /// Notify on the crossing, not on the state.
    ///
    /// A quota that is already low is low every time it is polled; saying so
    /// every five minutes is how a useful warning becomes something you turn
    /// off. This fires only when a reading moves from above the mark to below it.
    private func announceIfNewlyLow(provider: String,
                                    previous: UsageReportDTO?,
                                    current: UsageReportDTO) {
        guard Defaults[.usageNotifyOnLow] else { return }
        let low = Defaults[.usageLowThreshold]

        func crossed(_ old: UsageReportDTO.Quota?, _ new: UsageReportDTO.Quota?) -> Double? {
            guard let new, new.percentRemaining < low else { return nil }
            guard let old, old.percentRemaining >= low else { return nil }
            return new.percentRemaining
        }

        let hit = crossed(previous?.session, current.session) ?? crossed(previous?.weekly, current.weekly)
        guard let remaining = hit else { return }

        let name = provider == "claude" ? "Claude" : "Codex"
        let content = UNMutableNotificationContent()
        content.title = "\(name) is running low"
        content.body = "\(Int(remaining.rounded()))% of your allowance is left."
        if let reset = current.session?.resetText ?? current.weekly?.resetText {
            content.body += " \(reset)."
        }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "usage.low.\(provider)", content: content, trigger: nil))
    }

    // MARK: - Persistent cache

    private static func cacheKey(for provider: String, profile: String?) -> String {
        "usage.report.v2.\(provider).\(profile ?? "shared")"
    }

    private static func loadCachedReport(for provider: String, profile: String?) -> UsageReportDTO? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey(for: provider, profile: profile)),
              let report = try? UsageReportDTO.decoder.decode(UsageReportDTO.self, from: data),
              report.provider == provider, report.profileID == profile else { return nil }
        return report
    }

    private static func persistReport(_ report: UsageReportDTO, for provider: String, profile: String?) {
        UserDefaults.standard.set(try? UsageReportDTO.encoder.encode(report),
                                  forKey: cacheKey(for: provider, profile: profile))
    }

    private static func isCurrentEnough(_ report: UsageReportDTO, now: Date = Date()) -> Bool {
        now.timeIntervalSince(report.capturedAt) >= 0 && now.timeIntervalSince(report.capturedAt) <= maximumCacheAge
    }

    // MARK: - State access

    private func state(for provider: String) -> ProviderUsageState {
        provider == "claude" ? claude : (provider == "codex" ? codex : agy)
    }

    private func setState(_ state: ProviderUsageState, for provider: String) {
        if provider == "claude" {
            claude = state
        } else if provider == "codex" {
            codex = state
        } else {
            agy = state
        }
    }

    func lastError(for provider: String) -> String? { lastErrors[provider] }

    private func setLastError(_ error: String?, for provider: String) {
        if let error {
            lastErrors[provider] = error
        } else {
            lastErrors.removeValue(forKey: provider)
        }
        if provider == "claude" {
            Defaults[.usageLastClaudeError] = error
        } else if provider == "codex" {
            Defaults[.usageLastCodexError] = error
        }
    }

    // MARK: - Refresh

    /// Refreshes any provider whose cached report is older than the configured
    /// interval (or has never loaded). Called when the Usage tab becomes visible.
    /// The providers the reader has asked for. Someone who only uses one should
    /// not have the other reported as missing forever, or probed on a timer.
    static var enabledProviders: [String] {
        var out: [String] = []
        if Defaults[.usageShowClaude] { out.append("claude") }
        if Defaults[.usageShowCodex] { out.append("codex") }
        out.append("agy")
        return out
    }

    func refreshIfStale() {
        let interval = Defaults[.usageMonitorRefreshInterval]
        for provider in Self.enabledProviders {
            if isStale(state(for: provider), interval: interval) {
                refresh(provider: provider, force: false)
            }
        }
    }

    private func startPeriodicRefresh() {
        periodicRefreshTask?.cancel()
        periodicRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.expireOldReports()
                self.refreshIfStale()

                let interval: TimeInterval = 30
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return
                }
            }
        }
    }

    private func expireOldReports() {
        for provider in ["claude", "codex", "agy"] {
            if let report = state(for: provider).report, !Self.isCurrentEnough(report) {
                setState(.idle, for: provider)
            }
        }
    }

    private static func currentSecuritySessionID() -> String? {
        var sessionID: SecuritySessionId = 0
        guard SessionGetInfo(callerSecuritySession, &sessionID, nil) == errSecSuccess,
              sessionID != 0 else { return nil }
        return String(sessionID, radix: 16)
    }

    private func isStale(_ state: ProviderUsageState, interval: TimeInterval) -> Bool {
        guard let report = state.report, Self.isCurrentEnough(report) else { return true }
        return Date().timeIntervalSince(report.capturedAt) >= interval
    }

    /// Refreshes both providers as independent concurrent tasks.
    func refresh(force: Bool) {
        for provider in Self.enabledProviders {
            refresh(provider: provider, force: force)
        }
    }

    func selectedProfile(for provider: String) -> String? {
        switch provider {
        case "claude": Defaults[.usageClaudeProfile]
        case "codex": Defaults[.usageCodexProfile]
        default: nil
        }
    }

    func profiles(for provider: String) -> [UsageProfileOption] { profileOptions[provider] ?? [] }

    /// Asks the helper for Tangit's profiles; the sandboxed app cannot read them.
    func loadProfiles() {
        Task {
            for provider in ["claude", "codex"] {
                let options = await XPCHelperClient.shared.listUsageProfiles(provider: provider)
                await MainActor.run { self.profileOptions[provider] = options }
            }
        }
    }

    func selectProfile(_ id: String, for provider: String) {
        guard profiles(for: provider).contains(where: { $0.id == id }) else { return }
        if provider == "claude" { Defaults[.usageClaudeProfile] = id }
        else if provider == "codex" { Defaults[.usageCodexProfile] = id }
        else { return }
        // Show this profile's last good numbers while it re-syncs, so a
        // transient probe failure after a switch does not blank the column.
        if let cached = Self.loadCachedReport(for: provider, profile: id), Self.isCurrentEnough(cached) {
            setState(.loaded(cached), for: provider)
        } else {
            setState(.idle, for: provider)
        }
        setLastError(nil, for: provider)
        refresh(provider: provider, force: true)
    }

    func refreshProvider(_ provider: String) { refresh(provider: provider, force: true) }

    private func refresh(provider: String, force: Bool) {
        guard !inFlight.contains(provider) else { return }

        if !force {
            let interval = Defaults[.usageMonitorRefreshInterval]
            if !isStale(state(for: provider), interval: interval) { return }
        }

        let profile = selectedProfile(for: provider)
        inFlight.insert(provider)
        setState(.syncing(previous: state(for: provider).report.flatMap { Self.isCurrentEnough($0) ? $0 : nil }), for: provider)

        Task { [provider, profile] in
            let dto = await XPCHelperClient.shared.fetchUsage(
                provider: provider,
                profileID: profile,
                securitySessionID: Self.currentSecuritySessionID()
            )
            await MainActor.run {
                self.inFlight.remove(provider)
                guard self.selectedProfile(for: provider) == profile else {
                    self.refresh(provider: provider, force: true)
                    return
                }
                if let dto {
                    // A failed probe (network hiccup, CLI timeout) should not
                    // wipe real numbers — keep the last good report visible.
                    // cliNotInstalled/notLoggedIn are genuine states and replace it.
                    if dto.status == .error,
                       let previous = self.state(for: provider).report,
                       previous.status == .ok, Self.isCurrentEnough(previous) {
                        self.setLastError(dto.errorDescription ?? "Usage refresh failed", for: provider)
                        self.setState(.loaded(previous), for: provider)
                    } else {
                        let before = self.state(for: provider).report
                        self.setState(.loaded(dto), for: provider)
                        if dto.status == .ok {
                            self.setLastError(nil, for: provider)
                            Self.persistReport(dto, for: provider, profile: profile)
                            self.announceIfNewlyLow(provider: provider, previous: before, current: dto)
                        } else {
                            self.setLastError(dto.errorDescription ?? "Usage refresh failed", for: provider)
                        }
                    }
                } else {
                    // Transport failure — synthesize an error report so the column
                    // shows something actionable instead of spinning forever.
                    let previous = self.state(for: provider).report
                    if let previous, Self.isCurrentEnough(previous) {
                        self.setLastError("Helper unavailable", for: provider)
                        self.setState(.loaded(previous), for: provider)
                    } else {
                        self.setState(.loaded(UsageReportDTO(
                            provider: provider,
                            status: .error,
                            errorDescription: "Helper unavailable",
                            session: nil,
                            weekly: nil,
                            capturedAt: Date()
                        )), for: provider)
                    }
                }
            }
        }
    }
}
import Foundation

struct UsageProfileOption: Identifiable, Equatable {
    let id: String
    let identity: String?
}
