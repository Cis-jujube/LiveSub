# 英译中、术语与系统音频延迟：GitHub 调研

核查日期：2026-10-02。范围是 Apple Silicon 上的本地实时字幕。本文件记录第一方仓库、官方文档和实现建议；研究过程没有安装依赖、下载模型、调用云端翻译或测量新的性能数字。实际本轮改动与本机结果应由独立验证报告说明。

## 当前链路与优先级

调研开始时，正式识别链路是 `Qwen3-ASR-1.7B`、`qwen-asr` 的 Transformers/PyTorch MPS 后端；翻译是 `Qwen3-4B-Instruct-2507-4bit`、锁定的 `mlx-lm==0.29.1`。`backend/livesub/asr/qwen.py` 每增加约 800 ms 音频，重新识别当前累计音频；累计段上限为 12 秒。这是可修订的离线推理预览，不能因模型支持 streaming 就当作已经使用上游增量输入接口。

已存在的能力应继续复用：积压时跳过过时 ASR 预览但保留每个音频样本、相同预览/定稿译文复用、实际 token 前缀 KV 缓存、最长术语短语优先和本地保护标记。详见 [既有系统音频与缓存报告](system-audio-latency-2026-09-30.md)。[既有术语报告](terminology-and-paragraphs.md) 的 34 条有限文本样本中，术语保护把翻译中位数由 232.56 ms 增至 306.18 ms；扩大词库本身不能证明会更快。

建议先减少进入模型的重复工作、增长窗口和额外 prompt token，再逐条扩充实际会用到的术语。端到端等待需区分采集/说话人窗口、ASR 排队与推理、翻译排队与推理、上屏时间；单独翻译快了不等于系统音频字幕已经同步。

## 可参考的实时处理实现

| 第一方来源 | 已核实的行为 | 对当前项目的适用性与边界 |
| --- | --- | --- |
| [Qwen3-ASR 推理源码](https://github.com/QwenLM/Qwen3-ASR/blob/7c6daf77a2421100f5fb066495372c00129d39ff/qwen_asr/inference/qwen3_asr.py) | `transcribe` 接受 `context`；`init_streaming_state` 对非 vLLM 后端直接报错。流式状态可回撤末尾 token。 | 当前 MPS 路径可在核对本机安装签名后试验有界领域词/人名 context，且要检查热词幻觉和 prompt 开销。不能直接打开官方 streaming 开关替代现有 MPS 适配器。仓库 [Apache-2.0](https://github.com/QwenLM/Qwen3-ASR/blob/7c6daf77a2421100f5fb066495372c00129d39ff/LICENSE)。 |
| [Whisper-Streaming](https://github.com/ufal/whisper_streaming#background) | LocalAgreement 在多次相邻假设共有的前缀上确认文字；保留可修订尾部，控制累计处理窗口。实时模拟会考虑实际计算时间。 | 可以借鉴稳定文字/可修订尾部、有限音频窗口和追赶策略；不能把上游 Whisper 测试延迟当作本机 Qwen 结果。代码 MIT。 |
| [SimulStreaming](https://github.com/ufal/SimulStreaming/blob/077ea37d5ab4ff98bc567e4507f140dc4e5d5ad6/README.md#background) | ASR 和 LLM 翻译串联；译文状态区分已确认和未确认文字，末段必须冲刷。LocalAgreement 取相邻更新最长共同前缀。 | 可据此减少不稳定尾部触发的无效翻译，同时保留 final 强制翻译和源译 revision 配对。英语单词前缀不能保证英→中语序已经稳定；否定、数字、长短语和后置修饰必须回归。AlignAtt 使用 Whisper 编码器/解码器注意力，不能直接搬进 Qwen/MLX。当前仓库 [MIT](https://github.com/ufal/SimulStreaming/blob/077ea37d5ab4ff98bc567e4507f140dc4e5d5ad6/LICENCE.txt)，README 的 GPU/提速说法是其特定模型与环境结果。 |
| [MLX-LM prompt caching](https://github.com/ml-explore/mlx-lm#long-prompts-and-generations) | 支持复用共同 prompt 上下文，减少重复前缀计算。 | 本项目已实现该机制；继续按实际 token 比较，在会话/代次/方向变化时清空。先简化重复术语说明、保持稳定系统前缀，并以真实模型检查标记完整性、数字和否定。新版在线文档不代表锁定 0.29.1 API；实现仍以安装源码为准。 |

以上是设计依据，未声称本轮已完整移植 LocalAgreement 或 AlignAtt。对现有适配器进行有界窗口、预览去重或 prompt 优化，可以先用已有模型与依赖验证。稳定前缀策略若改变最终段边界，应另检查完整音频保存、停止尾句和段落合并。

## 可直接人工校订的小型词库来源

[CNCF Cloud Native Glossary](https://github.com/cncf/glossary/blob/dea5192058add96711c7cbf874f1a18b2c29acdb/README.md#license) 明确区分代码 Apache-2.0 与文档 CC BY 4.0。它有对应英文和简体中文 Markdown 文件，适合软件/云原生领域的小型术语预设。以下只摘选词名对应关系，不复制概念说明或导入整库；匹配应仅在启用的软件领域内生效，使用英文词边界与最长短语优先。

| 英文词名 | 校订候选译法 | 中文源文件 |
| --- | --- | --- |
| observability | 可观测性 | [observability.md](https://github.com/cncf/glossary/blob/dea5192058add96711c7cbf874f1a18b2c29acdb/content/zh-cn/observability.md) |
| container orchestration | 容器编排 | [container-orchestration.md](https://github.com/cncf/glossary/blob/dea5192058add96711c7cbf874f1a18b2c29acdb/content/zh-cn/container-orchestration.md) |
| service mesh | 服务网格 | [service-mesh.md](https://github.com/cncf/glossary/blob/dea5192058add96711c7cbf874f1a18b2c29acdb/content/zh-cn/service-mesh.md) |
| load balancer | 负载均衡器 | [load-balancer.md](https://github.com/cncf/glossary/blob/dea5192058add96711c7cbf874f1a18b2c29acdb/content/zh-cn/load-balancer.md) |
| event-driven architecture | 事件驱动架构 | [event-driven-architecture.md](https://github.com/cncf/glossary/blob/dea5192058add96711c7cbf874f1a18b2c29acdb/content/zh-cn/event-driven-architecture.md) |
| idempotence | 幂等性 | [idempotence.md](https://github.com/cncf/glossary/blob/dea5192058add96711c7cbf874f1a18b2c29acdb/content/zh-cn/idempotence.md) |
| distributed systems | 分布式系统 | [distributed-systems.md](https://github.com/cncf/glossary/blob/dea5192058add96711c7cbf874f1a18b2c29acdb/content/zh-cn/distributed-systems.md) |
| continuous delivery | 持续交付 | [continuous-delivery.md](https://github.com/cncf/glossary/blob/dea5192058add96711c7cbf874f1a18b2c29acdb/content/zh-cn/continuous-delivery.md) |

词名出处：CNCF Cloud Native Glossary contributors，源版本 `dea5192058add96711c7cbf874f1a18b2c29acdb`。文档许可：[Creative Commons Attribution 4.0 International](https://creativecommons.org/licenses/by/4.0/)。本表是经选择的词名/译名对应关系；任何增加的复数、连字符/空格变体或领域匹配规则都是本项目的修改。来源不构成 CNCF 对 LiveSub 的认可。若条目用于分发，应保留来源、许可链接和修改说明。

实施后的模型检查只保留了其中七个词条。`distributed systems` 的术语保护标记使测试句 “Distributed systems failed for 0.03 seconds, not 0.3 seconds.” 从故障持续时间变为“未通过，耗时”，因此未将该条加入默认软件词库；原句继续由现有模型翻译，并保留在本轮回归样本中。词名正确并不保证将它替换为无语义的保护标记后，整句仍然正确。

之前已核查的 [Google ML Glossary](terminology-research.md) 仍适合机器学习词条人工核对。机器之心 AI 术语数据库的 CC BY-NC-SA 不适合作为自由商业分发的默认整库。Microsoft 文档页面许可不能自动当作 TBX 数据库许可。这次未捆绑上述数据库。

词库的作用要区分：翻译术语约束保证偏好一致；ASR vocabulary/context 帮助辨认原词但只是概率性提示。把所有术语填入每次 ASR/MT prompt，或把 agent/token 在任何语境都强制替换，会增加开销并损害准确率。优先使用当前片段实际命中的短语，并保留用户自定义词条优先级。

## 需要单独批准、实测的替代运行时/模型

| 候选与官方来源 | 为什么值得小样本比较 | 不能直接采用的原因 |
| --- | --- | --- |
| [MLX-Audio Qwen3-ASR](https://github.com/Blaizzy/mlx-audio/blob/94c7716212b2228f178d2f9c7619a591fd1b0b78/mlx_audio/stt/models/qwen3_asr/README.md) | 已有 1.7B/0.6B 的 8-bit MLX 转换候选，可比较 Apple Silicon 上的 ASR 推理耗时与内存。 | 需新增 `mlx-audio` 依赖与转换权重，当前 PyTorch 权重不能默认直接沿用。其 [stream_transcribe 源码](https://github.com/Blaizzy/mlx-audio/blob/94c7716212b2228f178d2f9c7619a591fd1b0b78/mlx_audio/stt/models/qwen3_asr/qwen3_asr.py#L1533) 是对提供的完整音频按块生成 token，不接受持续追加音频的状态对象；不能据此宣称真正的缓存式直播输入。代码 [MIT](https://github.com/Blaizzy/mlx-audio/blob/94c7716212b2228f178d2f9c7619a591fd1b0b78/LICENSE)；具体转换权重卡与源模型许可另行核对。 |
| [Tencent Hy-MT2-1.8B](https://github.com/Tencent-Hunyuan/Hy-MT2/blob/ff1903ecaa724e10951a23c16817a2413c752b35/README.md) | 专用翻译模型，比当前 4B 小；官方给出术语、背景上下文提示词及 GGUF 候选。 | 官方要求 Transformers ≥5.6.0，现有 4.57.6 不满足；上一轮 7B 候选的加载失败不能当作 1.8B 已测结果。GGUF 路径需要新运行时，极低比特量化还需额外内核及质量检查。当前仓库 [LICENSE.txt](https://github.com/Tencent-Hunyuan/Hy-MT2/blob/ff1903ecaa724e10951a23c16817a2413c752b35/LICENSE.txt) 与 [官方 1.8B 模型卡](https://huggingface.co/tencent/Hy-MT2-1.8B) 均标 Apache-2.0，不能混用旧 Hy-MT1.5 的自定义许可。上游模型尺寸/速度说法不代表本机实测。 |
| [CTranslate2](https://github.com/OpenNMT/CTranslate2) + [Helsinki-NLP opus-mt-en-zh](https://huggingface.co/Helsinki-NLP/opus-mt-en-zh) | 专用 encoder-decoder 英译中可避开长通用 LLM prompt；ARM64 CPU 路径值得比较，也可检验是否减少 ASR/MT GPU 争用。 | [CTranslate2 官方硬件文档](https://opennmt.net/CTranslate2/hardware_support.html) 支持 ARM64 CPU，列出的 GPU 后端是 NVIDIA，不是 Metal。需新依赖、模型转换/权重和 SentencePiece；术语、未完句、否定、混合语言和目标简体中文标记需专项核对。官方 OPUS 模型卡标 Apache-2.0，不能依赖许可不同的社区转换说明。减少 GPU 争用仅为待测假设。 |

本轮继续使用现有 Qwen 模型，不为候选方案修改依赖声明/锁文件、不下载权重、不创建长期服务。候选试验先形成具体安装/模型清单、磁盘开销和回退范围，再按项目依赖与模型变更规则取得批准。此前 [TranslateGemma-12B 对比](translation-candidate-comparison.md) 已显示本机 12 条样本约慢 4.5 倍；重复下载该大模型不应成为优先优化手段。

## 验证建议与可报告的证据

1. 固定现有技术英文样本及英文连续样本，按实时节奏输入相同 WAV；每次记录首条原文、首条当前修订配对译文、ASR/MT 单独耗时、队列深度、停止尾句等待、音频样本完整性及源译 revision。运行时应将模型预热与正式采样分开。
2. 用现有文本案例交替比较 prompt/缓存路径，包含术语命中/不命中、长短语、历史错误译法、未完句、数字和协调否定。词条命中率不能取代整句语义检查；缩短 prompt 或减少生成量不可静默截断译文。
3. 原生系统音频需另用有已知语音起止时刻的公开/合成测试音频，记录采集与字幕显示。后端 WAV IPC 不包含 ScreenCaptureKit、SpeakerKit 或 SwiftUI，不应报告成原生音画偏移。只有完成这一步，才可对当前版本的系统音频上屏延迟给出结论。

研究来源已经重新核查；本文件不把上游论文/README 的速度、已有历史报告或算法启发当作本轮性能验收。
