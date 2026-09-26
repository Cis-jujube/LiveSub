# LiveSub：macOS 本地实时双语字幕 App — Codex 执行计划

> 交付对象：在用户 Mac 项目目录中工作的 Codex。
> 本文件是一份需求与实施计划，不是已完成的程序，也不代表已经在用户设备上通过性能测试。
> 按任务顺序实现、测试并记录结果。普通技术选择按本文默认方案执行；涉及系统授权、付费、公开发布或破坏性操作时，由用户确认。

**Goal：** 制作一个个人使用的 macOS App，将麦克风或电脑播放的声音实时转成原文和译文，支持应用内左右对照与跨应用透明悬浮字幕。

**Architecture：** SwiftUI 管理应用界面与会话状态；AppKit 仅负责特殊悬浮窗口；原生音频采集通过本机 IPC 交给独立的本地模型后端。语音识别和翻译引擎可替换，但不设计插件市场或复杂调度平台。

**Tech Stack：** SwiftUI、AppKit、AVFoundation、ScreenCaptureKit；Python 3.12 独立环境；R2T2 / llama.cpp 作为优先 ASR 路线；MLX-LM 小模型翻译；本机 WebSocket。

**Spec：** 本文件第 1–8 节是产品和技术规格，第 9–11 节是实施任务与验收要求。上游证据见第 12 节。

## 全局约束

- 面向 Apple Silicon Mac。按此前讨论的 M5 Pro、48GB 配置规划，但必须实际读取硬件和系统信息，不能据此声称性能已验证。
- 初始部署目标设为 macOS 15+，这是项目选择，不是断言所有 API 都从该版本才可用。先核实用户系统与已安装 SDK；不擅自升级系统或 Xcode。
- 个人本地版优先。首次安装可下载依赖和模型；模型就绪后，音频、识别和翻译默认全部离线处理。
- 第一版不做 iPhone、Android、Web 产品、账号登录、云同步、语音播报、说话人分离、会议总结或模型训练。
- “不显示字幕”仅表示关闭桌面悬浮层，不表示停止识别，也不表示应用内不显示译文。
- 应用内模式和悬浮模式必须共用同一条采集/识别流水线与同一份字幕数据。
- 不修改无关项目，不覆盖用户已有模型，不全局安装 Python 依赖，不关闭系统安全机制。
- 只能将真实完成的功能标为完成；模拟文本、离线 WAV 测试与实时麦克风测试必须区分。

## 重点审查的五类故障

1. 字幕抢走其他应用键盘焦点，或挡住鼠标点击：任务 6 验证。
2. 翻译乱序，把前一句译文配到后一句原文：任务 3 和任务 5 验证。
3. 暂停、恢复或切换音源后，旧音频和旧翻译回流：任务 3 和任务 4 验证。
4. 拔掉外接屏、切换 Space 或全屏后，字幕消失且无法找回：任务 6 验证。
5. 长时间运行后推理排队、内存增长或后端孤儿进程：任务 2、任务 3、任务 7 验证。

---

## 1. 产品范围与默认决策

工作名使用 **LiveSub**，不要把命名和 Logo 设计变成前置工作。

核心使用场景：用户听课、开会或看视频时，继续操作浏览器、编辑器、PDF 阅读器等软件；双语字幕在屏幕上持续显示，不需要切回翻译 App。

第一版必须完成：

- 英文 → 简体中文、中文 → 英文，提供明确的手动方向选择。
- 麦克风输入和系统音频输入，单次会话只使用一种，不默认混音。
- 应用内左右对照、透明双语悬浮字幕、菜单栏控制。
- 开始、暂停、继续、停止、复制、手动导出当前会话。
- 本地模型初始化、状态提示、错误提示与一键启动开发入口。

自动判断中英、指定单一应用音频、快捷键自定义、跨会话历史和 SRT 导出列为增强项，不得阻塞上述功能。不是第一版需要同时做好“所有场景”。

## 2. 两种显示模式

### 2.1 模式 A：应用内对照，不显示桌面悬浮层

主窗口左侧是原文，右侧是译文，语言跟随当前翻译方向。

```text
LiveSub                         音源：系统音频    英文 → 中文
开始 / 暂停 / 停止               显示悬浮字幕    设置

原文 · English                  译文 · 简体中文
We should review the data.      我们应该重新检查这些数据。
The sample size is small.       样本量比较小。

状态：正在识别                  翻译状态：正常
```

实现要求：

- 按“同一个字幕片段的一对原文和译文”组织行，使用统一的纵向滚动容器；不要用两个互不关联的列表拼成双栏。
- 允许调节左右宽度；每一行高度以两侧较高内容为准，避免逐渐错位。
- 新结果默认自动滚动到末尾；用户主动向上查看时暂停自动滚动，提供“回到实时”。
- 原文先到时立即显示，译文位置显示“翻译中”，不能放上一句的译文顶替。
- 支持选中、复制原文/译文，导出当前会话为 UTF-8 TXT 或 Markdown。
- 首次打开先显示主窗口，不自动录音；仅在用户点击开始后请求所需权限并采集。

### 2.2 模式 B：透明、跨应用的双语悬浮字幕

默认只显示文字，不显示普通窗口边框、标题栏、工具栏或底色。

```text
           We should review the data before drawing conclusions.
                    在得出结论之前，我们应该重新检查数据。
```

第一行区域始终为原文，第二行区域始终为目标译文；中文 → 英文时下面就是英文，不要把目标语言写死成中文。

默认样式（可调整的产品初始值，不是系统 API 限制）：

- 放在所选显示器底部居中，距离可用区域底边约 72 pt。
- 宽度约为显示器可用宽度的 70%，上限 1200 pt，并始终限制在可用区域内。
- 原文 24 pt，译文 28 pt，译文稍突出；采用系统字体。
- 白色文字配暗色描边或阴影，在浅色/深色背景上均需测试。
- 默认背景完全透明。设置中可选择低透明度底板，但不能默认做成一块深色悬浮卡片。
- 每种语言最多显示两行，总计通常不超过四行。长句拆成字幕片段；不能靠无限缩小字号塞入。
- 悬浮层只保留当前片段；完整内容进入主窗口。最后一对字幕在无新内容后保留约 6 秒再淡出；主窗口记录不删除。

#### 锁定显示与位置调整

**锁定显示是默认状态：**

- 鼠标点击、拖拽、滚动穿透到下面的软件。
- 字幕更新不激活 App、不抢键盘焦点。
- 没有可误触的隐藏按钮，不依赖鼠标悬停解锁。

**位置调整状态：**

- 用户从菜单栏进入“调整字幕位置”。
- 临时显示边界和拖动/缩放控件，允许移动与调整宽度。
- “完成调整”后重新恢复鼠标穿透；字号、颜色等更复杂的输入放在设置窗口。
- 菜单栏始终提供“重置字幕位置”，避免字幕被移出屏幕后找不回来。

#### 主窗口、模式与采集的关系

- 开启悬浮字幕不创建第二条识别任务；关掉悬浮字幕也不停止当前会话。
- 主窗口可以与悬浮层同时打开。
- 关闭主窗口后，如当前正在采集，App 继续在菜单栏运行并明确显示状态；不能悄悄让用户以为已经停止。
- 菜单栏提供：显示主窗口、暂停/继续、停止、显示/隐藏字幕、调整/锁定位置、设置、退出。
- 退出 App 必须停止采集、关闭连接并终止本 App 启动的子进程。

## 3. 音源、权限与语言

### 3.1 音源

**麦克风：** 使用 AVFoundation / AVAudioEngine 采集系统默认输入设备。第一版不必自建复杂的硬件路由设置。

**系统音频：** 使用 ScreenCaptureKit 捕获电脑播放的声音；该框架具有音频采集配置接口 [S4]。用于浏览器视频、线上课程等；不能用“把扬声器声音再录进麦克风”冒充系统音频。

- 首次默认选择麦克风；后续记住上次选择。
- 系统音频采集不需要保存视频，也不运行 OCR 或分析屏幕画面。
- 依据当前 SDK 配置音频采集及排除自身进程音频；转换格式时读取实际 sample buffer 格式，不能假设总是 16kHz [S4]。
- 第一版两种音源二选一；切换时结束旧音源片段、增加会话代次并清除旧的待处理数据。
- 不承诺支持被系统或内容保护机制限制的媒体；无法获取时给出清楚提示，不尝试绕过保护。

### 3.2 权限

- 根据所选音源请求麦克风或系统录制相关权限；具体名称以用户 macOS 实际提示为准。
- `.app` 必须具有稳定的 bundle identifier 和相应的用途说明，优先让 App 而不是临时终端进程发起采集。
- 拒绝授权后不循环弹窗、不崩溃；说明受限功能，并提供打开相关系统设置的入口。
- 仅为显示浮动文字，不应默认要求全局键盘监听或辅助功能权限。
- 不自动绕过权限、不重置用户 TCC 数据、不关闭 Gatekeeper。

### 3.3 翻译方向

第一版提供固定的 `EN → ZH` 与 `ZH → EN`，默认 `EN → ZH`。自动模式后续增加时必须保留手动覆盖；英文术语夹在中文里不能导致方向来回切换。

切换方向结束当前片段，从新片段生效；历史字幕保留原本的源/目标语言，不回头重新解释旧记录。

## 4. 技术结构

```text
麦克风 / 系统音频（Swift 原生采集）
                ↓
格式转换、带时间信息的音频帧、有限缓冲
                ↓
本机模型后端
  ASR → 稳定文本与分段 → 翻译调度 → 本地翻译模型
                ↓
带 session / segment / revision 的字幕事件
                ↓
共享 SubtitleStore（Swift）
          ↙                    ↘
应用内左右对照             透明悬浮双语字幕
```

### 4.1 原生前端

SwiftUI 管理主窗口、设置和菜单栏。用一个窄的 `OverlayWindowController` 管理 AppKit `NSPanel`，不要把窗口操作散布到所有 View 中。

悬浮层候选配置包括：无边框、非激活面板、透明背景、普通浮动层级、`hidesOnDeactivate = false`、锁定时 `ignoresMouseEvents = true`。AppKit 提供窗口级鼠标穿透属性 [S3]。实际样式掩码和可用性由 Codex 对照当前 SDK 检查。

- 显示字幕时不要调用 `makeKeyAndOrderFront` 来抢焦点。
- 验证 `canBecomeKey` / `canBecomeMain` 与非激活面板行为。
- Space / 全屏可评估 `canJoinAllSpaces` 和 `fullScreenAuxiliary`，但必须测试实际组合；这些设置不是“保证覆盖所有应用”的承诺。
- 不使用屏保级窗口层级，不覆盖系统密码框、锁屏或安全提示。
- 普通桌面应用是必须通过的场景；原生全屏、多个 Space、多个显示器单列测试结果与限制。

### 4.2 本机后端与进程管理

使用 App 管理的独立 Python 进程，优先用本地 FastAPI / WebSocket 服务隔离模型依赖。版本在验证后锁定，不盲目跟随最新版本。

- 只绑定 `127.0.0.1` 的临时空闲端口；每次启动生成临时认证 token。拒绝未经授权的连接。
- App 使用 `Process` 的 executable / arguments 启动后端，不拼接未经处理的 shell 字符串。
- 后端启动后通过受控 stdout 输出 ready 消息（端口、协议版本、状态）；日志走 stderr，不混入协议数据，不打印 token。
- Swift 音频回调不能同步等待网络、ASR 或翻译；使用有界队列和独立消费者。
- 同一会话只允许一条有效音频流，翻译不能阻塞 ASR 的输入处理。
- 模型按需加载并复用，禁止每个音频片段或每句译文都重新加载模型。
- 不使用 `pkill python` 等广泛终止命令，只管理本 App 创建的进程。

## 5. 模型选择与先行验证

### 5.1 优先 ASR：Confucius4-R2T2

R2T2 是流式语音识别模型，不是翻译模型；它提供稳定提交的识别文本，并针对中英文优化 [S1]。

必须首先验证 Mac 路线，而不是假设能直接运行。当前 `r2t2_llama` 文档描述的预编译文件面向 Linux x86_64、CUDA、CPython 3.12；非 CUDA 平台需要重新构建 [S2]。

执行要求：

1. 获取并记录 R2T2 的确切 commit；读取 `r2t2_llama/README.md`、构建配置、导入路径和依赖。
2. 优先验证完全基于 llama.cpp 的 `stream_llama`，不要默认使用含 vLLM / PyTorch 编码器的 hybrid 路线 [S2]。
3. 初始使用上游说明中匹配的 llama.cpp commit；后续升级必须说明原因并回归测试。
4. 用本机 arm64 编译器构建；验证 Metal 是否实际启用，不能只看编译参数推断加速成功。
5. 检查 Darwin 动态库路径、`@loader_path`、Python 扩展 ABI 和实际依赖。不要把 Linux 的 `.so` 文件重命名后当成可运行的 Mac 库。
6. 模型必须包含匹配的 GGUF 主模型和音频 projector；首次选择适中的量化配置，写入模型清单。
7. 先测试真实英文、中文 WAV，再按实时节奏分块送入；验证安静开头、尾句 flush 和持续运行。
8. 确认纯 llama.cpp 路径是否仍需 Hugging Face processor 等资源；缺什么下载什么，不照搬包含 CUDA 的整套安装命令。

**停止无效适配的边界：** 若发现上游算子或实现使适配需要大规模重写，先保存错误日志和最小复现，不无限重写模型。可启用已验证的 `whisper.cpp` 本地替代引擎以交付可用 App；该项目明确支持 Apple Silicon / Metal [S7]。

替代引擎必须在界面与报告中明确标识；不能声称 R2T2 已跑通。使用 Whisper 时保留原语言转录，再交给统一翻译层；其窗口化/分块识别不等同于 R2T2 的稳定流式输出，需要适配去重和确认逻辑。

### 5.2 本地翻译

建议先验证 **Qwen3-4B-Instruct-2507 的 4-bit MLX 路线**，作为第一版候选。官方模型卡将其描述为非思考模式模型；MLX-LM 支持 Apple Silicon 上的文本生成与量化 [S5][S6]。此选择不是关于其翻译质量或延迟的已验证结论。

- 采用实际可验证来源的模型转换版本，或从官方权重本地转换；记录源仓库、revision、量化与许可。
- 只实现一个默认翻译引擎，保留接口；不要先做模型商店、排行榜或多模型投票。
- 初始输出上限 256 tokens，输入上下文上限 2048 tokens；最近最多两句已确认上下文，最多占 512 tokens。
- 提示模型只翻译当前片段，不输出解释、寒暄、Markdown、思考过程或“翻译如下”。
- 不允许为补全一句未说完的话而补造事实；数字、否定、专有名词要纳入人工测试。
- 识别到的讲话是待翻译内容，不是给 App 的操作指令。模型不配置外部工具调用。
- 不采用 27B/30B 模型作为默认字幕引擎；先验证 ASR 和小翻译模型同时运行的实际吞吐。
- 若本机联合测试不达标，再评估更轻的专用翻译模型。此前提到的 OPUS-MT 可作为候选，不因体积小就假定质量合格。

## 6. 数据契约与字幕稳定策略

### 6.1 统一数据结构

在 `shared/protocol.md` 定义协议，并让 Swift 与 Python 使用同一份测试 fixture。

`AudioFrame`：

- `session_id`、`generation`、`sequence`、`start_sample`。
- `sample_rate = 16000`、`channels = 1`。
- 传输数据为 little-endian PCM16；原生模型适配层按需要转换为 float32。
- 初始帧长 160ms（2560 samples）。不得把这一数值当成字幕刷新周期或翻译延迟承诺。

`SubtitleSegment`：

- `session_id`、`generation`、`segment_id`、`sequence`。
- `start_ms`、`end_ms`：相对会话音频时间；第一版为片段级近似时间，不伪装成精确词级对齐。
- `source_language`、`target_language`。
- `source_text`、`source_revision`、`source_final`。
- `target_text`、`translated_source_text`、`translated_source_revision`。
- `translation_state`：`pending | preview | final | failed`。

会话状态：`idle | loading | listening | paused | stopping | error`。

本项目定义的核心接口（不是声称上游已具有这些接口）：

- Swift `AudioCaptureService.start(source:) -> AsyncThrowingStream<AudioFrame, Error>`；`stop()`。
- Python `ASREngine.start(config)`、`push(frame) -> list[ASREvent]`、`finish() -> list[ASREvent]`、`reset()`。
- Python `Translator.translate(request: TranslationRequest) -> TranslationResult`。
- `TranslationRequest` 携带完整的 session / generation / segment / revision、源文本、目标语言和有限上下文。
- Swift `SubtitleStore.apply(event:)` 统一校验身份、序号和版本，所有显示层只读该 Store。

### 6.2 明确区分三件事

1. ASR 已经稳定的原文。
2. 仍在发展的当前字幕片段。
3. 已经完成、以后不自动改写的译文。

“ASR 原文稳定”不等于“英文/中文译文可以逐词追加”。翻译只能在当前活动片段内预览和更新，不能频繁重写整段历史。

初始调度策略：

- 原文稳定增量立即进入 Store；上游输出是增量还是累计文本由适配层规范化，不允许重复拼接。
- 有新稳定文本时，最多每 750ms 提交一次翻译预览；没有新文本不重复调用。
- 句末标点或语音活动检测到约 500ms 停顿时结束片段并提交最终翻译。
- 连续讲话时，优先在分句边界切段；初始上限为 6 秒，或约 80 个中文字符 / 35 个英文词。达到上限仍需提交部分片段，不能无限等待句号。
- 上述数值是可配置的起始参数，使用真实录音调整，不声称对所有语速最优。
- 不默认实现逐字打字机动画，减少字幕跳动。

### 6.3 配对、过期结果与队列

- 翻译回包必须携带 session、generation、segment 和 source revision；不能把当前全局文本直接覆盖成任意晚到结果。
- 旧会话代次、已被更新结果覆盖的版本，以及已完成片段的过期预览必须丢弃。
- 不要仅因“最新 ASR 文本又增长了”就一律丢弃仍有效的当前片段预览，否则持续讲话时可能永远看不到译文。
- 主窗口可以显示最新原文，并标记译文仍在更新。
- 悬浮层成对显示 `translated_source_text` 与对应译文。新片段尚无译文时，可先显示原文和空的译文区域；不能把上一片段的译文放在新原文下面。
- 每个片段最多保留一个未开始的最新预览任务；优先处理最终翻译，过时预览合并而非无限排队。
- 最终翻译待处理队列上限初设为 32；超过上限自动暂停采集并提示性能不足，保留已经收到的原文，不默默丢掉历史。
- 音频缓冲初始上限 5 秒；溢出时明确报告中断并暂停，不悄悄跳过音频却继续宣称完整转录。

暂停立即停止接收新音频，处理已接收片段；继续时开启新的 generation。停止需要有界等待尾句完成，失败则保留原文和失败状态。所有控制操作可重复调用而不创建重复任务。

## 7. 隐私、模型文件与启动体验

- 原始音频默认不落盘；会话字幕默认只保存在内存，用户主动导出才写入文件。
- 设置可以持久化；日志默认只记录状态、耗时、错误类型，不包含原文、译文或录音。
- 模型、环境和设置放在 App 的 Application Support 目录或用户选择的位置，不写死开发者绝对路径。
- 首次模型准备展示下载大小、来源、进度、失败重试和磁盘不足提示；不能空白等待，也不能后台无限下载。
- 源码许可、模型许可分别记录；不能把 R2T2 代码的 Apache 2.0 当成权重的许可证 [S1]。
- 完成一次环境准备后，日常双击 `.app` 应自动启动本机后端；用户不必分别启动多个终端窗口。
- 第一版允许依赖在该 Mac 上准备好的私有 Python 环境，因此要标明“个人本机版”，不声称已经是可分发、已公证或 App Store 版本。
- 模型缺失、模型加载失败、后端崩溃、权限不足和无输入音频必须有不同状态，不能全部显示为“正在识别”。

## 8. 性能与验证口径

所有数值都是待验证的初始目标，不是已有基准结果。冷启动和模型下载不计入热运行字幕延迟，但必须单独记录。

- ASR 快于输入音频：计算时间 / 音频时长的 RTF < 1；测试计算耗时时不要把人为实时播放等待计入。
- 热运行下，短分句结束到对应译文出现，初始目标为中位数不超过 2 秒、P95 不超过 4 秒。
- 计时起点使用测试音频中该分句最后一个词结束的位置，终点使用对应字幕版本在 UI 可见的时间；不能从翻译 API 发起时才开始计时。
- 同时记录 ASR、等待分段、翻译、IPC 和 UI 延迟，避免只报一个无法解释的数字。
- 连续运行至少 30 分钟，报告音频/翻译队列、内存、CPU/GPU、尾句遗漏、重复字幕和崩溃情况。
- 至少进行一次浏览器/编辑器正常运行时的联合测试，不能只测试单模型独占机器的速度。
- 性能未达目标时如实报告；不以 mock、缓存固定句子或只显示原文冒充合格的实时双语字幕。

---

## 9. 建议项目目录

新项目使用以下结构；已有仓库则顺应既有结构，不为匹配目录而进行无关重构。

```text
LiveSub/
├── PLAN.md                         # 本文件
├── README.md
├── app/
│   ├── LiveSub.xcodeproj/           # 原生 macOS App target
│   ├── LiveSub/
│   │   ├── App/                    # 入口、会话生命周期、菜单栏、设置
│   │   ├── Audio/                  # 麦克风、系统音频、格式转换
│   │   ├── Backend/                # Process 生命周期与 WebSocket
│   │   ├── Subtitles/              # 数据模型、Store、配对规则
│   │   ├── MainWindow/             # 双栏及统一滚动
│   │   └── Overlay/                # NSPanel controller、字幕 View
│   └── LiveSubTests/
├── backend/
│   ├── pyproject.toml
│   ├── uv.lock
│   ├── livesub/
│   │   ├── server.py
│   │   ├── protocol.py
│   │   ├── session.py
│   │   ├── asr/                    # base.py、r2t2.py；必要时 whisper.py
│   │   ├── translation/            # base.py、mlx_engine.py、scheduler.py
│   │   └── subtitles/              # segmenter.py、revision.py
│   └── tests/
├── shared/
│   ├── protocol.md
│   └── fixtures/                   # 协议事件、乱序事件、空音频等
├── script/
│   ├── doctor.sh
│   ├── setup_models.sh
│   ├── build_and_run.sh
│   └── test.sh
├── third_party/                    # 锁定版本的上游源码或补丁
└── docs/
    ├── compatibility.md
    ├── model-manifest.md
    ├── benchmark.md
    ├── manual-test-matrix.md
    ├── known-issues.md
    └── delivery-report.md
```

不提交模型大文件、录音、个人转录、认证 token 或整个虚拟环境到 Git。

## 10. 按顺序执行的任务

### 任务 1：环境检查与 R2T2 兼容性验证

**文件：** `script/doctor.sh`、`backend/livesub/asr/base.py`、`backend/livesub/asr/r2t2.py`、`backend/tests/test_asr_contract.py`、`docs/compatibility.md`。

**产出接口：** 第 6 节的 `ASREngine`；至少一个真实可用 ASR adapter。

- [ ] 检查工作目录、Git 状态、macOS、arm64、内存、Xcode SDK、Python 与磁盘；不覆盖现有更改。
- [ ] 先写 ASR contract 测试：空输入不产生词、finish 发出尾句、reset 后没有旧状态；确认失败。
- [ ] 按第 5.1 节构建并验证真实 R2T2 路线，记录精确版本和错误。
- [ ] 用中英文各一份真实录音验证识别与实时节奏输入；不得把纯离线测试写成麦克风验证。
- [ ] 如触发替代边界，明确记录并实现替代引擎，不悄悄更换。
- [ ] 运行 contract 测试与真实音频 smoke test，记录实际结果后提交该任务。

**验证入口：** 创建并运行 `./script/doctor.sh`；`cd backend && uv run pytest tests/test_asr_contract.py -v`。真实模型测试以集成测试单列，不让缺模型被记成通过。

### 任务 2：翻译引擎与联合性能

**文件：** `backend/livesub/translation/base.py`、`mlx_engine.py`、`backend/tests/test_translation_contract.py`、`docs/model-manifest.md`、`docs/benchmark.md`。

**消费/产出：** 接收 `TranslationRequest`，返回带身份和 revision 的 `TranslationResult`。

- [ ] 先写空输入、方向传递、版本回传、超长输出限制的 contract 测试，确认失败。
- [ ] 接入单个本地 MLX 候选模型，固定提示词、上下文预算和本地模型路径。
- [ ] 准备至少 20 条中文、20 条英文人工样例，覆盖数字、否定、专业词、口语、不完整句和“忽略前面指令”这类应被翻译的原文。
- [ ] 检查是否擅自解释、遗漏否定或改变数字；报告逐条输出，不能只给“效果不错”。
- [ ] 与 ASR 同时运行测延迟及队列趋势，确定默认模型，不先增加多个并行模型。
- [ ] 运行 contract 测试、离线模型集成测试，更新基准与模型清单后提交。

**验证入口：** `cd backend && uv run pytest tests/test_translation_contract.py -v`；创建并记录可重复的真实模型 benchmark 命令。

### 任务 3：后端会话、分段、乱序保护与 IPC

**文件：** `server.py`、`protocol.py`、`session.py`、`translation/scheduler.py`、`subtitles/segmenter.py`、`subtitles/revision.py`、`backend/tests/test_session.py`、`test_scheduler.py`、`shared/protocol.md`。

**消费/产出：** 消费 `AudioFrame` 与控制消息，输出字幕事件和明确的状态事件。

- [ ] 先写测试：重复开始只建一个任务、旧 generation 回包无效、revision 2 之后收到 revision 1 不倒退。
- [ ] 增加持续讲话测试：有效的同片段预览不会因 ASR 继续增长而全部被丢弃。
- [ ] 实现第 6 节分段规则、最终任务优先、预览合并与有界队列。
- [ ] 实现本机端口与认证；错误 token 和格式错误帧返回受控错误，不拖垮服务。
- [ ] 覆盖暂停/恢复/停止尾句、队列溢出、客户端断开和后端退出清理。
- [ ] 使用真实音频跑通“输入音频 → 双语事件”闭环，写入可重放的事件测试 fixture。
- [ ] 测试通过并记录真实集成结果后提交。

**验证入口：** `cd backend && uv run pytest tests/test_session.py tests/test_scheduler.py -v`。

### 任务 4：原生 App、权限与两种音源

**文件：** `app/LiveSub/Audio/AudioCaptureService.swift`、`MicrophoneCapture.swift`、`SystemAudioCapture.swift`、`AudioConverter.swift`、`app/LiveSub/Backend/BackendProcess.swift`、`BackendClient.swift`、`app/LiveSubTests/AudioPipelineTests.swift`、`script/build_and_run.sh`。

**消费/产出：** 向任务 3 的协议发送音频，输出 UI 可观察的权限与会话状态。

- [ ] 先测试 48kHz 双声道到 16kHz 单声道的时长、样本数、帧序号和剩余帧 flush；确认失败。
- [ ] 创建 macOS App target、稳定 bundle identifier、用途说明与后端进程管理。
- [ ] 实现麦克风采集，再接系统音频；当前输入源必须清楚可见。
- [ ] 测试授权、拒绝授权、无音频、设备断开、切换音源、后端崩溃。
- [ ] 确认采集回调不阻塞主线程，旧帧不会进入新 generation。
- [ ] 创建统一 build/run 脚本，启动真正的 `.app`，不是直接运行裸 Swift GUI executable。
- [ ] 在用户 Mac 上通过两种真实音源测试后记录结果并提交。

**验证入口：** `./script/build_and_run.sh --verify`；`xcodebuild -project app/LiveSub.xcodeproj -scheme LiveSub -destination 'platform=macOS' test`。脚本和工程为本任务需要创建的产物，并非预先存在。

### 任务 5：应用内双栏与共享字幕 Store

**文件：** `app/LiveSub/Subtitles/SubtitleStore.swift`、`SubtitleSegment.swift`、`app/LiveSub/MainWindow/TranscriptView.swift`、`app/LiveSubTests/SubtitleStoreTests.swift`。

**消费/产出：** 接收任务 3 的事件；提供按片段排序、配对和版本校验的统一数据源。

- [ ] 先测试句子配对、重复事件去重、旧翻译拒绝、方向切换后历史不被重写，确认失败。
- [ ] 实现同一行内的左右原文/译文、可调宽度与统一滚动。
- [ ] 实现翻译中/失败状态、自动滚动暂停、回到实时、选择复制和主动导出。
- [ ] 测试空会话、长句、连续中英切换、30 分钟记录与大字号。
- [ ] 测试通过并以真实字幕展示，不只放静态样例，提交。

**验证入口：** 运行 `SubtitleStoreTests` 和主窗口 UI 测试；保留对应真实运行截图。

### 任务 6：透明悬浮字幕与菜单栏

**文件：** `app/LiveSub/Overlay/OverlayWindowController.swift`、`OverlayView.swift`、`OverlayPlacement.swift`、`app/LiveSub/App/MenuBarController.swift`、`app/LiveSubTests/OverlayPlacementTests.swift`。

**消费/产出：** 只消费任务 5 的 Store，不重新采集或识别。

- [ ] 先测试位置恢复：外接屏移除后，保存位置被限制回现有显示器可用区域；确认失败。
- [ ] 实现无边框透明 NSPanel、原文在上译文在下、配对快照和长句限行。
- [ ] 实现锁定穿透/调整位置两种状态，以及始终可用的菜单栏重置入口。
- [ ] 在浏览器和编辑器输入文字、点击和滚动，确认悬浮层不抢焦点、不拦截操作。
- [ ] 测试隐藏/显示悬浮层不重启模型，关闭主窗口后可以从菜单栏恢复。
- [ ] 测试普通窗口、Space 切换、实际原生全屏、外接屏拔插与不同缩放；记录不支持的组合，不承诺覆盖所有系统界面。
- [ ] 在明暗背景上检查文字可读性、行数、换行和译文尚未到达的状态。
- [ ] 单元测试和实机 UI 验证完成后提交。

**验证入口：** `OverlayPlacementTests`；`docs/manual-test-matrix.md` 中逐项记录操作、观察、系统版本和截图。不能用单元测试代替点击穿透与全屏实测。

### 任务 7：启动体验、长时间测试与个人版交付

**文件：** `script/setup_models.sh`、`script/test.sh`、设置与状态页、`README.md`、`docs/manual-test-matrix.md`、`known-issues.md`、`delivery-report.md`。

- [ ] 先测试模型目录不存在、磁盘不足、后端退出和重复退出操作的受控状态。
- [ ] 完成一次性本地环境准备与模型准备流程；日常启动不要求用户手动管理后端。
- [ ] 模型就绪后断网验证麦克风与本地媒体文件的实时双语字幕。
- [ ] 连续运行至少 30 分钟，并同时操作浏览器/编辑器；记录真实延迟和资源曲线。
- [ ] 退出后检查采集已停止且没有本 App 的孤儿模型进程。
- [ ] 确认 `.app`、脚本、文档和模型路径一致，模型大文件未进入 Git。
- [ ] 完成真实验收后生成交付报告；不能只报告编译通过。

**验证入口：** `./script/test.sh`、`./script/build_and_run.sh --verify`、实机 30 分钟测试。

可选增强功能只在上述任务完成后推进。已经具备合格核心功能时，不为了自动语言识别等增强项推迟交付。

## 11. 最终验收与执行纪律

最终应交付：

1. 完整源码与锁定依赖/模型来源的清单。
2. 本机可双击启动的 `LiveSub.app`，或明确的构建产物路径；说明一次性环境准备要求。
3. 一条明确的 build/run 命令与测试命令。
4. 使用说明：选择音源、开始/暂停、切换显示模式、移动字幕、关闭悬浮、退出。
5. 真实测试报告：当前 ASR 名称、翻译模型、硬件、版本、延迟、内存、权限与窗口兼容性。
6. 已知问题与未完成事项，不得隐藏 R2T2 适配失败或系统音频限制。

最低验收动作：

- 英文音频得到英文原文与中文译文；中文音频得到中文原文与英文译文。
- 麦克风和系统播放声音均可分别输入。
- 关闭悬浮时，主窗口持续正常记录双语内容。
- 开启悬浮时，上方原文、下方译文，默认只有文字，没有普通窗口外框。
- 在其他软件中点击、滚动和键入不受影响；不发生字幕抢焦点。
- 模式切换不丢记录、不创建第二条识别任务。
- 暂停停止新音频采集，继续不重放积压音频；停止尽可能提交尾句且明确失败状态。
- 断网、权限拒绝、模型缺失和后端故障均不出现假装工作的界面。
- 实机未验证项标为“未验证”，不标为“通过”。

Codex 执行纪律：

- 开始前读取此计划和仓库现有约束；先检查环境，不先堆砌精美 UI。
- 对确定性逻辑采用“先写失败测试 → 最小实现 → 运行测试 → 记录结果”的小步方式。
- 每个任务结束做小范围提交，前提是工作目录允许；不提交用户无关改动。
- 普通技术细节依据本文件默认选择推进，不反复让用户选择框架、目录名或配色。
- 用户必须点击的系统授权、不可自动完成的账户许可及破坏性操作，需要如实说明具体操作。
- 不把 fake engine、mock 字幕或静态界面作为真实模型交付；演示模式必须清楚标注。
- 若当前执行环境不是 Mac，可以完成协议/纯逻辑测试，但不能声称已测试原生权限、Metal、浮动窗口或真实音源。

## 12. 上游参考与证据边界

以下来源用于选型核对；执行时重新读取并锁定实际采用版本。所有本机性能数字仍需实测。

- **[S1] R2T2 项目说明：** `https://github.com/netease-youdao/Confucius4-R2T2`。ASR 定位、稳定输出、中英文优化、代码与权重分开许可。
- **[S2] R2T2 llama.cpp 后端：** `https://github.com/netease-youdao/Confucius4-R2T2/blob/master/r2t2_llama/README.md`。三条推理路线、预编译平台、匹配依赖和重建说明。
- **[S3] AppKit NSWindow：** `https://developer.apple.com/documentation/appkit/nswindow`。包括 `ignoresMouseEvents` 等窗口行为。NSPanel 和 collectionBehavior 的实际 SDK 声明需实施时核对。
- **[S4] ScreenCaptureKit 音频配置：** `https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturesaudio`；`https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/excludescurrentprocessaudio`。
- **[S5] Qwen 官方模型卡：** `https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507`。4B 非思考模式候选，不是本机翻译性能基准。
- **[S6] MLX-LM：** `https://github.com/ml-explore/mlx-lm`。Apple Silicon 推理、量化和文本生成接口。
- **[S7] whisper.cpp：** `https://github.com/ggml-org/whisper.cpp`。必要时使用的 Apple Silicon 本地 ASR 替代路线。

最后再次区分：**本计划已明确需求与实施顺序；R2T2 在用户 Mac 的编译结果、联合推理速度、全屏覆盖范围与成品 `.app` 都需要 Codex 实际验证和交付。**
