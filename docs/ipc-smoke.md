# Task 3: real backend WebSocket smoke test

Measured on 2026-09-26 on this Apple M5 Pro Mac with the locked Python 3.12 backend. The test starts `livesub.server` as a separate process, connects to its ephemeral loopback WebSocket with a fresh Bearer token, and sends real 16 kHz mono PCM16 speech in frames of at most 2,560 samples at 160 ms audio pace. It uses the pinned native R2T2 ASR and local four-bit Qwen translator. Before starting, the script verifies the pinned size and SHA-256 of each R2T2 model and processor asset, plus the Qwen weight SHA-256 and quantization config. The exact model repositories and revisions are in the JSON reports and [model manifest](model-manifest.md).

## Reproduce

After one-time native/model setup, run from `backend`:

```bash
uv run python ../script/smoke_server.py /tmp/livesub-whisper-jfk-en.wav \
  --language English --expected-tail-substring 'your country' \
  --output ../docs/ipc-en.json
uv run python ../script/smoke_server.py /tmp/livesub-r2t2-upstream-test-cn.wav \
  --language Chinese --expected-tail-substring '不让喝' \
  --output ../docs/ipc-zh.json
```

The public test clips are [whisper.cpp `samples/jfk.wav`](https://github.com/ggml-org/whisper.cpp/blob/d09f61a708f3487afa956ff578e60eae5e7a233c/samples/jfk.wav) (English, 11.00 s) and [R2T2 `resources/test.wav`](https://github.com/netease-youdao/Confucius4-R2T2/blob/26d55a54ce5670cff9947a167d8ed95d569fd4d9/resources/test.wav) (Chinese, 6.74 s). The WAVs are local external fixtures, not committed user recordings. The script writes timing, counts, model identity, and Boolean validation flags only. It never writes the recognized speech or translated text to the reports. Its temporary backend stderr file is discarded when the run finishes.

## Results

| WebSocket protocol measurement | [English → Chinese](ipc-en.json) | [Chinese → English](ipc-zh.json) |
| --- | ---: | ---: |
| Frames sent | 69 | 43 |
| Maximum paced-send lateness | 1.19 ms | 1.13 ms |
| Start request to `listening` | 3,774.87 ms | 3,760.41 ms |
| Audio start to first subtitle event | 744.04 ms | 1,222.40 ms |
| Distinct segment IDs | 4 | 2 |
| Final translated segments | 4 | 2 |
| Final translations received after `stop` | 1 | 0 |
| `stop` request to `idle` | 286.21 ms | 140.97 ms |
| Wrong Bearer refused | HTTP 403 | HTTP 403 |
| Duplicate final IDs / later state regressions | 0 / 0 | 0 / 0 |
| Frame rejection / reported queue overflow | 0 / 0 | 0 / 0 |
| Expected spoken tail in final source text | yes | yes |
| Source revision and text paired to final translation | yes | yes |
| Final translation events retained after `idle` | yes | yes |

Both runs emitted `loading → listening → stopping → idle`, reported no backend error event, and passed the smoke assertions. The owned subprocess exited with `-15` because the test sent it SIGTERM after closing the WebSocket; that exit code is expected test cleanup.

The two `ipc-*.json` files contain per-segment event-receipt time minus the segment's approximate audio end time. Those measurements include segmentation and backend work; they are **not** last-spoken-word latency or UI-visible latency. The backend does not expose queue depth in this protocol, so these reports can establish absence of reported overflow on two short clips, but cannot establish long-run queue stability. This test does not include macOS microphone or system-audio capture, Swift UI rendering, display-mode switching, or a 30-minute session. Translation fidelity limitations from the joint model run remain documented in [the Task 2 benchmark](benchmark.md).
