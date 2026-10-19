//
//  AppearancePane.swift
//  callaNotch
//

import Defaults
import SwiftUI

/// Size, colour and layout of the notch, edited against a drawing of it.
///
/// Notch Size, Accent Colour, Header Layout, Volume & Brightness and the shape
/// switches from Window were five pages. They all change the same surface, so
/// they share one page and one preview, and the preview answers every change
/// as it is made.
struct AppearancePane: View {
    @ObservedObject private var session = NotchResizeSession.shared
    @Default(.enableShadow) private var enableShadow
    @Default(.cornerRadiusScaling) private var cornerRadiusScaling
    @Default(.hudReplacement) private var hudReplacement
    @Default(.notchHeightMode) private var notchHeightMode
    @Default(.notchHeight) private var notchHeight
    @Default(.notchHeaderLeading) private var leading
    @Default(.notchHeaderTrailing) private var trailing
    @Default(.useCustomAccentColor) private var useCustomAccentColor
    @Default(.customAccentColorData) private var customAccentColorData
    @Environment(\.settingsRouter) private var router

    @State private var accessibilityGranted = true

    /// Three sizes most people want, so nobody has to drag to get one of them.
    private enum Preset: String, CaseIterable, Identifiable {
        case compact = "Compact", standard = "Standard", roomy = "Roomy"
        var id: String { rawValue }
        var size: CGSize {
            switch self {
            case .compact: return CGSize(width: 512, height: 168)
            case .standard: return CGSize(width: 600, height: 196)
            case .roomy: return CGSize(width: 700, height: 232)
            }
        }
    }

    /// Read through the session while it is on Normal, so the preview follows
    /// a size being dragged on screen as well as one picked here.
    private var normalSize: CGSize {
        session.activeProfile == .normal ? session.liveSize : NotchSizePreferences.size(.normal)
    }

    private var preset: Preset? {
        Preset.allCases.first { abs($0.size.width - normalSize.width) < 1 && abs($0.size.height - normalSize.height) < 1 }
    }

    var body: some View {
        SettingsPane(.appearance) {
            stage

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: SettingsMetrics.groupGap) {
                    sizeGroup
                    SettingsList("Accent colour") { AccentSwatches() }
                        .settingsAnchor(SettingsPage.accent)
                }
                .frame(maxWidth: .infinity, alignment: .top)

                VStack(alignment: .leading, spacing: SettingsMetrics.groupGap) {
                    shapeGroup
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }

            SettingsEmbedded(.headerLayout) { NotchLayoutPane() }

            SettingsAdvancedFold("appearance", title: "More options",
                                 opensFor: [SettingsPage.huds.identifier]) {
                SettingsEmbedded(.notchSize, caption: "Size of each layout") { NotchSizePane() }
                SettingsEmbedded(.huds) { HUD() }
            }
        }
        .onAppear { if !session.isEditing { session.select(.normal) } }
        .task { accessibilityGranted = await XPCHelperClient.shared.isAccessibilityAuthorized() }
        .onReceive(NotificationCenter.default.publisher(for: .accessibilityAuthorizationChanged)) { note in
            if let granted = note.userInfo?["granted"] as? Bool { accessibilityGranted = granted }
        }
        .onChange(of: notchHeightMode) {
            switch notchHeightMode {
            case .matchRealNotchSize: notchHeight = 38
            case .matchMenuBar: notchHeight = 44
            case .custom: notchHeight = 38
            }
            NotificationCenter.default.post(name: Notification.Name.notchHeightChanged, object: nil)
        }
    }

    // MARK: - Preview

    /// The open notch, to scale, with the header items where they really are
    /// and the accent on the one thing that is live.
    private var stage: some View {
        let scale = min(1, 600 / max(normalSize.width, 1)) * 0.86
        let width = normalSize.width * scale
        let height = min(normalSize.height * scale, 150)
        let radius: CGFloat = cornerRadiusScaling ? min(26, 12 + height / 12) : 12

        return NotchStage(height: 186) {
            NotchSlab(width: width, height: height, bottomRadius: radius, shadow: enableShadow) {
                VStack(spacing: 10) {
                    HStack {
                        headerStrip(leading.compactMap { $0 }, highlightFirst: true)
                        Spacer(minLength: 150)
                        headerStrip(trailing.compactMap { $0 }, highlightFirst: false)
                    }
                    .frame(height: 22)
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(red: 0.76, green: 0.38, blue: 0.23))
                            .frame(width: height * 0.45, height: height * 0.45)
                        VStack(alignment: .leading, spacing: 6) {
                            Capsule().fill(.white.opacity(0.85)).frame(width: 110, height: 8)
                            Capsule().fill(.white.opacity(0.4)).frame(width: 70, height: 7)
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.15))
                                Capsule().fill(NotchTint.active).frame(width: 60)
                            }
                            .frame(height: 4)
                            .padding(.top, 4)
                        }
                        Spacer(minLength: 0)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
        }
        .accessibilityLabel(Text("Live preview of the open notch"))
        // The accent is read imperatively, so name the two keys it comes from.
        .id("\(useCustomAccentColor)-\(customAccentColorData?.count ?? 0)")
    }

    private func headerStrip(_ items: [NotchHeaderItem], highlightFirst: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(items.filter { $0 != .none }.enumerated()), id: \.offset) { index, item in
                Image(systemName: item.icon)
                    .font(.system(size: 11))
                    .foregroundStyle(highlightFirst && index == 0 ? NotchTint.active : .white.opacity(0.6))
                    .frame(width: 26, height: 22)
                    .background(highlightFirst && index == 0 ? Color.white.opacity(0.14) : .clear,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
    }

    // MARK: - Groups

    private var sizeGroup: some View {
        SettingsList("Size") {
            SettingsListRow("Open notch") {
                Picker("", selection: Binding(
                    get: { preset },
                    set: { new in
                        guard let new else { return }
                        session.select(.normal)
                        session.setSize(new.size)
                    })) {
                    ForEach(Preset.allCases) { Text($0.rawValue).tag(Optional($0)) }
                    if preset == nil { Text("Custom").tag(Preset?.none) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
            SettingsListRow("Closed height") {
                Picker("", selection: $notchHeightMode) {
                    Text("Notch").tag(WindowHeightMode.matchRealNotchSize)
                    Text("Menu bar").tag(WindowHeightMode.matchMenuBar)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
            SettingsListRow("Fine-tune", detail: "Drag the notch's edges on screen.") {
                Button(session.isEditing ? "Editing…" : "Edit on screen") {
                    session.select(.normal)
                    session.begin(on: SettingsWindowController.shared.window?.screen)
                }
                .disabled(session.isEditing)
            }
        }
        .settingsAnchor(SettingsPage.notchSize)
    }

    private var shapeGroup: some View {
        SettingsList("Shape") {
            SettingsToggleRow("Shadow", isOn: $enableShadow)
            SettingsToggleRow("Rounder corners when larger", isOn: $cornerRadiusScaling)
            SettingsListRow("Volume & brightness",
                            detail: hudReplacement || accessibilityGranted
                                ? "Replace the system overlay"
                                : "Needs Accessibility to show in the notch") {
                Picker("", selection: Binding(
                    get: { hudReplacement },
                    set: { wantsNotch in
                        if wantsNotch, !accessibilityGranted {
                            router?.go(.init(.permissions, focus: "permissions.accessibility"))
                            return
                        }
                        hudReplacement = wantsNotch
                    })) {
                    Text("In notch").tag(true)
                    Text("System").tag(false)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
        .settingsAnchor("appearance.shape")
    }
}
