import Foundation

public enum TranslationState: String, Codable, Sendable {
    case pending, preview, final, failed
}

/// One row contains both languages. A translated source snapshot accompanies every target.
public struct SubtitleSegment: Codable, Identifiable, Equatable, Sendable {
    public var sessionId: String
    public var generation: UInt64
    public var segmentId: String
    public var sequence: UInt64
    public var startMs: UInt64
    public var endMs: UInt64
    public var sourceLanguage: String
    public var targetLanguage: String
    public var sourceText: String
    public var sourceRevision: UInt64
    public var sourceFinal: Bool
    public var targetText: String
    public var translatedSourceText: String
    public var translatedSourceRevision: UInt64
    public var translationState: TranslationState

    public var id: String { "\(sessionId):\(generation):\(segmentId)" }
    public var translationIsCurrent: Bool {
        translatedSourceRevision == sourceRevision &&
        translatedSourceText == sourceText &&
        !targetText.isEmpty &&
        (translationState == .preview || translationState == .final)
    }
}

public struct CaptionPair: Equatable, Sendable {
    public let sourceText: String
    public let translatedSourceText: String?
    public let targetText: String?

    public init(sourceText: String, translatedSourceText: String?, targetText: String?) {
        self.sourceText = sourceText
        self.translatedSourceText = translatedSourceText
        self.targetText = targetText
    }
}
