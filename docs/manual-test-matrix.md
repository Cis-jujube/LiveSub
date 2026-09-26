# LiveSub macOS 实机测试记录

环境：2026-09-26，Apple Silicon，macOS 27.0，`dist/LiveSub.app`（`local.jujube.livesub`）。本表把实际 GUI 操作、命令检查和未验证项目分开记录；空字幕不是识别成功的证据。测试中的系统权限决定由用户本人完成。

| 项目 | 实际操作与观察 | 结果 |
| --- | --- | --- |
| `.app` 构建与签名 | `./script/build_and_run.sh --verify` 返回 0；release build、Info.plist lint、打包后端文件检查、ad hoc codesign verify 均通过；输出明确写明未启动。随后手动 `open dist/LiveSub.app`。 | 通过（构建检查） |
| 主窗口 | CUA 观察到 LiveSub 主窗口、麦克风/系统音频选择器、中英方向选择器、开始/停止按钮、左侧“原文 English”与右侧“译文 简体中文”栏及空态。默认麦克风、英译中。 | 通过（空态与布局） |
| 后端自动启动 | 在 App 中按“开始”后，主窗口显示“正在加载本地模型…”，进程列表出现打包 App 和 `~/Library/Application Support/LiveSub/backend/.venv/bin/python3 -m livesub.server`。没有手动开启后端终端。 | 通过（进程启动）；识别结果另列 |
| 第一次麦克风启动 | 首次模型加载约 50 秒后进入采集，随后报 `The audio device format changed during capture`；已修正相同格式通知的误报。下一次发现 CoreAudio 回调的 Swift actor isolation trap，已修复回调隔离。后续实际字幕结果见下一行。 | 两项运行故障已修复并复测 |
| 麦克风真实识别与翻译 | 修复后的 `.app` 实际进入 English→简体中文麦克风采集，主窗口累积 20 个真实配对片段；停止后历史仍保留。测试为现场声音，未保存私人字幕内容，未做校准延迟测量。 | 英译中配对输出通过；最终包中译英环境音输出另见下文，准确率及可见延迟未验证 |
| 系统音频 | 实际启动在发现显示器阶段返回 ScreenCaptureKit `-3801`；虽然系统设置的 LiveSub 开关显示 on，尚未取得有效采集和真实系统音频字幕。 | 权限故障；真实识别未通过 |
| 悬浮显示开关 | 主窗口开关按钮正确切换，焦点留在主窗口。在有真实麦克风输入时切换，App/后端 PID 均未改变，片段计数继续从 13 增加到 19。未以截图确认实际文字呈现。 | 开关和采集连续性通过；呈现未验证 |
| 菜单栏额外状态项 | 标准 LiveSub 应用菜单与 View 菜单可用；SwiftUI `MenuBarExtra` 已在源码中定义，但当前 CUA 未成功访问额外状态项，未实际点击其控制项。 | 未验证 |
| 悬浮透明背景、上下文字、两行限制、6 秒淡出 | 需要真实字幕出现后观察悬浮层。 | 未验证 |
| 默认鼠标穿透、不抢焦点 | 显示悬浮层时主窗口焦点未丢失；尚未在覆盖其他 App 的实际文字区域点击/输入验证穿透。 | 焦点初步通过；穿透未验证 |
| 调整位置、锁定、重置 | 需要从菜单栏控制进入调整并实际拖动，当前未完成。 | 未验证 |
| Space、普通应用之上、全屏与多显示器 | 当前只观察了 LiveSub 主窗口，没有跨 Space、全屏应用或第二显示器的实机检查。 | 未验证 |

## 非 GUI 检查

- `swift run AudioPipelineChecks`：5 项通过，包含 48 kHz 立体声到 16 kHz 单声道 PCM16、2560 样本分帧、尾帧、重置、长流时间轴和缓冲上限。
- `swift run OverlayPlacementChecks`：4 项几何检查及悬浮字幕会话清空检查通过，包含默认位置、显示器移除回退、非法存储位置、调整后限界；额外断言同会话隐藏保留字幕，新会话显式清空后不再持有旧字幕，且不打开或解锁面板。此检查不代替实际显示/点击穿透验证。
- `swift run SubtitleStoreChecks`：输出 16 条断言及 1800 对长会话记录检查通过，包含同片段修订、过期译文拒绝、跨 generation 历史保留，以及 1802 条总记录和首尾导出完整性。这是数据层容量检查，不是 30 分钟真实采集稳定性测试。
- `swift run BackendProtocolChecks --transport`：15 条协议断言和真实本地 Python 后端握手通过；无 token WebSocket 被拒绝；测试后子进程退出。
- `swift run BackendProtocolChecks` 新增进程生命周期回归检查通过：用不加载模型的两个真实本地子进程，第二次启动等待 ready 时手动递送旧启动的 stdout、termination 回调和旧失败所属启动 ID 的清理，确认新进程引用仍有效、无错误退出通知，且 ready 端口和 token 属于新启动；当前启动 ID 的清理可正常关闭对应进程。
- `swift build --product LiveSub`：通过。CLT 链接器给出缺少可选 Developer/Library 搜索路径的警告，未阻断产物。
- 当前机器只有 Xcode Command Line Tools，`swift test` 因缺少 XCTest/Swift Testing macros 无法运行；上述检查为可执行程序，不声称 XCTest 已通过。

## 最终打包前诊断与复测（2026-09-26）

- 系统音频实际启动失败，主窗口显示 `discover displays: com.apple.ScreenCaptureKit.SCStreamErrorDomain -3801`；系统设置的 LiveSub “Screen & System Audio Recording”开关虽然为 on，不能据此认定当前签名 App 已获得有效授权。尚未观察到系统音频字幕。
- 检查并修复错误重试：开始新会话前，在错误状态下先停止采集并关闭旧后端，避免旧连接仍暂停/监听而以 `sessionMismatch` 拒绝新会话。修复调整字幕位置结束后主界面可见状态与实际面板隐藏状态不同步。
- 对旧运行实例执行 Cmd+Q 后，进程检查未发现 LiveSub 或 `livesub.server` 残留，退出清理通过。
- 上述两处修改后执行 `swift build --product LiveSub`、`./script/build_and_run.sh --verify`、`codesign --verify --deep --strict --verbose=2 dist/LiveSub.app` 和 `git diff --check`，全部成功。最终包已重签；需要针对这份包重新完成权限与运行检查。编译/签名成功不代表系统音频验证成功。

## 独立审查后的原生修复

- 后端每次启动分配 UUID；stdout、退出、ready 超时和清理在写入共享状态前校验所属启动，防止旧启动的异步通知清除新进程。上述真实子进程回归检查覆盖了旧 stdout/退出通知。
- 后端客户端的失败清理任务也捕获对应启动 UUID，禁止迟到清理关闭重试后的新进程；此路径的底层清理行为已加入上述双子进程检查。旧 socket 的收发回调及队列计数收尾仅作用于当前连接；连接建立使用 epoch，防止关闭后迟到的 launch/ping 完成恢复连接。后两项完成源码审查与编译，未对全部网络交错进行运行时故障注入。
- 开始新会话时同时清空 Store 和悬浮 caption，取消旧字幕淡出任务，保留位置和可见性设置。数据状态断言通过；新会话实际显示是否无旧字幕闪现仍待 GUI 复测。
- 错误状态下按“停止”改为停止采集并关闭后端后回到 idle，保留 Store 历史，避免断连后仍等待后端 stop 确认。已编译并审查控制流；当前没有对这一 AppController 路径执行运行时故障注入或 GUI 复测，不将它标记为实机通过。
- 本节修复后重新运行 `swift run BackendProtocolChecks`、`swift run OverlayPlacementChecks`、`swift build --product LiveSub`、`./script/build_and_run.sh --verify` 和单独的 `codesign --verify --deep --strict --verbose=2 dist/LiveSub.app`，均通过。未启动 App 或模型；待授权的产物是本节修复后重签的最终包。

## 最终签名包实机复测（21:13 后）

- 实测二进制 SHA-256 为 `6da96497ccecb8a6fd96c8ede7460b055acac5cb6cbb22dc66dbb1746bdb6ebf`，启动前 strict 签名验证通过；后续未重签。
- 系统音频在实际启动后仍返回 `discover displays: com.apple.ScreenCaptureKit.SCStreamErrorDomain -3801`，自动转为暂停，0 个片段。因此当前系统音频验收未通过。
- 同一 App/后端进程切换为麦克风后可继续产生字幕；英文→中文和中文→英文方向均观察到配对片段。公开英文 WAV 以 `afplay` 增益 0.1、0.4、1 短播，中文 WAV 以增益 1 短播，但识别内容未能与已知公开样本对应，不能把这些声学回录视为准确率通过。只读确认内置扬声器为默认输出、未静音、系统输出约 19%；未修改系统音量或路由。中文方向短测暂停后为 16 个片段；未导出或保存其环境音字幕／截图。
- 关闭主窗口后 App/后端仍存在；通过原生 File → New LiveSub Window 恢复，16 个片段历史仍保留。此操作验证的是原生 File 菜单，未验证 MenuBarExtra 状态栏入口。
- 主窗口隐藏／显示悬浮开关可用，焦点仍是主窗口。关闭主窗口时悬浮面板 AX 可观察到 Original subtitle 与 Translated subtitle 两个标签，之后无新字幕时标签消失。没有对私人字幕留图，因此像素级透明背景、准确淡出时长和行数裁剪仍未验证。
- 在悬浮开关保持启用时，独立公开 HTML 的输入框成功键入测试文本、按钮计数从 0 变为 1；TextEdit 新公开测试文档成功键入，滚动值从约 0.998 变为 0.427，焦点仍在文本区。公开编辑器测试文档保存至 `/tmp/LiveSub-public-editor-QA.rtf`，未修改用户已有文档。这证明基础跨 App 交互可继续，不证明操作点确实处于悬浮面板覆盖区域。
- 只读窗口元数据曾确认悬浮面板为 layer 3、alpha 1、frame `(226,660,1060,164)`；同一时刻主窗口处于 Stage Manager 缩略图，浏览器没有 on-screen 窗口。由于未能可靠确认同帧覆盖位置，实际覆盖区点击穿透仍保持未验证。
- CUA 浏览器控制器两次超时并重置会话，LiveSub 安全过滤绑定丢失。重新绑定会自动输出整段字幕 AX，故不再读取环境音文本。MenuBarExtra、位置调整和重置仍未完成实机验证。

### 原生麦克风环境音长测实际结果（2026-09-26）

本次执行的是**原生麦克风环境音会话的进程／资源观察**，中文→英文，未循环播放公开 WAV。短测已观察到环境音配对字幕；长测期间为避免输出私人字幕，没有逐点读取字幕计数或保存字幕、录音、截图，因此不能证明全程采集／字幕持续更新、准确率、UI 可见延迟或停止尾句。

- 监测开始：21:21:51.197 +08:00；结束：21:54:24.481 +08:00，总计 **1953.28 秒（32 分 33.28 秒）**。
- 共 **196 个样本**，其中 195 个样本中原始 App PID **26319** 和直属后端 PID **26346** 均存活；最后共同存活样本为 1943.23 秒。未观察到 PID 替换或重用。
- 用户报告已手动 **Cmd+Q** 退出；21:54:24.453 监测捕获两个原始进程均退出，正常结束而非中断。随后独立 `ps` 复核原 PID 不存在，过滤检查未发现 LiveSub App 或 `livesub.server` 残留。代理的 Dock UI 访问超时，退出动作由用户完成；没有 AppleScript 或强制终止。
- 首尾签名验证通过，主二进制哈希未变；结束后再次执行 `codesign --verify --deep --strict --verbose=2 dist/LiveSub.app` 通过。测试期间未重包、重签或改变权限。

| 指标 | App | 后端 |
| --- | ---: | ---: |
| RSS 首个→最后存活样本（MiB） | 148.42 → 175.52 | 4973.81 → 4980.05 |
| RSS 最小／最大（MiB） | 148.19 / 175.66 | 4973.81 / 4980.17 |
| RSS 首尾变化（MiB） | +27.10 | +6.24 |
| `ps %CPU` 最小／样本均值／最大 | 0.2 / 2.69 / 9.8 | 7.3 / 19.84 / 56.4 |

`ps %CPU` 是系统进程指标，不是 GPU 使用率或精确 10 秒区间 CPU 利用率。单次 RSS 曲线不能证明不存在泄漏。资源结果表明两个原始进程持续存在超过 30 分钟并在用户退出后清理；不将此结果标为完整字幕全链路验收通过。

原始证据：[native-soak-metrics.jsonl](native-soak-metrics.jsonl)；脚本汇总：[native-soak-summary.json](native-soak-summary.json)。记录只含时间、PID、资源、签名／哈希和验证边界，不含字幕文本。系统音频仍在 `discover displays` 返回 `SCStreamErrorDomain -3801`；公开样本声学回录准确率、实际覆盖区穿透、MenuBarExtra、位置调整／重置、跨 Space／全屏／多屏仍未验证。
