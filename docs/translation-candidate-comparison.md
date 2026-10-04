# 本地翻译候选小样本检查（2026-09-27）

这轮改造的主目标是提高**语音识别**准确率；翻译仍需检验，不能把识别模型的改进归给翻译模型。用 [12 条合成技术／金融／否定句](translation-candidate-cases.json) 在同一台 Apple M5 Pro、48 GB Mac 上比较当前 Qwen3-4B-Instruct-2507 4-bit MLX 与 TranslateGemma-12B 4-bit MLX。此组没有真人语音，也不是通用翻译评测。

| 候选 | 加载耗时 | 12 条逐句计算耗时中位数 | 观察与决定 |
| --- | ---: | ---: | --- |
| Qwen3-4B-Instruct-2507 4-bit | 2.54 s | 286 ms | 保留为当前实时翻译器；在本组 12 句中有一处中文否定关系误译 |
| TranslateGemma-12B 4-bit | 7.52 s | 1,285 ms | 该否定句译对，但“市盈率升至 28 倍”译文遗漏“倍”；本机逐句约慢 4.5 倍，暂不替换 |
| Hy-MT2-7B 4-bit | 无有效结果 | 无有效结果 | 下载后无法在当前锁定的 `transformers==4.57.6` 环境加载：`TokenizersBackend` 词表类不存在；不能据此比较质量 |

最能说明取舍的例子是“之前有顾客自己带酒水也没加收钱或者不让喝。”Qwen 译成 `...without being charged, or even being allowed to drink`，把最后一个否定关系反了；TranslateGemma 译成 `...without being charged or prevented from consuming them`，保住了原意。另一方面，TranslateGemma 把“市盈率升至 28 倍”译成 `price-to-earnings ratio rose to twenty-eight`，没有表达“倍”。两者都不能凭这 12 句称为“质量最高”。

TranslateGemma 的社区 MLX 转换权重在当前推理库里默认只把 `<eos>` 当终止符，译文后的 `<end_of_turn>` 会持续生成。比较脚本显式加入这个终止符后才得出上表；首次运行生成了大量结束标记的时间**不**计入表格。Hy-MT2 的失败发生在词表加载阶段，未修改项目依赖或模型权重来绕过兼容问题。2026-09-30 已清理本机 TranslateGemma 与 Hy-MT2 候选权重；正式 App 仍使用 Qwen 翻译和 Qwen3-ASR 权重。

复现脚本（结果保存在被 Git 忽略的 `.build/asr-benchmark/`）：

```bash
backend/.venv/bin/python script/benchmark_translation_candidates.py --model qwen --output .build/asr-benchmark/translation-qwen.json
backend/.venv/bin/python script/benchmark_translation_candidates.py --model gemma --output .build/asr-benchmark/translation-gemma.json
```

输入是合成句。脚本会写出完整原文和译文，不应用于未经同意的私人对话。若之后要重新选择翻译器，应先准备用户真实纠错样本、固定参考译文与延迟预算，再同时检查术语、数字、否定关系和字幕上下文。
