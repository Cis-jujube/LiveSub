# LiveSub macOS 实机测试记录

环境：2026-09-26，Apple Silicon，macOS 27.0，`dist/LiveSub.app`（`local.jujube.livesub`）。本表把实际 GUI 操作、命令检查和未验证项目分开记录；空字幕不是识别成功的证据。测试中的系统权限决定由用户本人完成。

| 项目 | 实际操作与观察 | 结果 |
| --- | --- | --- |
| `.app` 构建与签名 | `./script/build_and_run.sh --verify` 返回 0；release build、Info.plist lint、打包后端文件检查、ad hoc codesign verify 均通过；输出明确写明未启动。随后手动 `open dist/LiveSub.app`。 | 通过（构建检查） |
| 主窗口 | CUA 观察到 LiveSub 主窗口、麦克风/系统音频选择器、中英方向选择器、开始/停止按钮、左侧“原文 English”与右侧“译文 简体中文”栏及空态。默认麦克风、英译中。 | 通过（空态与布局） |
| 后端自动启动 | 在 App 中按“开始”后，主窗口显示“正在加载本地模型…”，进程列表出现打包 App 和 `~/Library/Application Support/LiveSub/backend/.venv/bin/python3 -m livesub.server`。没有手动开启后端终端。 | 通过（进程启动）；识别结果另列 |
| 第一次麦克风启动 | 首次模型加载约 50 秒后进入采集，随后报 `The audio device format changed during capture`；已修正相同格式通知的误报。下一次发现 CoreAudio 回调的 Swift actor isolation trap，已修复回调隔离。后续实际字幕结果见下一行。 | 两项运行故障已修复并复测 |
| 麦克风真实识别与翻译 | 修复后的 `.app` 实际进入 English→简体中文麦克风采集，主窗口累积 20 个真实配对片段；停止后历史仍保留。测试为现场声音，未保存私人字幕内容，未做校准延迟测量。 | 英译中通过；原生中译英及可见延迟未验证 |
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
