import AppKit
import SwiftUI

/// Signing in to Google, in the notch.
///
/// This exists because the old flow was invisible: starting a meeting without
/// credentials popped a browser and left the code with nowhere to go, while the
/// app showed a call that was never going to produce a suggestion. The sign-in now
/// happens where the user is already looking, with the steps on screen so a wait
/// is distinguishable from a hang.
///
/// Takes the compact panel — a line of text and a field, not a call.
struct CallaCopilotSignInView: View {
    @ObservedObject private var engine = CallaEngineClient.shared

    @State private var code = ""
    @State private var openedURL: String?
    @FocusState private var codeFocused: Bool

    private var copilot: CallaCopilotStatus { engine.status.copilot }

    /// The four moments worth showing. Anything else is detail.
    private enum Step: Int, CaseIterable {
        case checking, browser, code, exchanging

        var title: String {
            switch self {
            // Named for what the user is waiting on: the first stage can be a
            // credential check, which costs a full model round trip.
            case .checking: "Checking"
            case .browser: "Approve in browser"
            case .code: "Paste the code"
            case .exchanging: "Finishing"
            }
        }
    }

    private var stage: String { copilot.agyLoginStage ?? "starting" }

    private var current: Step {
        switch stage {
        case "opening_browser": .browser
        case "awaiting_code": .code
        case "exchanging", "signed_in": .exchanging
        default: .checking
        }
    }

    private var failed: Bool { stage == "failed" }
    private var succeeded: Bool { stage == "signed_in" }

    var body: some View {
        VStack(alignment: .leading, spacing: NotchGlassSpace.snug) {
            header
            steps
            if copilot.canAcceptCode || failed { codeRow }
            if let detail = copilot.lastResult, !detail.isEmpty {
                Text(detail)
                    .font(NotchGlassType.detail)
                    .foregroundStyle(failed ? NotchTint.attention : NotchInk.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, NotchGlassSpace.tight)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        NotchPlane.chip,
                        in: RoundedRectangle(cornerRadius: NotchGlassRadius.glyph, style: .continuous)
                    )
                    .accessibilityLabel(detail)
            }
        }
        // The shared insets, including the bottom one the notch's inward-curving
        // corners need. This used to be 16pt horizontal, which put the panel out
        // of line with every other tab by four points.
        .notchTabInsets()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The notch takes key focus while open, so the field is usable here.
        .onAppear { codeFocused = true }
        .onChange(of: copilot.agyAwaitingCode) { _, awaiting in
            if awaiting { codeFocused = true }
        }
        // The app opens the link, not the engine: an XPC service is not guaranteed
        // a GUI session, so `open` can fail there for reasons retrying cannot fix.
        // Keyed on the URL value, so it opens once per sign-in rather than once per
        // status poll.
        .onChange(of: copilot.agyLoginURL) { _, url in
            guard let url, url != openedURL, let target = URL(string: url) else { return }
            openedURL = url
            NSWorkspace.shared.open(target)
        }
    }

    private var header: some View {
        HStack(spacing: NotchGlassSpace.tight) {
            Image(systemName: succeeded ? "checkmark.circle.fill"
                  : failed ? "exclamationmark.triangle.fill" : "person.badge.key.fill")
                .font(NotchGlassType.glyph)
                .foregroundStyle(succeeded ? NotchTint.healthy
                                 : failed ? NotchTint.attention : NotchInk.secondary)
            Text(succeeded ? "Signed in" : "Sign in to use this Mac's copilot")
                .font(NotchGlassType.title)
                .foregroundStyle(NotchInk.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let url = copilot.agyLoginURL {
                NotchChip(action: {
                    if let target = URL(string: url) { NSWorkspace.shared.open(target) }
                }) {
                    Text("Open")
                }
                .accessibilityLabel("Open the sign-in page")
                NotchChip(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                }) {
                    Text("Copy")
                }
                .accessibilityLabel("Copy the sign-in link")
            }
        }
    }

    /// Progress as steps rather than a spinner: a wait the user can place is a
    /// wait they will tolerate.
    private var steps: some View {
        HStack(spacing: NotchGlassSpace.snug) {
            ForEach(Step.allCases, id: \.rawValue) { step in
                let done = step.rawValue < current.rawValue || succeeded
                let active = step == current && !succeeded && !failed
                HStack(spacing: NotchGlassSpace.hair + 2) {
                    Image(systemName: done ? "checkmark.circle.fill"
                          : active ? "circle.dotted" : "circle")
                        .font(NotchGlassType.glyphSmall)
                        .foregroundStyle(done ? NotchTint.healthy
                                         : active ? Color.effectiveAccent : NotchInk.tertiary)
                    // One ink step per state, rather than a second font weight on
                    // top of a second opacity. Four steps is the whole palette.
                    Text(step.title)
                        .font(NotchGlassType.caption)
                        .foregroundStyle(active ? NotchInk.primary
                                         : done ? NotchInk.secondary : NotchInk.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
                .accessibilityLabel("\(step.title): \(done ? "done" : active ? "in progress" : "waiting")")
                if step != Step.allCases.last {
                    Rectangle()
                        .fill(NotchInk.hairline)
                        .frame(height: 1)
                        .frame(maxWidth: 14)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
    }

    private var codeRow: some View {
        let empty = code.trimmingCharacters(in: .whitespaces).isEmpty
        return HStack(spacing: NotchGlassSpace.tight) {
            TextField("Paste the authorization code", text: $code)
                .textFieldStyle(.plain)
                .font(NotchGlassType.row)
                .foregroundStyle(NotchInk.primary)
                .focused($codeFocused)
                .onSubmit(submit)
                .padding(.horizontal, 10)
                .frame(height: NotchGlassSpace.control)
                .background {
                    let shape = RoundedRectangle(cornerRadius: NotchGlassRadius.chip,
                                                 style: .continuous)
                    ZStack {
                        shape.fill(Color.black.opacity(0.30))
                        shape.strokeBorder(codeFocused ? Color.effectiveAccent.opacity(0.55)
                                           : NotchInk.hairline, lineWidth: 1)
                    }
                }
                .accessibilityLabel("Authorization code")
            NotchChip(tint: .effectiveAccent, action: {
                if failed, empty {
                    engine.loginAgy(force: true)
                } else {
                    submit()
                }
            }) {
                Text(failed ? "Retry" : "Submit")
            }
            .opacity(!failed && empty ? 0.45 : 1)
            .disabled(!failed && empty)
            .accessibilityLabel(failed ? "Retry sign-in" : "Submit authorization code")
        }
    }

    private func submit() {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        engine.submitAgyToken(trimmed)
        code = ""
    }
}
