import Combine
import Foundation

/// The only mutable transcript source read by the main window and floating subtitle.
@MainActor
public final class SubtitleStore: ObservableObject {
    @Published public private(set) var segments: [SubtitleSegment] = []
    @Published public private(set) var activeSessionID: String?
    @Published public private(set) var activeGeneration: UInt64 = 0

    private var index: [String: Int] = [:]
    private var sourceSnapshots: [String: [UInt64: String]] = [:]

    public init() {}

    public func beginSession(_ sessionID: String) {
        guard !sessionID.isEmpty else { return }
        segments = []
        index = [:]
        sourceSnapshots = [:]
        activeSessionID = sessionID
        activeGeneration = 0
    }

    @discardableResult
    public func apply(eventJSON data: Data) -> Bool {
        struct SubtitleEnvelope: Decodable {
            let kind: String
            let segment: SubtitleSegment
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let envelope = try? decoder.decode(SubtitleEnvelope.self, from: data),
              envelope.kind == "subtitle" else { return false }
        return apply(envelope.segment)
    }

    @discardableResult
    public func apply(_ incoming: SubtitleSegment) -> Bool {
        guard !incoming.sessionId.isEmpty, !incoming.segmentId.isEmpty,
              incoming.sourceRevision > 0, !incoming.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              incoming.endMs >= incoming.startMs,
              (incoming.sourceLanguage, incoming.targetLanguage) == ("en", "zh") ||
                  (incoming.sourceLanguage, incoming.targetLanguage) == ("zh", "en") else { return false }

        guard activeSessionID == nil || incoming.sessionId == activeSessionID,
              incoming.generation >= activeGeneration else { return false }

        let key = incoming.id
        if let position = index[key] {
            let existing = segments[position]
            guard incoming.sequence > existing.sequence,
                  incoming.sourceRevision >= existing.sourceRevision,
                  !(existing.sourceFinal && (!incoming.sourceFinal || incoming.sourceText != existing.sourceText)),
                  incoming.sourceLanguage == existing.sourceLanguage,
                  incoming.targetLanguage == existing.targetLanguage else { return false }
            if incoming.sourceRevision == existing.sourceRevision && incoming.sourceText != existing.sourceText {
                return false
            }
        }

        var snapshots = sourceSnapshots[key] ?? [:]
        snapshots[incoming.sourceRevision] = incoming.sourceText
        var accepted = incoming
        let hasTarget = !incoming.targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let previewInvalidatedByFinalSource = incoming.sourceFinal &&
            incoming.translationState == .preview &&
            incoming.translatedSourceRevision < incoming.sourceRevision
        if incoming.translationState == .preview || incoming.translationState == .final {
            guard hasTarget,
                  incoming.translatedSourceRevision > 0,
                  incoming.translatedSourceRevision <= incoming.sourceRevision,
                  snapshots[incoming.translatedSourceRevision] == incoming.translatedSourceText,
                  !(incoming.translationState == .final &&
                    (!incoming.sourceFinal || incoming.translatedSourceRevision != incoming.sourceRevision)) else {
                return false
            }
        }
        if (incoming.translationState != .preview && incoming.translationState != .final) ||
            previewInvalidatedByFinalSource {
            accepted.targetText = ""
            accepted.translatedSourceText = ""
            accepted.translatedSourceRevision = 0
            if previewInvalidatedByFinalSource { accepted.translationState = .pending }
        }

        if let position = index[key] {
            let existing = segments[position]
            guard accepted.translatedSourceRevision >= existing.translatedSourceRevision ||
                    accepted.translationState == .pending else { return false }
            if existing.translationState == .final && accepted.translationState != .final { return false }
            if existing.translationState == .final && accepted.targetText != existing.targetText { return false }
            segments[position] = accepted
        } else {
            index[key] = segments.count
            segments.append(accepted)
        }
        sourceSnapshots[key] = snapshots
        if activeSessionID == nil { activeSessionID = incoming.sessionId }
        if incoming.generation > activeGeneration { activeGeneration = incoming.generation }
        return true
    }

    public var latestCaption: CaptionPair? {
        guard let latest = segments.last else { return nil }
        let paired = (latest.translationState == .preview || latest.translationState == .final) &&
            !latest.targetText.isEmpty && !latest.translatedSourceText.isEmpty
        return CaptionPair(
            sourceText: latest.sourceText,
            translatedSourceText: paired ? latest.translatedSourceText : nil,
            targetText: paired ? latest.targetText : nil
        )
    }

    public var exportMarkdown: String {
        var result = "# LiveSub session\n\n"
        for segment in segments {
            result += "- **\(segment.sourceLanguage.uppercased())** \(segment.sourceText)\n"
            result += "  - **\(segment.targetLanguage.uppercased())** \(segment.targetText.isEmpty ? "[翻译未完成]" : segment.targetText)\n"
        }
        return result
    }

    public var exportText: String {
        segments.map { "\($0.sourceText)\n\($0.targetText.isEmpty ? "[翻译未完成]" : $0.targetText)" }
            .joined(separator: "\n\n") + (segments.isEmpty ? "" : "\n")
    }
}
