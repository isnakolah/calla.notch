//
//  CopilotModelsPane.swift
//  callaNotch
//

import AppKit
import Defaults
import SwiftUI

/// Which model hears the call, and which one answers.
///
/// Intelligence and Transcription were two pages asking one question. The split
/// was not neutral: the speech model and the reasoning model share a budget and
/// a machine — choosing Small whisper and a local brain on the same Mac is a
/// decision about one machine's next four seconds — and a menu between them made
/// that impossible to see. They also both reported a download and both reported
/// a health, in two different vocabularies.
///
/// Merged, the page reads left to right the way a call does: what it hears, what
/// it answers with, and where the audio goes if this Mac cannot.
struct CopilotModelsPane: View {
    @ObservedObject private var engine = CallaEngineClient.shared

    @State private var authToken: String = ""
    @State private var availableModels: [String] = []
    @Default(.callaIntelligenceProvider) private var provider
    @Default(.callaIntelligenceLiveTier) private var liveTier
    @Default(.callaIntelligenceSummaryModel) private var summaryModel
    @Default(.callaIntelligenceFallback) private var fallback
    @Default(.callaGatewayStandby) private var gatewayStandby
    @Default(.callaCopilotLiveModel) private var speechModel
    @Default(.callaCopilotArchiveRetranscribe) private var archiveRetranscribe

    private var copilot: CallaCopilotStatus { engine.status.copilot }

    var body: some View {
        SettingsPane(.models) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    columnHead(1, "Hears the call", "Runs on this Mac. Nothing leaves it for transcription.")
                    hearsCard
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .settingsAnchor("models.hears")
                VStack(alignment: .leading, spacing: 12) {
                    columnHead(2, "Answers", "Writes suggestions during the call and the recap after it.")
                    answersCard
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .settingsAnchor("models.answers")
            }
            fallbackCard.settingsAnchor("models.fallback")
        }
        .task { engine.refresh(); engine.listQuizModels { availableModels = $0 } }
    }

    private func columnHead(_ number: Int, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("\(number)")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .background(Color.primary.opacity(0.1), in: Circle())
                Text(title).font(.system(size: 15, weight: .semibold))
            }
            Text(detail)
                .font(NotchType.paneDetail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 2)
    }

    // MARK: - Hears

    private struct SpeechOption: Identifiable {
        let id: String
        let name: String
        let note: String
    }

    private let speechOptions = [
        SpeechOption(id: "whisper-base-en", name: "Base", note: "Keeps up on a busy or older Mac."),
        SpeechOption(id: "whisper-small-en", name: "Small", note: "Clearer names and numbers."),
    ]

    private var hearsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsList {
                ForEach(speechOptions) { option in
                    speechRow(option)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Speech model"))

            SettingsList {
                if let download = copilot.modelDownload {
                    VStack(alignment: .leading, spacing: NotchSpace.tight) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(download.model).font(NotchType.rowTitle)
                            Spacer(minLength: 8)
                            Text(downloadFigure(download))
                                .font(NotchType.figure).foregroundStyle(.secondary)
                        }
                        SettingProgressBar(done: megabytes(download.receivedBytes),
                                           total: megabytes(download.totalBytes),
                                           active: download.isActive)
                        if let message = download.message {
                            Text(message)
                                .font(NotchType.rowDetail).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 10)
                } else {
                    SettingsListRow("Fetch it now", detail: "Downloads ahead of a call instead of at the start of one.") {
                        Button("Download") { engine.prefetchModel(speechModel) }
                            .disabled(!copilot.available)
                    }
                }
                SettingsToggleRow("Clean up the transcript afterwards",
                                  detail: "A slower, more accurate pass over the saved audio once the call ends.",
                                  isOn: $archiveRetranscribe)
            }
        }
    }

    private func speechRow(_ option: SpeechOption) -> some View {
        let selected = speechModel == option.id
        return Button { speechModel = option.id } label: {
            HStack(spacing: 12) {
                Circle()
                    .strokeBorder(selected ? NotchTint.active : Color.primary.opacity(0.35),
                                  lineWidth: selected ? 5 : 1.5)
                    .frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.name).font(.system(size: 13, weight: .semibold))
                    Text(option.note).font(NotchType.rowDetail).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if selected {
                    SettingBadge("In use", tint: NotchTint.healthy)
                } else {
                    Text("Downloads when picked")
                        .font(NotchType.rowDetail)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 8)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func downloadFigure(_ download: CallaModelDownload) -> String {
        guard download.totalBytes > 0 else { return stateLabel(download.state) }
        return "\(megabytes(download.receivedBytes)) of \(megabytes(download.totalBytes)) MB"
    }

    private func stateLabel(_ state: String) -> String {
        switch state {
        case "downloading": return "Downloading"
        case "verifying": return "Verifying"
        case "ready": return "On this Mac"
        case "failed": return "Failed"
        default: return state
        }
    }

    private func megabytes(_ bytes: Int64) -> Int { Int(bytes / 1_048_576) }

    // MARK: - Answers

    private var answersCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsList {
                SettingsListRow("Provider",
                                detail: provider == "local"
                                    ? "Transcript and selected passages go to Google's models. Audio stays on this Mac."
                                    : "The Calla gateway answers.") {
                    Picker("", selection: $provider) {
                        Text("Gemini").tag("local")
                        Text("Gateway").tag("gateway")
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                    .onChange(of: provider) { _, new in
                        engine.setIntelligence(provider: new, tier: liveTier,
                                               summaryModel: summaryModel, fallback: fallback)
                    }
                }
                if provider == "local" {
                    if copilot.agyAvailable {
                        signIn
                    } else {
                        SettingsListRow("Antigravity CLI", detail: "Not installed — install agy, or switch to Gateway.") {
                            SettingBadge("Missing", tint: NotchTint.attention)
                        }
                    }
                }
            }

            SettingsList {
                SettingsListRow("During the call", detail: "Applies from the next call.") {
                    Picker("", selection: $liveTier) {
                        Text("Fastest").tag("fast")
                        Text("Balanced").tag("balanced")
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                    .disabled(provider != "local")
                    .onChange(of: liveTier) { _, new in
                        engine.setIntelligence(provider: provider, tier: new)
                    }
                }
                SettingsListRow("Recap after the call") {
                    Picker("", selection: $summaryModel) {
                        ForEach(availableModels.contains(summaryModel) ? availableModels : [summaryModel] + availableModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .labelsHidden().frame(maxWidth: 170)
                    .disabled(provider != "local")
                    .onChange(of: summaryModel) { _, new in
                        engine.setIntelligence(provider: provider, summaryModel: new)
                    }
                }
                // Which brain is actually answering, which is not always the
                // one chosen above: a local failure hands the call to the
                // gateway mid-flight, and that has to be visible.
                if copilot.running {
                    SettingsListRow("Answering now", detail: copilot.providerDetail ?? "—") {
                        SettingBadge(copilot.activeProvider == "local" ? "Gemini" : "Gateway",
                                     tint: copilot.activeProvider == "local" ? NotchTint.active : nil)
                    }
                }
            }
        }
    }

    @ViewBuilder private var signIn: some View {
        SettingsListRow("Google account",
                   detail: copilot.agyLoggedIn
                    ? (copilot.agyAccount ?? "Authenticated")
                    : "Not signed in — sign in so agy can reach Gemini.") {
            if copilot.agyLoggedIn {
                HStack(spacing: 8) {
                    // Forces a fresh sign-in. Without `force` this does nothing
                    // when credentials exist, which is useless in exactly the
                    // case people press it: signed in on paper, failing in
                    // practice.
                    Button("Sign in again") { engine.loginAgy(force: true) }.controlSize(.small)
                    Button("Sign out") { engine.signOutAgy() }.controlSize(.small)
                }
            } else {
                Button("Sign in") { engine.loginAgy() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
        }

        if copilot.agyBackupAvailable, !copilot.agyLoggedIn {
            SettingsListRow("Previous sign-in",
                       detail: "Kept aside when you signed out. Put it back without going through Google again.") {
                Button("Restore") { engine.restoreSignIn() }.controlSize(.small)
            }
        }

        if let url = copilot.agyLoginURL {
            SettingsListRow("Sign-in link", detail: "Open this if your browser did not.") {
                HStack(spacing: 8) {
                    Button("Open") {
                        if let target = URL(string: url) { NSWorkspace.shared.open(target) }
                    }.controlSize(.small)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    }.controlSize(.small)
                }
            }
        }

        // Driven by agy actually sitting at its paste prompt, rather than by
        // matching words in the last status message.
        if copilot.canAcceptCode {
            SettingsListRow("Authorization code",
                       detail: "Paste the code the sign-in page gave you. It expires quickly.") {
                HStack(spacing: 8) {
                    TextField("Code", text: $authToken)
                        .textFieldStyle(.roundedBorder).frame(minWidth: 140)
                        .onSubmit { submitCode() }
                    Button("Submit", action: submitCode)
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(authToken.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func submitCode() {
        let code = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        engine.submitAgyToken(code)
        authToken = ""
    }

    // MARK: - Fallback

    /// One control for two questions that were previously answered separately
    /// and inconsistently: may the gateway answer, and when does its socket open.
    ///
    /// They were never independent. The socket connected on every call and
    /// received every turn whether or not the gateway was allowed to answer — so
    /// "fall back: off" still shipped the transcript, and every call paid ~1s of
    /// handshake before its microphone opened.
    ///
    /// A stop slider rather than a segmented picker because the three positions
    /// are ordered: they are increasing amounts of this call leaving the machine,
    /// and that ordering is the whole point of the control.
    private var fallbackCard: some View {
        SettingCard("If Gemini cannot answer",
                    detail: "A warm gateway hears the call as it happens, so a handover is instant. None of these delay recording.") {
            NotchStopSlider(
                selection: standbyBinding,
                stops: [
                    .init(value: "off", title: "Never", caption: "nothing sent"),
                    .init(value: "on-failure", title: "On failure", caption: "sends on handover"),
                    .init(value: "warm", title: "Keep warm", caption: "sends throughout"),
                ],
                detail: standbyDetail)
            .disabled(provider != "local")

            GatewayFlow(mode: standbyBinding.wrappedValue,
                        host: engine.status.gatewayReachable ? "Reachable" : "Unavailable")
        }
    }

    /// `fallback` stays the flag the engine and the advisor already understand —
    /// "may the gateway answer" — and is derived rather than picked, because
    /// "never connect" and "may answer" is not a state that means anything.
    private var standbyBinding: Binding<String> {
        Binding(
            get: { fallback ? gatewayStandby : "off" },
            set: { mode in
                let allowed = mode != "off"
                fallback = allowed
                if allowed { gatewayStandby = mode }
                engine.setIntelligence(provider: provider, fallback: allowed,
                                       gatewayStandby: allowed ? mode : "off")
            })
    }

    private var standbyDetail: String {
        switch standbyBinding.wrappedValue {
        case "off":
            return "The gateway is never opened, so no part of the transcript is sent to it. A local brain that fails simply says so — there is nowhere to hand over to."
        case "on-failure":
            return "The call stays on this Mac while it is going well. On a failure the socket opens and the recent transcript is sent so the handover is not blind, which costs a moment at exactly the wrong time."
        default:
            return "Every turn is sent to the gateway as it is transcribed, so it can take over mid-sentence. Its suggestions stay hidden unless the local brain gives up."
        }
    }
}

/// Where the transcript actually goes, for the mode chosen above.
///
/// "Nothing leaves this Mac" and "every turn is sent to the gateway" is a fact
/// about data flow, and a sentence under a picker is the wrong place to keep it —
/// it is the sentence people skip, and it is the one that matters most.
private struct GatewayFlow: View {
    let mode: String
    let host: String

    private var label: String {
        switch mode {
        case "off": return "nothing sent"
        case "on-failure": return "only on failure"
        default: return "every turn, live"
        }
    }

    private var tint: Color {
        switch mode {
        case "off": return NotchTint.paused
        case "on-failure": return NotchTint.attention
        default: return NotchTint.active
        }
    }

    var body: some View {
        HStack(spacing: NotchSpace.snug) {
            node(symbol: "cloud", title: "Agy · Google remote", detail: "transcript + selected passages", tint: NotchTint.active)

            VStack(spacing: 2) {
                SettingsMicroLabel(text: label, tint: tint)
                ZStack(alignment: .trailing) {
                    Rectangle()
                        .fill(LinearGradient(colors: [tint, tint.opacity(0.25)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(height: 2)
                        .opacity(mode == "off" ? 0.25 : 1)
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(tint)
                        .opacity(mode == "off" ? 0.25 : 1)
                }
            }
            .frame(maxWidth: .infinity)

            node(symbol: "network", title: "Gateway", detail: host, tint: NotchTint.paused)
        }
        .animation(NotchMotion.settle, value: mode)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Transcript sent to the gateway: \(label)")
    }

    private func node(symbol: String, title: String, detail: String, tint: Color) -> some View {
        HStack(spacing: NotchSpace.tight) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(NotchType.rowDetail)
                Text(detail).font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, NotchSpace.snug)
        .padding(.vertical, NotchSpace.tight)
        .background(tint.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: NotchRadius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: NotchRadius.control, style: .continuous)
                .strokeBorder(tint.opacity(0.28), lineWidth: 1))
    }
}
