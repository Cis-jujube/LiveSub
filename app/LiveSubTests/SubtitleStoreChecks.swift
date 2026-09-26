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
        precondition(store.paragraphs[0].targetForDisplay(in: .translationOnly) == "[翻译中…]", "no validated preview means pending placeholder")
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
        try displayPreferenceChecks(store: store)
        try paragraphAndTerminologyChecks(template: first)
        print("SubtitleStoreChecks: original contracts, 1800 long-session pairs, paragraph and terminology checks passed")
    }

    @MainActor private static func displayPreferenceChecks(store: SubtitleStore) throws {
        let suite = "LiveSubDisplayChecks-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        precondition(SubtitleDisplayMode.load(from: defaults) == .bilingual, "new installations default to bilingual")
        defaults.set("invalid", forKey: SubtitleDisplayMode.preferenceKey)
        precondition(SubtitleDisplayMode.load(from: defaults) == .bilingual, "unknown stored modes recover safely")
        let records = store.segments
        let paragraphs = store.paragraphs
        let text = store.exportText
        let markdown = store.exportMarkdown
        let revision = store.contentRevision
        let session = store.activeSessionID
        let generation = store.activeGeneration
        for mode in [SubtitleDisplayMode.translationOnly, .bilingual, .translationOnly] {
            mode.save(to: defaults)
            let restored = SubtitleDisplayMode.load(from: defaults)
            precondition(restored == mode, "display preference persists")
            for paragraph in store.paragraphs {
                precondition(restored.sourceForDisplay(paragraph.sourceText) == (mode == .bilingual ? paragraph.sourceText : nil))
            }
        }
        precondition(store.segments == records && store.paragraphs == paragraphs, "display projection preserves both language records")
        precondition(store.activeSessionID == session && store.activeGeneration == generation && store.contentRevision == revision, "display preference cannot change transcript session or generation")
        precondition(store.exportText == text && store.exportMarkdown == markdown, "exports remain bilingual after display switches")
        print("Display defaults, persistence, transcript and session preservation, and bilingual export checks passed")
    }

    @MainActor private static func paragraphAndTerminologyChecks(template: SubtitleSegment) throws {
        let store = SubtitleStore()
        var sequence: UInt64 = 0
        func make(_ id: String, _ source: String, _ target: String, final: Bool = true) -> SubtitleSegment {
            var segment = template
            sequence += 1
            segment.segmentId = id
            segment.sequence = sequence
            segment.startMs = sequence * 6_000
            segment.endMs = segment.startMs + 6_000
            segment.sourceText = source
            segment.sourceFinal = final
            segment.targetText = target
            segment.translatedSourceText = target.isEmpty ? "" : source
            segment.translatedSourceRevision = target.isEmpty ? 0 : 1
            segment.translationState = target.isEmpty ? .pending : (final ? .final : .preview)
            return segment
        }
        for index in 0..<4 {
            precondition(store.apply(make("sentence-\(index)", "Sentence \(index).", "第\(index)句。")))
        }
        precondition(store.paragraphs.count == 1, "six-second segments must grow one reading paragraph")
        precondition(store.paragraphs[0].sourceText == "Sentence 0. Sentence 1. Sentence 2. Sentence 3.")
        precondition(store.paragraphs[0].targetText == "第0句。第1句。第2句。第3句。")
        var active = make("active", "An Agent uses", "Agent 使用", final: false)
        precondition(store.apply(active))
        precondition(store.paragraphs.count == 2, "four sentences close a paragraph")
        let firstID = store.paragraphs[0].id
        let activeID = store.paragraphs[1].id
        let revision = store.contentRevision
        active.sequence += 1
        active.sourceRevision = 2
        active.sourceText = "An Agent uses a token."
        precondition(store.apply(active))
        precondition(store.contentRevision > revision, "in-place growth must trigger auto-follow")
        precondition(store.paragraphs[1].id == activeID)
        precondition(store.paragraphs[1].sourceText == active.sourceText)
        precondition(!store.paragraphs[1].targetText.contains("Agent 使用"), "stale target must not appear current")
        precondition(store.paragraphs[1].targetForDisplay(in: .translationOnly) == "Agent 使用 [上一版译文·更新中…]", "validated prior preview stays readable with explicit stale marker in translation-only")
        precondition(store.paragraphs[1].targetForDisplay(in: .bilingual) == "[译文更新中…]", "bilingual view remains strict and current")
        precondition(!store.exportText.contains("Agent 使用"), "bilingual export excludes stale preview")
        precondition(!store.exportMarkdown.contains("上一版译文"), "display-only stale markers never enter exports")
        precondition(store.paragraphs[1].pendingCount == 1)
        precondition(store.exportText.contains("[译文更新中…]"))
        active.sequence += 1
        active.translationState = .failed
        precondition(store.apply(active), "failed translation must replace a prior preview state")
        precondition(store.paragraphs[1].failedCount == 1)
        precondition(store.paragraphs[1].targetForDisplay(in: .translationOnly) == "[翻译失败]", "failed state removes prior preview")
        precondition(store.exportMarkdown.contains("[翻译失败]"))
        active.sequence += 1
        active.sourceFinal = true
        active.targetText = "Agent 使用一个 token。"
        active.translatedSourceRevision = 2
        active.translatedSourceText = active.sourceText
        active.translationState = .final
        precondition(store.apply(active))
        precondition(store.paragraphs[0].id == firstID && store.paragraphs[1].id == activeID)
        precondition(store.paragraphs[1].pendingCount == 0 && store.paragraphs[1].failedCount == 0)
        precondition(store.exportText.contains("An Agent uses a token.\nAgent 使用一个 token。"))
        precondition(store.paragraphs[1].targetForDisplay(in: .translationOnly) == "Agent 使用一个 token。", "current translation replaces stale marker after recovery")
        var switched = make("switched", "切换方向。", "Change direction.")
        switched.sourceLanguage = "zh"
        switched.targetLanguage = "en"
        precondition(store.apply(switched))
        precondition(store.paragraphs.count == 3, "mixed directions must never merge")
        switched.segmentId = "generation"
        switched.generation = 2
        switched.sequence += 1
        precondition(store.apply(switched))
        precondition(store.paragraphs.count == 4, "generation changes must never merge")
        precondition(store.latestCaption?.sourceText == "切换方向。", "overlay remains one segment")
        let unpunctuated = SubtitleStore()
        for index in 0..<13 {
            var segment = make("bound-\(index)", "word", "词")
            segment.startMs = UInt64(index * 1_000)
            segment.endMs = segment.startMs + 1_000
            precondition(unpunctuated.apply(segment))
        }
        precondition(unpunctuated.paragraphs.count == 2, "unpunctuated stream has a segment bound")

        var config = TerminologyConfiguration()
        precondition(config.profile == "ai")
        config.entries = [TerminologyEntry(sourceLanguage: "en", source: "Agent", target: "Agent")]
        let data = try config.validatedData()
        let decoded = try TerminologyConfiguration.decode(data)
        precondition(decoded == config)
        precondition(String(decoding: data, as: UTF8.self).contains("source_language"))
        config.entries.append(TerminologyEntry(source: "agent", target: "代理"))
        precondition((try? config.validatedData()) == nil, "duplicate terms must be rejected")
        config.entries = [TerminologyEntry(source: "", target: "词")]
        precondition((try? config.validatedData()) == nil)
        config.entries = [TerminologyEntry(source: String(repeating: "a", count: 81), target: "词")]
        precondition((try? config.validatedData()) == nil)
        config.entries = [TerminologyEntry(source: "a\tb", target: "词")]
        precondition((try? config.validatedData()) == nil, "backend also rejects controls")
        config.entries = [TerminologyEntry(source: String(repeating: " ", count: 81) + "a", target: "词")]
        precondition((try? config.validatedData()) == nil, "raw length must match backend validation")
        config.entries = Array(repeating: TerminologyEntry(source: "x", target: "y"), count: 101)
        precondition((try? config.validatedData()) == nil)
        precondition((try? TerminologyConfiguration.decode(Data(repeating: 32, count: 65_537))) == nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("terminology.json")
        let saved = try decoded.save(to: url, replacing: nil)
        precondition(tryData(url) == saved)
        try Data("invalid existing configuration".utf8).write(to: url)
        precondition((try? decoded.save(to: url, replacing: saved)) == nil, "concurrent edits must not be overwritten")
        precondition(tryData(url) == Data("invalid existing configuration".utf8))
        store.beginSession("new")
        precondition(store.paragraphs.isEmpty && store.segments.isEmpty)
        print("Paragraph projection, revision, bounds, export, and terminology persistence checks passed")
    }

    private static func tryData(_ url: URL) -> Data? { try? Data(contentsOf: url) }

    private static func decode(_ json: String) throws -> SubtitleSegment {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SubtitleSegment.self, from: Data(json.utf8))
    }
}
