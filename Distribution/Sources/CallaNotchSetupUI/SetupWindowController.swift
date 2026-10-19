import AppKit
import DistributionCore
import Darwin
import SwiftUI

/// The setup window belongs to the main calla.notch application. There is
/// no second application for Gatekeeper to approve.
public typealias SetupTransport = ([String: Any], @escaping ([String: Any]) -> Void) -> Void

@MainActor
public final class SetupWindowController: NSWindowController, NSWindowDelegate {
    private let model: InstallerModel

    /// - Parameters:
    ///   - autoStart: begin immediately; used when the disk-image copy hands
    ///     setup over to the copy it just installed.
    ///   - alreadySetUp: this Mac finished setup before, so the window opens on
    ///     a summary with Check & repair rather than a first-run welcome.
    public init(package: URL, autoStart: Bool = false, alreadySetUp: Bool = false,
                transport: @escaping SetupTransport) {
        model = InstallerModel(package: package, alreadySetUp: alreadySetUp, transport: transport)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "calla.notch Setup"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 820, height: 600)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: InstallerView(model: model))
        window.center()
        if autoStart { DispatchQueue.main.async { [model] in model.begin() } }
    }

    required init?(coder: NSCoder) { fatalError("Use init(package:)") }

    public func present() {
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.running {
            let alert = NSAlert()
            alert.messageText = "Pause setup?"
            alert.informativeText = "Finished steps are saved. Reopen calla.notch to continue where you left off. Let any macOS installer that is open finish first."
            alert.addButton(withTitle: "Keep going")
            alert.addButton(withTitle: "Pause setup")
            guard alert.runModal() == .alertSecondButtonReturn else { return false }
            model.stop()
        }
        return true
    }

    public func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if model.isInstallerCopy { NSApp.terminate(nil) }
    }
}

// MARK: - Model

struct SetupPrompt: Equatable {
    let message: String
    let choice: Bool
    let defaultYes: Bool
}

struct SetupStep {
    let title: String
    let summary: String
    let symbol: String
}

@MainActor
final class InstallerModel: ObservableObject {
    static let steps: [SetupStep] = [
        .init(title: "Install app", summary: "Copy calla.notch into Applications and verify its signature. macOS may ask for your administrator password.", symbol: "shippingbox"),
        .init(title: "Coding tools", summary: "AGY, Codex and Claude go into one Components folder, copied from this package or reused if already installed. If Git is missing, Apple’s installer adds its Command Line Tools.", symbol: "terminal"),
        .init(title: "Meeting settings", summary: "Turn on listening calls, with personas for standups, planning, retros, reviews and one-on-ones. Existing preferences are kept.", symbol: "slider.horizontal.3"),
        .init(title: "Google account", summary: "Sign in through the calla.notch sign-in window and approve access in your browser. Your account stays on this Mac.", symbol: "person.crop.circle.badge.checkmark"),
        .init(title: "Speech models", summary: "The English speech model, reused if it is already on this Mac or in a carried calla.notch Components folder, otherwise downloaded with progress. A higher-quality after-call model is optional.", symbol: "waveform"),
        .init(title: "Permissions", summary: "Allow the microphone, system audio, calendar, and the Documents folder where each call is saved. This window stays open while you switch to System Settings.", symbol: "hand.raised"),
        .init(title: "Meeting check", summary: "Speak a sentence and play a short spoken clip to confirm both sides are heard, then check the AI connection.", symbol: "checkmark.seal"),
        .init(title: "Tangit profile", summary: "Create one Tangit profile per account, for example “work” for Codex and “personal” for Claude. Terminal opens Tangit’s wizard: type a name, pick Codex or Claude, then sign in. Codex shows a device code.", symbol: "person.2"),
    ]
    /// Setup's checkpoint names, mapped to the step that owns them.
    static let checkpoints = ["app": 1, "agy": 2, "tangit-tools": 2, "settings": 3, "login": 4, "models": 5,
                              "permissions": 6, "calendar": 6, "calls-folder": 6, "launch-at-login": 6,
                              "meeting-test": 7, "tangit-profile": 8]

    @Published var running = false
    @Published var finished = false
    @Published var handingOff = false
    @Published var step = 0
    @Published var prompt: SetupPrompt?
    @Published var error: String?
    @Published var log = ""
    @Published var activity = ""
    @Published var detail = ""
    @Published var fraction: Double?
    @Published var stepStarted = Date()
    @Published var meetingReady = false
    @Published var skipped: Set<Int> = []
    @Published var completed: Set<Int> = []
    @Published var alreadySetUp: Bool
    let package: URL?
    let version: String
    let isInstallerCopy: Bool
    private let transport: SetupTransport
    private var token = ""
    private var buffer = Data()
    private var eventPrefix = ""
    private var startedOnce = false

    init(package source: URL, alreadySetUp: Bool, transport: @escaping SetupTransport) {
        self.transport = transport
        self.alreadySetUp = alreadySetUp
        isInstallerCopy = source.resolvingSymlinksInPath() != Layout.app.resolvingSymlinksInPath()
        if let manifest = try? PackageInstaller.manifest(in: source) {
            package = source
            version = "\(manifest.version) (\(manifest.build))"
        } else {
            package = nil
            version = "Private build"
            error = "The application payload is missing or incomplete. Open calla.notch from the complete private disk image."
        }
    }

    var overall: Double { Double(completed.union(skipped).count) / Double(Self.steps.count) }

    func begin(repair: Bool = false) {
        guard !running, package != nil else { return }
        error = nil; prompt = nil; finished = false; step = 0; fraction = nil
        if repair { completed = []; skipped = [] }
        buffer = Data(); log = ""; detail = ""
        activity = "Checking this Mac…"
        token = UUID().uuidString
        eventPrefix = "\u{1e}CALLA_SETUP:\(token):"
        running = true; startedOnce = true; stepStarted = Date()
        transport(["uiCommand": "start", "token": token, "repair": repair]) { [weak self] result in
            guard let self else { return }
            if let error = result["error"] as? String { self.error = error; self.running = false; return }
            self.poll()
        }
    }

    var hasStarted: Bool { startedOnce || !completed.isEmpty }

    private func poll() {
        guard running else { return }
        transport(["uiCommand": "read", "token": token]) { [weak self] result in
            guard let self else { return }
            if let error = result["error"] as? String { self.error = error; self.running = false; return }
            if let output = result["output"] as? String, let data = Data(base64Encoded: output) { self.receive(data) }
            if let status = result["status"] as? Int { self.exited(Int32(status)); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.poll() }
        }
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        // Download tools redraw one line with carriage returns; treat each
        // redraw as a line so its percentage reaches the progress bar.
        while let end = buffer.firstIndex(where: { $0 == 10 || $0 == 13 }) {
            let line = String(decoding: buffer[..<end], as: UTF8.self)
            buffer.removeSubrange(...end)
            consume(line)
        }
        if buffer.count > 64_000 { appendLog(String(decoding: buffer, as: UTF8.self)); buffer.removeAll() }
    }

    private static let percent = try! NSRegularExpression(pattern: #"(\d{1,3}(?:\.\d+)?)\s?%"#)

    private func consume(_ line: String) {
        guard let range = line.range(of: eventPrefix) else {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return }
            let ns = text as NSString
            if text.count < 160, let match = Self.percent.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
               let value = Double(ns.substring(with: match.range(at: 1))), value <= 100 {
                fraction = value / 100
                // A bare "42%" says nothing the bar doesn't; keep the last words.
                if text.count > 6 { detail = text }
                return
            }
            detail = text
            appendLog(text)
            return
        }
        guard let data = String(line[range.upperBound...]).data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { return }
        withAnimation(.smooth(duration: 0.35)) { apply(type, event) }
    }

    private func apply(_ type: String, _ event: [String: Any]) {
        switch type {
        case "restore":
            let done = (event["completed"] as? [String] ?? []).compactMap { Self.checkpoints[$0] }
            let skip = (event["skipped"] as? [String] ?? []).compactMap { Self.checkpoints[$0] }
            completed.formUnion(done); skipped.formUnion(skip)
        case "step":
            if step > 0, !skipped.contains(step) { completed.insert(step) }
            step = event["number"] as? Int ?? step
            prompt = nil; error = nil; fraction = nil; detail = ""; activity = ""
            stepStarted = Date()
        case "activity":
            activity = event["text"] as? String ?? activity
            // A new sentence starts a new piece of work; the last bar is done.
            fraction = nil; detail = ""
            appendLog("› " + activity)
        case "progress":
            fraction = event["fraction"] as? Double
            if let line = event["detail"] as? String { detail = line }
        case "prompt":
            prompt = SetupPrompt(message: event["message"] as? String ?? "Continue setup?",
                                 choice: event["kind"] as? String == "choice",
                                 defaultYes: event["defaultYes"] as? Bool ?? true)
            NSApp.requestUserAttention(.informationalRequest)
        case "error", "fatal": error = event["message"] as? String
        case "checkpoint":
            guard let name = event["name"] as? String, let number = Self.checkpoints[name] else { break }
            if event["skipped"] as? Bool == true { skipped.insert(number); completed.remove(number) }
        case "handoff":
            // Launched once this process has exited and released the setup
            // lock, so the installed copy never finds setup "already running".
            completed.insert(1); handingOff = true
        case "complete":
            meetingReady = event["meetingReady"] as? Bool == true
            if step > 0, !skipped.contains(step) { completed.insert(step) }
            finished = true; alreadySetUp = true; prompt = nil; error = nil; fraction = nil
        default: break
        }
    }

    private func appendLog(_ text: String) {
        log = String((log + text + "\n").suffix(40_000))
    }

    func answer(_ yes: Bool = true) {
        guard let prompt else { return }
        let text = prompt.choice ? (yes ? "y\n" : "n\n") : "\n"
        withAnimation(.smooth(duration: 0.25)) { self.prompt = nil }
        transport(["uiCommand": "input", "token": token, "input": text]) { [weak self] result in
            if let error = result["error"] as? String { self?.error = error }
            else if yes { self?.error = nil }
        }
    }

    private func exited(_ status: Int32) {
        if !buffer.isEmpty { consume(String(decoding: buffer, as: UTF8.self)); buffer.removeAll() }
        running = false; prompt = nil; fraction = nil
        if handingOff { continueInApplications(); return }
        if finished { return }
        if status != 0 {
            error = error ?? "Setup paused. Finished steps are saved. Choose Resume setup to continue."
        } else {
            activity = ""
            error = "Setup paused. Choose Resume setup when you’re ready."
        }
    }

    func stop() {
        transport(["uiCommand": "stop", "token": token]) { _ in }
    }

    /// The installed copy picks up exactly where this one stopped. Launching it
    /// fresh — rather than reusing a background instance — gives it the window.
    private func continueInApplications() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--continue-setup"]
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSWorkspace.shared.openApplication(at: Layout.app, configuration: configuration) { _, error in
                DispatchQueue.main.async {
                    if let error {
                        self.handingOff = false
                        self.error = "calla.notch is installed, but macOS did not open it: \(error.localizedDescription). Open calla.notch from Applications to continue."
                    } else {
                        NSApp.terminate(nil)
                    }
                }
            }
        }
    }

    func openApp() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = isInstallerCopy
        NSWorkspace.shared.openApplication(at: Layout.app, configuration: configuration) { _, error in
            if error == nil { DispatchQueue.main.async { NSApp.keyWindow?.close() } }
        }
    }

    func openTangit() {
        transport(["uiCommand": "launchTangit"]) { [weak self] result in
            if let error = result["error"] as? String { self?.error = error }
        }
    }
}

// MARK: - Views

struct InstallerView: View {
    @ObservedObject var model: InstallerModel
    @State private var showDetails = false

    var body: some View {
        HStack(spacing: 0) {
            SetupSidebar(model: model)
                .frame(width: 236)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        header
                        if model.handingOff { handoff }
                        else if model.finished { completion }
                        else if model.step == 0 && !model.running { introduction }
                        else { current }
                        if let error = model.error, !model.handingOff { ErrorBanner(text: error) }
                        if let prompt = model.prompt { PromptCard(prompt: prompt, model: model) }
                    }
                    .padding(.horizontal, 40).padding(.top, 52).padding(.bottom, 24)
                    .frame(maxWidth: 640, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if showDetails { DetailsLog(text: model.log).transition(.move(edge: .bottom).combined(with: .opacity)) }
                Divider()
                footer
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.55))
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 820, minHeight: 600)
        .background(VisualEffect(material: .windowBackground).ignoresSafeArea())
        .animation(.smooth(duration: 0.35), value: model.step)
        .animation(.smooth(duration: 0.3), value: model.finished)
        .animation(.smooth(duration: 0.25), value: showDetails)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(eyebrow)
                .font(.system(size: 11, weight: .semibold)).tracking(1.2)
                .foregroundStyle(.secondary)
            Spacer()
            Text(model.version).font(.caption).foregroundStyle(.tertiary).monospacedDigit()
        }
    }

    private var eyebrow: String {
        if model.handingOff { return "INSTALLED" }
        if model.finished { return "ALL DONE" }
        if model.step == 0 { return model.running ? "GETTING READY" : (model.alreadySetUp ? "THIS MAC IS SET UP" : "WELCOME") }
        return "STEP \(model.step) OF \(InstallerModel.steps.count)"
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
            if model.alreadySetUp {
                Text("Everything is in place.").font(.system(size: 30, weight: .semibold))
                Text("Run Check & repair to verify the app, tools, sign-in, models and permissions. Anything already working is left as it is.")
                    .font(.system(size: 15)).foregroundStyle(.secondary).lineSpacing(4)
            } else {
                Text(model.hasStarted ? "Pick up where you left off." : "Let’s set up this Mac.")
                    .font(.system(size: 30, weight: .semibold))
                Text("calla.notch, meeting listening and Tangit in one guided setup. Each step shows what it is doing, and finished steps are never repeated.")
                    .font(.system(size: 15)).foregroundStyle(.secondary).lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 16) {
                    IntroRow(symbol: "shippingbox.fill", tint: .blue, title: "Already included",
                             text: "The app, Tangit, Codex, Claude and AGY. Nothing to download for these.")
                    IntroRow(symbol: "arrow.down.circle.fill", tint: .teal, title: "Downloaded as needed",
                             text: "Only what is not already here: setup first checks this Mac and any calla.notch Components folder for the 488 MB speech model, then downloads what is missing with live progress.")
                    IntroRow(symbol: "hand.raised.fill", tint: .orange, title: "You approve the personal parts",
                             text: "Google sign-in and the macOS microphone, system audio and calendar prompts.")
                }
                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.6)))
                Label("Apple Silicon · macOS 15 or later · Internet · 3 GB free", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var current: some View {
        let info = model.step > 0 ? InstallerModel.steps[model.step - 1] : nil
        return VStack(alignment: .leading, spacing: 18) {
            if let info {
                Image(systemName: info.symbol).font(.system(size: 30, weight: .regular))
                    .foregroundStyle(.tint).frame(height: 36)
                    .id(model.step).transition(.scale(scale: 0.8).combined(with: .opacity))
            }
            Text(info?.title ?? "Getting ready").font(.system(size: 30, weight: .semibold))
                .contentTransition(.opacity)
            if let info {
                Text(info.summary).font(.system(size: 15)).foregroundStyle(.secondary).lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.running && model.prompt == nil { ActivityCard(model: model) }
        }
    }

    private var handoff: some View {
        VStack(alignment: .leading, spacing: 18) {
            ProgressView().controlSize(.large)
            Text("Continuing from Applications").font(.system(size: 30, weight: .semibold))
            Text("calla.notch is installed. This window closes and the installed app opens its own setup window to finish the remaining steps, so every macOS prompt belongs to the same app.")
                .font(.system(size: 15)).foregroundStyle(.secondary).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var completion: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: model.meetingReady ? "checkmark.circle.fill" : "checkmark.circle")
                .font(.system(size: 46)).foregroundStyle(.green)
                .symbolEffect(.bounce, value: model.finished)
            Text(model.meetingReady ? "Your Mac is ready." : "Installed — a few things to finish.")
                .font(.system(size: 30, weight: .semibold))
            Text(model.meetingReady
                 ? "Everything checked out. Here is where to start."
                 : "calla.notch is installed. Steps marked in the sidebar still need attention; reopen setup any time to finish them.")
                .font(.system(size: 15)).foregroundStyle(.secondary).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 16) {
                IntroRow(symbol: "waveform.badge.mic", tint: .blue, title: "Start a call from the notch",
                         text: "Pick the meeting type first: Standup, Planning, Refinement, Review or Retro for team rituals; Design or Incident review for engineering; 1:1, Interview, Sales or Support for conversations.")
                IntroRow(symbol: "house.fill", tint: .teal, title: "Home shows Now Playing and your calendar",
                         text: "Today’s meetings sit beside your music. Choose which calendars appear in Settings → Calendar.")
                IntroRow(symbol: "terminal.fill", tint: .orange, title: "Tangit is ready in Terminal",
                         text: "Choose Open Tangit below, or type tangit in any new Terminal window.")
            }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.6)))
            if !model.skipped.isEmpty {
                Label("Skipped: " + model.skipped.sorted().map { InstallerModel.steps[$0 - 1].title }.joined(separator: ", ")
                      + ". Choose Check & repair later to add them.", systemImage: "arrow.uturn.forward")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button { showDetails.toggle() } label: {
                Label(showDetails ? "Hide details" : "Show details", systemImage: "text.alignleft")
            }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
            Spacer()
            if model.handingOff {
                EmptyView()
            } else if model.finished || (model.alreadySetUp && !model.running) {
                Button("Open Tangit") { model.openTangit() }.controlSize(.large)
                if model.alreadySetUp && !model.finished {
                    Button("Check & repair") { model.begin(repair: true) }.controlSize(.large)
                }
                Button("Open calla.notch") { model.openApp() }
                    .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
            } else if !model.running {
                Button(model.hasStarted ? "Resume setup" : "Begin setup") { model.begin() }
                    .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                    .disabled(model.package == nil)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
    }
}

/// Live, always-moving status for the step in progress.
struct ActivityCard: View {
    @ObservedObject var model: InstallerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                if model.fraction == nil { ProgressView().controlSize(.small) }
                else {
                    Text("\(Int((model.fraction ?? 0) * 100))%")
                        .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(.tint).frame(minWidth: 36, alignment: .leading)
                        .contentTransition(.numericText())
                }
                Text(model.activity.isEmpty ? "Working…" : model.activity)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                Spacer(minLength: 8)
                TimelineView(.periodic(from: model.stepStarted, by: 1)) { context in
                    Text(Self.elapsed(context.date.timeIntervalSince(model.stepStarted)))
                        .font(.caption).monospacedDigit().foregroundStyle(.tertiary)
                }
            }
            if let fraction = model.fraction {
                SetupBar(value: fraction, tint: .accentColor)
            }
            if !model.detail.isEmpty {
                Text(model.detail)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.75), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6)))
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return total < 60 ? "\(total)s" : String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct PromptCard: View {
    let prompt: SetupPrompt
    @ObservedObject var model: InstallerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: prompt.choice ? "questionmark.circle.fill" : "hand.point.right.fill")
                    .font(.system(size: 20)).foregroundStyle(.tint)
                Text(prompt.message).font(.system(size: 14)).lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            HStack(spacing: 10) {
                Spacer()
                if prompt.choice {
                    Button("No") { model.answer(false) }.controlSize(.large)
                        .keyboardShortcut(prompt.defaultYes ? .cancelAction : .defaultAction)
                    Button("Yes") { model.answer(true) }.controlSize(.large)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(prompt.defaultYes ? .defaultAction : .cancelAction)
                } else {
                    Button("Continue") { model.answer() }.buttonStyle(.borderedProminent).controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.accentColor.opacity(0.35)))
        .transition(.scale(scale: 0.97).combined(with: .opacity))
    }
}

struct ErrorBanner: View {
    let text: String
    var body: some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        .font(.callout).textSelection(.enabled)
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .transition(.opacity)
    }
}

struct IntroRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(tint).frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct DetailsLog: View {
    let text: String
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text.isEmpty ? "Setup details will appear here." : text)
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                Color.clear.frame(height: 1).id("end")
            }
            .frame(height: 150)
            .background(Color.primary.opacity(0.04))
            .onChange(of: text) { proxy.scrollTo("end", anchor: .bottom) }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}

struct SetupSidebar: View {
    @ObservedObject var model: InstallerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("calla.notch").font(.system(size: 14, weight: .semibold))
                    Text("Setup").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 52).padding(.bottom, 22)

            VStack(alignment: .leading, spacing: 6) {
                SetupBar(value: model.overall, tint: .green)
                Text("\(model.completed.union(model.skipped).count) of \(InstallerModel.steps.count) done")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.bottom, 22)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(InstallerModel.steps.enumerated()), id: \.offset) { index, item in
                    StepRow(number: index + 1, title: item.title, state: state(index + 1),
                            last: index == InstallerModel.steps.count - 1)
                }
            }
            Spacer(minLength: 16)
            Label("Progress is saved. Close any time.", systemImage: "lock.shield")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.bottom, 20)
        }
        .padding(.horizontal, 22)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(VisualEffect(material: .sidebar).ignoresSafeArea())
    }

    private func state(_ number: Int) -> StepRow.State {
        if model.step == number && model.running && !model.finished { return .active }
        if model.skipped.contains(number) { return .skipped }
        if model.completed.contains(number) { return .done }
        return .pending
    }
}

struct StepRow: View {
    enum State { case pending, active, done, skipped }
    let number: Int
    let title: String
    let state: State
    let last: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                ZStack {
                    Circle().fill(fill).frame(width: 22, height: 22)
                    if state == .pending {
                        Circle().strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1.2).frame(width: 22, height: 22)
                    }
                    switch state {
                    case .done: Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    case .skipped: Image(systemName: "clock").font(.system(size: 10, weight: .semibold)).foregroundStyle(.orange)
                    case .active: Circle().fill(.white).frame(width: 7, height: 7).symbolEffect(.pulse)
                    case .pending: Text("\(number)").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    }
                }
                if !last {
                    Rectangle().fill(state == .done ? Color.green.opacity(0.5) : Color.secondary.opacity(0.18))
                        .frame(width: 1.5, height: 14)
                }
            }
            Text(title)
                .font(.system(size: 12.5, weight: state == .active ? .semibold : .regular))
                .foregroundStyle(state == .pending ? .secondary : .primary)
                .padding(.top, 3)
        }
        .animation(.smooth(duration: 0.3), value: state)
    }

    private var fill: Color {
        switch state {
        case .done: .green
        case .active: .accentColor
        case .skipped: .orange.opacity(0.15)
        case .pending: .clear
        }
    }
}

/// A bar that keeps its colour when the window is inactive — which is most of
/// the time during setup, while the reader is in System Settings or a browser.
struct SetupBar: View {
    let value: Double
    let tint: Color
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(tint)
                    .frame(width: max(value > 0 ? 6 : 0, geometry.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: 6)
        .animation(.smooth(duration: 0.4), value: value)
    }
}

struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material; view.blendingMode = .behindWindow; view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) { view.material = material }
}
