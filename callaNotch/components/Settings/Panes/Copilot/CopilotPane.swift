//
//  CopilotPane.swift
//  callaNotch
//

import CallaContracts
import Defaults
import SwiftUI

/// The copilot, opening on a pre-flight.
///
/// The question people bring here is "will this work on my next call", so the
/// page leads with four facts — your voice, their voice, what transcribes, what
/// answers — and one button. When a fact is broken the button fixes that fact
/// instead of starting a call. The settings sit under it in two groups: what
/// happens during a call, and what is kept after one.
///
/// This absorbs the old Live Call page, which held the same switches behind a
/// tile on a landing page.
struct CopilotPane: View {
    @ObservedObject private var engine = CallaEngineClient.shared
    @ObservedObject private var attention = SettingsAttention.shared
    @Environment(\.settingsRouter) private var router

    @Default(.callaCopilotEnabled) private var enabled
    @Default(.callaCopilotPersona) private var persona
    @Default(.callaIntelligenceProvider) private var provider
    @Default(.callaCopilotLiveModel) private var speechModel
    @Default(.callaCopilotAutoReveal) private var autoReveal
    @Default(.callaCopilotAmbient) private var ambient
    @Default(.callaCopilotGlassLevel) private var glassLevel
    @Default(.callaCallFoldersEnabled) private var callFoldersEnabled
    @Default(.callaCallFoldersAudio) private var callFoldersAudio
    @Default(.callaRememberVoices) private var rememberVoices
    @Default(.callaBackendSync) private var backendSync

    @State private var rememberedVoices: [CallaCallSpeakers.Voice] = []

    private var copilot: CallaCopilotStatus { engine.status.copilot }

    var body: some View {
        SettingsPane(.copilot, isOn: $enabled) {
            preflight

            HStack(alignment: .top, spacing: 16) {
                duringCall.frame(maxWidth: .infinity, alignment: .top)
                afterCall.frame(maxWidth: .infinity, alignment: .top)
            }

            SettingsList {
                SettingsListRow("Call panel size",
                                detail: "Expanded and compact call layouts are sized with the notch.") {
                    Button("Open in Appearance") { router?.go(page: .notchSize) }
                }
            }
        }
        .task {
            engine.refresh()
            engine.setCallPersona(Defaults[.callaCopilotPersona])
            engine.controlSpeakers(CallaSpeakerCommand(action: "list")) { rememberedVoices = $0?.voices ?? [] }
        }
        .onChange(of: callFoldersEnabled) { engine.applyCurrentPreferences() }
        .onChange(of: callFoldersAudio) { engine.applyCurrentPreferences() }
        .onChange(of: backendSync) { engine.applyCurrentPreferences() }
        .onChange(of: rememberVoices) { _, remember in
            // Turning it off means it: what was kept goes too.
            guard !remember else { return }
            engine.controlSpeakers(CallaSpeakerCommand(action: "forget_voices")) { rememberedVoices = $0?.voices ?? [] }
        }
    }

    // MARK: - Pre-flight

    private enum Readiness { case notInstalled, live, starting, blocked, ready }

    private var readiness: Readiness {
        if !copilot.available { return .notInstalled }
        if copilot.isRecording { return .live }
        if copilot.starting { return .starting }
        if blocker != nil { return .blocked }
        return .ready
    }

    /// The one thing that would stop a call being heard properly.
    private var blocker: SettingsBlocker? {
        attention.blockers.first { [.hostScreen, .hostMicrophone].contains($0.kind) }
    }

    private var bandTint: Color {
        switch readiness {
        case .live, .ready, .starting: return Color(red: 0.12, green: 0.56, blue: 0.31)
        case .blocked, .notInstalled: return Color(red: 0.72, green: 0.43, blue: 0.0)
        }
    }

    private var headline: String {
        switch readiness {
        case .notInstalled: return "Copilot is not installed"
        case .live: return "Listening"
        case .starting: return "Starting…"
        case .blocked:
            return blocker?.kind == .hostMicrophone ? "Cannot hear you yet" : "Ready, but only hears you"
        case .ready: return "Ready to listen"
        }
    }

    private var subline: String {
        switch readiness {
        case .notInstalled:
            return "The call host ships with the Calla runtime. Redeploy the app to install it."
        case .live:
            let sides = copilot.systemAudioActive ? "Both sides of the call" : "Your microphone only"
            return "\(sides) · \(copilot.turnCount) turn\(copilot.turnCount == 1 ? "" : "s") heard · suggestions appear in the notch"
        case .starting:
            return "Opening the microphone and loading the speech model."
        case .blocked:
            return blocker?.kind == .hostMicrophone
                ? "The microphone is off for the call host."
                : "The other side of the call needs Screen Recording. You can still start a call."
        case .ready:
            return "\(CallaCopilotPersona.title(persona)) persona · start from here or from the notch."
        }
    }

    private var preflight: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                SettingsIconTile(symbol: "waveform", color: bandTint, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline).font(.system(size: 17, weight: .semibold))
                    Text(subline)
                        .font(NotchType.rowDetail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if readiness == .live {
                    HStack(spacing: NotchSpace.stack) {
                        SettingsLevelMeter(label: "You",
                                           level: copilot.micActive ? (copilot.speaking == "me" ? 1 : 0.4) : 0)
                        SettingsLevelMeter(label: "Them",
                                           level: copilot.systemAudioActive ? (copilot.speaking == "them" ? 1 : 0.4) : 0)
                    }
                    Button("End call", role: .destructive) { engine.endCall() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                } else if readiness == .blocked || readiness == .ready {
                    if let blocker, let fix = blocker.fix {
                        Button(blocker.kind == .hostMicrophone ? "Allow microphone" : "Allow system audio") {
                            router?.go(fix)
                        }
                    }
                    Button("Start call") {
                        engine.startCall(persona: Defaults[.callaCopilotPersona], model: speechModel)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!enabled)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)

            Rectangle().fill(NotchSurface.hairline).frame(height: 1)

            HStack(spacing: 0) {
                ForEach(Array(facts.enumerated()), id: \.offset) { index, fact in
                    if index > 0 {
                        Rectangle().fill(NotchSurface.hairline).frame(width: 1)
                    }
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: fact.ok ? "checkmark" : "exclamationmark.triangle")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(fact.ok ? NotchTint.healthy : NotchTint.attention)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(fact.label).font(NotchType.rowDetail).foregroundStyle(.secondary)
                            Text(fact.value).font(NotchType.rowTitle).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .settingsCardSurface(tint: readiness == .blocked || readiness == .notInstalled ? NotchTint.attention
                                 : readiness == .live ? NotchTint.healthy : nil)
        .animation(NotchMotion.settle, value: headline)
    }

    private struct Fact { let label: String; let value: String; let ok: Bool }

    private var facts: [Fact] {
        let known = copilot.hostPermissionsKnown
        let ear = speechModel.contains("small") ? "Small" : "Base"
        let downloading = copilot.modelDownload?.isActive == true
        let answers: Fact = provider == "local"
            ? Fact(label: "Answers from",
                   value: copilot.agyLoggedIn ? "Gemini · signed in" : "Gemini · not signed in",
                   ok: copilot.agyLoggedIn)
            : Fact(label: "Answers from", value: "Calla gateway", ok: engine.status.gatewayReachable)
        return [
            Fact(label: "Your voice",
                 value: !known ? "Checking…" : copilot.hostMicGranted ? "Microphone" : "Needs Microphone",
                 ok: !known || copilot.hostMicGranted),
            Fact(label: "Their voice",
                 value: !known ? "Checking…" : copilot.hostScreenGranted ? "System audio" : "Needs Screen Recording",
                 ok: !known || copilot.hostScreenGranted),
            Fact(label: "Speech model",
                 value: downloading ? "\(ear) · downloading" : "\(ear) · on this Mac",
                 ok: !downloading),
            answers,
        ]
    }

    // MARK: - Groups

    private var duringCall: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.groupGap) {
            SettingsList("During a call") {
                SettingsListRow("Show new suggestions") {
                    Picker("", selection: $autoReveal) {
                        Text("Right away").tag(true)
                        Text("When I open it").tag(false)
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                }
                SettingsToggleRow("Running summary",
                                  detail: "The notch rests as a small island with the latest lines of the summary.",
                                  isOn: $ambient)
                VStack(alignment: .leading, spacing: 6) {
                    NotchSlider(value: $glassLevel,
                                range: 0...0.8,
                                label: "Panel transparency",
                                format: { "\(Int($0 / 0.8 * 100))%" },
                                ends: ("Opaque", "See-through"),
                                style: .glass)
                    Text("Hidden from screen recordings and shares for the whole call either way.")
                        .font(NotchType.rowDetail).foregroundStyle(.secondary)
                }
                .padding(.vertical, 10)
            }
        }
        .settingsAnchor("copilot.during")
    }

    /// One line: who this Mac is signed in as, and where the archive is up to.
    private var archiveDetail: String {
        guard let backend = engine.status.backend else { return "Keeps every call, whole, on nomonhomelab." }
        if let restore = backend.restore { return restore }
        guard backend.signedIn else {
            return backend.lastError ?? "Keeps every call, whole, on nomonhomelab."
        }
        if let syncing = backend.syncing {
            return "Sending \(syncing)… \(backend.pendingCalls) left"
        }
        if let error = backend.lastError { return error }
        let when = backend.lastSyncAt.map { "Last sent " + RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()) }
        return [backend.deviceName.map { "Signed in as \($0)" }, when].compactMap { $0 }.joined(separator: " · ")
    }

    private var afterCall: some View {
        SettingsList("After a call") {
            SettingsListRow("Save to a folder",
                            detail: "Documents › Calls, with the recap, transcript and answers.") {
                HStack(spacing: 8) {
                    Button("Show") { engine.revealCallFolder() }
                        .disabled(!callFoldersEnabled)
                    SettingsSwitch("Save to a folder", isOn: $callFoldersEnabled)
                }
            }
            SettingsToggleRow("Keep the audio", detail: "Both sides, compressed — about 30 MB an hour.",
                              isOn: $callFoldersAudio)
                .disabled(!callFoldersEnabled)
            SettingsListRow("Recognise voices",
                            detail: rememberedVoices.isEmpty
                                ? "Names speakers in later calls. Stored only on this Mac."
                                : "\(rememberedVoices.count) voice\(rememberedVoices.count == 1 ? "" : "s") remembered on this Mac.") {
                HStack(spacing: 8) {
                    if !rememberedVoices.isEmpty {
                        Menu("Forget") {
                            ForEach(rememberedVoices) { voice in
                                Button(voice.name) {
                                    engine.controlSpeakers(CallaSpeakerCommand(action: "forget_voice",
                                                                               personID: voice.personID)) {
                                        rememberedVoices = $0?.voices ?? rememberedVoices
                                    }
                                }
                            }
                            Divider()
                            Button("Forget all voices", role: .destructive) {
                                engine.controlSpeakers(CallaSpeakerCommand(action: "forget_voices")) {
                                    rememberedVoices = $0?.voices ?? []
                                }
                            }
                        }
                        .fixedSize()
                    }
                    SettingsSwitch("Recognise voices", isOn: $rememberVoices)
                }
            }
            SettingsListRow("Calls from before folders", detail: "Write a folder for every call already in History.") {
                Button("Save past calls") { engine.exportPastCalls() }
                    .disabled(!callFoldersEnabled)
            }
            SettingsListRow("Call archive", detail: archiveDetail) {
                HStack(spacing: 8) {
                    if engine.status.backend?.signedIn == true {
                        Button("Sync now") { engine.backendControl("sync") }
                            .disabled(!backendSync)
                        Button("Restore") { engine.backendControl("restore") }
                            .disabled(!backendSync)
                            .help("Bring back calls from the archive. Never overwrites what is on this Mac.")
                    } else {
                        Button("Sign in") { engine.backendControl("sign_in") }
                            .disabled(!backendSync)
                    }
                    SettingsSwitch("Call archive", isOn: $backendSync)
                }
            }
        }
        .settingsAnchor("copilot.after")
    }
}
