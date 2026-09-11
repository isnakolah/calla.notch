import ApplicationServices
import AppKit
import CallaContracts
import CoreImage
import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import IntelligenceCore
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers
@preconcurrency import Vision

public struct QuizCapturedWindow: Sendable {
    public let target: QuizWindowTarget
    public let jpeg: Data
    public let width: Int
    public let height: Int
    public let normalizedOCR: String
    public let tileHashes: [UInt64]
    public let visualHash: UInt64
    public let anchors: [String]
    /// OCR lines as written, for naming the question to a reader. Solve frames
    /// only — a probe never shows anyone anything.
    public let headlines: [String]?
}

public enum QuizWindowCaptureFailure: Error, Sendable, LocalizedError {
    case targetMissing
    case targetIdentityChanged
    case captureTooLarge
    case jpegEncodingFailed
    case invalidCaptureResolution
    case accessibilityDenied
    case captureTimedOut

    public var errorDescription: String? {
        switch self {
        case .targetMissing: "Quiz target window is closed or unavailable"
        case .targetIdentityChanged: "Quiz target identity changed; retarget required"
        case .captureTooLarge: "Quiz target capture exceeds 3 MiB"
        case .jpegEncodingFailed: "Quiz target could not be encoded"
        case .invalidCaptureResolution: "Quiz capture resolution is unsupported"
        case .accessibilityDenied: "Accessibility permission is required to scroll target window"
        case .captureTimedOut: "Quiz selected-window capture timed out"
        }
    }
}

public enum QuizWindowCatalog {
    public static func list() async throws -> [QuizWindowTarget] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        return content.windows.compactMap { window in
            guard let app = window.owningApplication, window.windowID > 0,
                  window.frame.width >= 160, window.frame.height >= 120,
                  app.bundleIdentifier.range(
                    of: "^[A-Za-z0-9][A-Za-z0-9.-]{2,239}$",
                    options: .regularExpression) != nil else { return nil }
            return QuizWindowTarget(
                processID: app.processID, windowID: window.windowID,
                bundleID: app.bundleIdentifier,
                applicationName: app.applicationName,
                windowTitle: window.title ?? "Untitled window",
                pixelWidth: Int(window.frame.width), pixelHeight: Int(window.frame.height))
        }.sorted {
            if $0.applicationName == $1.applicationName { return $0.windowTitle < $1.windowTitle }
            return $0.applicationName < $1.applicationName
        }
    }

    static func resolve(_ target: QuizWindowTarget) async throws -> SCWindow {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: { $0.windowID == target.windowID }) else {
            throw QuizWindowCaptureFailure.targetMissing
        }
        guard let app = window.owningApplication,
              app.processID == target.processID,
              app.bundleIdentifier == target.bundleID else {
            throw QuizWindowCaptureFailure.targetIdentityChanged
        }
        return window
    }
}

/// Selected-window-only ScreenCaptureKit path. No display filter, cursor, audio,
/// or frontmost-app following exists in this type.
public actor QuizWindowCapture {
    public init() {}

    public func capture(
        _ target: QuizWindowTarget,
        resolution: QuizCaptureResolution = QuizContract.defaultCaptureResolution,
        detail: QuizCaptureDetail = .solve
    ) async throws -> QuizCapturedWindow {
        // ScreenCaptureKit screenshot APIs still require CoreGraphics process
        // initialization in a command-line host. This does not activate app or
        // make target key.
        await MainActor.run {
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            if !application.isRunning { application.finishLaunching() }
        }
        let window = try await QuizWindowCatalog.resolve(target)
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = false
        configuration.capturesAudio = false
        let nativeSize = Self.nativePixelSize(for: window)
        let scale = min(
            1,
            Double(resolution.maximumWidth) / Double(nativeSize.width),
            Double(resolution.maximumHeight) / Double(nativeSize.height))
        configuration.width = max(1, Int((Double(nativeSize.width) * scale).rounded()))
        configuration.height = max(1, Int((Double(nativeSize.height) * scale).rounded()))
        configuration.scalesToFit = true
        // One frame is all this stream is for, so the interval is a floor on how
        // long the first one can take to arrive. A timescale of 2 made that floor
        // 500 ms of pure latency on every single capture.
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 1
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

        let image = try await QuizOneFrameStream.capture(
            filter: SCContentFilter(desktopIndependentWindow: window),
            configuration: configuration)
        return try await Self.analyze(image, target: target, detail: detail)
    }

    /// Exact post-capture pipeline, exposed internally for frozen screenshot
    /// fixtures. Tests exercise same JPEG bound, Vision OCR, fingerprints, and
    /// anchors as live ScreenCaptureKit frames without requiring TCC or a window.
    /// - Parameter reusing: the previous frame, when there is one. A probe whose
    ///   tiles have not moved is the same screen, and re-reading it with Vision
    ///   produces the same words at a cost that dwarfs everything else in this
    ///   function. The watcher runs twice a second on screens that mostly sit
    ///   still, so this is the bulk of the idle cost — and skipping it also frees
    ///   the CPU during a solve.
    public static func analyze(_ image: CGImage, target: QuizWindowTarget,
                               detail: QuizCaptureDetail = .solve,
                               reusing previous: QuizCapturedWindow? = nil)
    async throws -> QuizCapturedWindow {
        // Both hashes sample the same buffer. Each used to call `rgba` itself,
        // which allocates width * height * 4 bytes and rasterises the whole
        // image — so a 3402x2128 frame was drawn and copied twice, twice a
        // second, to produce 64 bits and a tile array.
        let raster = Self.rgba(image)
        let tiles = Self.tileHashes(image, raster: raster)
        let visual = Self.averageHash(image, raster: raster)

        // Hashes first, because they are what decides whether the expensive part
        // is needed at all.
        if detail == .probe, let previous, !previous.tileHashes.isEmpty,
           QuizFrameObservation.tileDifference(previous.tileHashes, tiles) <= unchangedTileRatio,
           (previous.visualHash ^ visual).nonzeroBitCount <= 6 {
            return QuizCapturedWindow(
                target: target, jpeg: Data(), width: image.width, height: image.height,
                normalizedOCR: previous.normalizedOCR, tileHashes: tiles,
                visualHash: visual, anchors: previous.anchors, headlines: previous.headlines)
        }

        let jpeg = detail.needsJPEG
            ? try Self.boundedJPEGData(image, preferredQuality: 0.85)
            : Data()
        let ocr = await Self.recognize(image, detail: detail)
        let normalized = QuizFrameObservation.normalizeOCR(ocr.joined(separator: "\n"))
        return QuizCapturedWindow(
            target: target, jpeg: jpeg, width: image.width, height: image.height,
            normalizedOCR: normalized, tileHashes: tiles,
            visualHash: visual, anchors: Self.anchors(from: ocr),
            headlines: detail.needsJPEG ? Self.headlines(from: ocr) : nil)
    }

    /// Tighter than the detector's stability threshold on purpose: this decides
    /// whether to *reuse text*, so it should only fire when the screen really has
    /// not moved.
    private static let unchangedTileRatio = 0.0

    public func scroll(_ target: QuizWindowTarget, direction: QuizCommandKind) async throws {
        _ = try await QuizWindowCatalog.resolve(target)
        guard AXIsProcessTrusted() else { throw QuizWindowCaptureFailure.accessibilityDenied }
        guard direction == .scrollUp || direction == .scrollDown else { return }
        let delta: Int32 = direction == .scrollUp ? 6 : -6
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                  wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0) else { return }
        event.postToPid(target.processID)
    }

    private static func jpegData(_ image: CGImage, quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw QuizWindowCaptureFailure.jpegEncodingFailed
        }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw QuizWindowCaptureFailure.jpegEncodingFailed
        }
        return data as Data
    }

    /// Treat setting as preferred quality. Step down only when required by
    /// immutable 3 MiB transport limit, never below user-selectable minimum.
    private static func boundedJPEGData(_ image: CGImage, preferredQuality: Double) throws -> Data {
        let minimumQuality = 0.45
        var quality = preferredQuality
        while quality + 0.000_1 >= minimumQuality {
            let jpeg = try jpegData(image, quality: quality)
            if jpeg.count <= QuizContract.maximumCaptureBytes { return jpeg }
            quality -= 0.05
        }
        throw QuizWindowCaptureFailure.captureTooLarge
    }

    /// Resolve window's display scale without assuming main display. Window
    /// frame and CoreGraphics display bounds share global coordinates.
    static func nativePixelSize(for window: SCWindow) -> (width: Int, height: Int) {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return (max(1, Int(window.frame.width)), max(1, Int(window.frame.height)))
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else {
            return (max(1, Int(window.frame.width)), max(1, Int(window.frame.height)))
        }
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        let display = displays.first { CGDisplayBounds($0).contains(center) }
            ?? displays.max { lhs, rhs in
                CGDisplayBounds(lhs).intersection(window.frame).width
                    * CGDisplayBounds(lhs).intersection(window.frame).height
                    < CGDisplayBounds(rhs).intersection(window.frame).width
                    * CGDisplayBounds(rhs).intersection(window.frame).height
            }
        guard let display else {
            return (max(1, Int(window.frame.width)), max(1, Int(window.frame.height)))
        }
        let bounds = CGDisplayBounds(display)
        let mode = CGDisplayCopyDisplayMode(display)
        let scaleX = mode.map { Double($0.pixelWidth) / max(1, bounds.width) } ?? 1
        let scaleY = mode.map { Double($0.pixelHeight) / max(1, bounds.height) } ?? 1
        return (
            max(1, Int((window.frame.width * scaleX).rounded())),
            max(1, Int((window.frame.height * scaleY).rounded())))
    }

    private static func recognize(_ image: CGImage,
                                  detail: QuizCaptureDetail) async -> [String] {
        guard detail.needsAccurateOCR else {
            // A stability probe is only ever fed to a word-overlap ratio and an
            // anchor scan. `.accurate` with language correction, twice, is the
            // most expensive thing in the pipeline and none of that precision
            // survives the comparison.
            return await recognize(image, region: nil, detail: detail)
        }
        async let full = recognize(image, region: nil, detail: detail)
        // Vision can omit one of several visually identical answer rows in a
        // large full-window request. A second accurate pass over center content
        // recovered correct option in frozen freeCodeCamp fixture. Screenshot
        // remains authoritative; this only strengthens supporting OCR.
        async let center = recognize(image, region: CGRect(x: 0, y: 0.22, width: 1, height: 0.58),
                                     detail: detail)
        var seen = Set<String>()
        return await (full + center).filter { seen.insert($0).inserted }
    }

    private static func recognize(_ image: CGImage, region: CGRect?,
                                  detail: QuizCaptureDetail) async -> [String] {
        await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let lines = (request.results as? [VNRecognizedTextObservation])?
                    .compactMap { $0.topCandidates(1).first?.string } ?? []
                continuation.resume(returning: lines)
            }
            request.recognitionLevel = detail.needsAccurateOCR ? .accurate : .fast
            request.usesLanguageCorrection = detail.needsAccurateOCR
            // Browser quiz options can be short relative to a high-resolution
            // full-window frame. 0.008 skipped an entire 25 px answer row in
            // the frozen 3402x2128 freeCodeCamp fixture.
            request.minimumTextHeight = 0.004
            if let region { request.regionOfInterest = region }
            DispatchQueue.global(qos: .userInitiated).async {
                do { try VNImageRequestHandler(cgImage: image).perform([request]) }
                catch { continuation.resume(returning: []) }
            }
        }
    }

    /// The top of the page, as written. Vision returns lines roughly in reading
    /// order, so the first handful is where a title or a stem lives.
    private static func headlines(from lines: [String]) -> [String] {
        lines.lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(12)
            .map { String($0.prefix(200)) }
    }

    private static func anchors(from lines: [String]) -> [String] {
        lines.compactMap { line in
            let normalized = QuizFrameObservation.normalizeOCR(line)
            let lower = normalized.lowercased()
            guard lower.contains("question") || lower.range(of: #"^\d+\s"#, options: .regularExpression) != nil
                    || lower.hasPrefix("choose") || lower.hasPrefix("select") else { return nil }
            return String(normalized.prefix(160))
        }
    }

    private static func tileHashes(_ image: CGImage, raster: [UInt8]?) -> [UInt64] {
        guard let pixels = raster else { return [] }
        let tile = 96
        let columns = max(1, Int(ceil(Double(image.width) / Double(tile))))
        let rows = max(1, Int(ceil(Double(image.height) / Double(tile))))
        return (0 ..< rows).flatMap { row in
            (0 ..< columns).map { column in
                var hash: UInt64 = 14_695_981_039_346_656_037
                for sampleY in 0 ..< 8 {
                    for sampleX in 0 ..< 8 {
                        let x = min(image.width - 1, column * tile + sampleX * tile / 8)
                        let y = min(image.height - 1, row * tile + sampleY * tile / 8)
                        let offset = (y * image.width + x) * 4
                        let luminance = (UInt64(pixels[offset]) * 3 + UInt64(pixels[offset + 1]) * 6
                                         + UInt64(pixels[offset + 2])) / 10
                        hash ^= luminance
                        hash &*= 1_099_511_628_211
                    }
                }
                return hash
            }
        }
    }

    private static func averageHash(_ image: CGImage, raster: [UInt8]?) -> UInt64 {
        guard let pixels = raster else { return 0 }
        var samples: [UInt64] = []
        samples.reserveCapacity(64)
        for y in 0 ..< 8 {
            for x in 0 ..< 8 {
                let px = min(image.width - 1, x * image.width / 8)
                let py = min(image.height - 1, y * image.height / 8)
                let offset = (py * image.width + px) * 4
                samples.append((UInt64(pixels[offset]) * 3 + UInt64(pixels[offset + 1]) * 6
                                + UInt64(pixels[offset + 2])) / 10)
            }
        }
        let average = samples.reduce(0, +) / UInt64(max(1, samples.count))
        return samples.enumerated().reduce(UInt64(0)) { partial, item in
            item.element >= average ? partial | (UInt64(1) << UInt64(item.offset)) : partial
        }
    }

    private static func rgba(_ image: CGImage) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ok = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return ok ? pixels : nil
    }
}

/// `SCScreenshotManager` fails to start from nested command-line app bundles on
/// current macOS even with valid TCC grants. One selected-window SCStream frame
/// uses same public capture stack as Call and works without display capture.
private final class QuizOneFrameStream: NSObject, SCStreamOutput, SCStreamDelegate,
                                        @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CGImage, Error>?
    private var stream: SCStream?
    private var finished = false
    private let context = CIContext(options: [.cacheIntermediates: false])

    static func capture(filter: SCContentFilter,
                        configuration: SCStreamConfiguration) async throws -> CGImage {
        let receiver = QuizOneFrameStream()
        let stream = SCStream(filter: filter, configuration: configuration, delegate: receiver)
        try stream.addStreamOutput(receiver, type: .screen,
                                   sampleHandlerQueue: DispatchQueue(label: "QuizOneFrameStream"))
        receiver.stream = stream
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                receiver.install(continuation)
                Task {
                    do { try await stream.startCapture() }
                    catch { receiver.finish(.failure(error)) }
                }
                Task {
                    try? await Task.sleep(for: .seconds(5))
                    receiver.finish(.failure(QuizWindowCaptureFailure.captureTimedOut))
                }
            }
        } onCancel: {
            receiver.finish(.failure(CancellationError()))
            Task { try? await stream.stopCapture() }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        finish(.failure(error))
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = context.createCGImage(image, from: image.extent) else { return }
        finish(.success(cgImage))
    }

    private func install(_ continuation: CheckedContinuation<CGImage, Error>) {
        lock.lock()
        if finished {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    private func finish(_ result: Result<CGImage, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let stream = self.stream
        self.stream = nil
        lock.unlock()
        continuation?.resume(with: result)
        if let stream { Task { try? await stream.stopCapture() } }
    }
}
