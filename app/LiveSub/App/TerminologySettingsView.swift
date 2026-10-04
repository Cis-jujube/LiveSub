import LiveSubSubtitles
import SwiftUI

struct TerminologySettingsView: View {
    @ObservedObject var editor: TerminologyEditor

    private static let domains: [(id: String, label: String)] = [
        ("ai", "AI"), ("software", "软件科技"), ("data", "数据统计"),
        ("finance", "金融"), ("quant", "量化金融"), ("blockchain", "区块链"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    HStack(spacing: 8) {
                        ForEach(Self.domains, id: \.id) { domain in
                            DomainChip(label: domain.label, isOn: editor.domainBinding(domain.id))
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    HStack(alignment: .firstTextBaseline) {
                        Text("翻译领域")
                        Spacer()
                        Menu("快速组合") {
                            Button("通用") { editor.configuration.domains = [] }
                            Button("AI 研发") { editor.configuration.domains = ["ai", "software", "data"] }
                            Button("AI + 金融") { editor.configuration.domains = ["ai", "data", "finance", "quant"] }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .font(.system(size: 12))
                    }
                } footer: {
                    Text("可自由组合，全部不选即通用翻译。术语仅影响译文，不会改写语音识别原文；多义词仍按上下文判断。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section {
                    if editor.configuration.entries.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("尚未添加自定义术语")
                                .font(.system(size: 13, weight: .medium))
                            Text("点击「添加术语」，填写原文及希望使用的译法。")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    } else {
                        HStack(spacing: 10) {
                            Text("方向").frame(width: 92, alignment: .leading)
                            Text("原文").frame(maxWidth: .infinity, alignment: .leading)
                            Color.clear.frame(width: 12, height: 1)
                            Text("固定译法").frame(maxWidth: .infinity, alignment: .leading)
                            Color.clear.frame(width: 22, height: 1)
                        }
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                        ForEach(editor.configuration.entries.indices, id: \.self) { index in
                            HStack(spacing: 10) {
                                Picker("第 \(index + 1) 条术语翻译方向", selection: editor.entryBinding(index, \.sourceLanguage)) {
                                    Text("英 → 中").tag("en")
                                    Text("中 → 英").tag("zh")
                                }
                                .labelsHidden()
                                .frame(width: 92)
                                TextField("原文", text: editor.entryBinding(index, \.source))
                                    .labelsHidden()
                                    .frame(maxWidth: .infinity)
                                    .accessibilityLabel("第 \(index + 1) 条术语原文")
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 12)
                                    .accessibilityHidden(true)
                                TextField("固定译法", text: editor.entryBinding(index, \.target))
                                    .labelsHidden()
                                    .frame(maxWidth: .infinity)
                                    .accessibilityLabel("第 \(index + 1) 条术语译文")
                                Button {
                                    editor.configuration.entries.remove(at: index)
                                } label: {
                                    Image(systemName: "minus.circle")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 22, height: 22)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("删除")
                                .accessibilityLabel("删除第 \(index + 1) 条术语")
                            }
                            .textFieldStyle(.roundedBorder)
                        }
                    }
                    Button {
                        editor.configuration.entries.append(TerminologyEntry())
                    } label: {
                        Label("添加术语", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(editor.configuration.entries.count >= 100 || !editor.maySave)
                } header: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("自定义术语")
                        Text("\(editor.configuration.entries.count) / 100")
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("按翻译方向指定固定译法，自定义术语优先于预设。保存后从下一次翻译请求起生效，已有译文保持不变。术语只保存在本机。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if let errorMessage = editor.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                } else if let statusMessage = editor.statusMessage {
                    Label(statusMessage, systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("恢复默认…") { editor.confirmingReset = true }
                    Button("重新载入") { editor.load() }
                    Spacer()
                    Button("保存术语") { editor.save() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                        .keyboardShortcut("s", modifiers: [.command])
                        .disabled(!editor.maySave)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .tint(.primary)
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
            Text("将清空编辑中的自定义术语并仅选择 AI。现有文件会在你点击保存术语后替换。")
        }
    }
}

/// Domain presets as selectable chips; selection uses the app's vermilion accent.
private struct DomainChip: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 5) {
            if isOn {
                Image(systemName: "checkmark").font(.system(size: 9.5, weight: .bold))
            }
            Text(label)
        }
        .font(.system(size: 12.5, weight: .medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .foregroundStyle(isOn ? Theme.accent : Color.primary.opacity(0.78))
        .background(Capsule(style: .circular).fill(isOn ? Theme.accent.opacity(0.11) : Color.primary.opacity(0.035)))
        .overlay(Capsule(style: .circular).strokeBorder(isOn ? Theme.accent.opacity(0.5) : Color.primary.opacity(0.12)))
        .contentShape(Capsule())
        .onTapGesture { isOn.toggle() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
        .accessibilityValue(isOn ? "已选择" : "未选择")
        .accessibilityAction { isOn.toggle() }
    }
}

@MainActor
final class TerminologyEditor: ObservableObject {
    @Published var configuration = TerminologyConfiguration()
    @Published var baseline: Data?
    @Published var loaded = false
    @Published var maySave = false
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    @Published var confirmingReset = false
    var savedConfiguration: TerminologyConfiguration?

    func domainBinding(_ domain: String) -> Binding<Bool> {
        Binding(
            get: { self.configuration.domains.contains(domain) },
            set: { enabled in
                if enabled {
                    if !self.configuration.domains.contains(domain) { self.configuration.domains.append(domain) }
                } else {
                    self.configuration.domains.removeAll { $0 == domain }
                }
            }
        )
    }

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
