//
//  PrivacyPane.swift
//  callaNotch
//

import Combine
import Defaults
import SwiftUI

// MARK: - What needs the reader

/// Something switched on that cannot work, and the one thing that fixes it.
struct SettingsBlocker: Identifiable, Equatable {
    enum Kind: String {
        case hostMissing, hostMicrophone, hostScreen, quizScreen, accessibility, calendars
    }

    let kind: Kind
    let title: String
    let detail: String
    /// Where the fix is, or `nil` when there is nothing in this window to press.
    let fix: SettingsRoute?
    var fixTitle: String = "Fix this"

    var id: String { kind.rawValue }

    /// The sidebar row that wears the dot.
    var section: SettingsSection { kind == .hostMissing ? .copilot : .permissions }
}

/// One answer to "is anything I turned on not working", shared by the sidebar
/// dot, Home's warning and Copilot's pre-flight, so the three cannot disagree.
@MainActor
final class SettingsAttention: ObservableObject {
    static let shared = SettingsAttention()

    @Published private(set) var blockers: [SettingsBlocker] = []

    var sections: Set<SettingsSection> { Set(blockers.map(\.section)) }

    private var cancellables: Set<AnyCancellable> = []
    private let engine = CallaEngineClient.shared
    private let monitor = PermissionMonitor.shared

    private init() {
        engine.$status.map { _ in () }
            .merge(with: monitor.$statuses.map { _ in () })
            .merge(with: Defaults.publisher(keys: .callaCopilotEnabled, .callaQuizEnabled,
                                            .hudReplacement, .showCalendar).map { _ in () })
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.recompute() }
            .store(in: &cancellables)
        recompute()
    }

    func refresh() async {
        engine.refresh()
        await monitor.refresh()
        recompute()
    }

    private func recompute() {
        let copilot = engine.status.copilot
        let copilotOn = Defaults[.callaCopilotEnabled]
        var next: [SettingsBlocker] = []

        if copilotOn, !copilot.available {
            next.append(.init(kind: .hostMissing, title: "Copilot is not installed",
                              detail: "The call host ships with the Calla runtime. Redeploy the app to install it.",
                              fix: nil))
        }
        if copilotOn, copilot.available, copilot.hostPermissionsKnown, !copilot.hostScreenGranted {
            next.append(.init(kind: .hostScreen, title: "Screen Recording is off",
                              detail: Defaults[.callaQuizEnabled]
                                ? "Screen Quiz cannot see your screen, and Copilot only hears your side of a call."
                                : "Copilot only hears your side of a call.",
                              fix: .init(.permissions, focus: "permissions.screenRecording")))
        } else if Defaults[.callaQuizEnabled], monitor.status(of: .screenRecording) == .denied {
            next.append(.init(kind: .quizScreen, title: "Screen Recording is off",
                              detail: "Screen Quiz cannot see the window you point it at.",
                              fix: .init(.permissions, focus: "permissions.screenRecording")))
        }
        if copilotOn, copilot.available, copilot.hostPermissionsKnown, !copilot.hostMicGranted {
            next.append(.init(kind: .hostMicrophone, title: "The microphone is off",
                              detail: "Copilot cannot hear your side of a call.",
                              fix: .init(.permissions, focus: "permissions.microphone")))
        }
        if Defaults[.hudReplacement], monitor.status(of: .accessibility) == .denied {
            next.append(.init(kind: .accessibility, title: "Accessibility is off",
                              detail: "The notch cannot replace the volume and brightness overlay.",
                              fix: .init(.permissions, focus: "permissions.accessibility")))
        }
        if Defaults[.showCalendar], monitor.status(of: .calendars) == .denied {
            next.append(.init(kind: .calendars, title: "Calendar access is off",
                              detail: "The notch cannot show what is next.",
                              fix: .init(.permissions, focus: "permissions.calendars")))
        }
        if next != blockers { blockers = next }
    }
}

// MARK: - The page

/// Everything macOS has been asked to allow, what each one is for, and a way
/// through fixing the one that is off.
///
/// Fixing is a short flow rather than a link: the page opens the right pane of
/// System Settings, says what to look for there, and notices on its own when
/// the switch is turned on.
struct PermissionsPane: View {
    @ObservedObject private var monitor = PermissionMonitor.shared
    @ObservedObject private var engine = CallaEngineClient.shared
    @Default(.callaCopilotEnabled) private var copilotEnabled
    @Default(.callaQuizEnabled) private var quizEnabled
    @Default(.hudReplacement) private var hudReplacement
    @Default(.showCalendar) private var showCalendar

    /// The permission being fixed in System Settings right now.
    @State private var waitingFor: SystemPermission?

    private let poll = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    private var copilot: CallaCopilotStatus { engine.status.copilot }
    /// The capture host holds the call's grants, not this app.
    private var hostInvolved: Bool { copilotEnabled && copilot.available }

    var body: some View {
        SettingsPane(.permissions) {
            SettingsList {
                ForEach(SystemPermission.allCases) { permission in
                    row(permission)
                    if waitingFor == permission { steps(for: permission) }
                }
            }
            Text("A permission is asked for only when a feature that needs it is on. Turning a feature off does not take anything back; that happens in System Settings.")
                .font(NotchType.rowDetail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
        .task {
            engine.refresh()
            await monitor.refresh()
        }
        .onReceive(poll) { _ in
            guard waitingFor != nil else { return }
            engine.refresh()
            Task { await monitor.refresh() }
        }
        .onChange(of: statusKey) {
            guard let waiting = waitingFor, status(of: waiting) == .granted else { return }
            withAnimation(NotchMotion.settle) { waitingFor = nil }
        }
    }

    /// Everything the rows read, so one change observer covers all of them.
    private var statusKey: [PermissionStatus] { SystemPermission.allCases.map(status(of:)) }

    // MARK: Row

    private func row(_ permission: SystemPermission) -> some View {
        let status = status(of: permission)
        return HStack(spacing: 14) {
            SettingsIconTile(symbol: permission.symbol,
                             color: status == .granted ? Color(red: 0.12, green: 0.56, blue: 0.31)
                                  : status == .denied && isNeeded(permission) ? Color(red: 0.72, green: 0.43, blue: 0.0)
                                  : Color(white: 0.38),
                             size: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(title(permission)).font(.system(size: 13, weight: .semibold))
                    if !isNeeded(permission) {
                        Text("· optional").font(NotchType.rowTitle).foregroundStyle(.secondary)
                    }
                }
                Text(unlocks(permission))
                    .font(NotchType.rowDetail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing(permission, status: status)
        }
        .padding(.vertical, 10)
        .frame(minHeight: 60)
        .settingsAnchor("permissions.\(permission.rawValue)")
    }

    @ViewBuilder
    private func trailing(_ permission: SystemPermission, status: PermissionStatus) -> some View {
        if status == .granted {
            Label("Allowed", systemImage: "checkmark")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(NotchTint.healthy)
                .labelStyle(.titleAndIcon)
        } else if waitingFor == permission {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Waiting for macOS…")
            }
            .font(.system(size: 12))
            .foregroundStyle(NotchTint.active)
        } else if status == .checking {
            Text("Checking…").font(.system(size: 12)).foregroundStyle(.secondary)
        } else if canAskInPlace(permission, status: status) {
            Button("Allow") { ask(permission) }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
        } else {
            Button("Open System Settings") { openSettings(for: permission) }
                .buttonStyle(.borderedProminent)
                .tint(isNeeded(permission) ? NotchTint.active : .gray)
        }
    }

    /// What to do in System Settings, shown under the row while the app waits.
    private func steps(for permission: SystemPermission) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                step(1, "In the window that just opened, find \(appNames(for: permission)).")
                step(2, "Turn it on. If macOS asks to quit and reopen the app, choose Later.")
                step(3, "Come back here. This page notices on its own.")
            }
            HStack(spacing: 8) {
                Button("Open System Settings again") { permission.openSystemSettings() }
                Button("Cancel") { withAnimation(NotchMotion.settle) { waitingFor = nil } }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 14)
        .padding(.leading, 44)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NotchTint.active.opacity(0.06))
        .padding(.horizontal, -14)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).").font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary)
            Text(text).font(NotchType.rowTitle).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Status

    /// The status that matters for what is switched on. For the call's
    /// microphone and screen that is the capture host's, not this app's.
    private func status(of permission: SystemPermission) -> PermissionStatus {
        switch permission {
        case .screenRecording:
            var parts: [PermissionStatus] = []
            if hostInvolved { parts.append(hostStatus(copilot.hostScreenGranted)) }
            if quizEnabled || !hostInvolved { parts.append(monitor.status(of: .screenRecording)) }
            return combine(parts)
        case .microphone:
            return hostInvolved ? hostStatus(copilot.hostMicGranted) : monitor.status(of: .microphone)
        default:
            return monitor.status(of: permission)
        }
    }

    private func hostStatus(_ granted: Bool) -> PermissionStatus {
        guard copilot.hostPermissionsKnown else { return .checking }
        return granted ? .granted : .denied
    }

    private func combine(_ parts: [PermissionStatus]) -> PermissionStatus {
        if parts.contains(.checking) { return .checking }
        if parts.allSatisfy({ $0 == .granted }) { return .granted }
        if parts.contains(.denied) { return .denied }
        return .undetermined
    }

    private func isNeeded(_ permission: SystemPermission) -> Bool {
        switch permission {
        case .screenRecording: return copilotEnabled || quizEnabled
        case .microphone: return copilotEnabled
        case .accessibility: return hudReplacement
        case .calendars: return showCalendar
        case .reminders: return false
        }
    }

    private func title(_ permission: SystemPermission) -> String {
        permission == .screenRecording ? "Screen & System Audio Recording" : permission.title
    }

    private func unlocks(_ permission: SystemPermission) -> String {
        switch permission {
        case .screenRecording: return "Lets Copilot hear the other side of a call and Screen Quiz read a window."
        case .microphone: return "Your side of a call."
        case .accessibility: return "Volume and brightness keys, and gestures on the notch."
        case .calendars: return "The next event beside the music, and meeting context for Copilot."
        case .reminders: return "Shows reminders alongside calendar events."
        }
    }

    private func appNames(for permission: SystemPermission) -> String {
        let host = hostInvolved && (permission == .screenRecording || permission == .microphone)
        return host ? "calla.notch and CallaCallHost" : "calla.notch"
    }

    // MARK: Fixing

    private func canAskInPlace(_ permission: SystemPermission, status: PermissionStatus) -> Bool {
        guard status == .undetermined else { return false }
        if hostInvolved, permission == .microphone { return true }
        return monitor.canRequest(permission)
    }

    private func ask(_ permission: SystemPermission) {
        if hostInvolved, permission == .microphone || permission == .screenRecording {
            engine.requestCopilotPermissions()
        } else {
            monitor.request(permission)
        }
    }

    private func openSettings(for permission: SystemPermission) {
        // The host has to have asked once to appear in System Settings' list.
        if hostInvolved, permission == .microphone || permission == .screenRecording {
            engine.requestCopilotPermissions()
        }
        if permission == .accessibility {
            XPCHelperClient.shared.requestAccessibilityAuthorization()
        }
        permission.openSystemSettings()
        withAnimation(NotchMotion.settle) { waitingFor = permission }
    }
}
