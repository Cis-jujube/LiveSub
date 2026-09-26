# LiveSub

LiveSub 是个人本机使用的 macOS 实时双语字幕 App。它使用原生 macOS 音频采集、R2T2 本地语音识别和 Qwen MLX 本地翻译。主窗口将连续字幕组织为逐步增长的段落；默认双语模式按同一段左右对齐，也可选择“仅译文”。主窗口与透明悬浮层同步使用显示偏好并读取同一个字幕 Store，不会另外启动识别。

本轮新增共享且持久保存的“仅译文”显示选项，并调整预览调度、复用完全相同请求的模型输出。三组有限 WAV IPC 样本的最终译文等待中位数分别降低约 16.1%、43.3%、22.6%；首条译文基本持平，技术 TTS 首译慢 32.30 ms，不能承诺通用延迟改善。整套 80 项后端及 Swift／IPC 检查、release 签名和未录音状态的原生切换／重开持久化检查已通过。方法、基线和结果见 [仅译文与延迟更新](docs/translation-only-and-latency.md)。上一轮 AI／科技术语、自定义词条及上下文改动见 [段落与术语更新](docs/terminology-and-paragraphs.md)，来源见 [调研记录](docs/terminology-research.md)。下方既有验收数字保留为历史快照。

上一轮本地文本模型测试的指定词检查为 **10/34 → 33/34**：其中 28 条是开发回归、6 条是最后新增的有限检查，不能称为通用翻译准确率。热模型短文本请求中位耗时从 232.56 ms 增至 306.18 ms；仍有未保护的认证语境词语混用英文、个别句子不够自然的问题。完整结果与失败见 [模型基准说明](docs/terminology-benchmark.md)。上一轮 `./script/test.sh` 通过时包含 65 项后端测试及 Swift／IPC 检查；补入两项 Unicode 回归后，后端完整重跑为 **67 passed**，该轮最后两项回归期间 Swift 未改。11 秒真实人声 WAV 的后端 IPC 回归也已通过；这些不代表原生音频采集验收通过。

**当前是部分验收完成的个人本地版本。** 此前版本的麦克风英译中、中译英均已观察到环境音配对字幕，但短播公开 WAV 的识别内容未能与样本对应，原生准确率尚未通过验证。中英两种方向的后端曾通过直接输入真实录音的测试。系统音频最近一次实测返回 ScreenCaptureKit `-3801`，本轮未修复或重验。悬浮实际覆盖区点击穿透、全屏/多屏兼容、断网实测及完整字幕链路的 30 分钟持续正确性仍待验证，详见 [人工测试矩阵](docs/manual-test-matrix.md)。

**正式后端连续测试已通过 1,804 秒（30 分 4 秒）。** 一个 WebSocket 会话按实时节奏重复 164 次公开英文录音，收到 656 个最终译文和 6,238 个字幕事件，未报告错误、重复 final、修订倒退或源译错配，尾句保留。后端采样 RSS 峰值为 4,979.45 MiB、起止增加 64.76 MiB；片段近似结束至最终事件接收的中位数为 958.55 ms、P95 为 1,217.92 ms。这是 **backend-only** 结果，不包含 macOS 采集、Swift UI 或悬浮层，也不是说话结束到屏幕显示的延迟。详见 [测试方法](docs/soak-backend.md) 与 [原始报告](docs/soak-backend.json)。

## 系统与一次性准备

- Apple Silicon Mac，部署目标为 macOS 15 或更新版本；实际只在本机 macOS 27.0 测试，未验证 macOS 15/26 兼容性。本机实测环境与限制见 [交付报告](docs/delivery-report.md)。
- Xcode Command Line Tools、Swift、`uv`。构建 R2T2 原生模块需要 C/C++ 编译工具；脚本会从固定修订下载并校验源码。当前个人版没有公证，也没有 App Store 签名。
- 预留至少约 8 GiB 可用空间，用于 R2T2、Qwen 模型、编译和独立 Python 环境。模型在 `~/Library/Application Support/LiveSub/models/`，不会进入 Git 或 `.app`。

在源码目录执行一次：

准备或重新构建前，请先退出正在运行的 LiveSub。

```bash
./script/setup_models.sh
```

脚本依次准备锁定的 Python 3.12 环境、R2T2 Metal 原生模块、校验 R2T2 与 Qwen 模型、构建并 ad hoc 签名 `.app`，最后准备 App 专用 Python 环境。R2T2 权重约 1.4 GB，Qwen 权重约 2.3 GB。模型来源、固定修订和哈希见 [模型清单](docs/model-manifest.md)。下载失败可以重跑脚本；已校验的 R2T2 文件会跳过。首次准备需要网络；模型就绪后识别和翻译使用本地模型，正式断网实测仍待完成。

## 构建、打开与测试

```bash
./script/build_and_run.sh --verify   # 构建、检查 .app 签名，不打开
./script/build_and_run.sh --run      # 构建并打开 App
./script/test.sh                     # 后端、Swift 逻辑、IPC 检查与构建
```

测试脚本使用锁定依赖，执行后端逻辑测试、Swift 可执行断言、真实本机握手和 debug 构建；它不会重新跑真实模型音频基准、采集权限或悬浮交互验收。release `.app` 打包和签名由 `--verify` 单独检查。

此前原生提交 `c0de296` 的检查已通过：44 项 Python 测试；Audio 5 项；Store 16 条断言加 1,800 对合成记录；Overlay 4 项位置检查和会话字幕清空；Backend 15 条协议断言、旧启动回调/失败清理隔离及真实认证握手。该版本 release `.app` 当时已重新打包并通过 `codesign --verify --deep --strict`，也完成部分运行交互复测；这些历史结果不包含系统音频成功或完整实机验收。

此前版本另完成 **1,953.28 秒（32 分 33.28 秒）原生进程与资源监测**：原始 App 和直属后端在 195 个样本中同时存活、未观察到 PID 重用；用户报告 Cmd+Q 后，监测记录两进程退出，独立进程检查未发现残留。App 采样 RSS 峰值 175.66 MiB，后端峰值 4,980.17 MiB；首尾增加分别为 27.10 和 6.24 MiB。结束时签名有效、二进制未变。这是旧版麦克风环境音中译英会话的进程观察，未逐点核验字幕更新，不能证明全程采集、准确率或可见延迟。见 [原生实测记录](docs/native-soak-plan.md) 和 [监测汇总](docs/native-soak-summary.json)。

上一轮经验证的构建产物是 `dist/LiveSub.app`，包路径为 `dist/LiveSub.app`。上一轮最终 `./script/build_and_run.sh --verify` 已通过 release 构建、bundle、Info.plist 与 ad hoc 严格签名检查；实机打开主窗口及设置成功。该轮 `Contents/MacOS/LiveSub` 的 SHA256 为 `4b30b70dbc2e14e296949937a29dde5b83b2e2461e2783b31b781b04021d73a0`。设置空值校验、保存、重新载入及删除测试词条均已操作验证，最后恢复为 AI 预设、0 条自定义术语；未启动录音。Cmd+Q 后检查未发现 App 或后端残留。

本轮新包仍位于 `dist/LiveSub.app`；`./script/build_and_run.sh --verify` 已通过 release、bundle、Info.plist 和严格 ad hoc 签名检查。新二进制 SHA256 为 `7926d5d8202fc3383cb1793d403ecd5544ed0d2aeb70bc2cb27a05edd56f7378`。原生主窗口的仅译文／双语切换、重开后记住选择、悬浮层开启期间切换与退出清理已在 idle 状态验证，未启动录音；最终保存为“仅译文”。菜单栏额外入口与说话期间切换未做现场操作验证，运行截图未提供可用像素证据，详见本轮记录。

当前个人 ad hoc 包未公证。旧版 `spctl -a -vv dist/LiveSub.app` 实测退出码为 3、结果为 `rejected`，本轮没有重做 Gatekeeper 验收；不保证分发后可直接双击打开。旧 [交付报告](docs/delivery-report.md) 及上面的长期监测数字保持历史快照，上一轮验证边界见 [更新记录](docs/terminology-and-paragraphs.md)，本轮构建与验证状态见 [仅译文与延迟更新](docs/translation-only-and-latency.md)。

App 成功打开后会自行启动和管理一个只绑定 `127.0.0.1` 的本地后端；无需手动打开后端终端。退出会停止采集并终止 App 启动的子进程。同一 Mac 上移动 `.app` 后可复用已准备的 App Support 环境，但移动后的启动行为未单独验证；若更改源码，重新构建 `.app`。

## 使用

1. 打开主窗口，选择“麦克风”或“系统音频”，以及 `English → 简体中文` 或 `中文 → English`。首次打开不会自动录音。
2. 点击“开始”。macOS 首次可能请求麦克风或屏幕与系统音频录制权限；必须在系统提示中由你授权，拒绝后可在系统设置中调整并重新打开 App。
3. 主窗口“字幕显示”可选“双语”或“仅译文”，菜单栏也可切换；主窗口与悬浮层同步，并记住选择。切换不会重启会话、清除原文或触发重新识别，复制和导出仍保留双语。双语模式左列是原文，右列是对应译文；仅译文模式使用整栏显示译文。新内容持续加入当前段落，两列共用滚动区域；原文修订与迟到译文会更新原段落。原文先到时右列显示“翻译中”，不会用旧版本译文冒充新译文。拖动列标题之间的分隔线调整宽度。手动滚动暂停自动跟随，点“回到实时”恢复。
4. 点击“显示悬浮字幕”后，双语文字显示在普通应用之上。默认背景透明、鼠标穿透；双语模式原文在上、译文在下，仅译文模式隐藏原文并缩小面板高度。译文尚未到达时显示“翻译中…”。关闭悬浮层不会停止识别或删除主窗口记录。
5. 菜单栏 LiveSub 图标可暂停/继续、停止、隐藏/显示悬浮层、调整或重置字幕位置、恢复主窗口。调整结束后选择“完成调整并锁定”，恢复鼠标穿透。
6. “复制全部”复制当前会话；“导出”可手动保存 UTF-8 TXT 或 Markdown。字幕默认仅在内存中，开始新会话会清除上一会话的窗口记录。
7. 打开“设置…”选择默认的“AI / 科技”或“通用”。AI 语境下预设保留 `Agent`、`token` 等常用原词；通用模式关闭内置 AI 预设，仍使用自定义术语。添加自定义词条时选择“英 → 中”或“中 → 英”，填写原文和固定译法，点击“保存术语”。保存后从下一次翻译请求生效，已有译文保持不变；自定义词条优先于预设。

术语配置仅保存在本机 `~/Library/Application Support/LiveSub/terminology.json`，最多 100 条，每个原文／译法为 1–80 个字符。它影响翻译，不会修改 ASR 原文。选中的词语会进行局部保护；模型未正确保留保护标记时会明确显示翻译失败，不把无效标记作为译文。歧义匹配、未保护词语和整句自然度仍有模型限制，具体未通过样例见本轮验证记录。

切换音源或翻译方向会结束当前片段并开始新的会话代次，旧字幕保持原方向。系统音频使用 ScreenCaptureKit，不保存屏幕视频。受系统或媒体保护限制的声音可能无法获取。

## 开发结构

- `app/LiveSub/Audio`：麦克风与 ScreenCaptureKit 采集，转换为 16 kHz 单声道 PCM16。
- `app/LiveSub/Backend`：独立 Python 子进程、本机 Bearer WebSocket、单连接和有界发送。
- `backend/livesub`：R2T2、翻译调度、会话和字幕版本控制。
- `app/LiveSub/Subtitles`：共享字幕 Store、稳定段落投影、术语配置校验与本地保存。
- `app/LiveSub/App/TerminologySettingsView.swift`：领域与方向化自定义术语编辑器。
- `backend/livesub/translation/terminology.py`：小型术语预设、本地配置重载、匹配与歧义处理。本轮未新增外部依赖或模型；原生 Overlay 增加了对现有 Subtitles target 的内部依赖。
- `app/LiveSub/Overlay`：非激活、透明、默认鼠标穿透的 AppKit 面板。
- `shared/protocol.md`：音频帧、状态和字幕事件契约。

详细真实测试数据与未验证项见 [交付报告](docs/delivery-report.md)、[人工测试矩阵](docs/manual-test-matrix.md) 和 [已知问题](docs/known-issues.md)。

公开报告中的本机路径已规范化为仓库相对路径或 `~/`；测试结果、数值与哈希保持原样。
