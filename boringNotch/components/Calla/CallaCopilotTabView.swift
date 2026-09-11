//
//  CallaCopilotTabView.swift
//  boringNotch
//
//  The copilot at rest, in the notch.
//
//  A pre-flight check rather than a settings page, because that is the question
//  people bring to it thirty seconds before a call: *will this work?* A copilot
//  that starts and then silently hears only one side is worse than one that
//  refuses to start, so the panel shows what is armed before it offers to begin,
//  and the primary control names whatever is missing instead of always saying
//  "start".
//
//  One card, two columns: the verdict on the left, the four facts behind it on
//  the right. An earlier pass put those facts in a grid *under* the verdict and
//  the whole second row fell through the notch's lower curve — 168pt does not
//  hold three stacked bands, which is why the tab-naming row is gone too.
//

import AppKit
import CallaContracts
import Defaults
import KeyboardShortcuts
import SwiftUI

/// The copilot at rest. Retained interview selections resolve to Live Call
/// while the interview feature is unavailable.
struct CallaCopilotTabView: View {
    @ObservedObject private var engine = CallaEngineClient.shared
    @Default(.callaQuizEnabled) private var quizEnabled
    @Default(.callaPlainCallEnabled) private var plainCallEnabled
    @Default(.callaCopilotMode) private var selectedMode

    var body: some View {
        Group {
            // Resolved rather than read: a mode whose setting has since been
            // switched off must not leave the notch on a surface the switcher
            // no longer offers a way back from.
            switch CallaMode.resolved(selectedMode, plainCall: plainCallEnabled, quiz: quizEnabled) {
            case .quiz: CallaQuizPreflightView()
            case .call: CallaCallPreflightView()
            case .interview: CallaCodingPreflightView()
            }
        }
        .task {
            engine.start()
            engine.startMonitoring()
        }
    }
}

/// The Wave interview, at rest and while it is running.
///
/// At rest this panel asks nothing. Everything a session needs — the project
/// folder and the interview brief — is prepared against the interview in the
/// Knowledge pane and resolved here by `CallaCodingSetupStore`, so the notch
/// names what it found and offers one button.
///
/// It used to ask for all of it here: an `NSOpenPanel` for the folder, a text
/// field for the brief, a second button to load one from a file, four readiness
/// rows, a three-line disclosure and a resume rail — eleven bands on a surface
/// that holds four. The last two were drawn through the notch's lower curve,
/// which is where the Start button was.
///
/// Which meeting this is is no longer one of the questions either. It was
/// resolved from the calendar — the nearest event within an hour that had a
/// setup of its own — so a rehearsal on Sunday resolved nothing and Monday
/// resolved something else, and the two sessions retrieved different knowledge
/// and landed in unrelated rows of History. It is one meeting, always
/// `WaveInterview`, and a session is a session of it.
struct CallaCodingPreflightView: View {
    @ObservedObject private var engine = CallaEngineClient.shared
    @ObservedObject private var library = CallaKnowledgeLibrary.shared
    @ObservedObject private var setups = CallaCodingSetupStore.shared
    @Default(.callaCopilotLiveModel) private var speechModel
    @Default(.callaCopilotMode) private var selectedMode
    @Default(.callaQuizEnabled) private var quizEnabled
    @Default(.callaPlainCallEnabled) private var plainCallEnabled
    @Default(.callaWaveSession) private var storedSession

    private var session: WaveInterview.Session { WaveInterview.Session.stored(storedSession) }

    @State private var windowMenuRequest = 0
    @State private var starting = false
    @State private var failure: String?

    private var call: CallaCopilotStatus { engine.status.copilot }
    private var coding: CodingSessionSnapshot { engine.coding }
    var body: some View {
        Group {
            if coding.lifecycle.active {
                LiveCodingViewport()
            } else {
                preflight
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .callaCodingAction)) { event in
            if event.object as? String == "window", !coding.lifecycle.active, !starting { windowMenuRequest += 1 }
        }
        .task {
            engine.start()
            engine.startMonitoring()
            engine.fetchRetainedCodingSessions()
            if library.events.isEmpty { await library.load() }
        }
        // The 45-second guard below is the backstop, not the release. Without
        // this the button reads "Starting…" from the moment the shadow is being
        // built until the timeout fires, on a session that is already running.
        .onChange(of: coding.lifecycle) { _, value in
            if value.active { starting = false; failure = nil }
            else {
                starting = false
                engine.fetchRetainedCodingSessions()
                if value == .failed { failure = coding.failure?.message }
            }
        }
    }

    // MARK: - At rest

    /// The setup this session runs on.
    ///
    /// Filed against the interview first, then the `always` row. Two rows
    /// rather than one because the folder is expected to change: pointing the
    /// `always` row at a scratch copy to try a scenario must not disturb what
    /// was prepared for the interview itself, and neither choice changes which
    /// meeting the session belongs to.
    private var setup: CallaCodingSetup? {
        if let filed = setups.setup(scope: WaveInterview.setupScope,
                                    scopeKey: WaveInterview.setupScopeKey), filed.hasFolder {
            return filed
        }
        if let fallback = setups.fallback, fallback.hasFolder { return fallback }
        // Anything else that names a folder, newest first. A project prepared
        // against some other scope is still the project; refusing to find it
        // and saying "No project set up yet" over a folder that is right there
        // is the worse failure.
        return setups.setups.filter(\.hasFolder).max { $0.updatedAt < $1.updatedAt }
            ?? setups.setup(scope: WaveInterview.setupScope, scopeKey: WaveInterview.setupScopeKey)
            ?? setups.fallback
    }

    /// What has been filed against the interview, for the readiness row. Notes
    /// reach the call through the meeting scope, not through a picker here.
    private var meetingNotes: [CallaKnowledgeNote] {
        library.notes.filter { note in
            note.scope == "series" && note.scopeKey == WaveInterview.seriesID
                || note.scope == "event" && note.scopeKey == WaveInterview.eventID
        }
    }

    private var preflight: some View {
        CallaPreflightCard(
            state: starting ? "Starting" : (session.isRehearsal ? "Rehearsal" : "Ready"),
            live: false,
            tint: .effectiveAccent,
            mode: $selectedMode,
            switcherEnabled: !call.running && !engine.status.quiz.active && !starting,
            includesQuiz: quizEnabled,
            includesPlainCall: plainCallEnabled,
            headline: headline,
            headlineTint: blockers.isEmpty && setup?.hasFolder == true
                ? NotchInk.primary : NotchTint.attention,
            detail: detail,
            checks: checks,
            context: { meetingChip },
            controls: { controls },
            utility: {
                NotchGlyphButton(symbol: "gearshape", help: "Set up Live Coding") {
                    openSetup()
                }
            })
    }

    /// Names the meeting, and which run of it this is.
    ///
    /// There is only one meeting, so the menu is not a meeting picker. What it
    /// does decide is the thing worth being able to see without remembering:
    /// whether the next Start is a rehearsal or the interview itself.
    private var meetingChip: some View {
        CallaContextChip(title: session.chipTitle,
                         symbol: session.isRehearsal ? "figure.run" : "calendar") {
            Text(WaveInterview.detail)
            Divider()
            ForEach(WaveInterview.Session.allCases) { option in
                Button {
                    engine.setWaveSession(option)
                } label: {
                    Label(option.title, systemImage: option == session ? "checkmark" : "")
                }
                .disabled(!engine.canChangeWaveSession)
            }
            Divider()
            Button("Set up the interview…") { openSetup() }
            Button("Add notes or files…") {
                SettingsWindowController.shared.showCopilotWindow(tab: "CopilotKnowledge")
            }
        }
        .help(session.detail)
    }

    private var headline: String {
        if let failure { return failure }
        guard let setup, setup.hasFolder else { return "No project set up yet" }
        return setup.folderName
    }

    private var detail: String {
        if failure != nil { return "Set the project up again in Knowledge." }
        guard let setup, setup.hasFolder else {
            return "Attach the project folder in Live Coding settings."
        }
        var parts: [String] = []
        if let live = engine.codingPreflight, live.folderName == setup.folderName {
            if let branch = live.branch { parts.append(branch + (live.dirty ? " (dirty)" : "")) }
            if !live.languages.isEmpty { parts.append(live.languages.joined(separator: ", ")) }
            parts.append("\(live.fileCount) files")
        } else {
            parts.append(setup.folderSummary)
        }
        if let brief = setup.brief { parts.append(brief.title) }
        return parts.joined(separator: " · ")
    }

    /// What would stop Start working, in the order worth fixing.
    private var blockers: [String] {
        var found: [String] = []
        if call.hostPermissionsKnown, !call.hostMicGranted { found.append("Microphone") }
        if call.hostPermissionsKnown, !call.hostScreenGranted { found.append("Other side") }
        if !call.agyLoggedIn { found.append("Agy") }
        return found
    }

    private var checks: [CallaCheck] {
        [
            CallaCheck("Microphone", symbol: call.hostMicGranted ? "mic.fill" : "mic.slash.fill",
                       value: call.hostPermissionsKnown
                        ? (call.hostMicGranted ? "allowed" : "not allowed") : "not checked yet",
                       state: call.hostPermissionsKnown
                        ? (call.hostMicGranted ? .ready : .blocking) : .unknown),
            CallaCheck("Other side", symbol: "speaker.wave.2.fill",
                       value: call.hostPermissionsKnown
                        ? (call.hostScreenGranted ? "captured" : "not captured") : "not checked yet",
                       state: call.hostPermissionsKnown
                        ? (call.hostScreenGranted ? .ready : .blocking) : .unknown),
            CallaCheck("Agy", symbol: "sparkles",
                       ready: call.agyLoggedIn, yes: "signed in", no: "signed out"),
            CallaCheck("Project", symbol: "folder.fill",
                       value: setup?.hasFolder == true ? (setup?.folderName ?? "attached") : "not set up",
                       state: setup?.hasFolder == true ? .ready : .blocking),
            // Not blocking: an interview with nothing attached still runs. It
            // is here because "the copilot did not know about my CV" is only
            // answerable before the call, and this is the last screen before it.
            CallaCheck("Context", symbol: "paperclip",
                       value: meetingNotes.isEmpty
                        ? "nothing attached"
                        : "\(meetingNotes.count) attached",
                       state: meetingNotes.isEmpty ? .unknown : .ready)
        ]
    }

    @ViewBuilder private var controls: some View {
        CodingWindowTargetMenu(target: setup?.observationTarget,
            shortcut: KeyboardShortcuts.getShortcut(for: .sessionTarget)?.description ?? "Unset",
            openRequest: windowMenuRequest) { window in
                var selected = setup ?? CallaCodingSetup(scope: "always")
                selected.observationTarget = window
                setups.save(selected)
            }
            .disabled(starting)

        if setup?.hasFolder != true {
            CallaPrimaryButton(title: "Set up…", symbol: "folder.badge.plus",
                               tint: NotchTint.attention) { openSetup() }
        } else if !call.agyLoggedIn {
            CallaPrimaryButton(title: "Sign in", symbol: "person.badge.key.fill",
                               tint: NotchTint.attention) { engine.loginAgy() }
        } else {
            if let retained = engine.retainedCodingSessions.first {
                NotchChip(action: {
                    engine.resumeCodingInterview(sessionID: retained.sessionID,
                                                 speechModel: speechModel)
                }) {
                    Image(systemName: "arrow.uturn.backward").font(NotchGlassType.glyph)
                    Text("Resume")
                }
                .help("Resume \(retained.folderName)")
            }
            CallaPrimaryButton(title: starting ? "Starting…" : "Start",
                               symbol: starting ? "circle.dotted" : "chevron.left.forwardslash.chevron.right",
                               enabled: !starting) { begin() }
        }
    }

    /// Straight to the Live Coding pane, which owns the project, the brief and
    /// the supplied-material intake. Landing on an index and asking the reader
    /// to find the right row again is how a "set this up" button gets ignored.
    private func openSetup() {
        SettingsWindowController.shared.show(route: SettingsRoute(.copilot, [.copilotCoding]))
    }

    /// Mints the engine's folder capability from the stored bookmark, then
    /// starts. The capability lives in the XPC process and dies with it, which
    /// is exactly why the durable half is the bookmark and this happens now
    /// rather than when the folder was chosen.
    private func begin() {
        guard let setup, setup.hasFolder else { return }
        guard let resolved = CallaCodingSetupStore.shared.resolveFolder(setup) else {
            failure = "The project folder could not be opened"
            return
        }
        starting = true
        failure = nil
        engine.registerCodingFolder(resolved.url) { preflight in
            resolved.release()
            guard let preflight, preflight.folderReadable, preflight.shadowReady else {
                starting = false
                failure = "The project folder could not be prepared"
                return
            }
            engine.startCodingInterview(capabilityID: preflight.capabilityID,
                                        brief: setup.brief,
                                        speechModel: speechModel,
                                        observationTarget: setup.observationTarget) { snapshot in
                // Show the engine's own reason instead of waiting out the timer.
                guard let message = snapshot?.failure?.message else { return }
                starting = false
                failure = message
            }
        }
        // A proxy that neither replies nor errors would otherwise leave the
        // button reading "Starting…" for ever, with no way back. Quiz guards its
        // launch the same way.
        Task {
            try? await Task.sleep(for: .seconds(45))
            guard starting, !engine.coding.lifecycle.active else { starting = false; return }
            starting = false
            if failure == nil { failure = "Live Coding did not start in time" }
        }
    }

}

extension Notification.Name {
    static let callaCodingAction = Notification.Name("callaCodingAction")
    static let callaCodingCopy = Notification.Name("callaCodingCopy")
    static let callaCodingPrevious = Notification.Name("callaCodingPrevious")
    static let callaCodingNext = Notification.Name("callaCodingNext")
    static let callaCodingScroll = Notification.Name("callaCodingScroll")
}

/// The personas the gateway flow ships, and their display names.
enum CallaCopilotPersona {
    /// Seeded by the gateway. Their guidance text can be edited in settings;
    /// their ids cannot, because the gateway's own allowlist knows them.
    static let builtIn = ["generic", "interview", "sales", "support"]

    static let all = builtIn

    /// The built-ins plus whatever the user added, in a stable order.
    static func all(including custom: [String]) -> [String] {
        builtIn + custom.filter { !builtIn.contains($0) }.sorted()
    }

    static func title(_ value: String) -> String {
        switch value {
        case "generic": return "General"
        case "interview": return "Interview"
        case "sales": return "Sales"
        case "support": return "Support"
        default:
            // A user-defined id like `board-review` reads as "Board review".
            return value
                .replacingOccurrences(of: "-", with: " ")
                .prefix(1).uppercased()
                + value.replacingOccurrences(of: "-", with: " ").dropFirst()
        }
    }

    /// Ids the user may create. Kept allowlist-shaped even though the guidance
    /// body is free text: an id can end up naming things, a paragraph cannot.
    static func isValidCustomID(_ value: String) -> Bool {
        !builtIn.contains(value)
            && value.range(of: "^[a-z0-9-]{1,24}$", options: .regularExpression) != nil
    }
}

/// A sentence with its code drawn as code.
///
/// The panel's prose is full of symbols, cell references and literals, and in a
/// proportional face they disappear into the words around them — which is most
/// of the reading cost when you look up mid-sentence. Monospaced and tinted
/// with the roles the code block already uses, so `A1` looks the same here as
/// it does in a diff.
///
/// One `Text` built by concatenation rather than a stack of views, so the line
/// still wraps, truncates and selects as a single sentence.
struct CodingProseText: View {
    private let sentence: String
    private let base: Font
    /// The point size of `base`. Passed rather than derived because `Font` does
    /// not expose one, and the code face has to be sized against it.
    private let size: CGFloat
    private let plain: Color
    private let codeWeight: Font.Weight

    init(_ sentence: String, base: Font, size: CGFloat, plain: Color,
         codeWeight: Font.Weight = .regular) {
        self.sentence = sentence
        self.base = base
        self.size = size
        self.plain = plain
        self.codeWeight = codeWeight
    }

    var body: some View {
        let spans = CodingProseSpan.spans(in: sentence)
        // Ordinary prose costs nothing: no spans to walk, no attributed text.
        if spans.count <= 1 {
            Text(sentence).font(base).foregroundStyle(plain)
        } else {
            spans.reduce(Text("")) { text, span in
                text + Text(span.text)
                    .font(span.isCode ? codeFont : base)
                    .foregroundColor(color(for: span.role))
            }
            .font(base)
            .foregroundStyle(plain)
        }
    }

    /// Slightly smaller than the prose around it: a monospaced face at the same
    /// point size reads as larger, and the line's rhythm breaks.
    private var codeFont: Font {
        .system(size: size * 0.92, weight: codeWeight, design: .monospaced)
    }

    /// The roles the code block already paints, so the notch keeps one palette
    /// rather than growing a second one for prose.
    ///
    /// These used to be `.effectiveAccent`, `NotchTint.healthy` and
    /// `NotchTint.attention` — the user's system accent, system green and
    /// system orange. Three hues from outside this pane, in a pane whose code
    /// plane is deliberately muted, and the accent one landed inside a bold
    /// white headline where a saturated blue `parse()` is the loudest thing on
    /// screen and not the most important. So an identifier is drawn in the
    /// plane's own plain ink and distinguished by the monospaced face alone:
    /// the face is what says "this is code", and it does not have to shout to
    /// say it. Literals keep a tint because a value is worth finding in a
    /// sentence, but the plane's tints, not the status ones.
    private func color(for role: CodingProseSpan.Role) -> Color {
        switch role {
        case .text: plain
        case .identifier: CodingCodeInk.plain
        case .string: CodingCodeInk.string
        case .number: CodingCodeInk.number
        }
    }
}

/// One stable reading plane. Native scrolling retains exact offsets per item,
/// including partially visible wrapped lines, when an answer interrupts code.
struct LiveCodingViewport: View {
    @ObservedObject private var session = CopilotLiveSession.shared
    @State private var heldFlow: CodingInterviewFlowState?
    @State private var heldDocument: CodingReadingDocument?
    @State private var heldFile: String?
    @ObservedObject private var engine = CallaEngineClient.shared
    @State private var surface: WaveSurface = .coding
    @State private var held = false
    @State private var unread = 0
    @State private var browsingMoves = false
    @State private var windowMenuRequest = 0
    @State private var windowError: String?
    @State private var displayedMove: CodingMove?
    @State private var answers: [CallAnswer] = []
    @State private var answerID: String?
    @State private var offsets: [String: Double] = [:]
    @State private var showingKeys = false
    @State private var showingAppearance = false
    @State private var lastEventSequence = -1
    @State private var pendingQuestion: CallQuestion?
    @State private var pendingAnswer: CallAnswer?
    @State private var pendingMove: CodingMove?
    @State private var transcript: [CallaCallTurn] = []
    private var coding: CodingSessionSnapshot { engine.coding }
    private var answer: CallAnswer? { answers.first { $0.id == answerID } }
    private var move: CodingMove? {
        guard let displayedMove else { return nil }
        return coding.interviewFlow.map { CodingInterviewPublication.screen(displayedMove, flow: $0) } ?? displayedMove
    }
    private var readingKey: String {
        switch surface {
        case .coding: "code:\(move?.id ?? coding.wave?.currentTaskID ?? "initial")"
        case .answer: "answer:\(answerID ?? "waiting")"
        case .history: "history"
        case .transcript: "transcript"
        case .evidence: "evidence"
        }
    }
    var body: some View {
        viewportWithDialogs
        .onAppear { displayedMove = coding.activeMove; consumeEvents(); restoreHistory(); session.codingHeld = held }
        .onDisappear { session.codingHeld = false }
        .onChange(of: engine.liveCallEvents.count) { _, _ in consumeEvents() }
        .onChange(of: engine.liveCallEvents.last?.id) { _, _ in consumeEvents() }
        .onChange(of: coding.activeMove) { _, fresh in
            if held || surface != .coding || browsingMoves { pendingMove = fresh; unread += 1 }
            else { displayedMove = fresh }
        }
        .onChange(of: coding.interviewFlow?.foregroundQuestionID) { old, fresh in
            if old != nil, fresh == nil, !held { returnToCoding() }
        }
        .onChange(of: coding.wave?.surface) { _, fresh in
            if fresh == .coding, !held { returnToCoding() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .callaCallAskQuestion)) { _ in openQuestion() }
        .onReceive(NotificationCenter.default.publisher(for: .callaCallToggleSurface)) { _ in
            guard !held else { return }; showingKeys = false
            if surface == .coding { surface = .history } else { returnToCoding() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .callaCallPreviousAnswer)) { _ in browseAnswer(-1) }
        .onReceive(NotificationCenter.default.publisher(for: .callaCallNextAnswer)) { _ in browseAnswer(1) }
        .onReceive(NotificationCenter.default.publisher(for: .callaCodingAction), perform: handleCodingAction)
        .onReceive(NotificationCenter.default.publisher(for: .callaCodingCopy)) { _ in copyDisplayed() }
        .onReceive(NotificationCenter.default.publisher(for: .callaCodingPrevious)) { _ in browseMove(-1) }
        .onReceive(NotificationCenter.default.publisher(for: .callaCodingNext)) { _ in browseMove(1) }

    }

    private var viewportWithDialogs: some View {
        viewportLayout
        .popover(isPresented: $showingAppearance) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Wave glass").font(.headline)
                Slider(value: Binding(get: { Defaults[.waveGlassLevel] }, set: { Defaults[.waveGlassLevel] = $0 }), in: 0...1)
                Text("Clear text stays fully opaque.").font(.caption).foregroundStyle(.secondary)
            }.padding().frame(width: 240)
        }
    }

    /// The panel: almost all of it is the step.
    ///
    /// What was here spent four rows on chrome before any content — a status
    /// row repeating the band above it, Hold and Compact as 30pt chips, a
    /// full-width file row, and five more chips along the bottom — around a
    /// card that got what was left. The session controls live in the band now
    /// (`CallaCopilotLiveHeader`), the file moved into the step's own meta line,
    /// and the keys are one 16pt hint row, the way Quiz has always shown them.
    private var viewportLayout: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 8) {
            CodingReadingPane(document: heldDocument ?? document, compact: compact, offsets: $offsets)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // About the code, so it sits with the code rather than in the
            // conversation lines below.
            if !compact, let watch = (held ? heldDocument.flatMap { _ in move?.watch } : move?.watch),
               !watch.isEmpty {
                guidance("Watch", watch, tint: NotchTint.attention, weight: .regular)
            }

            // What to say, and the one line that defends it. Two lines, in
            // reading order, where the reader looks up from typing.
            if let flow = held ? heldFlow : coding.interviewFlow {
                guidance("Say", flow.sayNext, tint: accent, weight: .medium)
            }
            if !compact, let supporting = supportingLine {
                guidance("Why", supporting, tint: NotchInk.tertiary, weight: .regular)
            }

            NotchSessionHints(surface: .coding, limit: compact ? 4 : 5)
        }
        .foregroundStyle(NotchInk.primary)
        .padding(.horizontal, compact ? 12 : 16)
        .padding(.top, compact ? 2 : 6)
        .padding(.bottom, compact ? 4 : 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A limitation outranks a justification: a caveat about what the step does
    /// not do is worth more mid-interview than the reason it was chosen.
    ///
    /// It falls back to the step's `why` only when the reading pane is showing
    /// code. On a step with no code the pane already prints `why` in full, and
    /// repeating it here — truncated to one line, immediately below itself —
    /// was most of why the panel read as undifferentiated.
    private var supportingLine: String? {
        let flow = held ? heldFlow : coding.interviewFlow
        if let limitation = flow?.limitation, !limitation.isEmpty { return limitation }
        guard document.blocks == nil, let why = move?.why, !why.isEmpty else { return nil }
        return why
    }

    /// One labelled line. Caps label, then the sentence, both on one row so the
    /// panel's height does not move when a field is absent.
    private func guidance(_ label: String, _ text: String,
                          tint: Color, weight: Font.Weight) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label.uppercased())
                .font(NotchGlassType.caps)
                .tracking(notchCapsTracking)
                .foregroundStyle(tint)
                .fixedSize()
            CodingProseText(text,
                            base: (compact ? NotchGlassType.caption : NotchGlassType.detail)
                                .weight(weight),
                            size: compact ? 10 : 11,
                            plain: label == "Say" ? NotchInk.primary : NotchInk.secondary,
                            codeWeight: weight)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(text)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(text)")
    }

    private func handleCodingAction(_ event: Notification) {
            let action = event.object as? String
            if action == "hold" { toggleHold(); return }
            if action == "end" { send(.end); engine.endCall(); return }
            if action == "window" { windowMenuRequest += 1; return }
            if action == "explain" { explainDisplayed(); return }
            guard !held else { return }
            if action != "keys", action != "advance" { showingKeys = false }
            switch action {
            case "advance": advanceOrReturn()
            case "transcript": surface = .transcript; engine.fetchTranscript(since: nil) { transcript = $0 }
            case "evidence": surface = .evidence
            case "keys": showingKeys.toggle()
            default: break
            }
    }

    private let accent = Color(red: 0.52, green: 0.9, blue: 0.78)
    private var compact: Bool { session.layout == .compact }
    private func windowMenu(compact: Bool) -> some View {
        CodingWindowTargetMenu(target: coding.observationTarget, compact: compact,
            shortcut: keyText(.sessionTarget), openRequest: windowMenuRequest,
            error: windowError) { target in
                guard let id = coding.sessionID, let callID = coding.callID else { return }
                windowError = nil
                let generation = coding.generation
                var command = CodingCommand(sessionID: id, callID: callID, generation: generation, kind: .selectWindow)
                command.observationTarget = target
                engine.sendCoding(command) { result in
                    guard coding.sessionID == id, coding.generation == generation else { return }
                    if result?.observationTarget != target || result == nil {
                        windowError = "The window change was not accepted. Refresh and try again."
                    }
                }
            }
    }
    private var primaryTitle: String { showingKeys || surface != .coding ? "Return" : "Next" }
    private func keyText(_ name: KeyboardShortcuts.Name) -> String {
        KeyboardShortcuts.getShortcut(for: name)?.description ?? "Unset"
    }
    private func keyLabel(_ title: String, _ name: KeyboardShortcuts.Name) -> some View {
        VStack(spacing: 0) {
            Text(title).font(.system(size: compact ? 9 : 10, weight: .medium))
            Text(keyText(name)).font(.system(size: compact ? 8 : 9, design: .monospaced)).foregroundStyle(.white.opacity(0.72))
        }.fixedSize().accessibilityLabel(title + ", " + keyText(name))
    }
    private func openQuestion() { send(.armSpokenQuestion) }
    private func explainDisplayed() {
        guard let id = coding.sessionID, let callID = coding.callID else { return }
        let item = heldDocument ?? document
        engine.sendCoding(.init(sessionID: id, callID: callID, generation: coding.generation,
            kind: .explainDisplayed, transcript: item.title + "\n" + String(item.content.string.prefix(800))))
    }
    private func browseAnswer(_ delta: Int) {
        guard !held, !answers.isEmpty else { return }
        let current = answers.firstIndex { $0.id == answerID } ?? (delta < 0 ? answers.count : -1)
        answerID = answers[min(max(0, current + delta), answers.count - 1)].id
        showingKeys = false; surface = .answer
    }
    private var shortcutReference: NSAttributedString {
        let entries: [(String, KeyboardShortcuts.Name)] = [
            ("Select working window", .sessionTarget), ("Expand / compact", .copilotToggleLayout), ("Hold / resume", .sessionHold),
            ("Next step / return", .sessionAdvance), ("Previous step", .sessionPrevious),
            ("Next saved step", .sessionNext), ("Scroll up", .sessionScrollUp), ("Scroll down", .sessionScrollDown),
            ("Copy code / answer", .sessionCopy), ("Run / stop check", .sessionRun),
            ("Ask a question", .sessionAsk), ("Explain more", .sessionExplain),
            ("History / return", .sessionSurface), ("Previous answer", .sessionPrevious), ("Next answer", .sessionNext),
            ("Transcript", .sessionTranscript), ("Why and checks", .sessionEvidence),
            ("Shortcut reference", .sessionShortcutHelp), ("End interview", .copilotToggleCall)
        ]
        return NSAttributedString(string: entries.map { keyText($0.1) + "   " + $0.0 }.joined(separator: "\n"),
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.white])
    }
    private var document: CodingReadingDocument {
        if showingKeys {
            return .init(identity: "shortcuts", title: "Keyboard shortcuts · scroll to see all",
                         eyebrow: "KEYS", content: shortcutReference, code: nil,
                         patch: nil, placement: nil)
        }

        let patch = surface == .coding ? move.flatMap(CodingPatchPresentation.display(for:)) : nil
        let title: String
        switch surface {
        case .coding: title = move?.say ?? "Listening for your next step"
        case .answer: title = answer?.question ?? pendingQuestion?.prompt ?? "Your question"
        case .history: title = "Answer history"
        case .transcript: title = "Conversation"
        case .evidence: title = "Why & checks"
        }
        return CodingReadingDocument(identity: readingKey, title: title,
            eyebrow: surface == .coding ? codingEyebrow : (surface == .answer ? "CALL ANSWER" : "REFERENCE"),
            content: readingContent,
            code: surface == .coding ? move.flatMap(CodingPatchPresentation.copyableText(for:)) : nil,
            patch: patch,
            blocks: surface == .coding && patch == nil ? codingBlocks : nil,
            // Only when there is somewhere for the step to land. "Placement
            // pending" was drawn against every step that had no file at all —
            // including the ones that are a sentence and were never going to
            // have one — where it read as something being broken.
            // Shown on any step that names a file, not only one carrying code.
            // An explanation about `_evaluate` is worth twice as much when it
            // also says which file and symbol it is about — that was already
            // computed and thrown away for every step without a patch.
            placement: CodingPatchPresentation.placement(for: move?.file, short: true))
    }

    /// A step with no code: the reason, then what is still uncovered.
    private var codingBlocks: [CodingProseBlock] {
        var blocks: [CodingProseBlock] = []
        func add(_ kind: CodingProseBlock.Kind, _ text: String?) {
            guard let text, !text.isEmpty else { return }
            blocks.append(CodingProseBlock(id: blocks.count, kind: kind, text: text))
        }

        // The reasoning is a *list*. `publishFlowPointer` builds `why` by
        // joining the pointers after the headline with newlines, so what
        // arrives here is two or three separate points — and drawing them as
        // one `lead` ran them together into a paragraph that has to be read
        // rather than scanned. Mid-interview the reader is glancing up between
        // sentences, and a bullet each is the difference between finding your
        // next point and re-reading the box.
        //
        // A single line stays prose: one bullet is not a list, and a coder's
        // paragraph of justification is not one either.
        let reasoning = (move?.why).map(CodingPatchPresentation.reasoningLines) ?? []
        if reasoning.count > 1 {
            for line in reasoning { add(.item, line) }
        } else {
            add(.lead, reasoning.first ?? move?.why)
        }
        // A background failure only appears when there is nothing else to show.
        //
        // These are transient and self-healing — a worker times out, a tool is
        // refused, the next turn succeeds — and none of them is something the
        // candidate can act on while someone is waiting for them to speak.
        // Printing them under the reasoning meant a recovered run still left
        // "The coding response exceeded its time budget" sitting in the one
        // pane read mid-sentence, pushing the actual step off the bottom. The
        // reasoning that is still on screen is worth more than the news that a
        // background job had to retry.
        if blocks.isEmpty, let failure = coding.failure {
            // Two blocks, not one string. They were concatenated with a space,
            // which ran the problem and the way out together into
            // "…exceeded its time budget Please repeat that point to retry."
            add(.notice, failure.message)
            add(.noticeDetail, failure.recovery)
        }
        // The uncovered brief is not here any more.
        //
        // It is a reference — four items you check between steps — and it was
        // stacked under the reasoning in the one pane read mid-sentence, where
        // it pushed the reasoning up and got clipped by the panel's own bottom
        // edge anyway: "STILL TO COVER" with its list cut off says less than
        // nothing. It lives on the reference surface (⇧⌥⌘E), whole, where there
        // is room to read it.
        return blocks
    }

    /// The step number, and how much of the brief is still uncovered. Coverage
    /// is a fact about the run rather than part of the step, so it belongs in
    /// this line rather than in the prose the reader is trying to read.
    private var codingEyebrow: String {
        var parts = [move.map { "STEP \($0.ordinal)" } ?? "READY"]
        let flow = held ? heldFlow : coding.interviewFlow
        let pending = flow?.pending.filter { $0.completedEvidence == nil && $0.required }.count ?? 0
        if pending > 0 { parts.append("\(pending) TO COVER") }
        return parts.joined(separator: " · ")
    }
    private var moveHistory: [CodingMove] {
        var latest: [String: CodingMove] = [:]
        for item in engine.codingEvents.compactMap(\.move) { latest[item.id] = item }
        return latest.values.sorted { $0.ordinal < $1.ordinal }
    }
    private func browseMove(_ delta: Int) {
        guard !held, !moveHistory.isEmpty else { return }
        let index = moveHistory.firstIndex { $0.id == move?.id } ?? moveHistory.count - 1
        let selected = min(max(0, index + delta), moveHistory.count - 1)
        displayedMove = moveHistory[selected]
        browsingMoves = selected < moveHistory.count - 1
        if !browsingMoves { pendingMove = nil; unread = 0 }
        showingKeys = false; surface = .coding
    }
    private func copyDisplayed() {
        let item = heldDocument ?? document
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.code ?? item.content.string, forType: .string)
    }
    private func returnToCoding() {
        // Restore the exact unfinished step first. Future proposals remain in history.
        showingKeys = false; surface = .coding; unread = 0
    }
    private func advanceOrReturn() {
        if showingKeys { showingKeys = false; return }
        if surface != .coding { returnToCoding(); send(.waveReturn); return }
        if let pendingMove, pendingMove.code == nil { displayedMove = pendingMove; self.pendingMove = nil; browsingMoves = false; unread = 0 }
        send(.waveContinue)
    }
    private var filePlacement: String {
        guard let file = move?.file else { return coding.wave?.currentTask?.title ?? "Confirm the target file before editing" }
        return file.path + (file.symbol.map { " · \($0)" } ?? "")
    }
    private var runActive: Bool { engine.codingEvents.compactMap(\.run).last?.lifecycle == .running }
    private func send(_ kind: CodingCommandKind) {
        guard let id = coding.sessionID, let callID = coding.callID else { return }
        engine.sendCoding(.init(sessionID: id, callID: callID, generation: coding.generation, kind: kind))
    }
    private func toggleHold() {
        if !held { heldDocument = document; heldFile = filePlacement; heldFlow = coding.interviewFlow }
        else { heldDocument = nil; heldFile = nil; heldFlow = nil }
        held.toggle()
        session.codingHeld = held
        send(held ? .waveHold : .waveResume)
        if !held {
            if let pendingAnswer { answerID = pendingAnswer.id; pendingQuestion = nil; surface = .answer }
            else if pendingQuestion != nil { answerID = nil; surface = .answer }
            else if surface == .coding, let pendingMove { displayedMove = pendingMove }
            pendingAnswer = nil; pendingMove = nil; unread = 0
        }
    }
    private func consumeEvents() {
        for event in engine.liveCallEvents where event.callID == coding.callID
                && event.generation == coding.generation && event.sequence > lastEventSequence {
            lastEventSequence = event.sequence
            if let fresh = event.answer, !answers.contains(where: { $0.id == fresh.id }) {
                answers.append(fresh)
                if held { pendingAnswer = fresh; unread += 1 }
                else { answerID = fresh.id; pendingQuestion = nil; surface = .answer }
            }
            if let question = event.question, let id = coding.sessionID, let callID = coding.callID {
                var command = CodingCommand(sessionID: id, callID: callID, generation: coding.generation, kind: .waveQuestion)
                command.questionID = question.id.uuidString
                engine.sendCoding(command)
                if !answers.contains(where: { $0.questionID == question.id }), question.state != .answered {
                    pendingQuestion = question
                    if held { unread += 1 }
                    else { answerID = nil; surface = .answer }
                }
            }
        }
    }
    private func restoreHistory() {
        guard let callID = coding.callID else { return }
        engine.fetchCallSuggestions(callID) { stored in
            guard answers.isEmpty else { return }
            answers = stored.enumerated().map { index, row in
                var result = CallAnswer(legacyID: "archive-\(index)", callID: callID,
                    afterSeq: row.afterSeq, headline: row.headline, angles: row.angles,
                    confirm: row.confirm, latencyMs: row.latencyMs ?? 0, at: Date())
                result.question = row.question ?? result.question
                return result
            }
        }
    }
    private var readingContent: NSAttributedString {
        let result = NSMutableAttributedString()
        func prose(_ text: String?, bold: Bool = false) {
            guard let text, !text.isEmpty else { return }
            let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 2; paragraph.paragraphSpacing = 6
            result.append(NSAttributedString(string: text + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: bold ? .semibold : .regular),
                .foregroundColor: NSColor.white, .paragraphStyle: paragraph]))
        }
        switch surface {
        case .coding:
            // Only what has nowhere better to be. Say next, Why and Watch are
            // drawn around the pane; Check is the Run key. What is left is the
            // uncovered brief, and a step with no code at all — where this
            // prose is the whole panel rather than a tail on the code.
            if move?.code == nil, move?.patch == nil, let why = move?.why, !why.isEmpty {
                prose(why)
            }
            if let flow = held ? heldFlow : coding.interviewFlow {
                let pending = flow.pending.filter { $0.completedEvidence == nil }
                if !pending.isEmpty {
                    // Whole, not the first four: this is the surface with room,
                    // and a truncated checklist is what the coding pane already
                    // could not do well.
                    prose("Still to cover", bold: true)
                    for item in pending {
                        prose(item.text + (item.required ? "" : " (optional)"))
                    }
                }
            }
            if let failure = coding.failure {
                prose(failure.message)
                if let recovery = failure.recovery { prose(recovery) }
            }
        case .answer:
            prose(CodingInterviewPublication.prose(answer?.main) ?? "Waiting for Call’s answer…", bold: true)
            for point in answer?.points ?? [] { prose(CodingInterviewPublication.prose(point)) }
            prose(CodingInterviewPublication.prose(answer?.warning))
            if let answer, !answer.citations.isEmpty { prose(answer.citations.map(\.label).joined(separator: " · ")) }
        case .history:
            for item in answers.reversed() { prose(item.question, bold: true); prose(CodingInterviewPublication.prose(item.main)); item.points.forEach { prose(CodingInterviewPublication.prose($0)) } }
            if answers.isEmpty { prose("No answers yet.") }
        case .transcript:
            for turn in transcript { prose("\(turn.isRemote ? "Them" : "Me"): \(turn.text)") }
            let last = transcript.last?.seq ?? -1
            for event in engine.liveCallEvents {
                if let turn = event.transcript, turn.transcriptSequence > last { prose("\(turn.source): \(turn.text)") }
            }
        case .evidence:
            if let failure = coding.failure { prose(failure.message, bold: true); prose(failure.recovery) }
            prose(move?.say, bold: true)
            prose(move?.why)
            prose(move?.watch)
            if let check = move?.check { prose("Suggested check: " + check.displayedCommand) }
            prose("Checks run in the private shadow project", bold: true)
            prose("These results do not establish that your current saved code passes.")
            for run in engine.codingEvents.compactMap(\.run).filter({ $0.lifecycle != .running }) {
                prose("\(run.lifecycle.rawValue) · \(run.displayedCommand)", bold: true)
                prose("Source revision: \(run.evidenceRevision)")
                prose(run.outputSummary)
            }
        }
        return result
    }
}

// MARK: - Live coding reading surface (also used by the visual acceptance renderer)
/// One piece of the short prose surfaces.
///
/// The coding panel's non-code state was one `NSAttributedString` at a single
/// size: a why, a bold "Still to cover", and the uncovered items all ran
/// together as a wall of 12pt paragraphs with no way to tell a heading from an
/// item. Structure it here and the view can draw each part as what it is.
struct CodingProseBlock: Identifiable, Equatable {
    /// `notice` is drawn as an interruption rather than as more reasoning.
    /// A background failure used to be appended as another `lead`, in the same
    /// weight and colour as the model's own explanation, directly under it —
    /// so "AGY attempted a disallowed tool" read as part of the argument for
    /// the step.
    enum Kind: Equatable { case lead, notice, noticeDetail, separator, sectionLabel, item }
    let id: Int
    let kind: Kind
    let text: String
}

struct CodingReadingDocument {
    var identity: String
    var title: String
    var eyebrow: String
    /// Prose, for the surfaces that are prose. `nil` code means this is what
    /// gets drawn.
    var content: NSAttributedString
    var code: String?
    /// A step, laid out. When this is set the pane draws it instead of
    /// `content`, and the guidance that used to be appended to `content` is
    /// drawn by the viewport around the pane.
    var patch: CodingPatchDisplay?
    /// Short, structured prose — the step that carries no code. Long scrolling
    /// surfaces (the transcript, history, evidence) keep `content`, because the
    /// text view behind it is what preserves their read position.
    var blocks: [CodingProseBlock]?
    var placement: String?
}

struct CodingControlStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var emphasized = false
    var destructive = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(destructive ? Color(red: 1, green: 0.56, blue: 0.54)
                : emphasized ? Color(red: 0.65, green: 0.98, blue: 0.85) : .white.opacity(0.85))
            .padding(.horizontal, 10).frame(height: 30)
            .background(emphasized ? Color(red: 0.12, green: 0.3, blue: 0.25)
                : Color.white.opacity(configuration.isPressed ? 0.14 : 0.055),
                in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(emphasized ? 0.1 : 0.04)))
            .opacity(!isEnabled ? 0.35 : configuration.isPressed ? 0.7 : 1)
    }
}

/// The step, laid out.
///
/// The description used to be appended *into* the code scroll: `Why`,
/// `Limitation`, `Pending`, `Say next`, `Check` and `Watch` were concatenated
/// after the source in one attributed string, so reading why a step was
/// proposed meant scrolling past the step — and `Say next` then drew a second
/// time under the pane. Each of those is about a different thing, so each now
/// sits where that thing is:
///
/// - about the step — the title, above the code, full width;
/// - about a line — a numbered note inside the code plane, next to the line;
/// - about the conversation — Say and Why, one line each under the code, where
///   the reader looks up from typing;
/// - about the run — `Check` is the Run key, not a sentence.
///
/// Stepping through moves and copying one used to be chevrons and a button in
/// this pane's own header. Both are keys now (`⌥⌘←`/`⌥⌘→`, `⌥⌘A`) named in the
/// hint row under the panel, so the pane draws the step and nothing else.
struct CodingReadingPane: View {
    let document: CodingReadingDocument
    let compact: Bool
    @Binding var offsets: [String: Double]

    private let accent = Color(red: 0.52, green: 0.9, blue: 0.78)

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 8) {
            meta
            if !compact || document.patch == nil {
                title
            }
            content
        }
        .foregroundStyle(NotchInk.primary)
    }

    /// Which step this is, and exactly where it lands. The placement was a
    /// separate full-width row below the panel; it belongs beside the step
    /// number, because both answer "where am I".
    private var meta: some View {
        HStack(spacing: 8) {
            Text(document.eyebrow)
                .font(NotchGlassType.caps)
                .tracking(notchCapsTracking)
                .foregroundStyle(accent)
                .fixedSize()

            Spacer(minLength: 4)

            if let placement = document.placement, !placement.isEmpty {
                Text(placement)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(NotchInk.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(placement)
            }
        }
        .frame(height: 13)
    }

    private var title: some View {
        let base = compact ? NotchGlassType.detail.weight(.semibold) : NotchGlassType.title
        return CodingProseText(document.title, base: base, size: compact ? 11 : 14,
                               plain: NotchInk.primary, codeWeight: .semibold)
            .lineLimit(compact ? 1 : 2)
            .help(document.title)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        if let patch = document.patch {
            CodingPatchView(display: patch, compact: compact)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let blocks = document.blocks {
            prose(blocks)
        } else {
            // The long surfaces — history, the transcript, the evidence sheet.
            // These keep the text view: it is what remembers where the reader
            // had got to, which is worth more on a surface you scroll than the
            // typographic control is.
            WaveReadingScroll(content: document.content, identity: document.identity,
                              offsets: $offsets, verticalInset: compact ? 3 : 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(ReadingPlane())
        }
    }

    /// A step with no code, drawn as what it is rather than as one paragraph
    /// stream at one size.
    private func prose(_ blocks: [CodingProseBlock]) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: compact ? 6 : 9) {
                ForEach(blocks) { block in
                    switch block.kind {
                    case .lead:
                        CodingProseText(block.text,
                                        base: compact ? NotchGlassType.detail : NotchGlassType.row,
                                        size: compact ? 11 : 12,
                                        plain: NotchInk.reading)
                            .fixedSize(horizontal: false, vertical: true)

                    case .notice:
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(NotchGlassType.glyph)
                                .foregroundStyle(NotchTint.attention)
                            Text(block.text)
                                .font((compact ? NotchGlassType.detail : NotchGlassType.row)
                                    .weight(.medium))
                                .foregroundStyle(NotchInk.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 2)

                    case .noticeDetail:
                        Text(block.text)
                            .font(NotchGlassType.detail)
                            .foregroundStyle(NotchInk.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            // Aligned under the notice's text, not its glyph.
                            .padding(.leading, 20)

                    case .separator:
                        Rectangle()
                            .fill(NotchInk.tertiary.opacity(0.18))
                            .frame(height: 1)
                            .padding(.vertical, 1)

                    case .sectionLabel:
                        Text(block.text.uppercased())
                            .font(NotchGlassType.caps)
                            .tracking(notchCapsTracking)
                            .foregroundStyle(NotchInk.tertiary)
                            .padding(.top, 2)

                    case .item:
                        // Sized against the surrounding prose rather than fixed
                        // at 11: these carry the reasoning now, not a reference
                        // list under it, and a step whose points were a size
                        // smaller than its own explanation read as a footnote.
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle()
                                .fill(accent.opacity(0.85))
                                .frame(width: 3, height: 3)
                                .offset(y: compact ? -3 : -4)
                            CodingProseText(block.text,
                                            base: compact ? NotchGlassType.detail : NotchGlassType.row,
                                            size: compact ? 11 : 12,
                                            plain: NotchInk.reading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, compact ? 8 : 11)
        }
        .scrollIndicators(.never)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(ReadingPlane())
    }
}

/// The dark plane the reading surfaces sit on.
private struct ReadingPlane: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(CodingCodeInk.plane.opacity(0.94),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(CodingCodeInk.planeBorder))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct WaveReadingScroll: NSViewRepresentable {
    let content: NSAttributedString
    let identity: String
    @Binding var offsets: [String: Double]
    var verticalInset: CGFloat = 10
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let text = NSTextView(); text.isEditable = false; text.isSelectable = true
        text.drawsBackground = false; text.textContainerInset = NSSize(width: 12, height: verticalInset)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak coordinator = context.coordinator, weak scroll] _ in
            guard let coordinator, let scroll, !coordinator.updating else { return }
            let key = coordinator.identity
            let y = scroll.contentView.bounds.origin.y
            DispatchQueue.main.async { coordinator.parent.offsets[key] = y }
        }
        context.coordinator.scrollObserver = NotificationCenter.default.addObserver(
            forName: .callaCodingScroll, object: nil, queue: .main
        ) { [weak scroll] notification in
            guard let scroll, let text = scroll.documentView else { return }
            let requested = CGFloat(notification.object as? Int ?? 0)
            // Keep one line of overlap even in a very short compact reader.
            // A fixed eight-line jump would skip unread code at Call's compact height.
            let distance = min(abs(requested) * 16, max(1, scroll.contentSize.height - 16))
            let delta = requested < 0 ? -distance : distance
            let y = min(max(0, scroll.contentView.bounds.origin.y + delta), max(0, text.frame.height - scroll.contentSize.height))
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView else { return }
        text.textContainerInset = NSSize(width: 12, height: verticalInset)
        let coordinator = context.coordinator
        coordinator.updating = true
        defer { coordinator.updating = false }
        let changedIdentity = coordinator.identity != identity
        let priorY = scroll.contentView.bounds.origin.y
        coordinator.parent = self; coordinator.identity = identity
        if text.attributedString() != content { text.textStorage?.setAttributedString(content) }
        text.setFrameSize(NSSize(width: scroll.contentSize.width, height: max(scroll.contentSize.height, text.frame.height)))
        text.layoutManager?.ensureLayout(for: text.textContainer!)
        if let container = text.textContainer, let layout = text.layoutManager {
            let height = layout.usedRect(for: container).height + 24
            text.setFrameSize(NSSize(width: scroll.contentSize.width, height: max(scroll.contentSize.height, height)))
        }
        let y = changedIdentity ? (offsets[identity] ?? 0) : priorY
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, min(y, text.frame.height - scroll.contentSize.height))))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    final class Coordinator {
        var parent: WaveReadingScroll
        var identity = ""
        var updating = false
        var observer: NSObjectProtocol?
        var scrollObserver: NSObjectProtocol?
        init(_ parent: WaveReadingScroll) { self.parent = parent }
        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        }
    }
}

struct WavePreparationControls: View {
    let setup: CallaCodingSetup
    var save: () -> Void
    @State private var preparing = false
    @State private var result: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer()
                Button(preparing ? "Preparing…" : "Prepare") {
                    guard let bookmark = setup.folderBookmark else { return }
                    save(); preparing = true
                    CallaEngineClient.shared.prepareWave(.init(projectBookmark: bookmark)) { response in
                        preparing = false; result = response?.failure ?? response?.report ?? "Preparation did not reply."
                    }
                }.disabled(preparing || !setup.hasFolder || CallaEngineClient.shared.coding.lifecycle.active)
            }
            // No attach step: supplied files go into the project folder by
            // hand, so the thing Prepare probes is the thing the session runs
            // against.
            Text("Reads the project folder as it is. Start begins listening.").font(.caption).foregroundStyle(.secondary)
            if let result { Text(result).font(.caption).textSelection(.enabled) }
        }
    }
}

/// Editor observation is independent of the Wave appearance profile.
struct WaveWindowPicker: View {
    @Binding var target: QuizWindowTarget?
    @State private var windows: [QuizWindowTarget] = []
    @State private var loading = false
    @State private var loaded = false

    private func title(_ window: QuizWindowTarget) -> String {
        window.windowTitle.isEmpty ? "VS Code window \(window.windowID)" : window.windowTitle
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("VS Code window").font(NotchType.rowTitle)
                Spacer(minLength: 8)
                Menu {
                    Button("Saved files only") { target = nil }
                    if !windows.isEmpty { Divider() }
                    ForEach(windows) { window in
                        Button { target = window } label: {
                            if target?.id == window.id {
                                Label(title(window), systemImage: "checkmark")
                            } else { Text(title(window)) }
                        }
                    }
                } label: {
                    Text(target.map(title) ?? "Select window…").lineLimit(1).truncationMode(.middle)
                }
                .help(target.map(title) ?? "Choose the VS Code window to observe")
                Button(loading ? "Refreshing…" : "Refresh") { refresh() }.disabled(loading)
            }
            Text("Observation starts with the session. Saved files come from the project folder above.")
                .font(.caption).foregroundStyle(.secondary)
            if loaded, !loading {
                if let target, !windows.contains(where: { $0.id == target.id }) {
                    Text("The selected window is unavailable. Reopen it and select its new window before Start.")
                        .font(.caption).foregroundStyle(NotchTint.attention)
                } else if windows.isEmpty {
                    Text("No VS Code windows found. Open your project in VS Code, then Refresh. Window observation needs Screen Recording access.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }.task { refresh() }
    }
    private func refresh() {
        guard !loading else { return }
        loading = true
        CallaEngineClient.shared.listQuizWindows { targets in
            windows = targets.filter { ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"].contains($0.bundleID) }
            loading = false; loaded = true
        }
    }
}

