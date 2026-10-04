<p align="center">
  <img src="assets/app-icon/LiveSubIcon.png" width="144" alt="LiveSub">
</p>

<h1 align="center">LiveSub</h1>

<p align="center">
  <b>Live bilingual subtitles for anything you hear on your Mac.</b><br>
  English ↔ Chinese · floating captions · runs entirely on your Mac, audio never leaves it
</p>

<p align="center">
  <b>English</b> · <a href="README.zh-CN.md">简体中文</a><br>
  macOS 15+ · Apple Silicon · MIT License
</p>

<br>

![LiveSub main window: source on the left, translation on the right, aligned by paragraph](design/previews/bilingual-1080.png)

LiveSub listens to your microphone or system audio — online classes, meetings, videos, podcasts — turns speech into text with a local speech-recognition model, and translates it into the other language as you listen. Source and translation sit side by side in paragraphs, or become a single line of transparent floating captions over whatever window you are watching. Recognition and translation both happen on your Mac.

## Highlights

- **Fast** — on a Mac with Apple's offline translation, English → Chinese translation is ready a median of **21 ms** after the words are recognised. See [Speed](#speed).
- **Live bilingual** — English → Simplified Chinese and Chinese → English. Source and translation are aligned by paragraph; the ⇄ button in the column header switches direction, or show the translation only.
- **Floating captions** — transparent, never steal focus, click-through, laid over videos or meetings. Size, position and width are adjustable; turn on the caption backdrop when the picture is bright.
- **Fully local** — speech-to-text runs on-device with Qwen3-ASR-1.7B; translation runs on-device with Qwen3-4B-Instruct (MLX), and on macOS 26.4+ with the system language packs installed, English → Chinese uses Apple's offline translation first.
- **Terminology** — combine AI, software, data & statistics, finance, quantitative finance and blockchain glossaries, plus up to 100 custom fixed translations.
- **Speakers** — optionally detect up to 5 speakers and translate only the ones you care about.
- **Save & export** — copy everything in one click, or export TXT / Markdown, always bilingual.
- **Native** — built with SwiftUI, with light and dark mode, accessibility and menu-bar controls.

| First launch | Dark mode |
|---|---|
| ![Empty state](design/previews/empty-1080.png) | ![Dark mode](design/previews/bilingual-dark.png) |
| **Floating captions (backdrop on)** | **Translation & terminology settings** |
| ![Floating captions](design/previews/overlay-backdrop.png) | ![Settings](design/previews/settings-rows.png) |

<sub>Screenshots are rendered from the real interface with sample text. The interface is in Chinese.</sub>

## Speed

Measured on an Apple M5 Pro (48 GB) with public and synthetic test audio. Times start when recognised text is ready and include terminology handling, inter-process communication and queueing; they exclude system audio capture and drawing on screen.

| Step | Measured |
|---|---|
| English → Chinese translation, Apple offline translation (174 ordinary sentences) | median **21 ms**, P95 **35 ms**, max 48 ms |
| Same path in the packaged app with continuous audio (47 translations) | median **36 ms**, P95 61 ms, all under 300 ms |
| Translation with the local Qwen model (ordinary English sentences) | median **225 ms** |
| First translated caption after the test audio starts | about **1.2 s** |
| Rolling speech-to-text previews | about every **0.8 s**, revised in place until each sentence is final |

Full method and raw data: [native translation round 4](docs/native-translation-round4-2026-10-03.md), [round 2](docs/english-chinese-round2-2026-10-03.md).

## Speech recognition models

LiveSub's speech-to-text has always run on local models. The first versions used NetEase Youdao's **Confucius4-R2T2**, which decoded audio incrementally every 160 ms. In a same-machine comparison on the same audio, **Qwen3-ASR-1.7B** kept key technical and financial terms more reliably, so it is now the default recognition engine. The R2T2 adapter and benchmark scripts remain in the repository for comparison.

| Engine (local, same audio) | Combined error rate |
|---|---:|
| Qwen3-ASR-1.7B (current) | **1.32%** |
| Confucius4-R2T2 Q4 | 3.97% |
| Whisper large-v3-turbo | 6.62% |

A small sample of one real recording and four synthetic ones; it is not a general accuracy claim. Details: [recognition model comparison](docs/asr-model-comparison.md).

## Requirements

- An Apple Silicon (M-series) Mac running macOS 15 or later. Developed and tested on macOS 27; earlier versions are untested.
- Xcode Command Line Tools (with Swift) and [uv](https://docs.astral.sh/uv/).
- About 12 GB of free space. The recognition model is about 4.7 GB and the translation model about 2.3 GB; both live in `~/Library/Application Support/LiveSub/models/`, never in the repository or the app.
- Downloading the models the first time needs internet; after that, recognition and translation run locally.

## Install

There is no prebuilt download yet, so LiveSub is built from source. Most of the time goes into downloading the models.

**1. Get the source**

```bash
git clone https://github.com/Cis-jujube/LiveSub.git
cd LiveSub
```

**2. Prepare a code-signing certificate**

macOS ties microphone and screen & system audio recording permissions to the app's signature, so LiveSub needs a stable signing identity. If you have no developer certificate, create a self-signed "Code Signing" certificate in Keychain Access → Certificate Assistant → Create a Certificate, then find its SHA-1:

```bash
security find-identity -v -p codesigning
```

**3. Prepare the models and the app (once)**

```bash
export LIVESUB_SIGNING_IDENTITY="your certificate's SHA-1 (40 hex characters)"
./script/setup_models.sh
```

The script prepares a locked Python 3.12 environment, downloads and verifies the models (sources, revisions and hashes are in the [model manifest](docs/model-manifest.md)), then builds and signs `dist/LiveSub.app`. If a download is interrupted, run it again.

**4. Open**

```bash
./script/build_and_run.sh --run
```

The app starts and manages its own local backend, listening only on `127.0.0.1`; no extra terminal needed. Quitting the app stops the backend too.

## Usage

1. In the toolbar choose the audio source: **麦克风** (microphone) or **系统音频** (system audio). Choose the translation direction with ⇄ in the column header.
2. Click **开始** (Start, ⌘R). The first time, macOS asks for microphone or screen & system audio recording permission.
3. Subtitles appear in the main window by paragraph. Scrolling back pauses auto-follow; click **回到实时** (Back to live) to resume.
4. Click **悬浮字幕** (Floating captions) to lay captions over other windows. In **字幕外观** (Caption appearance), adjust size, position, width and backdrop, then click **完成** (Done) on the caption.
5. ⌘R pauses / resumes, ⌘. stops. The **导出** (Export) menu copies everything or saves a file.
6. In **设置** (Settings, ⌘,), combine glossaries and add custom terms. Changes apply from the next sentence.

The menu-bar icon can also start, pause, show floating captions and change caption size.

## Privacy

- Audio capture and model inference all happen on your Mac; the backend binds only to `127.0.0.1`.
- Raw audio is never saved. Subtitles stay in memory for the current session by default and are written to a file only when you export them.
- System audio is captured with ScreenCaptureKit; the screen picture is not recorded.
- Terminology settings are stored in `~/Library/Application Support/LiveSub/terminology.json`.

## Status

LiveSub is a personal project and is partially validated:

- The app is not notarized by Apple; build and sign it yourself as described above.
- Recognition accuracy in everyday use, multi-speaker conversations, long sessions and floating captions in full-screen or multi-display setups are still being tested.
- Audio protected by the system or by media copyright may not be capturable.

Test methods and data: [known issues](docs/known-issues.md), [manual test matrix](docs/manual-test-matrix.md) and the [development & validation log](docs/development-log.md).

## Development

```bash
./script/test.sh                     # backend tests, Swift checks and a debug build
./script/build_and_run.sh --verify   # build and verify the release .app without opening it
./script/render_design.sh            # render interface screenshots with sample text into design/previews/
```

| Folder | Contents |
|---|---|
| `app/LiveSub/MainWindow` · `App` | SwiftUI main window, settings, menu bar and design tokens (`Theme.swift`) |
| `app/LiveSub/Overlay` | Transparent, non-activating, click-through floating caption panel |
| `app/LiveSub/Audio` | Microphone and ScreenCaptureKit capture, converted to 16 kHz mono PCM |
| `app/LiveSub/Subtitles` | Subtitle store, paragraph alignment, terminology settings |
| `app/LiveSub/Backend` | Python subprocess management and local WebSocket communication |
| `backend/livesub` | Qwen3-ASR recognition, translation scheduling, sessions and subtitle revisions |
| `shared/protocol.md` | Audio frame, state and subtitle event protocol |
| `design/` | Design direction, interface copy, QA records and icon explorations |

## License

LiveSub's source code is released under the [MIT License](LICENSE). Models are downloaded separately and keep their own licenses; see the [model manifest](docs/model-manifest.md).
