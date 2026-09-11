import AppKit
import CallaContracts
import CoreImage
import CoreMedia
import Foundation
import IntelligenceCore
@preconcurrency import ScreenCaptureKit

/// A ScreenCaptureKit stream held open for the life of a Quiz session.
///
/// The watcher used to spawn a whole `CallaCallHost` process per frame, twice a
/// second. Each spawn paid for an `NSApplication` bootstrap, an
/// `SCShareableContent` enumeration (a WindowServer round-trip), a display-mode
/// lookup, and a fresh `SCStream` start and stop — all to obtain one frame. Spawn
/// plus stream setup exceeded the poll interval, so the real frame period was
/// bounded by how long that took rather than by the interval, and it got worse
/// as the capture resolution went up.
///
/// This resolves the window once, starts the stream once, and delivers frames
/// until it is stopped.
public final class QuizWindowStream: NSObject, SCStreamOutput, SCStreamDelegate,
                                     @unchecked Sendable {
    private let lock = NSLock()
    private var stream: SCStream?
    private var continuation: AsyncStream<CGImage>.Continuation?
    private var finished = false
    private let context = CIContext(options: [.cacheIntermediates: false])

    /// Frames of the target window, until `stop()` or the stream fails.
    public static func frames(
        target: QuizWindowTarget,
        resolution: QuizCaptureResolution,
        interval: Duration
    ) async throws -> (QuizWindowStream, AsyncStream<CGImage>) {
        // ScreenCaptureKit still needs CoreGraphics process initialisation in a
        // command-line host. Paid once per session now, not once per frame.
        await MainActor.run {
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            if !application.isRunning { application.finishLaunching() }
        }
        let window = try await QuizWindowCatalog.resolve(target)
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = false
        configuration.capturesAudio = false
        let nativeSize = QuizWindowCapture.nativePixelSize(for: window)
        let scale = min(
            1,
            Double(resolution.maximumWidth) / Double(nativeSize.width),
            Double(resolution.maximumHeight) / Double(nativeSize.height))
        configuration.width = max(1, Int((Double(nativeSize.width) * scale).rounded()))
        configuration.height = max(1, Int((Double(nativeSize.height) * scale).rounded()))
        configuration.scalesToFit = true
        configuration.minimumFrameInterval = CMTime(
            value: CMTimeValue(max(1, interval.components.seconds * 1_000
                                   + interval.components.attoseconds / 1_000_000_000_000_000)),
            timescale: 1_000)
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

        let receiver = QuizWindowStream()
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window),
                              configuration: configuration, delegate: receiver)
        try stream.addStreamOutput(receiver, type: .screen,
                                   sampleHandlerQueue: DispatchQueue(label: "QuizWindowStream"))
        receiver.stream = stream

        let images = AsyncStream<CGImage> { continuation in
            receiver.install(continuation)
            continuation.onTermination = { _ in receiver.stop() }
        }
        try await stream.startCapture()
        return (receiver, images)
    }

    public func stop() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        let stream = self.stream
        self.continuation = nil
        self.stream = nil
        lock.unlock()
        continuation?.finish()
        if let stream { Task { try? await stream.stopCapture() } }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        stop()
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                       of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = context.createCGImage(image, from: image.extent) else { return }
        lock.lock()
        let continuation = self.continuation
        lock.unlock()
        continuation?.yield(cgImage)
    }

    private func install(_ continuation: AsyncStream<CGImage>.Continuation) {
        lock.lock()
        if finished {
            lock.unlock()
            continuation.finish()
            return
        }
        self.continuation = continuation
        lock.unlock()
    }
}
