// Standalone research probe for installed Apple translation languages.
// Compile with: xcrun swiftc -O -parse-as-library <source> -o <output>
// This executable cannot request language downloads and never starts a server.
import Foundation
import Translation

struct ProbePart: Codable {
    let text: String
    let protected: Bool
}

struct ProbeCase: Codable {
    let id: String
    let source_language: String
    let target_language: String
    let source: String
    let parts: [ProbePart]
    let direct_output: String?
}

struct ProbeRow: Codable {
    let round: Int
    let id: String
    let source: String
    let translation: String
    let elapsed_ms: Double
    let generated: Bool
    let error: String?
}

struct ProbeReport: Codable {
    let strategy: String
    let scope: String
    let languages_installed: Bool
    let downloads_requested: Bool
    let statuses: [String: String]
    let rounds: Int
    let cases: [ProbeRow]
}

@main
struct AppleTranslationProbe {
    @MainActor
    static func main() async {
        do {
            try await run()
        } catch {
            fputs("Translation probe failed: \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    @MainActor
    static func run() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4, let rounds = Int(arguments[3]), (1...3).contains(rounds) else {
            throw NSError(domain: "TranslationProbe", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Usage: probe prepared-cases.json new-output.json rounds(1...3)"])
        }
        let inputURL = URL(fileURLWithPath: arguments[1])
        let outputURL = URL(fileURLWithPath: arguments[2])
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw NSError(domain: "TranslationProbe", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Output path already exists"])
        }
        let cases = try JSONDecoder().decode([ProbeCase].self, from: Data(contentsOf: inputURL))
        guard cases.count == 96, Set(cases.map(\.id)).count == 96,
              cases.allSatisfy({
                  !$0.source.isEmpty &&
                  (($0.source_language == "en" && $0.target_language == "zh") ||
                   ($0.source_language == "zh" && $0.target_language == "en")) &&
                  ($0.direct_output != nil || !$0.parts.isEmpty)
              }) else {
            throw NSError(domain: "TranslationProbe", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Expected 96 unique nonempty prepared fixtures with en/zh directions"])
        }
        let availability = LanguageAvailability(preferredStrategy: .lowLatency)
        let pairs = [("en", "zh-Hans"), ("zh-Hans", "en")]
        var statuses: [String: String] = [:]
        for (source, target) in pairs {
            let status = await availability.status(from: Locale.Language(identifier: source),
                                                   to: Locale.Language(identifier: target))
            let label: String
            switch status {
            case .installed: label = "installed"
            case .supported: label = "supported_not_installed"
            case .unsupported: label = "unsupported"
            @unknown default: label = "unknown"
            }
            statuses["\(source)-\(target)"] = label
        }
        let ready = statuses.values.allSatisfy { $0 == "installed" }
        var rows: [ProbeRow] = []
        if ready {
            let english = TranslationSession(installedSource: Locale.Language(identifier: "en"),
                                             target: Locale.Language(identifier: "zh-Hans"),
                                             preferredStrategy: .lowLatency)
            let chinese = TranslationSession(installedSource: Locale.Language(identifier: "zh-Hans"),
                                             target: Locale.Language(identifier: "en"),
                                             preferredStrategy: .lowLatency)
            guard !english.canRequestDownloads, !chinese.canRequestDownloads else {
                throw NSError(domain: "TranslationProbe", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: "Probe must not be capable of requesting downloads"])
            }
            // Cold model startup is excluded from measured warm translations.
            _ = try await english.translate("Hello.")
            _ = try await chinese.translate("你好。")
            for round in 1...rounds {
                for item in cases {
                    let started = ProcessInfo.processInfo.systemUptime
                    var translation = ""
                    var failure: String?
                    do {
                        if let direct = item.direct_output {
                            translation = direct
                        } else {
                            var attributed = AttributedString("")
                            for part in item.parts {
                                var span = AttributedString(part.text)
                                if part.protected { span.translation.skipsTranslation = true }
                                attributed.append(span)
                            }
                            let session = item.source_language == "en" ? english : chinese
                            translation = try await session.translate(attributed).targetText
                        }
                    } catch {
                        failure = String(describing: error)
                    }
                    rows.append(ProbeRow(round: round, id: item.id, source: item.source,
                                         translation: translation,
                                         elapsed_ms: (ProcessInfo.processInfo.systemUptime - started) * 1000,
                                         generated: item.direct_output == nil, error: failure))
                }
            }
        }
        let report = ProbeReport(strategy: "lowLatency",
                                 scope: "Warm native full-output engine and attributed-span construction; excludes exported terminology lookup, ASR, app IPC and UI. No reference-context prompt or Qwen model parity is claimed.",
                                 languages_installed: ready, downloads_requested: false,
                                 statuses: statuses, rounds: rounds, cases: rows)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(report).write(to: outputURL, options: .atomic)
        print(ready ? "Native benchmark complete: \(rows.count) translations" : "Languages not installed; no translations or downloads attempted")
    }
}
