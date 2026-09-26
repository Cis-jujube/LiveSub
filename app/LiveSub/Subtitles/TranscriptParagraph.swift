import Foundation

/// A reading projection of the same subtitle records used by the overlay.
/// Membership is fixed when a segment arrives, so later revisions never move text between paragraphs.
public struct TranscriptParagraph: Identifiable, Equatable, Sendable {
    public let id: String
    public let sourceLanguage: String
    public let targetLanguage: String
    public let sourceText: String
    public let targetText: String
    private let translationOnlyTargetText: String
    public let pendingCount: Int
    public let failedCount: Int
    public let segmentCount: Int

    init(segments: [SubtitleSegment]) {
        let first = segments[0]
        id = first.id
        sourceLanguage = first.sourceLanguage
        targetLanguage = first.targetLanguage
        sourceText = Self.join(segments.map(\.sourceText), language: sourceLanguage)
        targetText = Self.join(segments.map { segment in
            if segment.translationIsCurrent { return segment.targetText }
            if segment.translationState == .failed { return "[翻译失败]" }
            return segment.targetText.isEmpty ? "[翻译中…]" : "[译文更新中…]"
        }, language: targetLanguage)
        // Store acceptance has already checked this preview against its source snapshot.
        // Keep it readable only in translation-only mode, explicitly marked as an older version.
        translationOnlyTargetText = Self.join(segments.map { segment in
            if segment.translationIsCurrent { return segment.targetText }
            if segment.translationState == .failed { return "[翻译失败]" }
            if segment.translationState == .preview,
               segment.translatedSourceRevision > 0,
               segment.translatedSourceRevision < segment.sourceRevision,
               !segment.translatedSourceText.isEmpty, !segment.targetText.isEmpty {
                return segment.targetText + " [上一版译文·更新中…]"
            }
            return "[翻译中…]"
        }, language: targetLanguage)
        pendingCount = segments.filter { !$0.translationIsCurrent && $0.translationState != .failed }.count
        failedCount = segments.filter { $0.translationState == .failed }.count
        segmentCount = segments.count
    }

    public func targetForDisplay(in mode: SubtitleDisplayMode) -> String {
        mode == .translationOnly ? translationOnlyTargetText : targetText
    }

    static func shouldStartNew(after existing: [SubtitleSegment], incoming: SubtitleSegment) -> Bool {
        guard let first = existing.first, let last = existing.last else { return true }
        guard first.sessionId == incoming.sessionId, first.generation == incoming.generation,
              first.sourceLanguage == incoming.sourceLanguage,
              first.targetLanguage == incoming.targetLanguage else { return true }
        let text = join(existing.map(\.sourceText), language: first.sourceLanguage)
        let duration = last.endMs >= first.startMs ? last.endMs - first.startMs : 0
        // Hard bounds also handle streams without punctuation. Never split a single ASR record.
        if existing.count >= 12 || text.count >= 1_800 || duration >= 60_000 { return true }
        let sentenceCount = text.filter { ".!?。！？".contains($0) }.count
        let endsSentence = text.last.map { ".!?。！？\"”’".contains($0) } ?? false
        return last.sourceFinal && endsSentence && (sentenceCount >= 4 || duration >= 30_000 || text.count >= 700)
    }

    static func join(_ parts: [String], language: String) -> String {
        parts.reduce("") { result, part in
            let text = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return result }
            guard let last = result.last, let first = text.first else { return text }
            let noSpaceBefore = ",.!?;:，。！？；：、)]}）】》”’".contains(first)
            let noSpaceAfter = "([{（【《“‘".contains(last)
            let bothASCIIWords = last.isASCII && first.isASCII && last.isLetterOrNumber && first.isLetterOrNumber
            let needsSpace = !noSpaceBefore && !noSpaceAfter && (language == "en" || bothASCIIWords || first == "[" || last == "]")
            return result + (needsSpace ? " " : "") + text
        }
    }
}

private extension Character {
    var isLetterOrNumber: Bool { isLetter || isNumber }
}
