import Foundation

/// A reading projection of the same subtitle records used by the overlay.
/// Membership is fixed when a segment arrives, so later revisions never move text between paragraphs.
public struct TranscriptParagraph: Identifiable, Equatable, Sendable {
    /// Inline placeholders inside `targetText`; views may restyle them, exports keep them verbatim.
    public enum Marker {
        public static let pending = "[翻译中…]"
        public static let updating = "[译文更新中…]"
        public static let failed = "[翻译失败]"
        public static let previousVersion = "[上一版译文·更新中…]"
        public static let unselected = "[未选中 · 未翻译]"
        public static let all = [previousVersion, updating, pending, failed, unselected]
    }

    public let id: String
    public let sourceLanguage: String
    public let targetLanguage: String
    public let speakerID: String?
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
        speakerID = first.speakerId
        sourceText = Self.join(segments.map(\.sourceText), language: sourceLanguage)
        let targets = segments.map { segment in
            if segment.translationIsCurrent { return segment.targetText }
            if segment.translationState == .skipped { return "" }
            if segment.translationState == .failed { return Marker.failed }
            return segment.targetText.isEmpty ? Marker.pending : Marker.updating
        }
        targetText = targets.allSatisfy(\.isEmpty) ? Marker.unselected : Self.join(targets, language: targetLanguage)
        // Store acceptance has already checked this preview against its source snapshot.
        // Keep it readable only in translation-only mode, explicitly marked as an older version.
        let translationOnlyTargets = segments.map { segment in
            if segment.translationIsCurrent { return segment.targetText }
            if segment.translationState == .skipped { return "" }
            if segment.translationState == .failed { return Marker.failed }
            if segment.translationState == .preview,
               segment.translatedSourceRevision > 0,
               segment.translatedSourceRevision < segment.sourceRevision,
               !segment.translatedSourceText.isEmpty, !segment.targetText.isEmpty {
                return segment.targetText + " " + Marker.previousVersion
            }
            return Marker.pending
        }
        translationOnlyTargetText = translationOnlyTargets.allSatisfy(\.isEmpty)
            ? Marker.unselected : Self.join(translationOnlyTargets, language: targetLanguage)
        pendingCount = segments.filter { !$0.translationIsCurrent && $0.translationState != .failed && $0.translationState != .skipped }.count
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
              first.targetLanguage == incoming.targetLanguage,
              first.speakerId == incoming.speakerId else { return true }
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
