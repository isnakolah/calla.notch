import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision

/// One picture of what is on screen during a call, and the words in it.
///
/// Taken here because this host is the executable holding the Screen
/// Recording grant. Boring Notch's own windows are left out, so pressing the
/// button in the notch does not photograph the notch.
public enum ScreenSnapshot {
    public struct Result: Sendable {
        public let file: URL
        public let text: String
    }

    public enum Failure: LocalizedError {
        case noDisplay
        case unwritable
        public var errorDescription: String? {
            switch self {
            case .noDisplay: "No display is available to capture."
            case .unwritable: "The screenshot could not be saved."
            }
        }
    }

    /// The longest edge kept. Enough to read a shared slide or a spreadsheet;
    /// a 6K display at full size would be several megabytes a shot.
    static let longEdge = 2560

    public static func capture(into directory: URL, name: String) async throws -> Result {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        // The display the reader is looking at is the one under the pointer.
        let pointer = CGEvent(source: nil)?.location ?? .zero
        guard let display = content.displays.first(where: { CGDisplayBounds($0.displayID).contains(pointer) })
                ?? content.displays.first else { throw Failure.noDisplay }
        let own = content.applications.filter { $0.bundleIdentifier.hasPrefix("theboringteam.boringnotch") }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])

        let configuration = SCStreamConfiguration()
        let scale = Double(filter.pointPixelScale)
        let width = Double(display.width) * scale, height = Double(display.height) * scale
        let shrink = min(1, Double(longEdge) / max(width, height))
        configuration.width = Int(width * shrink)
        configuration.height = Int(height * shrink)
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent(name)
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw Failure.unwritable }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.unwritable }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return Result(file: file, text: recognizeText(in: image))
    }

    /// The words on screen, top to bottom. On-device; nothing leaves the Mac
    /// here — only this text is later given to the call's model.
    static func recognizeText(in image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let lines = (request.results ?? [])
            .sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
            .compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }
}
