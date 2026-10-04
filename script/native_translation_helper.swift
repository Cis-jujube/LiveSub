// Private, app-owned JSON-lines bridge to installed offline translation models.
// No listener, language download, transcript logging, or model fallback here.
import Foundation
import Translation

private struct Part: Decodable {
    let text: String
    let protected: Bool
}

private struct Request: Decodable {
    let id: Int
    let operation: String
    let source_language: String?
    let parts: [Part]?
}

private struct Reply: Encodable {
    let id: Int
    let ready: Bool?
    let translation: String?
    let error: String?
}

@main
private struct NativeTranslationHelper {
    @MainActor
    static func main() async {
        guard #available(macOS 26.4, *) else {
            // Exit without attempting unsupported APIs. The owner uses Qwen.
            exit(EXIT_FAILURE)
        }
        await serve()
    }

    static func write(_ reply: Reply) {
        do {
            var data = try JSONEncoder().encode(reply)
            data.append(0x0A)
            try FileHandle.standardOutput.write(contentsOf: data)
        } catch {
            exit(EXIT_FAILURE)
        }
    }

    @available(macOS 26.4, *)
    @MainActor
    static func serve() async {
        var session: TranslationSession?
        while let line = readLine() {
            guard line.utf8.count < 65_536,
                  let request = try? JSONDecoder().decode(Request.self, from: Data(line.utf8)),
                  request.id > 0 else {
                exit(EXIT_FAILURE)
            }
            if request.operation == "close" { return }
            if request.operation == "prepare" {
                let availability = LanguageAvailability(preferredStrategy: .lowLatency)
                let source = Locale.Language(identifier: "en")
                let target = Locale.Language(identifier: "zh-Hans")
                guard await availability.status(from: source, to: target) == .installed else {
                    write(Reply(id: request.id, ready: false, translation: nil,
                                error: "languages_not_installed"))
                    continue
                }
                let installed = TranslationSession(installedSource: source, target: target,
                                                   preferredStrategy: .lowLatency)
                guard !installed.canRequestDownloads else { exit(EXIT_FAILURE) }
                do {
                    _ = try await installed.translate("Hello.")
                    session = installed
                    write(Reply(id: request.id, ready: true, translation: nil,
                                error: nil))
                } catch {
                    write(Reply(id: request.id, ready: false, translation: nil,
                                error: "prepare_failed"))
                }
                continue
            }
            guard request.operation == "translate", request.source_language == "en",
                  let parts = request.parts, !parts.isEmpty, parts.count <= 4096,
                  parts.allSatisfy({ !$0.text.isEmpty }),
                  parts.reduce(0, { $0 + $1.text.utf8.count }) <= 32_768,
                  let session else {
                write(Reply(id: request.id, ready: nil, translation: nil,
                            error: "invalid_request"))
                continue
            }
            var source = AttributedString("")
            for part in parts {
                var span = AttributedString(part.text)
                if part.protected { span.translation.skipsTranslation = true }
                source.append(span)
            }
            do {
                let response = try await session.translate(source)
                write(Reply(id: request.id, ready: nil, translation: response.targetText,
                            error: nil))
            } catch {
                write(Reply(id: request.id, ready: nil, translation: nil,
                            error: "translation_failed"))
            }
        }
        // EOF follows an orderly owner shutdown or crash; no helper is retained.
    }
}
