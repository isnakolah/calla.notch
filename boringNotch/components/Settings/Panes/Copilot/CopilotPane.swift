//
//  CopilotPane.swift
//  boringNotch
//

import Defaults
import AppKit
import SwiftUI

/// The copilot's front page.
///
/// It used to be a switch in a card and six drill rows — a menu standing in
/// front of the pages, and a scroll as soon as the sixth row appeared. The
/// landing pane is the one place in the section that can answer "is this
/// working right now", and it was the one place that did not.
///
/// So the switch becomes a band that reports the live call, with both capture
/// legs drawn rather than named — only your own side being heard is the failure
/// that looks like success, and "Capturing"/"Silent" reads the same until the
/// call is half over. The destinations become tiles carrying what their page
/// currently says, so "which model is answering" is legible without opening
/// anything.
struct CopilotPane: View {
    @ObservedObject private var engine = CallaEngineClient.shared
    @ObservedObject private var library = CallaKnowledgeLibrary.shared
    @ObservedObject private var codingSetups = CallaCodingSetupStore.shared
    @Environment(\.settingsRouter) private var router

    @Default(.callaCopilotEnabled) private var enabled
    @Default(.callaCopilotPersona) private var persona
    @Default(.callaCopilotCustomPersonas) private var customPersonas
    @Default(.callaIntelligenceProvider) private var provider
    @Default(.callaIntelligenceLiveTier) private var liveTier
    @Default(.callaCopilotLiveModel) private var speechModel
    @Default(.callaQuizEnabled) private var quizEnabled

    private var copilot: CallaCopilotStatus { engine.status.copilot }

    var body: some View {
        SettingsPane(.copilot) {
            band
            if let router { tiles(router) }
        }
        .task { engine.refresh() }
    }

    // MARK: - Band

    private var band: some View {
        SettingsStateBand(
            symbol: "waveform.badge.mic",
            title: stateTitle,
            detail: stateDetail,
            tint: bandTint,
            isOn: $enabled
        ) {
            if copilot.isRecording {
                HStack(spacing: NotchSpace.stack) {
                    SettingsLevelMeter(
                        label: "You",
                        level: copilot.micActive ? (copilot.speaking == "me" ? 1 : 0.4) : 0,
                        tint: copilot.micActive ? NotchTint.active : NotchTint.attention)
                    SettingsLevelMeter(
                        label: "Them",
                        level: copilot.systemAudioActive ? (copilot.speaking == "them" ? 1 : 0.4) : 0,
                        tint: copilot.systemAudioActive ? NotchTint.active : NotchTint.attention)
                }
                .padding(.trailing, NotchSpace.tight)
            }
        }
    }

    private var stateTitle: String {
        if !copilot.available { return "Call host is not installed" }
        if copilot.isRecording { return "In a call" }
        if copilot.starting { return "Starting" }
        return "Idle"
    }

    private var stateDetail: String {
        if !copilot.available {
            return "The copilot ships with Boring's Calla runtime. Redeploy to install it."
        }
        if copilot.isRecording {
            var parts: [String] = []
            parts.append(copilot.systemAudioActive
                         ? "Both sides captured"
                         : "Only your side is being heard")
            parts.append(copilot.activeProvider == "gateway" ? "answering on the gateway"
                                                             : "answering through agy · Google remote")
            parts.append("\(copilot.turnCount) turns heard")
            return parts.joined(separator: " · ")
        }
        return "Listens to a call you are in and suggests what to say next."
    }

    private var bandTint: Color? {
        if !copilot.available { return NotchTint.attention }
        if copilot.isRecording {
            // Half a conversation is the failure worth colouring differently.
            return copilot.systemAudioActive ? NotchTint.active : NotchTint.attention
        }
        return nil
    }

    // MARK: - Destinations

    /// Three groups, eight destinations, one level.
    ///
    /// It was a flat grid of six, with Screen Quiz missing from it entirely —
    /// a whole pane reachable only by the deep link the notch's gear fires — and
    /// Live Coding had no page at all. Eight peer tiles would have been worse
    /// than six: the three things the copilot can *do* would sit beside the five
    /// settings that apply to all three, with nothing saying which was which.
    ///
    /// So they are grouped by the question the reader is actually asking. Every
    /// tile still carries what its page currently says, because the point of a
    /// landing pane is to answer "is this set up right" without opening
    /// anything.
    private func tiles(_ router: SettingsRouter) -> some View {
        VStack(alignment: .leading, spacing: NotchSpace.group) {
            SettingsTileGroup(title: "What it can do") {
                SettingsTile(symbol: SettingsPage.copilotCall.symbol,
                             title: String(localized: SettingsPage.copilotCall.title),
                             value: callValue,
                             valueIsLive: copilot.isRecording) { router.push(.copilotCall) }
                SettingsTile(symbol: SettingsPage.copilotQuiz.symbol,
                             title: String(localized: SettingsPage.copilotQuiz.title),
                             value: quizValue,
                             valueIsLive: engine.status.quiz.active) { router.push(.copilotQuiz) }
                if CallaFeatureAvailability.liveCoding {
                    SettingsTile(symbol: SettingsPage.copilotCoding.symbol,
                                 title: String(localized: SettingsPage.copilotCoding.title),
                                 value: codingValue,
                                 valueIsLive: engine.coding.lifecycle.active) { router.push(.copilotCoding) }
                }
            }
            SettingsTileGroup(title: "What it knows") {
                SettingsTile(symbol: SettingsPage.copilotModels.symbol,
                             title: String(localized: SettingsPage.copilotModels.title),
                             value: modelsValue) { router.push(.copilotModels) }
                SettingsTile(symbol: SettingsPage.copilotPrompts.symbol,
                             title: String(localized: SettingsPage.copilotPrompts.title),
                             value: promptsValue) { router.push(.copilotPrompts) }
                SettingsTile(symbol: SettingsPage.copilotKnowledge.symbol,
                             title: String(localized: SettingsPage.copilotKnowledge.title),
                             value: knowledgeValue) { router.push(.copilotKnowledge) }
            }
            SettingsTileGroup(title: "What it keeps", columns: 2) {
                SettingsTile(symbol: SettingsPage.copilotHistory.symbol,
                             title: String(localized: SettingsPage.copilotHistory.title),
                             value: historyValue) { router.push(.copilotHistory) }
                SettingsTile(symbol: SettingsPage.copilotBackup.symbol,
                             title: String(localized: SettingsPage.copilotBackup.title),
                             value: "Export these settings, bring them back, or start over") {
                    router.push(.copilotBackup)
                }
            }
        }
    }

    private var callValue: String {
        if copilot.isRecording {
            guard let startedAt = copilot.startedAt else { return "In a call" }
            let minutes = Int(Date().timeIntervalSince(startedAt) / 60)
            return "In a call · \(minutes) min"
        }
        guard copilot.available else { return "Host not installed" }
        return "\(CallaCopilotPersona.title(persona)) persona · ready to start"
    }

    private var quizValue: String {
        let quiz = engine.status.quiz
        if quiz.active { return "Watching a window" }
        var missing: [String] = []
        if !quiz.screenRecordingReady { missing.append("Screen Recording") }
        if !quiz.accessibilityReady { missing.append("Accessibility") }
        if !quiz.modelsReady { missing.append("reasoners") }
        guard missing.isEmpty else { return "Needs \(missing.joined(separator: ", "))" }
        return quizEnabled ? "Ready · answers what is on one window" : "Turned off"
    }

    private var codingValue: String {
        if engine.coding.lifecycle.active { return "Interview running" }
        let prepared = codingSetups.setups.filter(\.hasFolder)
        guard let fallback = codingSetups.fallback, fallback.hasFolder else {
            return prepared.isEmpty
                ? "No project set up yet"
                : "\(Self.count(prepared.count, "meeting")) prepared"
        }
        let others = prepared.filter { $0.scope != "always" }.count
        guard others > 0 else { return "\(fallback.folderName) · any session" }
        return "\(fallback.folderName) · \(Self.count(others, "meeting")) prepared"
    }

    private var modelsValue: String {
        let brain = provider == "local" ? "Agy · Google remote" : "Gateway"
        let tier = liveTier == "fast" ? "Fast" : "Balanced"
        let ear = speechModel.contains("small") ? "Small" : "Base"
        return "\(brain) · \(tier) · whisper \(ear)"
    }

    private var promptsValue: String {
        let title = CallaCopilotPersona.title(persona)
        guard !customPersonas.isEmpty else { return "\(title) persona" }
        return "\(title) · \(Self.count(customPersonas.count, "custom persona"))"
    }

    private var knowledgeValue: String {
        guard !library.notes.isEmpty else { return "Files and notes the copilot reads" }
        let documents = library.notes.filter(\.isDocument).count
        return "\(Self.count(documents, "file")) · \(Self.count(library.notes.count - documents, "note"))"
    }

    private var historyValue: String {
        guard !library.calls.isEmpty else { return "Past calls, transcripts and what was suggested" }
        return "\(Self.count(library.calls.count, "call")) recorded"
    }

    /// "1 file", "4 files".
    ///
    /// Written out rather than left to `^[...](inflect: true)`: a tile's value is
    /// a plain `String` rendered by `Text(String)`, which does not resolve
    /// automatic-grammar markup — so the cards were printing the markup itself.
    private static func count(_ value: Int, _ noun: String) -> String {
        "\(value) \(noun)\(value == 1 ? "" : "s")"
    }
}
