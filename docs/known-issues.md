# Known issues and scope

## Speaker detection

- SpeakerKit runs locally after a first-use model download. The current signed
  App reached "说话人检测已就绪" after downloading and loading the model. Actual
  native diarization of two or more voices has not yet been verified.
- Classification now waits for about two seconds of initial audio and uses
  800 ms steps with up to three seconds of context. With 160 ms capture frames,
  the first batch arrives at 2.08 seconds. Model processing adds to this delay.
  A cached-model synthetic single-voice check preserved all 63 audio frames and
  one speaker identity; short-turn/multi-voice accuracy remains uncalibrated.
  See [the latency repair and measurements](system-audio-latency-2026-09-30.md).
- The cross-window voice matching threshold is an initial conservative value,
  not a calibrated guarantee. Overlap, short turns, similar voices, or more than
  five distinct voices may remain unattributed or be assigned inconsistently.
- Speaker selection changes future translation only. Previously skipped final
  source segments are retained but are not translated retroactively.

## 2026-09-29 系统音频权限恢复进度

用户完成正式包授权开关的关闭／开启后，运行仍在 `discover displays` 返回 `SCStreamErrorDomain -3801`、`preflight=false`。经用户明确授权执行 `tccutil reset ScreenCapture local.jujube.livesub`，命令成功，设置列表中的 LiveSub 条目消失。此时直接使用 `SCShareableContent` 仍被拒绝；对照本机 CoreGraphics SDK 的说明，在预检查为 false 时补上 `CGRequestScreenCaptureAccess()` 请求入口，继续由 ScreenCaptureKit 报告最终错误，不以预检查结果提前拦截。

`./script/test.sh` 再次通过（Python 92 项、Swift 检查、debug 构建），正式包以相同本机签名身份重新构建，严格签名校验通过；新旧构建的指定要求均为 `local.jujube.livesub` 加同一证书根哈希，代码哈希已变化。随后系统 TCC 日志明确记录该标识的 ScreenCapture 状态为 `Allowed (System Set)`，并对当前进程的保存签名要求检查返回 `status: 0`。授权后重启的正式包选择系统音频并显示“音频已连接 · 等待声音”，未再报 `-3801`；停止操作已通过。为验证授权跨更新连续性，又把授权请求的返回结果加入失败诊断，运行 `swift run AudioPipelineChecks` 通过，以同一证书构建代码哈希不同的新包（`18573f8a…` → `b7c9bbfc…`）；TCC 对新进程再次报告 `Allowed (System Set)` 且签名要求匹配 `status: 0`，采集流再次启动并可停止。

第一轮已知内容测试播放了仓库公开样本 `.build/asr-benchmark/zh-public.wav`（4.204 秒，参考语句“甚至出现交易几乎停滞的情况。”）。`afplay` 正常退出，采集期间生成 4 段字幕，但原文中没有“交易”或“停滞”；同时系统中有其他音频播放。因此这轮只证实采集和识别链路有输出，未证实该样本由同一系统音频路径进入并正确识别。已停止采集，需在没有其他播放声音时重试。

其他声音暂停后，同一正式包重新选择系统音频并播放同一样本，得到原文“甚至出现交易，几乎。停滞的情况。”；去除标点后与参考语句一致。停止后历史字幕保留；再启动并重播，得到“甚至出现交易几乎停滞的情况。嗯。”，参考语句主体再次匹配，但多一个语气词。两次均无采集错误，第二次停止并退出后 App 与后端进程均消失。由此本机当前包的授权、短时真实系统音频、已知原文及停止/重试通过；仍不代表一般准确率、长期稳定性或其他 Mac 分发验收，旧授权失配的具体成因也未被历史 TCC 记录直接证明。

## 2026-09-28 屏幕与系统音频权限修复进度

构建脚本要求正式包使用明确指定的有效代码签名身份，并给图标、UI、Qwen 预览包分配各自的 Bundle ID 和显示名称。ScreenCaptureKit 错误按原始域和错误码区分授权拒绝、缺少 entitlement、启动失败及其他错误；预检查值仅保留为诊断信息。`./script/test.sh` 通过（Python 92 项，Swift 检查与 debug 构建）。22:30 的最新正式包已用本机自签身份重新构建并通过严格签名校验，指定要求为正式 Bundle ID 加证书哈希；新包已启动。其余六份 `.app` 已移入废纸篓，仓库的 `dist/` 仅剩正式包。尚未完成新包上的真实系统音频采集或跨构建授权复测，因此权限故障仍未确认修复。下文的 ad hoc 签名结果均为历史构建记录。

2026-09-29 复查：系统设置的“屏幕与系统音频录制”列表起初显示已开启的 `LiveSub-Qwen`。Launch Services 当时仍登记了废纸篓内六份旧包，其中三份与正式包共用 `local.jujube.livesub`；已仅注销这六份旧包的注册记录，复查该标识现在只指向 `dist/LiveSub.app`。随后权限列表同一位置改为显示已开启的 `LiveSub`，没有新增授权项或修改开关。正式包随后选择系统音频并实际启动，仍在 `discover displays` 返回 `SCStreamErrorDomain -3801`、`preflight=false`，因此注册清理没有恢复运行权限。当前正式包签名哈希为 `0c17445f74463ec39a62bd1cc6f9e032d8e69cbb`；旧包注册是否造成拒绝仍属推断。

This is a personal local build for the Mac on which setup was run. The current app uses a local self-signed identity; it has not been notarized, packaged for other Macs, or submitted to the App Store. Preparing it on another Apple Silicon Mac requires a valid signing identity, the two pinned Qwen models, and the locked Python app environment. The historical R2T2 extension and weights are optional comparison assets and were removed from this Mac on 2026-09-30.

The final release package containing native revision `c0de296` passed its build and strict codesign verification. Automated checks passed for 44 Python cases, Audio 5, Store 16 assertions plus 1,800 paired rows, Overlay 4 geometry checks plus caption reset, and Backend 15 protocol assertions plus launch-lifecycle isolation and authenticated transport. These results are detailed in [the delivery report](delivery-report.md); the remaining gaps below concern native runtime acceptance and model quality. The final package was later exercised and monitored as detailed below.

## Recognition and translation quality

- The pinned R2T2 streaming implementation can revise an earlier `fixed_text` hypothesis. LiveSub treats these as revisable previews and only finalizes a source segment after an explicit boundary; a preview can still visibly change.
- R2T2's forced 6-second split produced an extra “The” at one boundary in the public JFK sample. Segment times are approximate, not word-aligned timestamps.
- In the real WAV joint benchmark, Qwen completed an unfinished English fragment with words that were not spoken, and a Chinese sentence had incorrect negation scope. Stronger literal/negation prompting did not fix either in the recorded recheck. These failures are documented in [the joint benchmark](benchmark.md), separately from the [40-item curated text review](translation-review.json), in which no reversed negation was observed.
- Quality and latency vary with noise, accents, overlapping speakers, device load, and source material. Automatically detecting direction and mixing microphone/system audio are outside this first version.

## macOS and build constraints

- On this Mac, `codesign --verify --deep --strict dist/LiveSub.app` passed, but `spctl -a -vv dist/LiveSub.app` returned exit code **3** with **`rejected`**. This personal ad hoc package has not been notarized and is not established as accepted by Gatekeeper or ready for direct distribution. `open dist/LiveSub.app` previously succeeded on this development Mac; that observation does not guarantee launch after copying or downloading the package elsewhere.
- This Mac has Command Line Tools but not full Xcode. The project uses SwiftPM and executable assertion checks; `swift test` based on XCTest and Swift Testing is unavailable with this toolchain. `./script/test.sh` runs the available checks.
- System audio uses ScreenCaptureKit. Protected or system restricted content may not be available; the app does not attempt to bypass these restrictions.
- The current native system-audio attempt returned ScreenCaptureKit `-3801` even though a LiveSub permission toggle appeared enabled in System Settings. The effective permission/capture state remains unresolved; no real system-audio subtitle result is claimed. This observation alone does not establish a protected-content failure.
- macOS 15 is the deployment target; the actual test machine runs macOS 27.0. Compatibility with other macOS releases is unverified.
- The floating panel uses ordinary floating window level and `canJoinAllSpaces` / `fullScreenAuxiliary`. It is not intended to cover lock screens, secure input, system prompts, or every native fullscreen app. Actual tested combinations are recorded separately in [the manual matrix](manual-test-matrix.md).
- The first model setup is a terminal script. It reports model origins, approximate sizes, verification, and disk errors, and can be rerun. The App itself reports missing preparation but does not download or compile model assets from its Settings window.

## Outstanding acceptance evidence

- An earlier live microphone English→Chinese session reached 20 paired segments. The final package subsequently produced ambient-audio pairs in both directions, with 16 segments retained in the Chinese-direction short test. Brief public-WAV playback did not yield text matching the known samples, so native acoustic-capture accuracy remains unverified. System-audio capture still fails with `-3801`.
- Overlay toggling preserved the App/backend processes in the earlier test. Final-package browser and TextEdit typing/clicking/scrolling worked with the toggle enabled, but reliable panel coverage of the interaction points was not established. Actual covered-area click-through, pixel-level rendering, exact fade timing, MenuBarExtra, position adjustment/reset, and Space/fullscreen/multiple-display compatibility remain unverified. The main window was restored through File → New LiveSub Window with history retained; the status-item route was not tested.
- The formal [backend-only soak](soak-backend.md) passed: 1,804 seconds, 164 repetitions of one public English WAV, 30 complete minute samples, 656 final translations and 6,238 subtitle events, with no reported error, duplicate final, revision regression, or final source/translation mismatch; the expected tail was present. The [raw report](soak-backend.json) records sampled RSS peak 4,979.45 MiB and start-to-after-idle growth of 64.76 MiB. These observations cover this single repeated-speech workload; queue depth is not exposed and absence of leaks is not established.
- Final-package native monitoring lasted **1,953.28 seconds** in a microphone ambient-audio ZH→EN session. The two original processes were jointly alive in 195 samples, last at 1,943.23 seconds, with no PID reuse. App RSS peak was 175.66 MiB (+27.10 MiB first-to-last alive); backend peak was 4,980.17 MiB (+6.24 MiB). The user reported Cmd+Q, after which the monitor recorded both original PIDs absent at 1,953.25 seconds; an independent process check found no LiveSub App/backend residue. The binary was unchanged and ending strict signature verification passed. See [native summary](native-soak-summary.json) and [raw metrics](native-soak-metrics.jsonl).
- That native monitoring did not periodically check subtitle counts or content. It does not prove uninterrupted capture, continuous subtitle updates, accuracy, UI-visible latency, or final-tail completion. The full native subtitle-chain acceptance and formal offline test remain pending. The separate backend soak timings (segment-end→final median 958.55 ms/P95 1,217.92 ms; stop→idle 412.98 ms) remain backend-only measurements; the 1,800-row Store check remains synthetic.
- Final-package normal exit cleanup now has observed process evidence. The automated lifecycle checks separately reject stale stdout, termination, and failure cleanup from a previous launch without disrupting its replacement. Not every forced-crash or socket race has been exercised.
- Actual retry/stop behavior after backend failure and absence of an old-caption flash on a new session remain pending; caption-state assertions and process lifecycle checks do not replace these GUI observations.
