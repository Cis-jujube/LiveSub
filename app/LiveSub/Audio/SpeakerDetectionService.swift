import Foundation
import SpeakerKit

public struct SpeakerDetectionBatch: Sendable {
    public let frames: [AudioFrame]
    public let speakerIDs: [String]
}

/// Classifies bounded windows of the same PCM stream sent to the backend.
/// Speaker IDs and voice embeddings live only for the current app session.
@MainActor
public final class SpeakerDetectionService {
    private static let sampleRate = 16_000
    private static let firstWindowSamples = 2 * sampleRate
    private static let nextWindowSamples = 800 * sampleRate / 1_000
    private static let contextSamples = 3 * sampleRate
    private static let maximumSpeakers = 5
    // Conservative starting value; real conversation audio must calibrate it.
    private static let maximumCentroidDistance: Float = 0.30

    private var classify: (@MainActor ([Float]) async throws -> DiarizationResult)?
    private var generation: UInt64?
    private var pending: [AudioFrame] = []
    private var pendingSampleCount = 0
    private var context: [Float] = []
    private var centroids: [String: [Float]] = [:]

    public init() {}

    // Lets framing and generation boundaries be checked without downloading models.
    init(classify: @escaping @MainActor ([Float]) async throws -> DiarizationResult) {
        self.classify = classify
    }

    public var detectedSpeakerIDs: [String] { centroids.keys.sorted() }

    public func prepare() async throws {
        if classify == nil {
            let kit = try await SpeakerKit(PyannoteConfig(download: true, load: true, verbose: false))
            classify = { samples in
                try await kit.diarize(
                    audioArray: samples,
                    options: PyannoteDiarizationOptions(useExclusiveReconciliation: false)
                )
            }
        }
    }

    public func beginSession() {
        centroids.removeAll()
        beginGeneration(nil)
    }

    public func beginGeneration(_ generation: UInt64?) {
        self.generation = generation
        pending.removeAll()
        pendingSampleCount = 0
        context.removeAll()
    }

    public func consume(_ frame: AudioFrame) async throws -> SpeakerDetectionBatch {
        guard classify != nil else { throw SpeakerDetectionError.modelNotReady }
        if generation != frame.generation { beginGeneration(frame.generation) }
        pending.append(frame)
        pendingSampleCount += frame.sampleCount
        let required = context.isEmpty ? Self.firstWindowSamples : Self.nextWindowSamples
        guard pendingSampleCount >= required else {
            return SpeakerDetectionBatch(frames: [], speakerIDs: detectedSpeakerIDs)
        }
        return try await classifyPending()
    }

    public func finish() async throws -> SpeakerDetectionBatch {
        guard !pending.isEmpty else {
            return SpeakerDetectionBatch(frames: [], speakerIDs: detectedSpeakerIDs)
        }
        if context.count + pendingSampleCount < Self.firstWindowSamples {
            let unclassified = pending
            pending.removeAll()
            pendingSampleCount = 0
            return SpeakerDetectionBatch(frames: unclassified, speakerIDs: detectedSpeakerIDs)
        }
        return try await classifyPending()
    }

    private func classifyPending() async throws -> SpeakerDetectionBatch {
        guard let classify else { throw SpeakerDetectionError.modelNotReady }
        let frames = pending
        var samples = context
        samples.reserveCapacity(context.count + pendingSampleCount)
        for frame in frames { Self.appendSamples(from: frame.pcm16, to: &samples) }
        let result = try await classify(samples)
        let identities = matchSpeakers(in: result)
        let prefixSamples = context.count
        let firstSample = frames[0].startSample
        let labeled = frames.map { frame in
            let start = prefixSamples + Int(frame.startSample - firstSample)
            let speakerID = Self.speakerID(
                for: start..<(start + frame.sampleCount),
                segments: result.segments,
                identities: identities
            )
            return AudioFrame(
                sessionID: frame.sessionID, generation: frame.generation,
                sequence: frame.sequence, startSample: frame.startSample,
                pcm16: frame.pcm16, speakerID: speakerID
            )
        }
        context = Array(samples.suffix(Self.contextSamples))
        pending.removeAll()
        pendingSampleCount = 0
        return SpeakerDetectionBatch(frames: labeled, speakerIDs: detectedSpeakerIDs)
    }

    private func matchSpeakers(in result: DiarizationResult) -> [Int: String] {
        let localIDs = Set(result.segments.compactMap { $0.speaker.speakerId })
        var matches: [Int: String] = [:]
        var usedGlobalIDs: Set<String> = []
        var candidates: [(local: Int, global: String, distance: Float)] = []
        for local in localIDs {
            guard let vector = result.speakerCentroidEmbeddings[local], Self.valid(vector) else { continue }
            for (global, known) in centroids {
                if let distance = Self.cosineDistance(vector, known),
                   distance <= Self.maximumCentroidDistance {
                    candidates.append((local, global, distance))
                }
            }
        }
        for candidate in candidates.sorted(by: { $0.distance < $1.distance }) {
            guard matches[candidate.local] == nil,
                  !usedGlobalIDs.contains(candidate.global) else { continue }
            matches[candidate.local] = candidate.global
            usedGlobalIDs.insert(candidate.global)
        }
        let unmatched = localIDs.filter { matches[$0] == nil }.sorted { lhs, rhs in
            let left = result.segments.first { $0.speaker.speakerId == lhs }?.startTime ?? .infinity
            let right = result.segments.first { $0.speaker.speakerId == rhs }?.startTime ?? .infinity
            return left < right
        }
        for local in unmatched {
            guard centroids.count < Self.maximumSpeakers,
                  let vector = result.speakerCentroidEmbeddings[local], Self.valid(vector) else { continue }
            let id = String(UnicodeScalar(65 + centroids.count)!)
            matches[local] = id
            centroids[id] = vector
        }
        for (local, global) in matches {
            guard let next = result.speakerCentroidEmbeddings[local],
                  let previous = centroids[global], previous.count == next.count else { continue }
            centroids[global] = zip(previous, next).map { pair in
                0.8 * pair.0 + 0.2 * pair.1
            }
        }
        return matches
    }

    private static func speakerID(
        for sampleRange: Range<Int>,
        segments: [SpeakerSegment],
        identities: [Int: String]
    ) -> String? {
        let duration = Float(sampleRange.count) / Float(sampleRate)
        let start = Float(sampleRange.lowerBound) / Float(sampleRate)
        let end = Float(sampleRange.upperBound) / Float(sampleRate)
        var overlap: [String: Float] = [:]
        var unattributedOverlap: Float = 0
        for segment in segments {
            let seconds = max(0, min(end, segment.endTime) - max(start, segment.startTime))
            if let local = segment.speaker.speakerId, let global = identities[local] {
                overlap[global, default: 0] += seconds
            } else {
                unattributedOverlap += seconds
            }
        }
        let ranked = overlap.sorted { $0.value > $1.value }
        guard let first = ranked.first,
              first.value >= 0.6 * duration,
              unattributedOverlap < 0.2 * duration,
              (ranked.dropFirst().first?.value ?? 0) < 0.2 * duration else { return nil }
        return first.key
    }

    private static func appendSamples(from pcm16: Data, to samples: inout [Float]) {
        pcm16.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for index in stride(from: 0, to: bytes.count, by: 2) {
                let value = UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
                samples.append(Float(Int16(bitPattern: value)) / 32_768)
            }
        }
    }

    private static func valid(_ values: [Float]) -> Bool {
        !values.isEmpty && values.allSatisfy(\.isFinite)
    }

    private static func cosineDistance(_ lhs: [Float], _ rhs: [Float]) -> Float? {
        guard lhs.count == rhs.count, valid(lhs), valid(rhs) else { return nil }
        var dot: Float = 0
        var leftMagnitude: Float = 0
        var rightMagnitude: Float = 0
        for (left, right) in zip(lhs, rhs) {
            dot += left * right
            leftMagnitude += left * left
            rightMagnitude += right * right
        }
        guard leftMagnitude > 0, rightMagnitude > 0 else { return nil }
        return 1 - dot / (sqrt(leftMagnitude) * sqrt(rightMagnitude))
    }
}

public enum SpeakerDetectionError: LocalizedError {
    case modelNotReady

    public var errorDescription: String? {
        switch self {
        case .modelNotReady: "说话人模型尚未准备好。"
        }
    }
}
