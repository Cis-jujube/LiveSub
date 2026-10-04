import Foundation
import LiveSubAudio

public struct BackendEvent: Decodable, Sendable {
    public let kind: String
    public let sessionID: String?
    public let generation: UInt64?
    public let state: String?
    public let detail: String?
    public let code: String?
    public let segment: BackendSegment?

    private enum CodingKeys: String, CodingKey {
        case kind, generation, state, detail, code, segment
        case sessionID = "session_id"
    }
}

public struct BackendSegment: Decodable, Sendable {
    public let sessionID: String
    public let generation: UInt64
    public let segmentID: String
    public let sequence: UInt64
    public let startMs: UInt64
    public let endMs: UInt64
    public let sourceLanguage: String
    public let targetLanguage: String
    public let sourceText: String
    public let sourceRevision: UInt64
    public let sourceFinal: Bool
    public let targetText: String
    public let translatedSourceText: String
    public let translatedSourceRevision: UInt64
    public let translationState: String
    public let speakerID: String?

    private enum CodingKeys: String, CodingKey {
        case generation, sequence
        case sessionID = "session_id"
        case segmentID = "segment_id"
        case startMs = "start_ms"
        case endMs = "end_ms"
        case sourceLanguage = "source_language"
        case targetLanguage = "target_language"
        case sourceText = "source_text"
        case sourceRevision = "source_revision"
        case sourceFinal = "source_final"
        case targetText = "target_text"
        case translatedSourceText = "translated_source_text"
        case translatedSourceRevision = "translated_source_revision"
        case translationState = "translation_state"
        case speakerID = "speaker_id"
    }
}

struct BackendReady: Decodable {
    let kind: String
    let version: Int
    let port: Int

    var isValid: Bool { kind == "ready" && version == 1 && (1...65_535).contains(port) }
}

struct BackendCommand: Encodable {
    let kind: String
    let sessionID: String
    let generation: UInt64
    var sourceLanguage: String?
    var targetLanguage: String?
    var sequence: UInt64?
    var startSample: UInt64?
    var sampleRate: Int?
    var channels: Int?
    var pcm16: String?
    var speakerID: String? = nil
    var speakerIDs: [String]? = nil

    private enum CodingKeys: String, CodingKey {
        case kind, generation, sequence, channels, pcm16
        case sessionID = "session_id"
        case sourceLanguage = "source_language"
        case targetLanguage = "target_language"
        case startSample = "start_sample"
        case sampleRate = "sample_rate"
        case speakerID = "speaker_id"
        case speakerIDs = "speaker_ids"
    }

    static func audio(_ frame: AudioFrame) -> BackendCommand {
        BackendCommand(
            kind: "audio",
            sessionID: frame.sessionID,
            generation: frame.generation,
            sequence: frame.sequence,
            startSample: frame.startSample,
            sampleRate: frame.sampleRate,
            channels: frame.channels,
            pcm16: frame.pcm16.base64EncodedString(),
            speakerID: frame.speakerID
        )
    }
}

public enum BackendConnectionState: String, Sendable {
    case idle
    case launching
    case connected
    case failed
}

public enum BackendClientError: LocalizedError {
    case alreadyStarting
    case environmentMissing(String)
    case unsupportedPython
    case invalidReadyMessage
    case launchTimeout
    case processExited(Int32)
    case disconnected
    case invalidDirection
    case sessionMismatch
    case audioOutOfOrder
    case invalidAudioFrame
    case sendBacklogFull
    case invalidBackendEvent
    case notListening
    case operationTimedOut(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyStarting: "The local backend is already starting."
        case .environmentMissing(let path): "The prepared local backend is missing: \(path)"
        case .unsupportedPython: "LiveSub needs its prepared Python 3.12 environment."
        case .invalidReadyMessage: "The local backend sent an invalid ready message."
        case .launchTimeout: "The local backend did not become ready within 20 seconds."
        case .processExited(let status): "The local backend exited unexpectedly (status \(status))."
        case .disconnected: "The local backend connection is closed."
        case .invalidDirection: "Choose English to Chinese or Chinese to English."
        case .sessionMismatch: "This command belongs to an old session or generation."
        case .audioOutOfOrder: "Audio frames arrived out of order."
        case .invalidAudioFrame: "The audio frame must contain at most 2560 mono PCM16 samples."
        case .sendBacklogFull: "The local backend send queue is full. Capture must pause."
        case .invalidBackendEvent: "The local backend sent an invalid event."
        case .notListening: "The local backend is not listening for audio."
        case .operationTimedOut(let action): "The local backend did not finish \(action) in time."
        }
    }
}
