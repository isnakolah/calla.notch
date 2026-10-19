import AppKit
import SwiftUI

struct NotchSizePane: View {
    @ObservedObject private var session = NotchResizeSession.shared

    private var profileBinding: Binding<NotchSizeProfile> {
        Binding(get: { session.activeProfile }, set: { session.select($0) })
    }

    private var widthBinding: Binding<Double> {
        Binding(
            get: { Double(session.liveSize.width) },
            set: { value in
                session.setSize(CGSize(width: value, height: session.liveSize.height))
            }
        )
    }

    private var heightBinding: Binding<Double> {
        Binding(
            get: { Double(session.liveSize.height) },
            set: { value in
                session.setSize(CGSize(width: session.liveSize.width, height: value))
            }
        )
    }

    var body: some View {
        SettingsPane(page: .notchSize) {
            SettingCard("Edit on the notch",
                        detail: "Drag the bottom-right corner on the real notch. Its top stays centred on the display.",
                        tint: session.isEditing ? NotchTint.active : nil) {
                HStack(spacing: NotchSpace.row) {
                    SettingStatusIcon(ok: session.isEditing)
                    VStack(alignment: .leading, spacing: NotchSpace.hair) {
                        Text(session.isEditing ? "Preview active" : "Preview finished")
                            .font(NotchType.rowTitle)
                        Text(session.failureReason ?? editorStatus)
                            .font(NotchType.rowDetail)
                            .foregroundStyle(session.failureReason == nil ? Color.secondary : NotchTint.stuck)
                    }
                    Spacer(minLength: 8)
                    if !session.isEditing {
                        Button("Edit on notch") { beginEditing() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                }
            }

            SettingCard("Profile",
                        detail: "Normal sizes regular tabs. Call uses the expanded and compact sizes.") {
                Picker("Profile", selection: profileBinding) {
                    ForEach(NotchSizeProfile.allCases) { profile in
                        Text(profile.title).tag(profile)
                    }
                }
                .pickerStyle(.menu)

                HStack(alignment: .top, spacing: NotchSpace.card) {
                    NotchSlider(
                        value: widthBinding,
                        range: Double(session.activeProfile.widthBounds.lowerBound)...Double(session.activeProfile.widthBounds.upperBound),
                        step: 2,
                        label: "Width",
                        format: { "\(Int($0)) pt" },
                        ends: ("\(Int(session.activeProfile.widthBounds.lowerBound))",
                               "\(Int(session.activeProfile.widthBounds.upperBound))")
                    )
                    NotchSlider(
                        value: heightBinding,
                        range: Double(session.activeProfile.heightBounds.lowerBound)...Double(session.activeProfile.heightBounds.upperBound),
                        step: 2,
                        label: "Height",
                        format: { "\(Int($0)) pt" },
                        ends: ("\(Int(session.activeProfile.heightBounds.lowerBound))",
                               "\(Int(session.activeProfile.heightBounds.upperBound))")
                    )
                }

                HStack {
                    Text("\(Int(session.liveSize.width)) × \(Int(session.liveSize.height)) points")
                        .font(NotchType.figure)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Spacer()
                    Button("Reset \(session.activeProfile.title)") {
                        session.resetActiveProfile()
                    }
                    .controlSize(.small)
                    .disabled(NotchSizePreferences.isDefault(session.activeProfile))
                }
            }

            SettingCard("Content safety") {
                SettingRow("Knowledge and drop panels",
                           detail: "These may grow above Normal when their controls need more room. Saved Normal size does not change.") {
                    SettingBadge("Protected", tint: NotchTint.healthy)
                }
                SettingRow("Call preview",
                           detail: "Sample transcript and answer are inert. Resizing never starts capture or sends a Call command.") {
                    SettingBadge("No capture", tint: NotchTint.healthy)
                }
            }
        }
        .onDisappear { session.finish() }
    }

    private var editorStatus: String {
        guard session.isEditing else {
            return "Saved sizes remain in use. Start another preview to adjust them directly."
        }
        guard let uuid = session.targetScreenUUID,
              let screen = NSScreen.screen(withUUID: uuid) else {
            return "Target notch is pinned open until Done or this page closes."
        }
        return "Editing on \(screen.localizedName). Done restores prior tab and open state."
    }

    private func beginEditing() {
        session.begin(on: SettingsWindowController.shared.window?.screen)
    }
}
