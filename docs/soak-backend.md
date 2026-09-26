# Backend-only 30-minute soak result

`script/soak_server.py` drives the real local R2T2 and Qwen backend through its authenticated loopback WebSocket in one uninterrupted session. It repeats the public [whisper.cpp JFK WAV](https://github.com/ggml-org/whisper.cpp/blob/d09f61a708f3487afa956ff578e60eae5e7a233c/samples/jfk.wav) at audio speed. Repetition is deliberate: this tests process, session, revision, and queue behavior over time with reproducible speech, not recognition accuracy over varied conversation. The WAV is outside Git. The script checks pinned R2T2 and Qwen assets before starting and writes no transcript or translation text to its report.

After one-time model and native setup, the full run is:

```bash
cd backend
uv run python ../script/soak_server.py /tmp/livesub-whisper-jfk-en.wav \
  --language English --expected-tail-substring 'your country' \
  --min-duration-seconds 1800 --output ../docs/soak-backend.json
```

For the 11-second fixture, the script schedules 164 complete repeats, or 1,804 seconds of audio, so the final utterance is not cut off. It sends at most 2,560 PCM16 samples per WebSocket frame and carries one continuous sample offset, frame sequence, session ID, and generation throughout. It sends one `start`, then all audio, then one `stop`, and waits for `idle` and any pending final translation. A short run requires `--smoke` and a separate output path; it cannot overwrite the full result.

Every elapsed minute, it samples the **backend subprocess** RSS and `%CPU` reported by macOS `ps`, along with cumulative subtitle, final translation, error, and revision counters. The report also records paced-send lateness, approximate segment-end-to-final-event time, stop-to-idle time, duplicated final IDs, source/translation revision mismatches, and whether the final source segment contains the known public WAV tail. Backend queue depth is not exposed by the protocol, so the report records error and rejection counts but cannot assert an exact queue-depth curve. RSS growth across 30 minutes is an observation, not by itself proof of a memory leak.

The Astra-reviewed 22-second two-repeat script check passed on this Mac: 138 frames, 8 final translations, no backend error, duplicate final, revision regression, or source/translation mismatch, and the known spoken tail was present. Its report is `/tmp/livesub-soak-astra-smoke.json`; it is **not** the 30-minute result. The script also rejects non-finite durations and resolves output paths before preventing short runs from overwriting the formal report.

The formal backend run **passed**. It started at **2026-09-26 20:42:09 +08:00**, after the native App and its backend exited; the raw report was written at **21:12:19.818 +08:00**. Harness PID was 16854 and dedicated backend PID was 16859. Both exited after the run. The report's backend exit code of `-15` is the harness's deliberate SIGTERM cleanup after receiving `idle`, not a crash. The unmodified measured output is [soak-backend.json](soak-backend.json).

| Measurement | Actual result |
| --- | --- |
| Paced audio / audio-start-to-idle wall time | 1,804.00 s / 1,804.41 s |
| Sessions / complete public-fixture repetitions | 1 / 164 |
| PCM frames / subtitle events | 11,316 / 6,238 |
| Unique segments / final translated segments | 656 / 656 |
| Backend errors / rejected-frame and overflow errors | 0 / 0 |
| Duplicate finals / revision regressions / post-final regressions | 0 / 0 / 0 |
| Source/translation final-pair mismatches / missing target-script segments | 0 / 0 |
| Consecutive minute metric samples | 30, all RSS/CPU values available |
| Start-to-listening / first subtitle after audio start | 4,137.01 ms / 750.93 ms |
| Approximate segment-end-to-final event, median / p95 / max | 958.55 / 1,217.92 / 1,561.64 ms |
| Paced-send lateness, median / p95 / max | 1.08 / 2.09 / 10.00 ms |
| Stop-to-idle | 412.98 ms |
| Final translations after stop / after idle | 1 / 0 |
| Initial / final / peak sampled backend RSS | 4,914.62 / 4,979.38 / 4,979.45 MiB |
| Initial-to-final RSS change | +64.76 MiB |
| Minute 1 / minute 30 RSS | 4,977.38 / 4,979.45 MiB |

The known public WAV tail was present in the last final source segment, which ended within one second of the sent audio's end. The state order was `loading → listening → stopping → idle`; there were no failure codes or unexpected backend stdout lines. Minute 1–30 RSS remained between 4,977.38 and 4,979.45 MiB; most of the observed growth occurred before the first minute. This run gives no evidence of continued substantial RSS growth in this workload, but does not establish general leak freedom. These CPU readings are macOS `ps` samples, not integrated CPU or GPU utilization.

Post-run verification checked the raw JSON's ≥1,800-second audio and wall durations, consecutive minute 1–30 samples, zero sampled errors, and absence of source/target speech text and authorization material. The JSON contains no transcript or translation text.

This backend-only soak does not test macOS microphone or system-audio capture, Swift event handling, overlay behavior, browser/editor interaction, or UI-visible latency. Those require separate native App tests.
