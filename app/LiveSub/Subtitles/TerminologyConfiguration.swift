import Foundation

public struct TerminologyEntry: Codable, Equatable, Sendable {
    public var sourceLanguage: String
    public var source: String
    public var target: String

    public init(sourceLanguage: String = "en", source: String = "", target: String = "") {
        self.sourceLanguage = sourceLanguage
        self.source = source
        self.target = target
    }

    enum CodingKeys: String, CodingKey {
        case sourceLanguage = "source_language", source, target
    }
}

public struct TerminologyConfiguration: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var profile: String = "ai"
    public var entries: [TerminologyEntry] = []

    public init() {}

    public static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LiveSub/terminology.json")
    }

    public func validatedData() throws -> Data {
        guard version == 1, ["ai", "general"].contains(profile) else {
            throw TerminologyError.invalid("术语配置版本或领域无效。")
        }
        guard entries.count <= 100 else { throw TerminologyError.invalid("自定义术语最多 100 条。") }
        var seen: Set<String> = []
        for (index, entry) in entries.enumerated() {
            guard ["en", "zh"].contains(entry.sourceLanguage) else {
                throw TerminologyError.invalid("第 \(index + 1) 条术语的翻译方向无效。")
            }
            let source = entry.source.trimmingCharacters(in: .whitespacesAndNewlines)
            let target = entry.target.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty, !target.isEmpty,
                  (1...80).contains(entry.source.unicodeScalars.count),
                  (1...80).contains(entry.target.unicodeScalars.count) else {
                throw TerminologyError.invalid("第 \(index + 1) 条术语的原文和译文各需 1–80 个字符。")
            }
            guard !(entry.source + entry.target).unicodeScalars.contains(where: { scalar in
                switch scalar.properties.generalCategory {
                case .control, .format, .surrogate, .privateUse, .unassigned: return true
                default: return false
                }
            }) else { throw TerminologyError.invalid("第 \(index + 1) 条术语不能包含控制字符或不可见格式字符。") }
            let normalized = source.precomposedStringWithCompatibilityMapping
                .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            let key = entry.sourceLanguage + ":" + normalized
            guard seen.insert(key).inserted else {
                throw TerminologyError.invalid("第 \(index + 1) 条术语与同方向的已有原文重复。")
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= 65_536 else { throw TerminologyError.invalid("术语配置不能超过 64 KiB。") }
        return data
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 65_536 else { throw TerminologyError.invalid("术语配置不能超过 64 KiB。") }
        let configuration = try JSONDecoder().decode(Self.self, from: data)
        _ = try configuration.validatedData()
        return configuration
    }

    /// Compare with the file opened by the editor before replacing it atomically.
    public func save(to url: URL = Self.fileURL, replacing expectedData: Data?) throws -> Data {
        let data = try validatedData()
        let current = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        guard current == expectedData else {
            throw TerminologyError.invalid("术语文件已被其他程序修改，请重新载入后再编辑。")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return data
    }
}

public enum TerminologyError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case let .invalid(message): return message }
    }
}
