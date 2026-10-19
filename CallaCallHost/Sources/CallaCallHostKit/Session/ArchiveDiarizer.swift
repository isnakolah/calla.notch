import CoreML
import Darwin
import FluidAudio
import Foundation
import os.log

private let diarizeLog = Logger(subsystem: "org.calla.notch.callhost", category: "diarize")

/// Splits a finished call's system audio into individual voices.
///
/// Only `system.wav`: the mic leg is the user by construction, so diarizing it
/// could only ever invent a second "me". Runs FluidAudio's offline pipeline
/// (pyannote Community-1 segmentation, WeSpeaker embeddings, VBx clustering),
/// whose models download on first use into the host's own models directory
/// beside whisper's.
public enum ArchiveDiarizer {
    public struct Result: Sendable {
        public var spans: [DiarizedSpan]
        /// One L2-normalised embedding per diarizer id, for voiceprint matching.
        public var embeddings: [String: [Float]]
    }

    public enum Failure: Error, LocalizedError {
        case unsupportedOS

        public var errorDescription: String? {
            switch self {
            case .unsupportedOS: "speaker diarization needs macOS 15 or later"
            }
        }
    }

    public static var modelsDirectory: URL {
        CallHostPaths.modelsDirectory.appendingPathComponent("diarizer", isDirectory: true)
    }

    /// macOS 14 builds crash inside BNNS during CoreML prediction (documented by
    /// FluidAudio, fixed by Apple in 15). A post-call nicety is not worth that.
    public static var isSupported: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15
    }

    public static func diarize(systemAudio url: URL) async throws -> Result {
        guard isSupported else { throw Failure.unsupportedOS }
        // The host exits without finalizing its WAVs, so the header usually says
        // the file is empty. Same exact, idempotent fix every other reader uses.
        try? WAVRepair.repairIfNeeded(at: url)
        let manager = OfflineDiarizerManager(config: .default)
        try await manager.prepareModels(
            directory: modelsDirectory,
            configuration: DiarizerRuntimePolicy.current.modelConfiguration)
        let result = try await manager.process(url)
        let spans = result.segments.compactMap { segment -> DiarizedSpan? in
            let start = Double(segment.startTimeSeconds)
            let end = Double(segment.endTimeSeconds)
            guard !segment.speakerId.isEmpty, start.isFinite, end.isFinite, end > start else { return nil }
            return DiarizedSpan(speakerID: segment.speakerId, start: start, end: end)
        }
        diarizeLog.notice("diarized \(url.deletingLastPathComponent().lastPathComponent, privacy: .public): \(Set(spans.map(\.speakerID)).count, privacy: .public) speakers, \(spans.count, privacy: .public) spans")
        return Result(spans: spans, embeddings: result.speakerDatabase ?? [:])
    }
}

/// Which CoreML compute units the diarizer may use on this Mac.
///
/// Ported from Muesli's `DiarizerRuntimePolicy` (MIT): FluidAudio's diarizer
/// crashes inside MPSGraph on M1-family chips running macOS 15.1, so the GPU is
/// left out there and nowhere else.
struct DiarizerRuntimePolicy: Equatable {
    var computeUnits: MLComputeUnits

    static var current: DiarizerRuntimePolicy {
        resolve(cpuBrand: sysctlString("machdep.cpu.brand_string"),
                version: ProcessInfo.processInfo.operatingSystemVersion)
    }

    static func resolve(cpuBrand: String?, version: OperatingSystemVersion) -> DiarizerRuntimePolicy {
        let isMacOS151 = version.majorVersion == 15 && version.minorVersion == 1
        let brand = cpuBrand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isM1 = brand == "Apple M1" || brand.hasPrefix("Apple M1 ")
        return DiarizerRuntimePolicy(computeUnits: isMacOS151 && isM1 ? .cpuAndNeuralEngine : .all)
    }

    var modelConfiguration: MLModelConfiguration {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        return configuration
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return String(cString: value)
    }
}
