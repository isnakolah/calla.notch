import Combine
import Defaults
import Foundation
import SystemConfiguration

/// Manages only the VPN services this call actually disconnected.
@MainActor
final class CallVPNManager: ObservableObject {
    static let shared = CallVPNManager()

    struct Service: Identifiable {
        let id: String
        let name: String
    }

    @Published private(set) var services: [Service] = []
    @Published private(set) var busy = false
    @Published private(set) var warning: String?
    @Published private(set) var pendingRestore: [String]

    private var monitoringTask: Task<Void, Never>?
    private var inCall = false
    private var observedActiveCall = false

    private init() {
        pendingRestore = Defaults[.callVPNPendingRestoreIDs]
        refreshServices()
    }

    var hasPendingRestore: Bool { !pendingRestore.isEmpty }

    func refreshServices() {
        guard let preferences = SCPreferencesCreate(nil, "Calla VPN services" as CFString, nil),
              let entries = SCNetworkServiceCopyAll(preferences) else {
            services = []
            return
        }
        var found: [Service] = []
        for index in 0..<CFArrayGetCount(entries) {
            let service = unsafeBitCast(CFArrayGetValueAtIndex(entries, index), to: SCNetworkService.self)
            guard let interface = SCNetworkServiceGetInterface(service),
                  let interfaceType = SCNetworkInterfaceGetInterfaceType(interface),
                  let serviceID = SCNetworkServiceGetServiceID(service) else { continue }
            let type = interfaceType as String
            guard type == "VPN" || type == "PPP" else { continue }
            let id = serviceID as String
            let name = SCNetworkServiceGetName(service).map { $0 as String } ?? id
            found.append(Service(id: id, name: name))
        }
        services = found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The meeting may still start when a VPN operation fails; the warning stays visible.
    func prepareForCall() async {
        guard !busy else { return }
        inCall = true
        observedActiveCall = false
        warning = nil
        guard Defaults[.callVPNDisconnectEnabled] else { return }
        busy = true
        defer { busy = false }
        refreshServices()
        let selected = Set(Defaults[.callVPNSelectedServiceIDs])
        var failed: [String] = []
        for service in services where selected.contains(service.id) && !pendingRestore.contains(service.id) {
            guard let connection = connection(for: service.id) else {
                failed.append(service.name)
                continue
            }
            guard SCNetworkConnectionGetStatus(connection) == .connected else { continue }
            guard SCNetworkConnectionStop(connection, true),
                  await waitForStatus(.disconnected, connection: connection) else {
                failed.append(service.name)
                continue
            }
            pendingRestore.append(service.id)
            persistPendingRestore()
        }
        let missing = selected.subtracting(services.map(\.id))
        failed.append(contentsOf: missing.sorted())
        if !failed.isEmpty {
            warning = "Could not disconnect VPN: \(failed.joined(separator: ", ")). Call started anyway."
        }
        startMonitoring()
    }

    func restoreAfterCall() async {
        inCall = false
        observedActiveCall = false
        monitoringTask?.cancel()
        monitoringTask = nil
        if pendingRestore.isEmpty {
            warning = nil
            return
        }
        await restorePending()
    }

    /// Also used after a previous app session was interrupted.
    func restorePending() async {
        guard !busy, !pendingRestore.isEmpty else { return }
        busy = true
        defer { busy = false }
        refreshServices()
        var failed: [String] = []
        for id in pendingRestore {
            guard let connection = connection(for: id) else {
                failed.append(serviceName(id))
                continue
            }
            if SCNetworkConnectionGetStatus(connection) == .connected {
                removePending(id)
                continue
            }
            guard SCNetworkConnectionStart(connection, nil, true),
                  await waitForStatus(.connected, connection: connection) else {
                failed.append(serviceName(id))
                continue
            }
            removePending(id)
        }
        warning = failed.isEmpty ? nil : "Could not reconnect VPN: \(failed.joined(separator: ", ")). Try Restore VPN."
    }

    /// A host may stop on its own without the reader pressing End call.
    func noteCallStatus(running: Bool, finishing: Bool, starting: Bool) {
        guard inCall else { return }
        if running { observedActiveCall = true }
        if observedActiveCall && !running && !finishing && !starting {
            Task { await restoreAfterCall() }
        }
    }

    private func connection(for id: String) -> SCNetworkConnection? {
        SCNetworkConnectionCreateWithServiceID(nil, id as CFString, nil, nil)
    }

    private func waitForStatus(_ target: SCNetworkConnectionStatus,
                               connection: SCNetworkConnection) async -> Bool {
        for _ in 0..<32 {
            if SCNetworkConnectionGetStatus(connection) == target { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return SCNetworkConnectionGetStatus(connection) == target
    }

    private func startMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = Task { @MainActor [weak self] in
            while let self, self.inCall, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { break }
                // A manually reconnected service is no longer ours to restore.
                for id in self.pendingRestore {
                    if let connection = self.connection(for: id),
                       SCNetworkConnectionGetStatus(connection) == .connected {
                        self.removePending(id)
                        self.warning = "A selected VPN reconnected during the call. Check your meeting video and sharing."
                    }
                }
            }
        }
    }

    private func removePending(_ id: String) {
        pendingRestore.removeAll { $0 == id }
        persistPendingRestore()
    }

    private func persistPendingRestore() {
        Defaults[.callVPNPendingRestoreIDs] = pendingRestore
    }

    private func serviceName(_ id: String) -> String {
        services.first(where: { $0.id == id })?.name ?? id
    }
}
