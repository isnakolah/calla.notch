import CallaContracts
import Darwin
import Foundation
import XCTest
@testable import CallaCallHostKit

final class CallEventChannelTests: XCTestCase {
    func testOwnerOnlySocketStreamsBoundedTypedEvent() async throws {
        let root = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("ce-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("events.sock")
        let channel = CallEventChannel(path: path)
        try channel.start()
        defer { channel.stop() }

        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let fd = try connect(path)
        defer { Darwin.close(fd) }
        try await Task.sleep(for: .milliseconds(20))
        let event = CallEvent(callID: "call-a", generation: 4, sequence: 9,
                              kind: .answer, message: "ready")
        channel.publish(event)

        let header = try read(count: 4, from: fd)
        let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        XCTAssertLessThanOrEqual(length, 256 * 1_024)
        let payload = try read(count: Int(length), from: fd)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CallEvent.self, from: payload)
        XCTAssertEqual(decoded.id, event.id)
        XCTAssertEqual(decoded.callID, event.callID)
        XCTAssertEqual(decoded.generation, event.generation)
        XCTAssertEqual(decoded.sequence, event.sequence)
        XCTAssertEqual(decoded.kind, event.kind)
        XCTAssertEqual(decoded.message, event.message)
    }

    private func connect(_ path: URL) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.ENFILE) }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let maximum = MemoryLayout.size(ofValue: address.sun_path) - 1
        _ = path.path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { destination in
                strncpy(UnsafeMutableRawPointer(destination).assumingMemoryBound(to: CChar.self), source, maximum)
            }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { let code = errno; Darwin.close(fd); throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EINVAL) }
        return fd
    }

    private func read(count: Int, from fd: Int32) throws -> Data {
        var data = Data(count: count)
        let complete = data.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            var offset = 0
            while offset < count {
                let result = recv(fd, base.advanced(by: offset), count - offset, 0)
                if result > 0 { offset += result; continue }
                if result < 0, errno == EINTR { continue }
                return false
            }
            return true
        }
        guard complete else { throw POSIXError(.ETIMEDOUT) }
        return data
    }
}
