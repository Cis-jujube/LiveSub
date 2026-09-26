# LiveSub

LiveSub 是个人本机使用的 macOS 实时双语字幕 App。它使用原生 macOS 音频采集、R2T2 本地语音识别和 Qwen MLX 本地翻译。主窗口按片段左右对照；透明悬浮层显示同一片段的上下双语文字。两种显示方式读取同一个字幕 Store，不会另外启动识别。

**当前是部分验收完成的个人本地版本。** 本机已观察到麦克风英译中真实双语字幕；中英两种方向的本地模型和 WebSocket 已通过真实录音测试。系统音频目前遇到 ScreenCaptureKit `-3801`，尚未取得真实系统音频字幕。悬浮层跨应用点击穿透、全屏/多屏兼容、断网实测和完整 App 的 30 分钟稳定性仍待验证，详见 [人工测试矩阵](docs/manual-test-matrix.md)。

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

原生提交 `c0de296` 的最终检查已通过：44 项 Python 测试；Audio 5 项；Store 16 条断言加 1,800 对合成记录；Overlay 4 项位置检查和会话字幕清空；Backend 15 条协议断言、旧启动回调/失败清理隔离及真实认证握手。最终 release `.app` 已重新打包并通过 `codesign --verify --deep --strict`。最终包尚未完成权限和运行交互复测，以上结果不包含系统音频成功或完整实机验收。

构建产物是 [LiveSub.app](dist/LiveSub.app)，本机曾通过 `open dist/LiveSub.app` 成功启动。当前个人 ad hoc 包未公证：虽然严格签名校验通过，`spctl -a -vv dist/LiveSub.app` 实测仍返回退出码 3 和 `rejected`。因此这里不保证分发后的包可直接双击打开，也不宣称 Gatekeeper 已接纳它。

App 成功打开后会自行启动和管理一个只绑定 `127.0.0.1` 的本地后端；无需手动打开后端终端。退出会停止采集并终止 App 启动的子进程。同一 Mac 上移动 `.app` 后可复用已准备的 App Support 环境，但移动后的启动行为未单独验证；若更改源码，重新构建 `.app`。

## 使用

1. 打开主窗口，选择“麦克风”或“系统音频”，以及 `English → 简体中文` 或 `中文 → English`。首次打开不会自动录音。
2. 点击“开始”。macOS 首次可能请求麦克风或屏幕与系统音频录制权限；必须在系统提示中由你授权，拒绝后可在系统设置中调整并重新打开 App。
3. 主窗口左列是原文，右列是对应译文；原文先到时右列显示“翻译中”。拖动列标题之间的分隔线调整宽度。向上滚动暂停自动跟随，点“回到实时”恢复。
4. 点击“显示悬浮字幕”后，双语文字显示在普通应用之上。默认背景透明、鼠标穿透，原文在上、译文在下。关闭悬浮层不会停止识别或删除主窗口记录。
5. 菜单栏 LiveSub 图标可暂停/继续、停止、隐藏/显示悬浮层、调整或重置字幕位置、恢复主窗口。调整结束后选择“完成调整并锁定”，恢复鼠标穿透。
6. “复制全部”复制当前会话；“导出”可手动保存 UTF-8 TXT 或 Markdown。字幕默认仅在内存中，开始新会话会清除上一会话的窗口记录。

切换音源或翻译方向会结束当前片段并开始新的会话代次，旧字幕保持原方向。系统音频使用 ScreenCaptureKit，不保存屏幕视频。受系统或媒体保护限制的声音可能无法获取。

## 开发结构

- `app/LiveSub/Audio`：麦克风与 ScreenCaptureKit 采集，转换为 16 kHz 单声道 PCM16。
- `app/LiveSub/Backend`：独立 Python 子进程、本机 Bearer WebSocket、单连接和有界发送。
- `backend/livesub`：R2T2、翻译调度、会话和字幕版本控制。
- `app/LiveSub/Subtitles`：主窗口与悬浮层共享的字幕 Store。
- `app/LiveSub/Overlay`：非激活、透明、默认鼠标穿透的 AppKit 面板。
- `shared/protocol.md`：音频帧、状态和字幕事件契约。

详细真实测试数据与未验证项见 [交付报告](docs/delivery-report.md)、[人工测试矩阵](docs/manual-test-matrix.md) 和 [已知问题](docs/known-issues.md)。
