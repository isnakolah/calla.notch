import CryptoKit
import Foundation
import XCTest
@testable import DistributionCore

final class ComponentTransferTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("transfer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    func testCopyingAToolFolderKeepsFilesModesAndLinks() throws {
        let source = root.appendingPathComponent("codex/0.1.0")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let binary = source.appendingPathComponent("bin/codex")
        try Data("#!/bin/sh\necho codex 0.1.0\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("codex-path").path, withDestinationPath: "bin")

        var reports: [TransferStatus] = []
        let destination = root.appendingPathComponent("Components/codex/0.1.0")
        try Transfer.copy(source, to: destination, name: "Codex") { reports.append($0) }

        let copied = destination.appendingPathComponent("bin/codex")
        XCTAssertEqual(try Data(contentsOf: copied), try Data(contentsOf: binary))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: copied.path))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("codex-path").path), "bin")
        XCTAssertEqual(reports.last?.fraction, 1)
        // Nothing half-copied is left beside the destination.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path), ["0.1.0"])
    }

    func testCopyingOneFileReplacesWhatWasThere() throws {
        let source = root.appendingPathComponent("model.bin")
        try Data(repeating: 7, count: 4096).write(to: source)
        let destination = root.appendingPathComponent("models/model.bin")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: destination)
        try Transfer.copy(source, to: destination, name: "Model") { _ in }
        XCTAssertEqual(try Data(contentsOf: destination), Data(repeating: 7, count: 4096))
    }

    func testVerificationChecksTheBytesAndRemembersAPass() throws {
        let file = root.appendingPathComponent("model.bin")
        let bytes = Data(repeating: 3, count: 10_000)
        try bytes.write(to: file)
        let expected = sha256(bytes)

        XCTAssertFalse(Transfer.verify(file, sha256: expected, size: 9_999, name: "Model") { _ in })
        XCTAssertFalse(Transfer.verify(file, sha256: String(repeating: "0", count: 64), name: "Model") { _ in })

        var hashed = false
        XCTAssertTrue(Transfer.verify(file, sha256: expected, size: 10_000, name: "Model") { _ in hashed = true })
        XCTAssertTrue(hashed)
        // A second check of the unchanged file trusts the sidecar.
        hashed = false
        XCTAssertTrue(Transfer.verify(file, sha256: expected, size: 10_000, name: "Model") { _ in hashed = true })
        XCTAssertFalse(hashed)

        // A changed file is read again and fails.
        try Data(repeating: 4, count: 10_000).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: file.path)
        XCTAssertFalse(Transfer.verify(file, sha256: expected, size: 10_000, name: "Model") { _ in })
    }

    func testProgressTextReadsLikeAProgressLine() {
        let status = TransferStatus(verb: "Downloading", name: "English speech model",
                                    done: 120_000_000, total: 488_000_000, bytesPerSecond: 8_000_000)
        XCTAssertEqual(status.summary, "120 MB of 488 MB · 8 MB/s · about 46 s left")
        XCTAssertEqual(status.fraction!, 120.0 / 488.0, accuracy: 0.0001)
        XCTAssertEqual(TransferStatus.size(1_624_555_275), "1.62 GB")
        XCTAssertEqual(TransferStatus.duration(3725), "1 h 2 min")
    }

    func testDownloadsRefuseAnythingButHTTPS() {
        XCTAssertThrowsError(try Transfer.download(URL(string: "http://example.com/x")!,
                                                   to: root.appendingPathComponent("x"), expectedSize: nil, name: "X") { _ in })
    }
}

/// Opt-in: `DIST_LIVE_DOWNLOAD=<dir>` downloads the 148 MB base.en model into
/// that folder, resuming a partial file left by a killed earlier run.
final class LiveDownloadTests: XCTestCase {
    func testDownloadResumesAndVerifies() throws {
        guard let directory = ProcessInfo.processInfo.environment["DIST_LIVE_DOWNLOAD"] else { throw XCTSkip("set DIST_LIVE_DOWNLOAD") }
        let destination = URL(fileURLWithPath: directory).appendingPathComponent("ggml-base.en.bin")
        try Transfer.download(URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin")!,
                              to: destination, expectedSize: 147_964_211, name: "Base model") { status in
            print("PROGRESS \(status.fraction.map { String(format: "%.0f%%", $0 * 100) } ?? "?") \(status.verb) \(status.name) — \(status.summary)")
        }
        XCTAssertTrue(Transfer.verify(destination, sha256: "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002",
                                      size: 147_964_211, name: "Base model") { _ in })
    }
}
