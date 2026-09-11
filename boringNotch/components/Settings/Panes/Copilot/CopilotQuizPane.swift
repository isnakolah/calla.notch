//
//  CopilotQuizPane.swift
//  boringNotch
//

import AppKit
import CallaContracts
import Defaults
import SwiftUI

/// Screen Quiz: the window it watches, who answers, and what it keeps.
///
/// This was the fourth card down inside "Live Call" — a pane named for calls,
/// with Quiz's five sections stacked inside one `SettingCard` separated by bare
/// `Divider()`s. Nothing in the sidebar or in search mentioned Quiz at all, so
/// the only way to find its permissions was to know they were there.
///
/// Quiz is still configured here rather than in the notch. The notch has one
/// job: bind the prepared setup to an exact window and start the session.
struct CopilotQuizPane: View {
    @ObservedObject private var engine = CallaEngineClient.shared
    @ObservedObject private var library = CallaKnowledgeLibrary.shared
    @Environment(\.settingsRouter) private var router

    private var copilot: CallaCopilotStatus { engine.status.copilot }

    @Default(.callaQuizEnabled) private var quizEnabled
    @Default(.callaQuizVoterOneModel) private var quizVoterOne
    @Default(.callaQuizVoterTwoModel) private var quizVoterTwo
    @Default(.callaQuizVoterThreeModel) private var quizVoterThree
    @Default(.callaQuizArbiterModel) private var quizArbiter
    @Default(.callaQuizCaptureResolution) private var quizCaptureResolution

    @State private var quizModels: [String] = []
    @State private var quizPermissions: QuizPermissionReadiness?
    @State private var quizSetupLoading = false
    @State private var quizAuthCode = ""
    @State private var editingMode: QuizMode = .choice
    @Default(.callaQuizProfiles) private var quizProfiles
    @Default(.callaQuizWarmMode) private var quizWarmMode
    @Default(.callaQuizSpeculative) private var quizSpeculative
    @Default(.callaQuizCodeFont) private var codeFont
    @Default(.callaQuizCodeFontSize) private var codeFontSize
    @Default(.callaQuizCodeLineNumbers) private var codeLineNumbers
    @State private var monospacedFamilies: [String] = []

    var body: some View {
        SettingsPane(SettingsPage.copilotQuiz, nav: [.copilotModels, .copilotHistory]) {
            SettingCard("Quiz mode",
                        detail: "Choices save automatically. Start each session from the Copilot notch; its last target restores when still available.",
                        tint: quizEnabled ? NotchTint.active : nil) {
                SettingRow("Enable Quiz mode",
                           detail: "Adds Call | Quiz to the Copilot notch. Call and Quiz remain mutually exclusive.") {
                    Toggle("", isOn: $quizEnabled).labelsHidden().toggleStyle(.switch)
                        .disabled(engine.status.quiz.active)
                }
            }

            SettingCard("Permissions",
                        detail: "Permissions belong to CallaCallHost, the process that captures and scrolls the locked window.") {
                quizPermissionsSection
            }

            SettingCard("Capture") {
                quizCaptureSection
            }

            SettingCard("Code answers",
                        detail: "How a code answer is set in the notch. A face that is not installed falls back to the system monospaced one.") {
                codeAppearanceSection
            }

            SettingCard("Reasoners") {
                quizReasonersSection
            }

            SettingCard("Event context") {
                quizContextSection
            }

            SettingCard(tint: NotchTint.active) {
                Label {
                    Text("Only the chosen window is captured. Screenshots and selected context go through local AGY to the voters configured above for that kind of question; an arbiter request may follow. Web research may occur. Captures stay encrypted until you delete them in History. Quiz never clicks, types, selects, or submits.")
                        .font(NotchType.rowDetail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(NotchTint.active)
                }
            }
        }
        .task {
            engine.refresh()
            normalizeQuizCaptureResolution()
            refreshQuizSetup()
            await library.load()
        }
        .onChange(of: quizEnabled) { _, _ in engine.applyCurrentPreferences() }
    }

    private var quizPermissionsSection: some View {
        VStack(alignment: .leading, spacing: NotchSpace.tight) {
            HStack {
                Text("Permissions").font(NotchType.rowTitle)
                Spacer()
                Button(quizSetupLoading ? "Checking…" : "Check and grant") {
                    requestQuizPermissions()
                }
                .controlSize(.small)
                .disabled(quizSetupLoading || engine.status.quiz.active)
                Menu {
                    Button("Screen & System Audio Recording") {
                        openPrivacySettings("Privacy_ScreenCapture")
                    }
                    Button("Accessibility") {
                        openPrivacySettings("Privacy_Accessibility")
                    }
                } label: {
                    Image(systemName: "gearshape")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help("Open macOS Privacy & Security")
            }
            quizSetupFact("Screen Recording", ready: quizPermissions?.screenRecording)
            quizSetupFact("Accessibility", ready: quizPermissions?.accessibility)
            Text("Permissions belong to CallaCallHost, the process that captures and scrolls the locked window.")
                .font(NotchType.rowDetail)
                .foregroundStyle(.secondary)
        }
    }

    private var codeAppearanceSection: some View {
        VStack(alignment: .leading, spacing: NotchSpace.row) {
            SettingRow("Font", detail: installed(codeFont)
                       ? "Installed." : "Not installed — using the system monospaced face.") {
                Picker("Font", selection: $codeFont) {
                    ForEach(monospacedFamilies, id: \.self) { Text($0).tag($0) }
                    if !monospacedFamilies.contains(codeFont) {
                        Text(codeFont).tag(codeFont)
                    }
                }
                .labelsHidden()
                .frame(width: 240)
            }

            SettingRow("Size", detail: String(format: "%.1f pt", codeFontSize)) {
                HStack(spacing: NotchSpace.snug) {
                    Slider(value: $codeFontSize, in: 8 ... 18, step: 0.5)
                        .frame(width: 180)
                    Button("Reset") { codeFontSize = 10.5 }
                        .controlSize(.small)
                }
            }

            SettingRow("Line numbers") {
                Toggle("", isOn: $codeLineNumbers).labelsHidden().toggleStyle(.switch)
            }

            codePreview
        }
        .task { loadMonospacedFamilies() }
    }

    /// Worth showing rather than describing: the face and size are the whole
    /// setting, and a sample says more than a number.
    private var codePreview: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Preview").font(NotchType.rowDetail).foregroundStyle(.secondary)
            Text("def minimumDeletions(self, nums):  # 42")
                .font(previewFont)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(NotchSurface.sunken,
                            in: RoundedRectangle(cornerRadius: NotchRadius.control,
                                                 style: .continuous))
        }
    }

    private var previewFont: Font {
        installed(codeFont)
            ? .custom(codeFont, fixedSize: CGFloat(codeFontSize))
            : .system(size: CGFloat(codeFontSize), design: .monospaced)
    }

    private func installed(_ name: String) -> Bool {
        !name.isEmpty && NSFont(name: name, size: 12) != nil
    }

    /// Only fixed-pitch families, because a proportional face makes indentation
    /// meaningless.
    private func loadMonospacedFamilies() {
        guard monospacedFamilies.isEmpty else { return }
        let families = NSFontManager.shared.availableFontFamilies.filter { family in
            guard let font = NSFont(name: family, size: 12) else { return false }
            return font.isFixedPitch
        }
        monospacedFamilies = families.sorted()
    }

    private var quizReasonersSection: some View {
        VStack(alignment: .leading, spacing: NotchSpace.tight) {
            HStack {
                Text("Reasoners").font(NotchType.rowTitle)
                Spacer()
                SettingBadge(quizModelsReady ? "Ready" : "Setup required",
                             tint: quizModelsReady ? NotchTint.healthy : NotchTint.attention)
                Button {
                    refreshQuizModels()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(quizSetupLoading)
                .help("Refresh AGY authentication and model catalog")
            }
            quizAuthenticationRows

            Divider()
            councilEditor

            Text("Settings freeze when Quiz starts.")
                .font(NotchType.rowDetail)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var quizAuthenticationRows: some View {
        SettingRow("AGY account",
                   detail: quizModelsReady
                    ? (copilot.agyAccount ?? "Authenticated and reachable")
                    : "A saved login may be expired. Verify it before starting Quiz.") {
            Button(copilot.agyLoggedIn ? "Sign in again" : "Sign in") {
                engine.loginAgy(force: copilot.agyLoggedIn)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }

        if let url = copilot.agyLoginURL {
            SettingRow("Sign-in link", detail: "Open this if browser did not open automatically.") {
                HStack(spacing: 8) {
                    Button("Open") {
                        if let target = URL(string: url) { NSWorkspace.shared.open(target) }
                    }
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    }
                }
                .controlSize(.small)
            }
        }

        if copilot.canAcceptCode {
            SettingRow("Authorization code", detail: "Paste code from Google, then refresh reasoners.") {
                HStack(spacing: 8) {
                    TextField("Code", text: $quizAuthCode)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 150)
                        .onSubmit { submitQuizAuthCode() }
                    Button("Submit", action: submitQuizAuthCode)
                        .buttonStyle(.borderedProminent)
                        .disabled(quizAuthCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .controlSize(.small)
            }
        }
    }

    private func submitQuizAuthCode() {
        let code = quizAuthCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        engine.submitAgyToken(code)
        quizAuthCode = ""
    }

    private var quizCaptureSection: some View {
        VStack(alignment: .leading, spacing: NotchSpace.tight) {
            NotchStopSlider(
                selection: $quizCaptureResolution,
                stops: supportedQuizResolutions.map { resolution in
                    .init(value: resolution.rawValue,
                          title: resolution.label,
                          caption: quizCaptureEstimate(resolution),
                          tint: quizCaptureTint(resolution))
                },
                label: "Capture resolution",
                detail: "Estimated local preparation time appears under each stop; network and reasoner time vary. Only connected-display resolutions appear. Quiz never upscales a smaller target window. Hard answer deadline remains 120 seconds.")
            .disabled(engine.status.quiz.active)
        }
    }

    private func quizCaptureEstimate(_ resolution: QuizCaptureResolution) -> String {
        switch resolution {
        case .hd720: "<1s"
        case .hd900: "~1s"
        case .fullHD: "1–2s"
        case .twoK: "~2s"
        case .fourteenForty: "2–4s"
        case .fourK: "4–7s"
        case .fiveK: "7–12s"
        case .sixK: "10–16s"
        case .eightK: "18–30s"
        }
    }

    private func quizCaptureTint(_ resolution: QuizCaptureResolution) -> Color {
        switch resolution {
        case .hd720, .hd900, .fullHD: NotchTint.healthy
        case .twoK, .fourteenForty: NotchTint.active
        case .fourK, .fiveK, .sixK, .eightK: NotchTint.attention
        }
    }

    private var supportedQuizResolutions: [QuizCaptureResolution] {
        QuizCaptureResolution.allCases.filter { resolution in
            resolution == .hd720 || NSScreen.screens.contains { screen in
                let scale = screen.backingScaleFactor
                let width = Int((screen.frame.width * scale).rounded())
                let height = Int((screen.frame.height * scale).rounded())
                return max(width, height) >= resolution.maximumWidth
                    && min(width, height) >= resolution.maximumHeight
            }
        }
    }

    private func normalizeQuizCaptureResolution() {
        guard supportedQuizResolutions.contains(where: { $0.rawValue == quizCaptureResolution }) else {
            // Falling back to `.last` picked the *highest* supported stop — up to
            // 8K, which this pane itself estimates at 18–30 s of local prep per
            // frame. The contract default is the right landing place; only drop
            // below it if the displays cannot do it.
            let fallback = supportedQuizResolutions
                .first { $0 == QuizContract.defaultCaptureResolution }
                ?? supportedQuizResolutions.first
                ?? QuizContract.defaultCaptureResolution
            quizCaptureResolution = fallback.rawValue
            return
        }
    }

    private var quizContextSection: some View {
        VStack(alignment: .leading, spacing: NotchSpace.tight) {
            HStack {
                Text("Next session context").font(NotchType.rowTitle)
                Spacer()
                Button("Manage knowledge") {
                    router?.go(.init(.copilot, [.copilotKnowledge]))
                }
                .controlSize(.small)
            }
            if let meeting = engine.pendingQuizMeeting {
                SettingFact(title: "Event", value: meeting.title ?? "Calendar event")
                if meeting.notes?.isEmpty == false {
                    quizContextRow(id: "event-invite-notes", title: "Event notes", symbol: "calendar")
                }
                ForEach(quizAttachedNotes) { note in
                    quizContextRow(id: note.id,
                                   title: note.title.isEmpty ? "Untitled note" : note.title,
                                   symbol: note.symbol)
                }
                if meeting.notes?.isEmpty != false && quizAttachedNotes.isEmpty {
                    Text("No event notes or files attached. Add context from the event menu in Calendar.")
                        .font(NotchType.rowDetail)
                        .foregroundStyle(.secondary)
                }
                Button("Use no event") { engine.prepareQuiz(for: nil) }
                    .controlSize(.small)
            } else {
                Text("No event selected. Start Quiz from a Calendar event to include its event and recurring-series context.")
                    .font(NotchType.rowDetail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var quizAttachedNotes: [CallaKnowledgeNote] {
        guard let meeting = engine.pendingQuizMeeting else { return [] }
        return library.notes.filter { note in
            if note.scope == "event" { return note.scopeKey == meeting.eventID }
            if note.scope == "series" { return note.scopeKey == meeting.seriesID }
            return false
        }
    }

    private var quizModelsReady: Bool {
        // Every model any council could ask for, not four fixed slots.
        let selected = QuizProfileStore.referencedModelIDs
        return !quizModels.isEmpty && selected.allSatisfy(quizModels.contains)
    }

    private func quizSetupFact(_ title: String, ready: Bool?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ready == true ? "checkmark.circle.fill" :
                    ready == false ? "exclamationmark.circle.fill" : "questionmark.circle.fill")
                .foregroundStyle(ready == true ? NotchTint.healthy :
                                 ready == false ? NotchTint.attention : Color.secondary)
            Text(title).font(NotchType.rowTitle)
            Spacer()
            Text(ready == true ? "Granted" : ready == false ? "Required" : "Not checked")
                .font(NotchType.figure)
                .foregroundStyle(.secondary)
        }
    }

    /// One council per kind of question, edited a mode at a time.
    ///
    /// A four-option multiple choice and a code exercise want completely
    /// different treatment — how many voters, which models, how hard they think,
    /// and what settles a disagreement. Quiz used to give every question the same
    /// three models at the same maximum effort.
    private var councilEditor: some View {
        let profile = QuizProfileStore.profile(for: editingMode)
        return VStack(alignment: .leading, spacing: NotchSpace.row) {
            Picker("Question type", selection: $editingMode) {
                ForEach(QuizMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(editingMode.detail)
                .font(NotchType.rowDetail)
                .foregroundStyle(.secondary)

            SettingRow("Settled by",
                       detail: strategyDetail(profile.strategy, voters: profile.voters.count)) {
                Picker("Settled by", selection: strategyBinding(profile)) {
                    ForEach(QuizAnswerStrategy.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 160)
            }

            ForEach(Array(profile.voters.enumerated()), id: \.offset) { item in
                voterRow(profile: profile, index: item.offset, selection: item.element)
            }

            HStack(spacing: NotchSpace.snug) {
                Button("Add voter") { addVoter(to: profile) }
                    .controlSize(.small)
                    .disabled(profile.voters.count >= QuizContract.maximumVoters
                              || engine.status.quiz.active)
                Text("\(profile.voters.count) of \(QuizContract.maximumVoters)")
                    .font(NotchType.rowDetail)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            SettingRow("Arbiter",
                       detail: profile.hasArbiter
                       ? "Breaks a disagreement the voters cannot settle."
                       : "Off — a council that cannot agree says so, rather than asking a fourth model.") {
                Toggle("", isOn: arbiterBinding(profile))
                    .labelsHidden().toggleStyle(.switch)
                    .disabled(engine.status.quiz.active)
            }
            if let arbiter = profile.arbiter {
                arbiterPicker(arbiter, in: profile)
            }

            SettingRow("Improve the answer afterwards",
                       detail: profile.hasRefiner
                       ? "A stronger model reasons about the question again with the published answer in hand, and returns a better implementation and why it is better. It arrives as a second revision — step to it with the answer keys."
                       : "Off — the council's answer is final.") {
                Toggle("", isOn: refinerBinding(profile))
                    .labelsHidden().toggleStyle(.switch)
                    .disabled(engine.status.quiz.active)
            }
            if let refiner = profile.refiner {
                refinerPicker(refiner, in: profile)
            }

            Divider()
            SettingRow("Start spawning before the screen settles",
                       detail: "Begins bringing a council up while the question is still appearing, instead of after. Costs a spawn that occasionally goes unused.") {
                Toggle("", isOn: $quizSpeculative)
                    .labelsHidden().toggleStyle(.switch)
                    .disabled(engine.status.quiz.active)
            }
            SettingRow("Spawn this council at start",
                       detail: "Other kinds are spawned when they first appear, which costs a moment the first time.") {
                Toggle("", isOn: warmBinding)
                    .labelsHidden().toggleStyle(.switch)
                    .disabled(engine.status.quiz.active)
            }
        }
    }

    private func voterRow(profile: QuizModeProfile, index: Int,
                          selection: QuizModelSelection) -> some View {
        SettingRow("Voter \(index + 1)") {
            HStack(spacing: NotchSpace.snug) {
                Picker("Model", selection: Binding(
                    get: { selection.modelID },
                    set: { model in
                        replaceVoter(in: profile, at: index,
                                     with: QuizModelSelection(modelID: model,
                                                              effort: selection.effort))
                    })) {
                        ForEach(modelChoices(including: selection.modelID), id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 215)

                Picker("Effort", selection: Binding(
                    get: { selection.effort },
                    set: { effort in
                        replaceVoter(in: profile, at: index,
                                     with: QuizModelSelection(modelID: selection.modelID,
                                                              effort: effort))
                    })) {
                        Text("Low").tag("low")
                        Text("Medium").tag("medium")
                        Text("High").tag("high")
                    }
                    .labelsHidden()
                    .frame(width: 90)

                Button {
                    update(profile) { current in
                        var voters = current.voters
                        voters.remove(at: index)
                        return QuizModeProfile(voters: voters, arbiter: current.arbiter,
                                               strategy: current.strategy, turbo: current.turbo)
                    }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)
                .disabled(profile.voters.count <= 1 || engine.status.quiz.active)
                .help(profile.voters.count <= 1 ? "A council needs at least one voter"
                      : "Remove this voter")
            }
        }
    }

    private func arbiterPicker(_ arbiter: QuizModelSelection,
                               in profile: QuizModeProfile) -> some View {
        HStack {
            Spacer().frame(width: 16)
            Picker("Arbiter model", selection: Binding(
                get: { arbiter.modelID },
                set: { model in
                    update(profile) {
                        QuizModeProfile(voters: $0.voters,
                                        arbiter: QuizModelSelection(modelID: model,
                                                                    effort: arbiter.effort),
                                        strategy: $0.strategy, turbo: $0.turbo)
                    }
                })) {
                    ForEach(modelChoices(including: arbiter.modelID), id: \.self) {
                        Text($0).tag($0)
                    }
                }
                .labelsHidden()
                .frame(width: 285)
            Spacer()
        }
    }

    private func refinerPicker(_ refiner: QuizModelSelection,
                               in profile: QuizModeProfile) -> some View {
        HStack {
            Spacer().frame(width: 16)
            Picker("Refiner model", selection: Binding(
                get: { refiner.modelID },
                set: { model in
                    update(profile) {
                        QuizModeProfile(voters: $0.voters, arbiter: $0.arbiter,
                                        strategy: $0.strategy, turbo: $0.turbo,
                                        refiner: QuizModelSelection(modelID: model,
                                                                    effort: "high"))
                    }
                })) {
                    ForEach(modelChoices(including: refiner.modelID), id: \.self) {
                        Text($0).tag($0)
                    }
                }
                .labelsHidden()
                .frame(width: 285)
            Spacer()
        }
    }

    private func refinerBinding(_ profile: QuizModeProfile) -> Binding<Bool> {
        Binding(get: { profile.hasRefiner },
                set: { on in
                    update(profile) {
                        QuizModeProfile(
                            voters: $0.voters, arbiter: $0.arbiter, strategy: $0.strategy,
                            turbo: $0.turbo,
                            refiner: on ? QuizModelSelection(modelID: quizArbiter,
                                                             effort: "high") : nil)
                    }
                })
    }

    private func modelChoices(including current: String) -> [String] {
        guard !quizModels.isEmpty else { return [current] }
        return quizModels.contains(current) ? quizModels : [current] + quizModels
    }

    private func strategyDetail(_ strategy: QuizAnswerStrategy, voters: Int) -> String {
        switch strategy {
        case .first:
            "The first answer back wins. No cross-check — the fastest a council can be."
        case .majority:
            "Publishes once \(strategy.requiredAgreement(of: voters)) of \(voters) agree; the rest are cancelled."
        case .unanimous:
            "Every voter must agree, or the arbiter decides."
        }
    }

    private func update(_ profile: QuizModeProfile,
                        _ transform: (QuizModeProfile) -> QuizModeProfile) {
        QuizProfileStore.setProfile(transform(profile), for: editingMode)
    }

    private func replaceVoter(in profile: QuizModeProfile, at index: Int,
                              with selection: QuizModelSelection) {
        update(profile) { current in
            var voters = current.voters
            guard voters.indices.contains(index) else { return current }
            voters[index] = selection
            return QuizModeProfile(voters: voters, arbiter: current.arbiter,
                                   strategy: current.strategy, turbo: current.turbo)
        }
    }

    private func addVoter(to profile: QuizModeProfile) {
        let model = quizModels.first ?? profile.voters.first?.modelID ?? "gemini-3.1-pro-high"
        update(profile) {
            QuizModeProfile(voters: $0.voters + [QuizModelSelection(modelID: model, effort: "high")],
                            arbiter: $0.arbiter, strategy: $0.strategy, turbo: $0.turbo)
        }
    }

    private func strategyBinding(_ profile: QuizModeProfile) -> Binding<QuizAnswerStrategy> {
        Binding(get: { profile.strategy },
                set: { value in
                    update(profile) {
                        QuizModeProfile(voters: $0.voters, arbiter: $0.arbiter,
                                        strategy: value, turbo: $0.turbo)
                    }
                })
    }

    private func arbiterBinding(_ profile: QuizModeProfile) -> Binding<Bool> {
        Binding(get: { profile.hasArbiter },
                set: { on in
                    update(profile) {
                        QuizModeProfile(
                            voters: $0.voters,
                            arbiter: on ? QuizModelSelection(modelID: quizArbiter) : nil,
                            strategy: $0.strategy, turbo: $0.turbo)
                    }
                })
    }

    private var warmBinding: Binding<Bool> {
        Binding(get: { QuizProfileStore.warmMode == editingMode },
                set: { on in if on { quizWarmMode = editingMode.rawValue } })
    }

    private func quizContextRow(id: String, title: String, symbol: String) -> some View {
        let excluded = engine.pendingQuizExcludedContextIDs.contains(id)
        return HStack(spacing: 8) {
            Image(systemName: symbol).frame(width: 14)
            Text(title).font(NotchType.rowTitle).lineLimit(1)
            Spacer()
            Button {
                engine.togglePendingQuizContext(id)
            } label: {
                Label(excluded ? "Excluded" : "Included",
                      systemImage: excluded ? "circle" : "checkmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(excluded ? Color.secondary : NotchTint.healthy)
        }
    }

    private func refreshQuizSetup() {
        let status = engine.status.quiz
        if status.screenRecordingReady || status.accessibilityReady {
            quizPermissions = QuizPermissionReadiness(
                screenRecording: status.screenRecordingReady,
                accessibility: status.accessibilityReady)
        }
        refreshQuizModels()
    }

    private func refreshQuizModels() {
        quizSetupLoading = true
        engine.listQuizModels { values in
            quizModels = values
            quizSetupLoading = false
        }
    }

    private func requestQuizPermissions() {
        quizSetupLoading = true
        engine.requestQuizPermissions { readiness in
            quizPermissions = readiness
            quizSetupLoading = false
        }
    }

    private func openPrivacySettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
