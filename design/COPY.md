# Interface copy contract

User delegated the design update; these functional labels are implementation choices to verify against the final source, not separately approved marketing copy.

## Main reading window

Retain: LiveSub; 音源; 麦克风; 系统音频; 方向; 双语; 仅译文; 原文; 译文; 开始 / 暂停 / 继续; 停止; 设置; 显示 / 隐藏悬浮字幕; 回到实时; 复制全部; 导出; TXT; Markdown.

Use a short empty-state reading prompt tied to the selected display mode. Explain that the user starts the session and chooses the input. Keep truthful permission and local-storage information available without repeating it in the toolbar, footer and empty state.

Status must come from the real controller. Pending, failed and previous-preview markers retain their existing meanings. Do not insert test text, fake live activity, unmeasured latency or unsupported accuracy claims.

## Settings

Prioritize 翻译与术语, AI / 科技, 通用, 自定义术语, 翻译方向, 原文, 固定译法, 添加, 删除, 保存术语, 重新载入 and 恢复默认. Preserve the reset confirmation and its statement that saving replaces the file.

Explain that custom terms override presets, saving applies to the next translation request, and existing translations remain unchanged. Keep permission requirements, local model identifiers and storage behavior in the secondary local-runtime surface. Error/success wording must reflect the actual operation.

## Verification

Final wording and deliberate label changes are recorded in QA after inspecting the implemented views. Do not add decorative feature descriptions or implied speaker identification.

Final empty-state idle headline is “字幕会显示在这里” or “译文会显示在这里”, followed by “选择音源与翻译方向，点击「开始」。” Loading/listening/paused/stopping/error use phase-specific copy. Removed the oversized branding subtitle and repeated inline export explanation; bilingual export remains explained by button help. “添加” became “添加术语”. Settings categories are “翻译与术语” and “权限与本地运行”.

## 2026-10-04 label changes

Toolbar status words: 就绪 / 准备中 / 聆听中 / 已暂停 / 正在收尾 / 需要处理 / 准备说话人模型 (full controller status stays in the tooltip and accessibility value). Overlay toggle is labelled 悬浮字幕 with on/off state instead of 显示字幕 / 隐藏字幕. 复制全部 moved into the 导出 menu beside 导出纯文本 · TXT and 导出 Markdown · MD; confirmations read 已复制全部字幕 / 已导出纯文本 / 已导出 Markdown. Translation-only header reads 简体中文 · 译自 English. The direction picker became the ⇄ button (help: 切换翻译方向（当前：…）). New: 字幕底板 with 在明亮画面上更易读；默认透明。 and the overlay's 完成. Settings tabs keep 翻译与术语 and 权限与本地运行; 删除 is an icon button with the same accessibility label. Placeholder notes render without brackets (翻译中… / 上一版译文 · 更新中… / 翻译失败 / 未选中 · 未翻译) while exports keep the bracketed originals. Empty-state copy is unchanged; error detail now points 上方 because the banner sits above the columns.
