//
//  ShortcutsPane.swift
//  boringNotch
//

import KeyboardShortcuts
import SwiftUI

/// Every key combination the app answers to.
///
/// There were three of these. This pane owned two recorders, the copilot pane
/// owned three, and Pomodoro owned three more — so "what is bound to ⌥⌘C" could
/// not be answered without opening three panes, and nothing stopped two features
/// claiming the same chord.
///
/// Grouped by the feature each belongs to, because that is the question people
/// arrive with. The feature panes keep no recorders of their own; they point
/// here.
///
/// Four further names exist in `ShortcutConstants` — clipboard history,
/// microphone toggle, and the two backlight steps — and are deliberately absent:
/// nothing handles them, so a recorder for them would bind a key to nothing.
struct ShortcutsPane: View {
    @State private var shortcutConflict: String?

    var body: some View {
        SettingsPane(.shortcuts) {
            SettingCard("The notch") {
                VStack(spacing: NotchSpace.row) {
                    row("Open and close the notch", .toggleNotchOpen,
                        detail: "Toggles the notch whether or not Open on hover is set.")
                    Divider().opacity(0.35)
                    row("Pin or unpin the notch", .copilotTogglePin,
                        detail: "Works system-wide, even while another app has focus.")
                    Divider().opacity(0.35)
                    row("Peek at what is playing", .toggleSneakPeek,
                        detail: "Shows the current track without opening the notch.")
                }
            }

            SettingCard("Call and Quiz",
                        detail: "Shared controls work system-wide in whichever mode is selected.") {
                VStack(spacing: NotchSpace.row) {
                    row("Start or stop selected mode", .copilotToggleCall,
                        detail: "When Quiz is idle, opens its preflight so the target can be confirmed.")
                    Divider().opacity(0.35)
                    row("Expanded or compact", .copilotToggleLayout)
                    Divider().opacity(0.35)
                    row("Close the notch", .copilotDismiss,
                        detail: "The session keeps running; new guidance can reveal it again.")
                }
            }

            SettingCard("The live session",
                        detail: "Controls apply to the current Call or Quiz session and do nothing when none is running.") {
                VStack(spacing: NotchSpace.row) {
                    row("Previous", .sessionPrevious,
                        detail: "The previous answer.")
                    row("Next", .sessionNext)
                    Divider().opacity(0.35)
                    row("Scroll up", .sessionScrollUp,
                        detail: "Scrolls what you are reading. In Quiz, once it has asked for more of the question, this scrolls the watched window instead.")
                    row("Scroll down", .sessionScrollDown)
                    Divider().opacity(0.35)
                    if CallaFeatureAvailability.liveCoding {
                        row("Continue", .sessionAdvance,
                            detail: "Live Coding: the next step, or back to the code from a reference surface.")
                    }
                    row("Hold or resume", .sessionHold,
                        detail: "Pauses or resumes a Quiz.")
                    Divider().opacity(0.35)
                    row("Ask a question", .sessionAsk)
                    row("Answer history", .sessionSurface)
                    row("Copy what is on screen", .sessionCopy,
                        detail: "Copies the displayed Quiz answer.")
                    if CallaFeatureAvailability.liveCoding { row("Run or stop the check", .sessionRun) }
                }
            }

            SettingCard("Reference",
                        detail: "The surfaces you step aside to read, and the setup you do once.") {
                VStack(spacing: NotchSpace.row) {
                    if CallaFeatureAvailability.liveCoding {
                        row("Transcript", .sessionTranscript)
                        row("Why and checks", .sessionEvidence)
                        row("Ask for more explanation", .sessionExplain)
                        Divider().opacity(0.35)
                        row("Select working window", .sessionTarget)
                        row("Shortcut reference", .sessionShortcutHelp)
                    }
                    Divider().opacity(0.35)
                    row("Toggle code wrapping", .quizToggleWrap, detail: "Quiz only.")
                    if let shortcutConflict {
                        Text(shortcutConflict)
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }

            SettingCard("Pomodoro") {
                VStack(spacing: NotchSpace.row) {
                    row("Start / pause", .pomodoroStartPause)
                    Divider().opacity(0.35)
                    row("Skip to next block", .pomodoroSkipPhase)
                    Divider().opacity(0.35)
                    row("Stop", .pomodoroStopTimer)
                }
            }
        }
    }

    private func row(_ title: String, _ name: KeyboardShortcuts.Name,
                     detail: String? = nil) -> some View {
        SettingRow(title, detail: detail) {
            KeyboardShortcuts.Recorder("", name: name) { shortcut in
                guard let shortcut else { shortcutConflict = nil; return }
                let names: [KeyboardShortcuts.Name] = [
                    .toggleNotchOpen, .toggleSneakPeek, .pomodoroStartPause,
                    .pomodoroSkipPhase, .pomodoroStopTimer, .copilotToggleCall,
                    .copilotToggleLayout, .copilotTogglePin, .copilotDismiss,
                    .sessionPrevious, .sessionNext, .sessionScrollUp, .sessionScrollDown,
                    .sessionAdvance, .sessionHold, .sessionAsk, .sessionCopy,
                    .sessionRun, .sessionSurface, .sessionTranscript, .sessionEvidence,
                    .sessionExplain, .sessionTarget, .sessionShortcutHelp, .quizToggleWrap,
                ]
                guard names.contains(where: {
                    $0 != name && KeyboardShortcuts.getShortcut(for: $0) == shortcut
                }) else { shortcutConflict = nil; return }
                KeyboardShortcuts.setShortcut(nil, for: name)
                shortcutConflict = "Shortcut conflicts with another Boring action. Assignment removed."
            }
        }
    }
}
