//
//  UsageProbeService.swift
//  CallaNotchXPCHelper
//
//  Orchestrates provider probes and maps their snapshots/errors into the
//  Codable UsageReportDTO carried across the XPC boundary. Coalesces
//  duplicate in-flight requests per provider so a burst of XPC calls can't
//  spawn concurrent `claude`/`codex` subprocesses.
//

import Foundation

actor UsageProbeService {
    static let shared = UsageProbeService()

    private var inFlight: [String: Task<UsageReportDTO, Never>] = [:]

    func fetchUsage(provider: String, profileID: String?, securitySessionID: String?) async -> UsageReportDTO {
        if let existing = inFlight[provider + ":" + (profileID ?? "shared")] {
            return await existing.value
        }

        let task = Task<UsageReportDTO, Never> { [provider, profileID, securitySessionID] in
            await Self.runProbe(provider: provider, profileID: profileID, securitySessionID: securitySessionID)
        }
        inFlight[provider + ":" + (profileID ?? "shared")] = task
        let result = await task.value
        inFlight[provider + ":" + (profileID ?? "shared")] = nil
        return result
    }

    private static func runProbe(provider: String, profileID: String?, securitySessionID: String?) async -> UsageReportDTO {
        if provider == "agy" { return await AGYUsageProbe.fetchReport() }
        guard let profileID, let profile = TangitUsageProfile.resolve(profileID, provider: provider) else {
            return UsageReportDTO(provider: provider, status: .notLoggedIn,
                errorDescription: "Select a valid Tangit profile and sign in with its CLI", session: nil,
                weekly: nil, capturedAt: Date(), profileID: profileID)
        }
        let signedIn = provider == "claude"
            ? ClaudeProfileCredentials.sync(directory: profile.directory, securitySessionID: securitySessionID)
            : FileManager.default.fileExists(atPath: profile.directory.appendingPathComponent("auth.json").path)
        if !signedIn {
            return UsageReportDTO(provider: provider, status: .notLoggedIn,
                errorDescription: "Run tangit login \(profile.id) \(provider)",
                session: nil, weekly: nil, capturedAt: Date(), profileID: profile.id,
                accountIdentity: ProfileIdentity.read(provider: provider, directory: profile.directory))
        }
        let probe: UsageProbe
        switch provider {
        case "claude":
            probe = ClaudeUsageProbe(securitySessionID: securitySessionID, configDirectory: profile.directory)
        case "codex":
            probe = CodexUsageProbe(codexHome: profile.directory.path)
        default:
            return UsageReportDTO(
                provider: provider,
                status: .error,
                errorDescription: "Unknown provider '\(provider)'",
                session: nil,
                weekly: nil,
                capturedAt: Date(), profileID: profileID,
                accountIdentity: ProfileIdentity.read(provider: provider, directory: profile.directory)
            )
        }

        guard await probe.isAvailable() else {
            return UsageReportDTO(
                provider: provider,
                status: .cliNotInstalled,
                errorDescription: "\(provider) CLI not found",
                session: nil,
                weekly: nil,
                capturedAt: Date(), profileID: profileID,
                accountIdentity: ProfileIdentity.read(provider: provider, directory: profile.directory)
            )
        }

        do {
            let snapshot = try await probe.probe()
            var report = map(snapshot: snapshot, provider: provider)
            report.profileID = profileID
            report.accountIdentity = ProfileIdentity.read(provider: provider, directory: profile.directory)
            return report
        } catch let error as ProbeError {
            AppLog.probes.error("\(provider, privacy: .public) probe failed: \(String(describing: error), privacy: .public)")
            var report = map(error: error, provider: provider)
            report.profileID = profileID
            report.accountIdentity = ProfileIdentity.read(provider: provider, directory: profile.directory)
            return report
        } catch {
            return UsageReportDTO(
                provider: provider,
                status: .error,
                errorDescription: error.localizedDescription,
                session: nil,
                weekly: nil,
                capturedAt: Date(), profileID: profileID,
                accountIdentity: ProfileIdentity.read(provider: provider, directory: profile.directory)
            )
        }
    }

    private static func map(snapshot: UsageSnapshot, provider: String) -> UsageReportDTO {
        func quota(for type: QuotaType) -> UsageReportDTO.Quota? {
            guard let q = snapshot.quotas.first(where: { $0.quotaType == type }) else { return nil }
            return UsageReportDTO.Quota(
                percentRemaining: q.percentRemaining,
                resetText: q.resetText,
                resetsAt: q.resetsAt
            )
        }

        return UsageReportDTO(
            provider: provider,
            status: .ok,
            errorDescription: nil,
            session: quota(for: .session),
            weekly: quota(for: .weekly),
            capturedAt: snapshot.capturedAt
        )
    }

    private static func map(error: ProbeError, provider: String) -> UsageReportDTO {
        let status: UsageReportDTO.Status
        let description: String

        switch error {
        case .cliNotFound:
            status = .cliNotInstalled
            description = "\(provider) CLI not found"
        case .authenticationRequired:
            status = .notLoggedIn
            description = "Not logged in"
        case .subscriptionRequired:
            status = .error
            description = "API-billing account — no quota data"
        default:
            status = .error
            description = error.errorDescription ?? "Usage probe failed"
        }

        return UsageReportDTO(
            provider: provider,
            status: status,
            errorDescription: description,
            session: nil,
            weekly: nil,
            capturedAt: Date()
        )
    }
}
