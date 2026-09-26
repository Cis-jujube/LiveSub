# LiveSub 专业术语与上下文调研

核查日期：2026-09-26。范围：中英 AI／计算机实时字幕；本文件是来源核查与实现建议，不代表真实音频质量已经验证。

## 结论

建议采用小型、人工校订的 AI／计算机术语预设，允许用户以本地自定义词条覆盖。AI 语境下保留 `Agent` 和 `token` 是本项目根据用户要求制定的输出偏好，不能宣称是所有领域唯一正确译法；用户也可指定 `AI agent → AI 智能体` 等译法。完整短语应优先于单词；`travel agent`、`access token` 等不同语义不能无条件套用 AI 词义。

暂不整库下载、抓取或捆绑第三方术语数据库。下列来源适合人工核对概念与候选译法，来源许可也应与预设本身的维护记录分开保存。

## 可用来源与边界

| 来源 | 价值 | 本地使用边界 |
| --- | --- | --- |
| [Google Machine Learning Glossary（英文）](https://developers.google.com/machine-learning/glossary?hl=en)／[中文](https://developers.google.com/machine-learning/glossary?hl=zh-cn) | 同一站点提供机器学习、生成式 AI、agent 等术语与概念解释；适合人工交叉核对 | 英文页面页脚明确 CC BY 4.0（例外内容除外）；复用或改写应署名、链接来源及许可、说明修改。中文同页可见“智能体／代理”“词元／令牌”等不同译法，因此仍需本地校订，不能直接全量映射。参见 [Google 内容使用政策](https://developers.google.com/terms/site-policies)。 |
| [Microsoft language resources](https://learn.microsoft.com/en-us/globalization/reference/microsoft-language-resources)／[Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology) | 面向软件本地化的通用 IT 术语；官方页面提供检索与 TBX 下载入口 | 页面确认可用于整合术语集合，但本次下载链接未成功打开，未核实具体 TBX 下载包当前授权。不能把文档许可自动等同于术语数据库许可；现阶段只作人工参考。 |
| [机器之心 AI 中英术语数据库](https://github.com/jiqizhixin/Artificial-Intelligence-Terminology-Database) | 按领域整理中英术语，README 说明参考教材并由领域专家参与完善 | [LICENSE](https://github.com/jiqizhixin/Artificial-Intelligence-Terminology-Database/blob/master/LICENSE) 是 CC BY-NC-SA 4.0，涉及署名、非商业及相同方式共享限制。不把该数据库直接纳入需要自由商业分发的默认包。 |
| [DeepSeek 官方中文 API 文档](https://api-docs.deepseek.com/zh-cn/api/list-models/) | 官方中文 API 说明保留 `token`，可佐证技术读者确实使用英文原词 | 搜索索引核查到“上下文窗口的 token 总容量”等用法，直接打开该路径失败；只作为术语用法的补充证据。未确认文档批量再分发许可，不复制文档构成数据库。 |

## 术语与上下文机制的第一方依据

[Google Cloud Translation glossary 文档](https://docs.cloud.google.com/translate/docs/advanced/glossary) 将术语表用于领域词、歧义词、产品名及不翻译的借词，并区分大小写匹配。它也提供结合上下文处理术语的选项。这说明术语映射需要语境，不适合在译文上进行无条件字符串替换。该云服务的功能不能视为本地 Qwen 模型已经具备相同保证。

[DeepL 翻译请求文档](https://developers.deepl.com/api-reference/translate/request-translation) 将 `context` 定义为影响翻译、但自身不输出翻译的附加文本。[DeepL 的功能说明](https://www.deepl.com/en/blog/deepl-api-context-parameter) 特别提到短文本缺少上下文时的消歧用途。对实时字幕，可参考此设计，将前文放入独立参考字段，并要求只输出当前片段。

## 对现有代码的具体建议

调研开始时的代码快照：`backend/livesub/translation/mlx_engine.py` 使用本地 Qwen3-4B，输入上限 2048 token，输出上限 256 token；`_build_prompt` 最多读取最近两对 `confirmed_context`，上下文预算为 512 token。`backend/livesub/session.py` 也只传最近两对。这里的“confirmed”是字幕生命周期中的最终结果，并非人类确认译文正确，因此历史误译可能继续影响后文。

建议实现与验证以下行为：

1. 提供通用与 AI／计算机领域选择，保留短小明确的主题提示，例如“正在讨论大语言模型与智能体”。用户自定义映射高于内置预设。
2. 只把当前源片段实际匹配的术语放进 prompt；使用大小写规则、英文单词边界与最长短语优先，避免 `agent` 命中 `reagent`，或短词遮蔽 `AI agent`。
3. 将领域、术语映射、参考上下文和当前片段分成明确字段。字幕内容与词条值均是数据，不能提升为系统指令。对长度、词条数量和总 prompt token 设置预算；超限先减少旧上下文，不静默截断当前字幕。
4. 明确“历史译文只作参考；当前术语偏好优先”。可先小幅增加前文数量，但必须受总 token 预算限制；不要直接把整场会议或整本词库塞入每条请求。
5. 不用译文全局替换来保证术语：例如把所有“代理”替为“智能体”会破坏网络代理和经纪人语境。以匹配词提示加真实模型测试为先；prompt 服从性是概率性的，不能声称硬性保证。
6. 自定义词条首版使用可检查的本地纯文本格式（例如每行 `source = target`），明确覆盖顺序、重复项行为与错误反馈，避免引入新依赖。

## 必须分开的质量验证

翻译词库只作用于 ASR 后的文本。若音频中的 `AI agent` 已被 ASR 识别为其他词，翻译器无法可靠恢复原话。`backend/livesub/asr/r2t2.py` 的流式假设还可回撤；仅最终片段可作为识别结果评估。

这不代表 ASR 无法利用术语。[Confucius4-R2T2 官方 README](https://github.com/netease-youdao/Confucius4-R2T2) 明确列出上下文与热词提示支持。本地固定版本的 `third_party/Confucius4-R2T2/r2t2/r2t2_asr.py` 中 `init_streaming_state` 接受 `context` 参数；本项目调研开始时的 `_new_state` 尚未传入领域术语。ASR 热词是可接入但本轮未实测的独立改进项；不能将翻译术语测试成绩等同于 ASR 热词效果。

至少应保留两组证据：

- 文本直译测试：正确输入 `AI agent`、`tokens`、`context window`、`tool calling`，核对 AI 模式输出；同时测试 `travel agent`、`access token`、无关词和历史错误译法，检查误伤。
- 真实音频测试：对同一音频分别记录人工转写、最终 ASR 原文、最终译文。分别判断识别是否正确、术语是否符合偏好、否定／数字／代词／未完句是否保真，并记录延迟。

本调研阶段没有下载第三方术语库、安装依赖或修改 ASR／翻译代码，也未以调研本身证明模型质量改善。主任务随后已实现翻译术语与上下文改动并执行模型测试；最终实现、实测结果及剩余限制见 [连续段落与专业术语更新](terminology-and-paragraphs.md)。
