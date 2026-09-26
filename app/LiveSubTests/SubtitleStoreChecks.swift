import Foundation
import LiveSubSubtitles

@main
struct SubtitleStoreChecks {
    @MainActor static func main() throws {
        let store = SubtitleStore()
        let first = try decode("""
        {"session_id":"session-1","generation":1,"segment_id":"first","sequence":0,
         "start_ms":0,"end_ms":1200,"source_language":"en","target_language":"zh",
         "source_text":"Hello","source_revision":1,"source_final":false,
         "target_text":"","translated_source_text":"","translated_source_revision":0,
         "translation_state":"pending"}
        """)
        precondition(store.apply(first))
        precondition(!store.apply(first), "duplicate event must be ignored")
        var revised = first
        revised.sequence = 1
        revised.sourceText = "Hello world"
        revised.sourceRevision = 2
        precondition(store.apply(revised))
        var mismatched = revised
        mismatched.sequence = 2
        mismatched.targetText = "你好"
        mismatched.translatedSourceText = "Something else"
        mismatched.translatedSourceRevision = 1
        mismatched.translationState = .preview
        precondition(!store.apply(mismatched), "translation snapshot must match known source")
        var paired = revised
        paired.sequence = 3
        paired.targetText = "你好，世界"
        paired.translatedSourceText = "Hello world"
        paired.translatedSourceRevision = 2
        paired.translationState = .preview
        precondition(store.apply(paired))
        precondition(store.segments.count == 1)
        precondition(store.segments[0].targetText == "你好，世界")
        var finalSource = paired
        finalSource.sequence = 4
        finalSource.sourceText = "Hello world!"
        finalSource.sourceRevision = 3
        finalSource.sourceFinal = true
        precondition(store.apply(finalSource), "final source must not be lost with stale preview")
        precondition(store.segments[0].targetText.isEmpty)
        var finalPair = finalSource
        finalPair.sequence = 5
        finalPair.targetText = "你好，世界！"
        finalPair.translatedSourceText = "Hello world!"
        finalPair.translatedSourceRevision = 3
        finalPair.translationState = .final
        precondition(store.apply(finalPair))
        precondition(!store.apply(paired), "older preview must not replace final translation")

        let next = try decode("""
         {"session_id":"session-1","generation":2,"segment_id":"second","sequence":6,
         "start_ms":0,"end_ms":1800,"source_language":"zh","target_language":"en",
         "source_text":"你好","source_revision":1,"source_final":true,
         "target_text":"Hello","translated_source_text":"你好","translated_source_revision":1,
         "translation_state":"final"}
        """)
        precondition(store.apply(next))
        precondition(store.segments.count == 2)
        precondition(store.segments[0].sourceLanguage == "en")
        precondition(store.segments[1].targetLanguage == "en")
        revised.sequence = 7
        precondition(!store.apply(revised), "old generation cannot overwrite current records")
        precondition(store.latestCaption?.sourceText == "你好")
        for index in 0..<1_800 {
            var row = next
            row.segmentId = "long-session-\(index)"
            row.sequence = UInt64(7 + index)
            row.startMs = UInt64(index * 1_000)
            row.endMs = row.startMs + 1_000
            row.sourceText = "第\(index)句"
            row.translatedSourceText = row.sourceText
            row.targetText = "Sentence \(index)"
            precondition(store.apply(row))
        }
        precondition(store.segments.count == 1_802, "30-minute-length record must not truncate")
        precondition(store.latestCaption?.targetText == "Sentence 1799")
        precondition(store.exportText.contains("Hello world!"))
        precondition(store.exportText.contains("Sentence 1799"))
        print("SubtitleStoreChecks: 16 assertions plus 1800 long-session pairs passed")
    }

    private static func decode(_ json: String) throws -> SubtitleSegment {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SubtitleSegment.self, from: Data(json.utf8))
    }
}
