# Task 2: local translation and joint inference benchmark

Measured on 2026-09-26 on this MacBook Pro (Apple M5 Pro, 48 GB unified memory, macOS 27.0, arm64). Python was 3.12.13 in `backend/.venv`; the locked runtime used `mlx-lm==0.29.1`, `mlx==0.32.2`, `qwen-asr==0.0.6`, `torch==2.14.0`, and `transformers==4.57.6`. The pinned translation weight and licenses are in [`model-manifest.md`](model-manifest.md).

These are real local-model results. The 40 translation examples are manually written text, not microphone or ASR output. The joint tests used genuine public prerecorded speech fed in 160 ms PCM frames at audio speed. Neither test includes the macOS capture path, IPC, UI rendering, browser load, or a 30-minute run. Consequently, the plan's last-spoken-word-to-visible-subtitle latency target is **not verified by these numbers**.

## Reproduce

```bash
cd backend
uv sync
uv run pytest tests/test_translation_contract.py -v
uv run python -m livesub.translation.download_model --verify-only
uv run python -m livesub.translation.benchmark --output ../docs/translation-review.json
uv run python ../script/benchmark_joint.py /path/to/english-16k-mono-pcm16.wav --language English --output ../docs/joint-en.json
uv run python ../script/benchmark_joint.py /path/to/chinese-16k-mono-pcm16.wav --language Chinese --output ../docs/joint-zh.json
```

The public English test was [whisper.cpp `samples/jfk.wav`](https://github.com/ggml-org/whisper.cpp/blob/d09f61a708f3487afa956ff578e60eae5e7a233c/samples/jfk.wav), 11.0 s; the Chinese test was [R2T2 `resources/test.wav`](https://github.com/netease-youdao/Confucius4-R2T2/blob/26d55a54ce5670cff9947a167d8ed95d569fd4d9/resources/test.wav), 6.74 s. Both WAVs were kept outside Git. `--include-text` was used for the two committed public-fixture JSON reports; it is opt-in because normal transcripts may be private. Native R2T2 diagnostics went to separate local stderr logs, not the JSON output.

## Contract and model test

The contract test was run before implementation and failed at import because `livesub.translation` did not exist. After implementation, all **8 tests passed**: empty input without loading, both explicit directions, identity/revision return, generation's 256-token ceiling, rejection of an empty model response for nonempty source, 2048-token input ceiling, two-pair/512-token context budget, and regression coverage for MLX loading and inference on the same worker thread. These tests use injected deterministic functions and do **not** count as model-quality tests.

The pinned Qwen model was downloaded into Application Support and its entire `model.safetensors` file passed the expected SHA-256 check. Real English→Chinese and Chinese→English generations passed. The final locked-environment, final-prompt 40-case run is [`translation-review.json`](translation-review.json); it records **every source sentence, exact model output, direction, focus area, and inference time**. There are 20 English and 20 Chinese examples covering numerals, negation, statistics and technical terms, ordinary speech, unfinished fragments, and spoken text that resembles an instruction.

| Translation-only measurement | Result |
| --- | ---: |
| Model preparation in this warmed process | 2.025 s |
| Warm inference, 40 examples, median | 245 ms |
| Warm inference, 40 examples, P95 | 296 ms |
| Peak process RSS reported by macOS | 2.92 GB |

One first run immediately after changing the environment took 79.2 s to prepare the model; a repeat took 2.56 s. This cold-start difference was observed but not attributed to a specific cause. It is excluded from the warm inference numbers and is not a startup-time guarantee.

I reviewed all 40 exact outputs in the JSON. In this small curated set, 37 have no observed material meaning error and 3 merit caution:

| Case | Observed output issue |
| --- | --- |
| `en-06` | “Turn left after 200 meters” became “行驶200米后左转”; “行驶” adds a vehicle/travel mode that the source did not state. |
| `en-18` | “It's 6:45 p.m.” became “现在是下午6点45分”; “现在” adds a time reference. |
| `zh-17` | “嗯，听起来差不多。” became “Hmm, sounds about the same.” This can shift “roughly right” toward “similar to something else.” |

No reversed negation or numerical value was observed in those 40 curated outputs; 3.5 hours was expressed as “三个半小时,” preserving the quantity in words. The `en-10` and `zh-10` instruction-like utterances were translated as speech, not acted on. These judgments are manual checks of this narrow sample, not an accuracy estimate for other speech.

## R2T2 + Qwen in one process

The joint benchmark loaded both real models in the **same Python 3.12 process**. A paced ASR producer and a dedicated translation worker ran concurrently; the worker maintained a bounded queue and returned translations for final ASR segments. `ASR RTF` is computation time divided by source audio duration, excluding the deliberate pacing wait. `After segment end` in the JSON uses the 6 s segment boundary or clip end as the clock start; it is **not** the last spoken word or UI-visible time.

| Public WAV | ASR RTF | Max frame feed lateness | Final segments translated | Max translation queue depth | Peak process RSS |
| --- | ---: | ---: | ---: | ---: | ---: |
| [English JFK](joint-en.json), 11.0 s | 0.691 | 23.9 ms | 2 / 2 | 1 | 5.25 GB |
| [Chinese R2T2](joint-zh.json), 6.74 s | 0.678 | 74.3 ms | 1 / 1 | 1 | 5.25 GB |

The English final translations appeared 677 ms and 493 ms after their respective segment boundaries. The Chinese final translation appeared 784 ms after its 6 s segment boundary. Both models reused their weights; the joint runs reported no translation failures or queue overflow. These short clips are insufficient to infer steady-state queue behavior or memory stability over 30 minutes.

The joint run exposed two quality failures that the curated set did not: the English 6 s ASR split ended with “ask not what your”, and Qwen completed the familiar quotation beyond the words received; the Chinese utterance “之前有顾客自己带酒水也没加收钱或者不让喝。” was translated with the opposite implication about allowing the customer to drink. Stronger literal/negation prompting did not fix either in a direct recheck or the final joint run. They remain known translation limitations and require segment-level review or a better model before claiming faithful wording in all cases. The English ASR split also introduced a spurious “The” at the start of the second segment, as recorded in Task 1's [`compatibility.md`](compatibility.md).

## Dependency and thread findings

`mlx-lm==0.31.3` worked in a translation-only environment but requires `transformers>=5`; `qwen-asr==0.0.6` requires `transformers==4.57.6`. `uv` rejected that combination. The selected `mlx-lm==0.29.1` ran real Qwen inference and joint R2T2 inference with the locked `transformers==4.57.6`. The resolver and both real-model runs are the evidence for this version choice.

MLX raised `RuntimeError('There is no Stream(gpu, 0) in current thread.')` when the model was loaded on one thread and generated on another. `MLXTranslator` now owns one dedicated worker for both operations. The same-thread regression test and both final joint runs passed after this change.
