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
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    NotchCaps(capsLine, tint: failed ? NotchAccent.attention : NotchAccent.call)
                    Text(headline)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(NotchInk.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text(detail)
                        .font(NotchGlassType.detail)
                        .foregroundStyle(failed ? NotchAccent.attention : NotchInk.secondary)
                        .lineLimit(2)
                        .lineSpacing(1)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(detail)
                }
                Spacer(minLength: 6)
                if copilot.canAcceptCode || failed { codeRow }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            steps
                .padding(.leading, 16)
                .frame(width: 168, alignment: .leading)
                .frame(maxHeight: .infinity)
                .overlay(alignment: .leading) {
                    Rectangle().fill(NotchInk.hairline).frame(width: 1)
                }
        }
        // The shared insets, including the bottom one the notch's inward-curving
        // corners need.
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
        .onChange(of: copilot.agyLoginURL, initial: true) { _, url in
            if let url { engine.openAgySignInPageOnce(url) }
        }
    }

    private var capsLine: String {
        if succeeded { return "Signed in" }
        if failed { return "Sign-in failed" }
        return "Sign in · step \(current.rawValue + 1) of \(Step.allCases.count)"
    }

    private var headline: String {
        if succeeded { return "Signed in" }
        if failed { return "Sign in to use this Mac's copilot" }
        return current.title
    }

    private var detail: String {
        if let detail = copilot.lastResult, !detail.isEmpty { return detail }
        switch current {
        case .checking: return "Checking whether this Mac is already signed in."
        case .browser, .code: return "Approve in the browser, then paste the code it shows you."
        case .exchanging: return "Trading the code for this Mac's credentials."
        }
    }

    /// Progress as steps rather than a spinner: a wait the user can place is a
    /// wait they will tolerate.
    private var steps: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Step.allCases, id: \.rawValue) { step in
                let done = step.rawValue < current.rawValue || succeeded
                let active = step == current && !succeeded && !failed
                HStack(spacing: 8) {
                    ZStack {
                        if done {
                            Circle().fill(NotchAccent.call.opacity(0.20))
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .heavy))
                                .foregroundStyle(NotchAccent.call)
                        } else {
                            Circle().strokeBorder(active ? NotchAccent.call : Color.white.opacity(0.24),
                                                  lineWidth: active ? 1.5 : 1)
                            Text("\(step.rawValue + 1)")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(active ? NotchAccent.call : NotchInk.tertiary)
                        }
                    }
                    .frame(width: 18, height: 18)
                    Text(step.title)
                        .font(.system(size: 12, weight: active ? .semibold : .medium))
                        .foregroundStyle(active ? NotchInk.primary
                                         : done ? NotchInk.secondary : NotchInk.tertiary)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(step.title): \(done ? "done" : active ? "in progress" : "waiting")")
            }
            if let url = copilot.agyLoginURL {
                HStack(spacing: 6) {
                    linkChip("Open page", help: "Open the sign-in page") {
                        if let target = URL(string: url) { NSWorkspace.shared.open(target) }
                    }
                    linkChip("Copy link", help: "Copy the sign-in link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    }
                }
                .padding(.leading, 26)
            }
        }
        .frame(maxHeight: .infinity, alignment: .center)
        .accessibilityElement(children: .contain)
    }

    private func linkChip(_ title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.86))
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(Capsule().fill(Color.white.opacity(0.08)))
                .frame(height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .padding(.vertical, -4)
    }

    private var codeRow: some View {
        let empty = code.trimmingCharacters(in: .whitespaces).isEmpty
        let disabled = !failed && empty
        return HStack(spacing: 6) {
            TextField("Authorization code", text: $code)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(NotchInk.primary)
                .focused($codeFocused)
                .onSubmit(submit)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background {
                    let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
                    ZStack {
                        shape.fill(Color.white.opacity(0.06))
                        shape.strokeBorder(codeFocused ? NotchAccent.call.opacity(0.6)
                                           : Color.white.opacity(0.16), lineWidth: 1)
                    }
                }
                .accessibilityLabel("Authorization code")
            Button {
                if failed, empty {
                    engine.loginAgy(force: true)
                } else {
                    submit()
                }
            } label: {
                Text(failed ? "Retry" : "Submit")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(NotchAccent.onAccent)
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(failed ? NotchAccent.attention : NotchAccent.call))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(disabled ? 0.45 : 1)
            .disabled(disabled)
            .help(failed ? "Retry sign-in" : "Submit authorization code")
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
