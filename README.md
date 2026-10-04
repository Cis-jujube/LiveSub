<p align="center">
  <img src="assets/app-icon/LiveSubIcon.png" width="144" alt="LiveSub">
</p>

<h1 align="center">LiveSub</h1>

<p align="center">
  <b>为 Mac 上听到的任何声音，配上实时双语字幕。</b><br>
  中英互译 · 悬浮字幕 · 完全本地运行，音频不离开你的电脑
</p>

<p align="center">
  macOS 15+ · Apple Silicon · <a href="#english">English</a>
</p>

<br>

![LiveSub 主窗口：左侧原文、右侧译文，按段落对齐](design/previews/bilingual-1080.png)

LiveSub 听取麦克风或系统音频——网课、会议、视频、播客——用本地语音识别模型转写，再即时翻译成另一种语言。原文与译文按段落并排呈现，也可以变成一行透明的悬浮字幕，叠在你正在看的任何窗口上。识别和翻译都在这台 Mac 上完成。

## 亮点

- **实时双语**　English → 简体中文、中文 → English。原文与译文按段落对齐，栏头的 ⇄ 一键切换方向；也可以只看译文。
- **悬浮字幕**　透明、不抢焦点、鼠标可穿透，叠在视频或会议上方。字号、位置和宽度可调；画面太亮时打开「字幕底板」。
- **完全本地**　Qwen3-ASR-1.7B 本地识别，Qwen3-4B-Instruct（MLX）本地翻译；macOS 26.4+ 装有系统翻译语言包时，英译中优先使用 Apple 离线翻译。
- **专业术语**　AI、软件科技、数据统计、金融、量化金融、区块链词库自由组合，另可添加 100 条自定义固定译法。
- **说话人**　可选检测最多 5 位说话人，只翻译你关心的那几位。
- **保存与导出**　一键复制，或导出 TXT / Markdown，始终保留双语。
- **原生体验**　SwiftUI 构建，适配浅色 / 深色模式、辅助功能与菜单栏控制。

| 首次打开 | 深色模式 |
|---|---|
| ![空白状态](design/previews/empty-1080.png) | ![深色模式](design/previews/bilingual-dark.png) |
| **悬浮字幕（打开字幕底板）** | **翻译与术语设置** |
| ![悬浮字幕](design/previews/overlay-backdrop.png) | ![设置](design/previews/settings-rows.png) |

<sub>截图由真实界面渲染，字幕内容为示例文本。</sub>

## 系统要求

- Apple Silicon（M 系列）Mac，macOS 15 或更新。开发与测试在 macOS 27 上进行，更早的版本尚未实测。
- Xcode Command Line Tools（含 Swift）与 [uv](https://docs.astral.sh/uv/)。
- 约 12 GB 可用空间。识别模型约 4.7 GB、翻译模型约 2.3 GB，存放在 `~/Library/Application Support/LiveSub/models/`，不会进入仓库或 App。
- 首次下载模型需要联网，之后识别与翻译都在本地进行。

## 安装

目前还没有预编译的下载包，需要从源码构建。主要耗时在下载模型。

**1. 获取源码**

```bash
git clone https://github.com/Cis-jujube/LiveSub.git
cd LiveSub
```

**2. 准备代码签名证书**

macOS 把麦克风、屏幕与系统音频录制权限绑定在 App 的签名上，所以 LiveSub 需要一个固定的签名身份。没有开发者证书时，可以在「钥匙串访问 → 证书助理 → 创建证书」里新建一个自签名的「代码签名」证书，再查看它的 SHA-1：

```bash
security find-identity -v -p codesigning
```

**3. 一次性准备模型与 App**

```bash
export LIVESUB_SIGNING_IDENTITY="你的证书 SHA-1（40 位十六进制）"
./script/setup_models.sh
```

脚本会准备锁定版本的 Python 3.12 环境，下载并校验模型（来源、版本与哈希见[模型清单](docs/model-manifest.md)），构建并签名 `dist/LiveSub.app`。下载中断时重新运行即可。

**4. 打开**

```bash
./script/build_and_run.sh --run
```

App 会自己启动并管理一个只监听 `127.0.0.1` 的本地后端，不需要另开终端；退出 App 时后端一并结束。

## 使用

1. 在工具栏选择音源：**麦克风** 或 **系统音频**；在栏头用 ⇄ 选择翻译方向。
2. 点 **开始**（⌘R）。第一次使用时，macOS 会请求麦克风或「屏幕与系统音频录制」权限。
3. 字幕按段落出现在主窗口。手动往回翻时自动跟随会暂停，点 **回到实时** 继续。
4. 点 **悬浮字幕** 把字幕叠到其他窗口上；在 **字幕外观** 里调整字号、位置、宽度和底板，调整完在字幕上点 **完成**。
5. ⌘R 暂停 / 继续，⌘. 停止。**导出** 菜单里可以复制全部或保存为文件。
6. 在 **设置**（⌘,）里组合领域词库、添加自定义术语。保存后从下一句开始生效。

菜单栏图标同样可以开始、暂停、显示悬浮字幕和调整字号。

## 隐私

- 音频采集与模型推理全部在本机进行，后端只绑定 `127.0.0.1`。
- 原始音频不会保存。字幕默认只保存在当前会话的内存里，只有你手动导出时才会写入文件。
- 系统音频通过 ScreenCaptureKit 获取，不录制屏幕画面。
- 术语配置保存在 `~/Library/Application Support/LiveSub/terminology.json`。

## 当前状态

LiveSub 是一个个人项目，处于部分验收阶段：

- App 未经 Apple 公证，需要按上面的步骤自行构建和签名。
- 一般场景的识别准确率、多人对话、长时间运行以及全屏 / 多屏下的悬浮字幕仍在验证中。
- 受系统或媒体版权保护的声音可能无法采集。

测试方法与数据见[已知问题](docs/known-issues.md)、[人工测试矩阵](docs/manual-test-matrix.md)和[开发与验证记录](docs/development-log.md)。

## 开发

```bash
./script/test.sh                     # 后端测试、Swift 检查与调试构建
./script/build_and_run.sh --verify   # 构建并校验 release 版 .app，不打开
./script/render_design.sh            # 用示例文本渲染界面截图到 design/previews/
```

| 目录 | 内容 |
|---|---|
| `app/LiveSub/MainWindow` · `App` | SwiftUI 主窗口、设置、菜单栏与设计规范（`Theme.swift`） |
| `app/LiveSub/Overlay` | 透明、非激活、默认鼠标穿透的悬浮字幕面板 |
| `app/LiveSub/Audio` | 麦克风与 ScreenCaptureKit 采集，转换为 16 kHz 单声道 PCM |
| `app/LiveSub/Subtitles` | 字幕存储、段落对齐、术语配置 |
| `app/LiveSub/Backend` | Python 子进程管理与本机 WebSocket 通信 |
| `backend/livesub` | Qwen3-ASR 识别、翻译调度、会话与字幕版本控制 |
| `shared/protocol.md` | 音频帧、状态与字幕事件协议 |
| `design/` | 设计方向、界面文案、QA 记录与图标方案 |

---

<a id="english"></a>

## English

**LiveSub gives anything you hear on your Mac live bilingual subtitles, entirely on-device.** It listens to the microphone or system audio, transcribes speech with a local Qwen3-ASR model, and translates English ↔ Simplified Chinese with a local Qwen model, or Apple's offline translation on macOS 26.4+ when the language packs are installed. Source and translation sit side by side in paragraphs, or float over any window as transparent, click-through captions. Audio never leaves your computer.

**Highlights:** paragraph-aligned bilingual transcript · translation-only mode · floating captions with adjustable size, position and an optional backdrop · domain glossaries (AI, software, data, finance, quant, blockchain) plus up to 100 custom terms · optional speaker detection · copy or export to TXT / Markdown · native SwiftUI with light and dark mode. The interface is currently in Chinese.

**Requirements:** an Apple Silicon Mac running macOS 15 or later (developed and tested on macOS 27), Xcode Command Line Tools, [uv](https://docs.astral.sh/uv/), and about 12 GB of free space for models.

**Build from source** (no prebuilt download yet). macOS ties audio permissions to the app's signature, so you need a code-signing certificate; a self-signed one from Keychain Access works.

```bash
git clone https://github.com/Cis-jujube/LiveSub.git && cd LiveSub
security find-identity -v -p codesigning        # find your certificate's SHA-1
export LIVESUB_SIGNING_IDENTITY="<40-hex SHA-1>"
./script/setup_models.sh                        # one-time: Python env, models, signed app
./script/build_and_run.sh --run                 # build and open dist/LiveSub.app
```

**Status:** a personal project that is partially validated. The app is not notarized. General accuracy, multi-speaker use, long sessions and multi-display overlays are still being tested. See [known issues](docs/known-issues.md) and the [development log](docs/development-log.md).
