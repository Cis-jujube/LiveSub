# 本地识别模型小样本对比（2026-09-27）

在同一台 Apple M5 Pro、48 GB 内存的 Mac 上，用同一批 16 kHz 单声道 PCM16 音频比较旧版 R2T2、Qwen3-ASR-1.7B、Whisper large-v3-turbo，以及按 LiveSub 输入帧运行的 Qwen3-ASR。模型均本地推理，未使用云端识别。逐条参考文本、模型输出、计算耗时和原始错误率见 [样本清单](asr-benchmark-cases.json)、[R2T2](asr-r2t2-results.json)、[Qwen 整句](asr-qwen-results.json)、[Qwen 实时适配器](asr-qwen-live-results.json)、[Whisper](asr-whisper-results.json)。

| 引擎 | 原始 CER/WER 合计 | 关键错词 | 实时方式 |
| --- | ---: | --- | --- |
| R2T2 Q4 | 3.97% | “置信区间”→“智信区间”，“机器学习”→“一起学习”，“Sharpe”→“sharp” | 每 160 ms 增量解码，6 秒硬切 |
| Qwen3-ASR-1.7B 整句 | 1.32% | 本组未观察到关键术语错词 | 整段离线 |
| Qwen3-ASR-1.7B LiveSub 适配器 | 1.32% | 本组未观察到关键术语错词 | 约每 1.2 秒预览；停顿／12 秒定稿 |
| Whisper large-v3-turbo | 6.62% | “置信区间”→“智信区间” | 整段离线 |

原始错误率按英文单词、中文字符计算，大小写和标点忽略，但没有把“twenty five”与“25”、中文数字与阿拉伯数字作等价归一化。因此 Qwen 和 Whisper 的英文金融样本虽然语义正确，仍各记了两个词错误；Whisper 的中文金融样本也因“二十八”→“28”、“百分之三”→“3%”受到较大惩罚。选择 Qwen 的主要证据是逐条核对关键术语和否定关系，而不是只看表格中的一个百分比。

真实语音只有 Qwen 官方示例中的一句“甚至出现交易几乎停滞的情况”，四个领域样本由本机 `say` 合成。该真人录音可能参与过 Qwen 的训练或调试，不能作为独立盲测。现有样本缺少噪声、口音、多人、实际麦克风和长会话；结论是“在这组本机可复现样本中更好”，不是通用最高准确率证明。用户报告的原生麦克风低准确率仍需在新 App 中用自愿提供、带参考文本的实际讲话复测。

[火山引擎的豆包语音识别产品文档](https://www.volcengine.com/docs/6561/1354871?lang=zh)介绍的是在线流式与录音文件服务；本轮未找到可核验、可在此 Mac 本地运行的豆包 ASR 开放权重，因此没有把豆包服务混进离线模型的同机排名。Typeless 也没有作为可下载的本地识别权重参与此轮测试。

应用链路另用合成音频经过真实本机 WebSocket 服务、ASR、译文队列、字幕版本控制。初次链路测试发现，可修订预览中的标点会过早触发定稿，把 `context window` 截成 `context`，并拆开 `must not`。现已改为仅在实际静音或长度上限时切段；英文 10.01 秒样本重新检查通过，完整原句和否定关系都保住，得到 1 条最终译文、无重复 final、无源译版本错配、无后端错误。首条字幕从音频开始到测试客户端收到约 1.71 秒，首条可用译文约 2.37 秒；这不含 macOS 原生采集或 UI 绘制。中文样本也得到 1 条完整定稿，并用 AI 词库补上 Qwen 自动插入顿号的“检索、增强、生成”变体，使其译为 `retrieval-augmented generation`。这些短测不能代替 30 分钟稳定性或真实采集验收。

重建音频并复测（音频和非公开日志保存在被 Git 忽略的 `.build/asr-benchmark/`）：

```bash
mkdir -p .build/asr-benchmark
curl -fLsS --output .build/asr-benchmark/zh-public.wav https://qianwen-res.oss-cn-beijing.aliyuncs.com/Qwen3-ASR-Repo/asr_zh.wav
say -v Daniel -r 145 -o .build/asr-benchmark/en-tech.aiff 'An AI agent can use tools. The language model has a context window. Each input token has a cost. The AI agent must not delete the files.'
say -v Tingting -r 165 -o .build/asr-benchmark/zh-tech.aiff '这个人工智能智能体使用检索增强生成，分析置信区间和样本量。请保留英文的 token 和 API。'
say -v Daniel -r 155 -o .build/asr-benchmark/en-finance.aiff 'The central bank raised interest rates by twenty five basis points. A higher Sharpe ratio does not guarantee higher returns. The token is not a security token.'
say -v Tingting -r 175 -o .build/asr-benchmark/zh-finance.aiff '这家公司的市盈率是二十八倍，现金流下降了百分之三。我们用机器学习预测波动率，但不能保证收益。'
for name in en-tech zh-tech en-finance zh-finance; do afconvert ".build/asr-benchmark/$name.aiff" ".build/asr-benchmark/$name.wav" -f WAVE -d LEI16@16000 -c 1; done
backend/.venv/bin/python script/benchmark_asr.py --engine qwen-live --cases docs/asr-benchmark-cases.json --output .build/asr-benchmark/qwen-live.json
```

替换 `--engine` 为 `r2t2`、`qwen` 或 `whisper` 可复测其他候选；需先准备相应本地模型。2026-09-30 已清理本机 R2T2、Whisper 测试权重及 R2T2 原生运行时；复测这两项前需重新准备，正式 App 只要求 Qwen3-ASR-1.7B。`script/benchmark_asr.py` 会把完整识别文本写入 JSON；仅可用于公开或合成音频，不要直接对私人录音使用该输出参数。
