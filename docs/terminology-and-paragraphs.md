# 连续段落与专业术语更新

日期：2026-09-26。此记录只描述本轮改动；原有交付报告与长期测试数字仍是各自时间点的历史证据。

## 使用体验

主窗口把多条字幕组成逐步增长的段落，原文与译文在同一行左右对齐，共用一个滚动区域。源文修订、译文迟到和翻译失败都在原位置更新。等待中的内容明确标记，不显示已经过时的旧译文。复制和 TXT／Markdown 导出也按段落组织。

段落按完整句与长度／时长边界分组，语言、会话或代次变化会开启新段。分组不是语义摘要，原始字幕记录及修订关系仍保留，悬浮字幕继续读取当前片段。手动滚动会暂停自动跟随；“回到实时”恢复跟随，译文单独更新时也会触发跟随。

在“设置…”中：

- **AI / 科技**：默认启用小型本地术语预设。`AI agent` 保留为 `AI Agent`；独立的 `agent`、`token` 等歧义词结合 AI／LLM 上下文选择，避免无条件套用到经纪人、访问令牌等场景。
- **通用**：关闭内置预设，仍应用用户自定义术语。
- **自定义术语**：每条选择“英 → 中”或“中 → 英”，填写原文与固定译法；同方向自定义词条覆盖内置条目。例如英译中 `AI agent → 智能体`。这只是用户偏好，不宣称唯一权威译法。
- **保存术语**：保存后下一次翻译请求使用新配置，已有译文不追溯改写。“恢复默认…”先恢复编辑草稿，仍需保存才会替换文件；“重新载入”读取当前本地配置。

配置位于 `~/Library/Application Support/LiveSub/terminology.json`，最多 100 条，每侧 1–80 个字符，文件上限 64 KiB。编辑器校验空值、重复词条、控制字符和长度；原子写入前核对文件是否被其他程序修改。后端读到损坏配置时保留最近有效配置并记录警告。

## 实现范围

| 文件 | 作用 |
| --- | --- |
| `app/LiveSub/Subtitles/TranscriptParagraph.swift` | 将原始字幕投影为稳定段落；同段拼接原文和当前版本译文 |
| `app/LiveSub/Subtitles/SubtitleStore.swift` | 段落状态、每次有效内容更新的通知、段落导出 |
| `app/LiveSub/MainWindow/TranscriptView.swift` | 段落双栏、共享滚动、等待／失败状态、回到实时 |
| `app/LiveSub/Subtitles/TerminologyConfiguration.swift` 与 `app/LiveSub/App/TerminologySettingsView.swift` | 配置校验、本地保存与设置界面 |
| `backend/livesub/translation/terminology.py` | 预设、自定义覆盖、方向与边界匹配、上下文消歧 |
| `backend/livesub/translation/mlx_engine.py` | 在有界 prompt 中加入匹配术语，最多参考四对前文，仍受 512 context token／2048 总输入 token 约束 |
| `backend/livesub/session.py` | 在实际开始翻译时获取同会话、同代次、同方向且位于当前片段之前的已完成前文，避免排队时过早固定旧上下文及未来片段泄漏 |

本轮没有增加项目依赖，也未下载或捆绑大型第三方术语库。[术语调研](terminology-research.md) 保留了 [Google ML Glossary](https://developers.google.com/machine-learning/glossary?hl=en)、[Microsoft 语言资源](https://learn.microsoft.com/en-us/globalization/reference/microsoft-language-resources)、[机器之心术语库及许可](https://github.com/jiqizhixin/Artificial-Intelligence-Terminology-Database/blob/master/LICENSE) 的来源与边界，以及 [Google glossary](https://docs.cloud.google.com/translate/docs/advanced/glossary)／[DeepL context](https://developers.deepl.com/api-reference/translate/request-translation) 的设计依据。

最终采用当前源文的局部词语保护：只有通过方向、词边界、短语优先与领域规则的词语会被标记；模型翻译周围文字，本地检查每个标记恰好保留一次后恢复指定词语。缺失、重复或未知标记导致明确的翻译失败，不在任意译文中全局替换“代理”“令牌”。有保护词时只提供历史源文，避免沿用历史机器误译；原始字幕记录保持原文。

## 验证与剩余限制

### 文本真实模型对比

固定本地 Qwen3-4B-Instruct-2507-4bit，同次加载、temperature 0、最多输出 256 token，逐例交替旧 prompt 与最终版。详细方法及全部迭代失败见 [基准说明](terminology-benchmark.md)，逐例输出与耗时见 [最终原始报告](terminology-benchmark-protected-final.json)。早期名为 `terminology-benchmark-final.json` 的文件是当时的候选版，不能当作本轮最终结果。

| 检查 | 旧版 | 最终版 |
| --- | ---: | ---: |
| 28 条开发回归指定词检查 | 10/28 | 28/28 |
| 最后新增 6 条有限检查 | 0/6 | 5/6 |
| 合计 | 10/34 | 33/34 |
| 热模型单请求耗时中位数 | 232.56 ms | 306.18 ms |
| 均值／最大值 | 238.19／313.24 ms | 311.96／416.89 ms |

中位数增加 73.62 ms（约 31.7%）。这是短文本单次配对结果，不包括 ASR、采集、排队、IPC 或屏幕显示；前 28 条已用于迭代，不是独立评测。词法检查通过也不等于整句翻译准确。

34 条均生成译文且无标记校验失败。唯一剩余词法失败是 `Keep the authentication token secret.`：新旧都生成“保持认证token的机密性。”，没有满足检查期望的“令牌”。选择器已避开认证义项，模型仍自行混用英文。部分保护后的句子也偏生硬，例如“AI Agent 并未花费 90 输出 tokens。”，因此自然度、量词与冠词仍需改善。

早期仅提示词方案漏掉 `tokens`、抄用“AI代理人”，均保留在原始报告。最终旧历史案例输出“该AI Agent使用了一个上下文窗口。”，未完句仍为“如果AI Agent无法”。这是局部保护与上下文组合改动的证据，不能拆成单一策略的独立收益。

### 界面与链路验证

`./script/test.sh` 已通过：65 项 Python 测试，Audio 5 项，Store 的段落／术语与 1,800 对记录检查，Overlay 4 项位置检查与 reset，Backend 15 条协议及子进程／认证检查，Swift debug 构建。

随后补入两项 Unicode 回归，最终后端全套为 **67 passed**；Swift 代码在上述整套检查后未改。这里区分两次检查，未把 67 项误写成先前 `test.sh` 的结果。

[11 秒公开真实人声 WAV 的 IPC 原始报告](ipc-terminology-en.json) 为 `passed=true`：按实时节奏发送 69 帧，收到 44 个字幕事件和 4 条最终译文；无错误、重复 final 或修订错配，尾句存在，停止到 idle 为 313.91 ms。该样例验证后端音频、ASR、翻译、IPC 与收尾，不是原生麦克风采集，也不是针对 AI 术语的识别率测评。

[技术语句音频联合报告](terminology-audio-tts.json) 使用本机 macOS Daniel 声音合成的 10.010 秒英文 WAV，由真实 R2T2 与 Qwen 处理。两段最终翻译均完成、失败为 0，最大翻译队列深度 1；ASR 计算实时系数为 0.704，采样最大 RSS 为 5,270,470,656 bytes（约 4.91 GiB）。两段翻译计算分别为 992.99／381.43 ms，从片段近似结束到译文完成分别为 1194.80／615.79 ms，均不是说话到屏幕的延迟。

第一段识别为 `An AI agent can use tools. The language model has a context window. Each input token`，译为“一个AI Agent可以使用工具。语言模型具有上下文窗口。每个输入token”；第二段以 `Has a cost.` 开头，后半句译为“AI Agent 不得删除这些文件。”。`AI Agent`／`token` 与上下文窗口映射符合本次目标，但第六秒的切分把 `Each input token has a cost.` 拆开，说明词库不能消除 ASR 分段问题。

该 harness 直接调用 ASR → translator，不经过 `LiveSession` 的上下文选择、WebSocket IPC 或原生采集。它是人工合成语音的有限模型联合检查，不能等同于真实讲座识别率。

复现技术音频检查（只生成文件，不播放）：

```sh
say -v Daniel -r 145 -o /tmp/livesub-ai-terminology.aiff 'An AI agent can use tools. The language model has a context window. Each input token has a cost. The AI agent must not delete the files.'
afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/livesub-ai-terminology.aiff /tmp/livesub-ai-terminology.wav
backend/.venv/bin/python script/benchmark_joint.py /tmp/livesub-ai-terminology.wav --language English --include-text --output /tmp/livesub-terminology-audio-recheck.json
```

最终 `./script/build_and_run.sh --verify` 已通过 release 构建、bundle、Info.plist 及 ad hoc 严格 codesign 校验。新包路径为 `dist/LiveSub.app`；`Contents/MacOS/LiveSub` 的 SHA256 为 `4b30b70dbc2e14e296949937a29dde5b83b2e2461e2783b31b781b04021d73a0`。这是本轮产物身份，旧交付报告中的包与长期验收保持历史快照。

原生 CUA 操作确认：主窗口在 idle 状态打开设置并显示 AI 预设；新增空条目保存时出现长度校验；英译中 `AI agent → AI Agent` 保存后重新载入仍存在，独立后端解析器也成功读取同一文件。随后删除测试词条并保存，重开设置确认 AI 预设、0 条自定义术语。Cmd+Q 正常退出，进程检查未发现 App、`livesub.server` 或相关测试进程残留。此次没有启动录音。

此前段落 PNG 已人工检视。后续 CUA 截图工具返回空白，因此此次设置交互只补充操作与可访问性状态证据，不追加像素质量保证；详细范围见 [界面验证记录](paragraph-ui-checks.md)。

- [段落界面记录](paragraph-ui-checks.md) 与 [合成截图](paragraph-layout-fixture.png) 使用实际生产 `TranscriptView` 的离屏渲染。输入是合成字幕，证明排版状态，不能证明 ASR、翻译质量或真实滚动交互。
- 文本真实模型测试直接向本地 Qwen 输入文本，隔离翻译词库效果；词条命中不等于整句语义正确，其推理耗时不等于说话到屏幕的延迟。
- 真实 WAV 后端回归覆盖音频输入、ASR、翻译与 IPC；即使通过，也不证明 macOS 麦克风／系统音频采集或屏幕显示效果。

翻译术语不能可靠修复已经识别错误的原文。R2T2 上游及本地版本支持 ASR 上下文／热词，但本轮没有启用或实测热词注入。原生系统音频的 ScreenCaptureKit `-3801` 问题也不在本轮已解决范围，现有“部分验收”状态继续适用。
