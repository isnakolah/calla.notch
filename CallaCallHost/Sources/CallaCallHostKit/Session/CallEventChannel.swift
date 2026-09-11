import CallaContracts
import Darwin
import Foundation

/// Owner-only persistent event socket. JSON files remain recovery records; live
/// lifecycle, transcript, question, and answer events take this bounded path.
public final class CallEventChannel: @unchecked Sendable {
    private let path: URL
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var clients: [Int32] = []
    private var acceptTask: Task<Void, Never>?

    public init(path: URL = CallHostPaths.eventSocketFile) { self.path = path }
    deinit { stop() }

    public func start() throws {
        try CallHostPaths.ensureRoot()
        CallHostPaths.remove(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.ENFILE) }
        descriptor = fd
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let maximum = MemoryLayout.size(ofValue: address.sun_path) - 1
        guard path.path.utf8.count <= maximum else {
            Darwin.close(fd); descriptor = -1
            throw POSIXError(.ENAMETOOLONG)
        }
        _ = path.path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { destination in
                strncpy(UnsafeMutableRawPointer(destination).assumingMemoryBound(to: CChar.self), source, maximum)
            }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 2) == 0 else {
            let error = errno
            Darwin.close(fd); descriptor = -1
            throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EINVAL)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        acceptTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let client = accept(fd, nil, nil)
                if client < 0 { break }
                self.lock.withLock { self.clients.append(client) }
            }
        }
    }

    public func publish(_ event: CallEvent) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let payload = try? encoder.encode(event), payload.count <= 256 * 1_024 else { return }
        var length = UInt32(payload.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(payload)
        lock.withLock {
            clients.removeAll { client in
                guard Self.write(frame, to: client) else {
                    Darwin.close(client)
                    return true
                }
                return false
            }
        }
    }

    public func stop() {
        acceptTask?.cancel(); acceptTask = nil
        lock.withLock {
            clients.forEach { Darwin.close($0) }
            clients.removeAll()
        }
        if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
        CallHostPaths.remove(path)
    }

    private static func write(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return false }
            var written = 0
            while written < data.count {
                let count = send(fd, base.advanced(by: written), data.count - written, MSG_NOSIGNAL)
                if count > 0 { written += count; continue }
                if count < 0, errno == EINTR { continue }
                return false
            }
            return true
        }
    }
}
