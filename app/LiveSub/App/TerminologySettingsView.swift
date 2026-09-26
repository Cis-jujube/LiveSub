import LiveSubSubtitles
import SwiftUI

struct TerminologySettingsView: View {
    @StateObject private var editor = TerminologyEditor()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("翻译领域与术语").font(.headline)
            Picker("领域", selection: $editor.configuration.profile) {
                Text("AI / 科技").tag("ai")
                Text("通用").tag("general")
            }
            .pickerStyle(.segmented)
            Text(editor.configuration.profile == "ai"
                 ? "AI / 科技预设保留 Agent、token 等常用术语。普通多义词仍依上下文翻译；此设置不会修改语音识别的原文。"
                 : "通用翻译不启用 AI / 科技术语预设；仍会使用下方自定义术语。此设置不会修改语音识别的原文。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("自定义术语 · \(editor.configuration.entries.count)/100").font(.subheadline)
                Spacer()
                Button("添加") { editor.configuration.entries.append(TerminologyEntry()) }
                    .disabled(editor.configuration.entries.count >= 100 || !editor.maySave)
            }
            if editor.configuration.entries.isEmpty {
                Text("可按翻译方向添加原文与固定译法，自定义术语优先于预设。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 65, alignment: .leading)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(editor.configuration.entries.indices, id: \.self) { index in
                            HStack(spacing: 8) {
                                Picker("翻译方向", selection: editor.entryBinding(index, \.sourceLanguage)) {
                                    Text("英 → 中").tag("en")
                                    Text("中 → 英").tag("zh")
                                }
                                .labelsHidden().frame(width: 95)
                                TextField("原文", text: editor.entryBinding(index, \.source))
                                    .accessibilityLabel("第 \(index + 1) 条术语原文")
                                TextField("固定译法", text: editor.entryBinding(index, \.target))
                                    .accessibilityLabel("第 \(index + 1) 条术语译文")
                                Button("删除") { editor.configuration.entries.remove(at: index) }
                            }
                            .textFieldStyle(.roundedBorder)
                        }
                    }
                }
                .frame(height: min(210, CGFloat(editor.configuration.entries.count * 36)))
            }
            if let errorMessage = editor.errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let statusMessage = editor.statusMessage {
                Text(statusMessage).foregroundStyle(.secondary).font(.system(size: 12))
            }
            HStack {
                Button("恢复默认…") { editor.confirmingReset = true }
                Button("重新载入") { editor.load() }
                Spacer()
                Button("保存术语") { editor.save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!editor.maySave)
            }
            Text("保存后从下一次翻译请求起生效，已有译文保持不变。术语只保存在本机。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .task { if !editor.loaded { editor.load() } }
        .onChange(of: editor.configuration) { _, value in
            if value != editor.savedConfiguration { editor.statusMessage = nil }
        }
        .alert("恢复默认术语？", isPresented: $editor.confirmingReset) {
            Button("取消", role: .cancel) {}
            Button("恢复默认", role: .destructive) {
                editor.configuration = TerminologyConfiguration()
                editor.maySave = true
                editor.errorMessage = nil
                editor.statusMessage = "已恢复默认草稿；点击保存术语后写入文件。"
            }
        } message: {
            Text("将清空编辑中的自定义术语并选择 AI / 科技。现有文件会在你点击保存术语后替换。")
        }
    }

}

@MainActor
private final class TerminologyEditor: ObservableObject {
    @Published var configuration = TerminologyConfiguration()
    @Published var baseline: Data?
    @Published var loaded = false
    @Published var maySave = false
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    @Published var confirmingReset = false
    var savedConfiguration: TerminologyConfiguration?

    func entryBinding(_ index: Int, _ keyPath: WritableKeyPath<TerminologyEntry, String>) -> Binding<String> {
        Binding(
            get: { self.configuration.entries.indices.contains(index) ? self.configuration.entries[index][keyPath: keyPath] : "" },
            set: { value in
                guard self.configuration.entries.indices.contains(index) else { return }
                self.configuration.entries[index][keyPath: keyPath] = value
            }
        )
    }

    func load() {
        loaded = true
        maySave = false
        errorMessage = nil
        statusMessage = nil
        do {
            let url = TerminologyConfiguration.fileURL
            baseline = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
            configuration = try baseline.map(TerminologyConfiguration.decode) ?? TerminologyConfiguration()
            savedConfiguration = configuration
            maySave = true
        } catch {
            errorMessage = "无法载入术语：\(error.localizedDescription) 现有文件未修改。可修复后重新载入，或明确恢复默认后保存。"
        }
    }

    func save() {
        do {
            for index in configuration.entries.indices {
                configuration.entries[index].source = configuration.entries[index].source.trimmingCharacters(in: .whitespacesAndNewlines)
                configuration.entries[index].target = configuration.entries[index].target.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            baseline = try configuration.save(replacing: baseline)
            savedConfiguration = configuration
            errorMessage = nil
            statusMessage = "已保存；下一次翻译请求将使用新的领域和术语。"
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = nil
        }
    }
}
