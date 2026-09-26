# 本地术语与上下文验证

2026-09-26，在本机已安装的 Qwen3-4B-Instruct-2507-4bit 上执行。Python 3.12.13、mlx-lm 0.29.1、MLX 0.32.2。使用同一个模型加载、同一输出上限 256 tokens、temperature=0；baseline/new 逐例交替先后顺序。运行时没有并发 ASR GPU 工作负载。模型仓库和固定 revision、加载时间、逐例输出与耗时保存在各 JSON。

## 最终结果与边界

最终文件是 `terminology-benchmark-protected-final.json`：

| 集合 | 旧版指定词检查 | 最终版指定词检查 |
| --- | ---: | ---: |
| 20 个初始开发案例 | 7/20 | 20/20 |
| 8 个后续回归变体 | 3/8 | 8/8 |
| 最后新增的 6 个有限检查 | 0/6 | 5/6 |
| 合计 | 10/34 | 33/34 |

这不是通用翻译准确率。检查只判断事先指定的词语出现/禁用词不出现，不能自动证明语义、语法、时态与字幕节奏。前 28 条已经用于发现问题和迭代实现，因此属于开发回归集；最后 6 条是在最终保护策略确定后加入的一次有限检查，也不是独立的大规模评测。

最终全部 34 条都产生了译文，没有保护标记校验失败。残余检查失败是 `holdout-auth`：输入 `Keep the authentication token secret.`，前文提到 LLM，两路都生成 `保持认证token的机密性。`，没有满足预设检查所期望的“令牌”。术语选择器正确避开了 authentication 义项，但模型仍自行混用英文。这说明未保护的歧义词译法仍依赖模型。

人工阅读发现保护后的个别句子更生硬：例如 `AI Agent 并未花费 90 输出 tokens。`、`large language model's context window has 4096 tokens.`。核心数字和否定保留，但中文量词、英文冠词和词间空格仍有改善空间。旧历史案例最终为 `该AI Agent使用了一个上下文窗口。`，未完句 `如果AI Agent无法` 保持未完状态。不能用词法通过率替代这些语义观察。

| 最终同次运行耗时 | baseline | 最终版 |
| --- | ---: | ---: |
| 中位数 | 232.56 ms | 306.18 ms |
| 均值 | 238.19 ms | 311.96 ms |
| 最大值 | 313.24 ms | 416.89 ms |

中位数增加约 73.62 ms（31.7%）。这是短文本、热模型串行推理的单次测量，不包含 ASR、音频采集、排队、IPC、窗口渲染，也不代表持续运行 p95。

## 为什么最终使用局部术语保护

仅把 JSON 词表交给模型不能可靠满足偏好；曾出现 `tokens → 标记`、`software agents → 软件代理`，以及抄用历史错误 `AI代理人`。最终实现对已经通过方向、完整短语、英文词边界和领域规则筛选的当前源文跨度生成唯一标记。模型翻译周围文字，输出必须逐个保留标记且恰好一次；本地只把这些标记恢复为选定词语，不在任意中文输出中全局替换“代理”“令牌”。

缺失、重复、未知保护标记会明确抛出 `TranslationError`，字幕状态走现有 failed 路径，不把标记显示为译文；没有自动无限重试。源文、自定义目标文本、历史上下文中的标记样式均纳入碰撞检查。源记录和结果的 `translated_source_text` 始终保留原文。

出现术语保护时，提示中的历史只提供源文，不提供过去的机器译文，以免模型抄旧错误。没有保护词时仍可使用旧版源文/译文配对。所谓 confirmed context 是已完成的机器译文，并非人工审核通过。

最终读取最近最多 4 个同 session、同 generation、同方向、时间上不重叠且确实位于当前片段之前的已完成片段；在出队时读取，修复积压队列冻结旧上下文的问题。保留缓存最多 32 条，generation 改变即清空。历史预算仍为 512 tokens，总输入仍不超过 2048 tokens。先移除旧上下文，再减少选中术语，始终不截断当前源文；去掉所有术语时同步去掉保护指令，避免额外指令把原本能放入的源文挤出预算。若连原文与基础提示都不能放入，则报输入超限。

从 2 条增为 4 条的证据是 `context-four-old` 与 `new-three-context`：主题线索位于第 3 个先前片段，旧版把 token/agent 译作标记/代理，最终版按已知 AI 话题保留 token/Agent。4 条只是有界改善，超出范围的主题或歧义依然可能丢失。

## 迭代证据保留

- `terminology-benchmark.json`：初始 JSON glossary，20 条，baseline 7/20、新版 17/20。失败包括旧误译历史、LLM tokens、超出 2 条上下文的主题。
- `terminology-benchmark-validation.json`：强化指令和 4 条上下文，28 条，10/28 → 25/28；旧历史、input tokens、software agents 仍失败。
- `terminology-benchmark-final.json`：进一步把映射加入 system，28 条，10/28 → 26/28；LLM tokens 与 input tokens 仍失败。此文件名来自当时的候选版，不是最终实现。
- 第一次局部保护实验同时保留了原词表，前 13 条后在 unfinished 案例明确报 marker 缺失，实验中止，未生成完整 JSON。该实验促使后续提示仅提供标记而不提供会诱导模型自行还原的目标词。
- `terminology-benchmark-protected.json`：标记保护、仍含历史机器译文，28 条，10/28 → 27/28。旧错误历史导致标记校验失败，JSON 保留该错误。
- `terminology-benchmark-protected-final.json`：有保护词时改为历史源文上下文，34 条，10/34 → 33/34，是本说明的最终结果。

基准脚本保留修改前完整 system prompt 与 `_build_prompt` 算法（2 对上下文、512 tokens）。原 `mlx_engine.py` 文件 SHA256 是 `d07f23276f602fd968498cfac93f58f38511319e7fc29d4d116e4d6c0a5aa47e`。baseline 忽略自定义词表，与旧版实际行为一致。新实现从临时目录读取词表，不修改用户设置。

复现最终集合：

```sh
backend/.venv/bin/python script/benchmark_terminology.py --validation --holdout --output /tmp/livesub-terminology-recheck.json
```

运行该命令前停止其他模型推理工作以避免 GPU 争用。

## 自动化回归

后端 67 项 pytest 通过。新增覆盖词表校验/大小/热读取/无效文件保留与日志、最长短语和英文边界、方向与自定义覆盖、总输入预算、重复术语、原文含标记、全角和空白下的索引映射、组合音符/Hangul规范化与兼容展开的完整跨度边界、恶意目标文本、未知/重复/丢失标记、原文 identity，以及积压队列新上下文、future/self/跨代/跨方向排除。一次现有 Starlette `httpx` 弃用警告，不影响结果。

本轮是翻译术语与上下文改进，没有启用词表驱动的 ASR 热词/偏置。没有把术语表灌给语音识别，也不声称改善识别率。
