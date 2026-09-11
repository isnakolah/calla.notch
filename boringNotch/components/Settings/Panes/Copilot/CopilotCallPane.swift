//
//  CopilotCallPane.swift
//  boringNotch
//

import AppKit
import CallaContracts
import Defaults
import SwiftUI

/// The live call: what is being captured right now, what starts it, and what
/// the panel looks like while it runs.
///
/// The two capture legs are reported separately on purpose. Only your own side
/// being heard is the failure that looks like success — suggestions keep
/// arriving, built from half a conversation.
///
/// Laid out in two columns because it was seven cards in one scroll: the state
/// of the call and the permissions it needs on the left, the shape of the panel
/// and the pre-roll on the right. Nothing here is below the fold at the window's
/// default size, which is the whole point.
struct CopilotCallPane: View {
    @ObservedObject private var engine = CallaEngineClient.shared
    @ObservedObject private var library = CallaKnowledgeLibrary.shared
    @Environment(\.settingsRouter) private var router

    @Default(.callaCopilotEnabled) private var copilotEnabled
    @Default(.callaQuizEnabled) private var quizEnabled
    @Default(.callaPlainCallEnabled) private var plainCallEnabled
    @Default(.callaCopilotLiveModel) private var model
    @Default(.callaCopilotAutoReveal) private var autoReveal
    @Default(.callaCopilotGlassLevel) private var glassLevel


    private var copilot: CallaCopilotStatus { engine.status.copilot }

    var body: some View {
        SettingsPane(SettingsPage.copilotCall, nav: [.copilotModels, .copilotHistory]) {
            if !copilot.available { notInstalled }
            SettingsColumns {
                liveCard
                permissionsCard
            } trailing: {
                panelSizeLink
            }
            notchCard
            quizLink
            if let result = copilot.lastResult {
                SettingCard("Last result") {
                    Text(result)
                        .font(NotchType.rowDetail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task {
            engine.refresh()
            // Keep settings and the notch on the selected call profile.
            engine.setCallPersona(Defaults[.callaCopilotPersona])
            await library.load()
        }
    }

    // MARK: - Cards

    private var notInstalled: some View {
        SettingCard(tint: NotchTint.attention) {
            HStack(spacing: NotchSpace.snug) {
                SettingStatusIcon(ok: false)
                VStack(alignment: .leading, spacing: NotchSpace.hair) {
                    Text("Call host is not installed").font(NotchType.rowTitle)
                    Text("The copilot ships with Boring's Calla runtime. Redeploy to install it.")
                        .font(NotchType.rowDetail).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var liveCard: some View {
        SettingCard("Right now", tint: copilot.running ? NotchTint.active : nil) {
            VStack(spacing: NotchSpace.snug) {
                SettingFact(title: "State", value: stateValue,
                            tint: copilot.running ? NotchTint.active : NotchTint.paused)
                if copilot.running {
                    SettingFact(title: "Your microphone",
                                value: copilot.micActive ? "Capturing" : "Silent",
                                tint: copilot.micActive ? NotchTint.healthy : NotchTint.attention)
                    SettingFact(title: "The other party",
                                value: copilot.systemAudioActive ? "Capturing" : "Not captured",
                                tint: copilot.systemAudioActive ? NotchTint.healthy : NotchTint.attention)
                    SettingFact(title: "Gateway",
                                value: copilot.gatewayConnected ? "Connected" : "Disconnected",
                                tint: copilot.gatewayConnected ? NotchTint.healthy : NotchTint.attention)
                    SettingFact(title: "Turns heard", value: "\(copilot.turnCount)")
                }
                if CallaFeatureAvailability.liveCoding {
                    SettingRow("Plain listening call",
                               detail: "Adds a Call segment to the notch: any meeting, any persona, no project. Off, the notch is only the Wave interview.") {
                        Toggle("", isOn: $plainCallEnabled).labelsHidden().toggleStyle(.switch)
                    }
                }
                HStack {
                    if copilot.running {
                        Button("End call", role: .destructive) { engine.endCall() }
                    } else {
                        Button("Start call") {
                            engine.startCall(persona: Defaults[.callaCopilotPersona], model: model)
                        }
                            .buttonStyle(.borderedProminent)
                            .disabled(!copilot.available)
                    }
                    Spacer()
                }
                .controlSize(.small)
            }
        }
    }

    private var stateValue: String {
        if copilot.isRecording {
            guard let startedAt = copilot.startedAt else { return "In a call" }
            let elapsed = Int(Date().timeIntervalSince(startedAt))
            return String(format: "In a call · %d:%02d", elapsed / 60, elapsed % 60)
        }
        if copilot.starting { return "Starting" }
        return "Idle"
    }

    /// Grants belong to the capture host, not to Boring and not to the engine.
    ///
    /// TCC keys a grant to the signature of the process that asks, so a prompt
    /// raised anywhere else grants nothing the host can use — which is why this
    /// pane used to be able to report the problem but never fix it. Unknown is
    /// drawn as unknown: until the host has reported once there is nothing to
    /// say, and saying "not granted" would be the same wrong answer the engine
    /// used to give by preflighting on its own behalf.
    private var permissionsResolved: Bool { copilot.hostPermissionsKnown }
    private var permissionsSatisfied: Bool {
        permissionsResolved && copilot.hostMicGranted && copilot.hostScreenGranted
    }

    private var permissionsCard: some View {
        SettingCard("Permissions",
                    detail: "Held by the capture host, which is the process that actually records.",
                    tint: permissionsResolved && !permissionsSatisfied ? NotchTint.attention : nil) {
            VStack(spacing: NotchSpace.snug) {
                permissionRow("Microphone",
                              detail: "Your own side of the call.",
                              granted: copilot.hostMicGranted)
                permissionRow("Screen recording",
                              detail: "The other party's audio. Without it the copilot only hears you, and its pointers are built almost entirely from what they said.",
                              granted: copilot.hostScreenGranted)
                if !permissionsResolved {
                    Text("Checking what the capture host holds…")
                        .font(NotchType.rowDetail)
                        .foregroundStyle(.secondary)
                } else if !permissionsSatisfied {
                    HStack {
                        Text("Already denied once? macOS will not ask again — turn it on by hand.")
                            .font(NotchType.rowDetail)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button("Open System Settings") { openPrivacySettings() }
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private func permissionRow(_ title: String, detail: String, granted: Bool) -> some View {
        SettingRow(title, detail: detail) {
            HStack(spacing: NotchSpace.snug) {
                if !permissionsResolved {
                    Image(systemName: "questionmark.circle.fill")
                        .font(NotchType.rowTitle)
                        .foregroundStyle(.tertiary)
                } else {
                    SettingStatusIcon(ok: granted)
                    if !granted {
                        Button("Grant") { engine.requestCopilotPermissions() }
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: - Quiz

    /// Quiz has its own page now; this keeps it reachable from where it used to
    /// live.
    private var quizLink: some View {
        SettingsDrillGroup {
            SettingsDrillRow(
                symbol: SettingsPage.copilotQuiz.symbol,
                title: String(localized: SettingsPage.copilotQuiz.title),
                detail: "The window Quiz watches, who answers, and what it keeps.",
                badge: quizEnabled ? "On" : "Off",
                badgeTint: quizEnabled ? NotchTint.active : nil
            ) {
                router?.go(.init(.copilot, [.copilotQuiz]))
            }
        }
    }

    private var panelSizeLink: some View {
        SettingsDrillGroup(
            "Panel size",
            detail: "Normal, expanded Call, and compact Call sizes now live together under Appearance."
        ) {
            SettingsDrillRow(
                symbol: SettingsPage.notchSize.symbol,
                title: String(localized: SettingsPage.notchSize.title),
                detail: "Open the real notch and resize it directly.",
                badge: "Appearance"
            ) {
                router?.go(.init(.appearance, [.notchSize]))
            }
        }
    }

    private var notchCard: some View {
        SettingCard("In the notch") {
            HStack(alignment: .top, spacing: NotchSpace.group) {
                VStack(spacing: NotchSpace.row) {
                    SettingRow("Enable call copilot",
                               detail: "Off hides the copilot tab and stops it starting with a call.") {
                        Toggle("", isOn: $copilotEnabled).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow("Reveal new suggestions",
                               detail: "Peeks the newest pointer as it arrives instead of waiting to be opened.") {
                        Toggle("", isOn: $autoReveal).labelsHidden().toggleStyle(.switch)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: NotchSpace.tight) {
                    // The glass style rather than the amount style: the rail is
                    // the transparency it is setting, so the control shows the
                    // answer instead of describing it.
                    NotchSlider(value: $glassLevel,
                                range: 0...0.8,
                                label: "Panel transparency",
                                format: { "\(Int($0 / 0.8 * 100))%" },
                                ends: ("Opaque", "See-through"),
                                style: .glass)
                    Text("How much of the desktop shows through the live panel. It is hidden from screen recordings and shares for the whole call regardless.")
                        .font(NotchType.rowDetail).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // The three copilot recorders moved to Settings › Shortcuts, which is now
    // the only place any of them live. Three panes used to own recorders, so
    // "what is bound to ⌥⌘C" could not be answered from one screen and nothing
    // stopped two features claiming the same chord.

    private func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }
}
