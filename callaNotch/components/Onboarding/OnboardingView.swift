//
//  OnboardingView.swift
//  callaNotch
//
//  Created by Alexander on 2025-06-23.
//

import AVFoundation
import Defaults
import SwiftUI

enum OnboardingStep {
    /// The whole first run: choose, allow, try it.
    case welcome
    /// Only the music source, for a Mac where Now Playing stopped working.
    case musicPermission
}

struct OnboardingView: View {
    @State var step: OnboardingStep = .welcome
    let onFinish: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        switch step {
        case .welcome:
            FirstRunView(onFinish: onFinish, onOpenSettings: onOpenSettings)
        case .musicPermission:
            MusicControllerSelectionView {
                CallaViewCoordinator.shared.firstLaunch = false
                onFinish()
            }
            .frame(width: 400)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// First run, in three steps: pick what lives in the notch, allow only what
/// those need, then try it.
///
/// The old onboarding asked for calendars, reminders and accessibility one
/// screen at a time before anyone had said they wanted the features those
/// unlock. Asking after the choice means nothing is requested for a feature
/// that is off.
struct FirstRunView: View {
    let onFinish: () -> Void
    let onOpenSettings: () -> Void

    @ObservedObject private var monitor = PermissionMonitor.shared
    @ObservedObject private var engine = CallaEngineClient.shared

    @State private var stepIndex = 1
    @State private var picked: Set<Feature> = [.music, .calendar, .copilot]

    private let poll = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    enum Feature: String, CaseIterable, Identifiable {
        case music, calendar, shelf, focus, hud, copilot
        var id: String { rawValue }

        var name: String {
            switch self {
            case .music: return "Music"
            case .calendar: return "Calendar"
            case .shelf: return "Shelf"
            case .focus: return "Focus Timer"
            case .hud: return "Volume & Brightness"
            case .copilot: return "Copilot"
            }
        }

        var note: String {
            switch self {
            case .music: return "What is playing, with controls."
            case .calendar: return "Your next event, beside the music."
            case .shelf: return "Drop files on the notch to keep them close."
            case .focus: return "Focus blocks and breaks."
            case .hud: return "Replaces the system overlay."
            case .copilot: return "Suggests what to say during calls."
            }
        }

        var symbol: String {
            switch self {
            case .music: return "music.note"
            case .calendar: return "calendar"
            case .shelf: return "tray.fill"
            case .focus: return "timer"
            case .hud: return "speaker.wave.2.fill"
            case .copilot: return "waveform"
            }
        }

        var tint: Color {
            switch self {
            case .music: return SettingsSection.music.tint
            case .calendar: return SettingsSection.calendar.tint
            case .shelf: return SettingsSection.shelf.tint
            case .focus: return SettingsSection.focus.tint
            case .hud: return Color(white: 0.30)
            case .copilot: return SettingsSection.copilot.tint
            }
        }

        var needs: [SystemPermission] {
            switch self {
            case .calendar: return [.calendars]
            case .hud: return [.accessibility]
            case .copilot: return [.microphone, .screenRecording]
            default: return []
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            stepper.padding(.top, 34)

            Group {
                switch stepIndex {
                case 1: choose
                case 2: allow
                default: tryIt
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 60)
            .padding(.top, 32)

            footer
        }
        .frame(width: 860, height: 600)
        .background(NotchSurface.base)
        .preferredColorScheme(.dark)
        .onAppear { picked = current() }
        .task { await monitor.refresh(); engine.refresh() }
        .onReceive(poll) { _ in
            guard stepIndex == 2 else { return }
            engine.refresh()
            Task { await monitor.refresh() }
        }
    }

    // MARK: - Steps

    private var stepper: some View {
        HStack(spacing: 28) {
            ForEach(Array(["Choose", "Allow", "Try it"].enumerated()), id: \.offset) { index, label in
                let number = index + 1
                HStack(spacing: 8) {
                    ZStack {
                        Circle().fill(number == stepIndex ? NotchTint.active
                                      : number < stepIndex ? NotchTint.healthy : Color.primary.opacity(0.1))
                        if number < stepIndex {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                        } else {
                            Text("\(number)").font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .frame(width: 20, height: 20)
                    .foregroundStyle(number <= stepIndex ? .white : .secondary)
                    Text(label)
                        .font(.system(size: 12))
                        .foregroundStyle(number == stepIndex ? .primary : .secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Step \(stepIndex) of 3"))
    }

    private func heading(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.system(size: 26, weight: .semibold))
            Text(detail).font(.system(size: 14)).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
    }

    private var choose: some View {
        VStack(spacing: 28) {
            heading("What should live in the notch?", "Pick any. Everything can change later in Settings.")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                ForEach(Feature.allCases) { feature in featureCard(feature) }
            }
            .frame(maxWidth: 740)
        }
    }

    private func featureCard(_ feature: Feature) -> some View {
        let on = picked.contains(feature)
        return Button {
            if on { picked.remove(feature) } else { picked.insert(feature) }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    SettingsIconTile(symbol: feature.symbol, color: feature.tint, size: 32)
                    Spacer()
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18))
                        .foregroundStyle(on ? NotchTint.active : Color.primary.opacity(0.3))
                }
                Text(feature.name).font(.system(size: 14, weight: .semibold))
                Text(feature.note)
                    .font(NotchType.rowDetail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(on ? NotchTint.active.opacity(0.12) : NotchSurface.raised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(on ? NotchTint.active : NotchSurface.hairline, lineWidth: on ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var needed: [(SystemPermission, String)] {
        SystemPermission.allCases.compactMap { permission in
            let users = Feature.allCases.filter { picked.contains($0) && $0.needs.contains(permission) }
            guard !users.isEmpty else { return nil }
            return (permission, users.map(\.name).joined(separator: " and "))
        }
    }

    private var allow: some View {
        VStack(spacing: 28) {
            heading("Allow what those need", "Only the permissions for what you picked. Nothing else is asked for.")
            SettingsList {
                if needed.isEmpty {
                    SettingsListRow("Nothing you picked needs a permission.") { EmptyView() }
                }
                ForEach(needed, id: \.0) { permission, users in
                    SettingsListRow(permission == .screenRecording ? "Screen & System Audio Recording" : permission.title,
                                    detail: "For \(users)") {
                        if status(of: permission) == .granted {
                            Label("Allowed", systemImage: "checkmark")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(NotchTint.healthy)
                        } else {
                            Button("Allow") { request(permission) }
                        }
                    }
                }
            }
            .frame(maxWidth: 620)
        }
    }

    private var tryIt: some View {
        VStack(spacing: 28) {
            heading("Move your pointer to the notch", "That is the whole app. It opens on hover and closes when you leave.")
            NotchStage(height: 220) {
                NotchSlab(width: 440, height: 130, bottomRadius: 20, shadow: true) {
                    HStack(spacing: 8) {
                        ForEach(Feature.allCases.filter { picked.contains($0) }) { feature in
                            SettingsIconTile(symbol: feature.symbol, color: feature.tint, size: 32)
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 14)
                }
            }
            .frame(width: 640)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if stepIndex > 1 {
                Button("Back") { withAnimation(NotchMotion.settle) { stepIndex -= 1 } }
            }
            Spacer()
            Text(footnote).font(NotchType.rowDetail).foregroundStyle(.secondary)
            if stepIndex < 3 {
                Button("Continue") {
                    if stepIndex == 1 { apply() }
                    withAnimation(NotchMotion.settle) { stepIndex += 1 }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Open Settings") { finish(); onOpenSettings() }
                Button("Done") { finish(); onFinish() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .overlay(alignment: .top) { Rectangle().fill(NotchSurface.hairline).frame(height: 1) }
    }

    private var footnote: String {
        switch stepIndex {
        case 1: return "\(picked.count) picked"
        case 2:
            let left = needed.filter { status(of: $0.0) != .granted }.count
            return left == 0 ? "All set" : "\(left) left, or skip and allow later"
        default: return ""
        }
    }

    // MARK: - Applying

    private func current() -> Set<Feature> {
        var set: Set<Feature> = []
        if CallaViewCoordinator.shared.musicLiveActivityEnabled { set.insert(.music) }
        if Defaults[.showCalendar] { set.insert(.calendar) }
        if Defaults[.callaShelf] { set.insert(.shelf) }
        if Defaults[.pomodoroTab] { set.insert(.focus) }
        if Defaults[.hudReplacement] { set.insert(.hud) }
        if Defaults[.callaCopilotEnabled] { set.insert(.copilot) }
        return set.isEmpty ? [.music, .calendar] : set
    }

    private func apply() {
        CallaViewCoordinator.shared.musicLiveActivityEnabled = picked.contains(.music)
        Defaults[.showCalendar] = picked.contains(.calendar)
        Defaults[.callaShelf] = picked.contains(.shelf)
        Defaults[.pomodoroTab] = picked.contains(.focus)
        Defaults[.callaCopilotEnabled] = picked.contains(.copilot)
        // The HUD switch is turned on once Accessibility allows it.
        if !picked.contains(.hud) { Defaults[.hudReplacement] = false }
    }

    private func finish() {
        if picked.contains(.hud), monitor.status(of: .accessibility) == .granted {
            Defaults[.hudReplacement] = true
        }
        CallaViewCoordinator.shared.firstLaunch = false
    }

    // MARK: - Permissions

    private var hostInvolved: Bool { picked.contains(.copilot) && engine.status.copilot.available }

    private func status(of permission: SystemPermission) -> PermissionStatus {
        let copilot = engine.status.copilot
        if hostInvolved, permission == .microphone || permission == .screenRecording {
            guard copilot.hostPermissionsKnown else { return .undetermined }
            let granted = permission == .microphone ? copilot.hostMicGranted : copilot.hostScreenGranted
            return granted ? .granted : .denied
        }
        return monitor.status(of: permission)
    }

    private func request(_ permission: SystemPermission) {
        if hostInvolved, permission == .microphone || permission == .screenRecording {
            engine.requestCopilotPermissions()
            if permission == .screenRecording { permission.openSystemSettings() }
            return
        }
        if monitor.canRequest(permission) {
            monitor.request(permission)
        } else {
            permission.openSystemSettings()
        }
    }
}
