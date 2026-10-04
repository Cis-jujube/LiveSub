<p align="center">
  <img src="assets/app-icon/LiveSubIcon.png" width="144" alt="LiveSub">
</p>

<h1 align="center">LiveSub</h1>

<p align="center">
  <b>Live bilingual subtitles for anything you hear on your Mac.</b><br>
  English ↔ Chinese, right on your screen as people speak — private, fast, and free.
</p>

<p align="center">
  <a href="https://github.com/Cis-jujube/LiveSub/releases/download/v0.1.1/LiveSub-0.1.1.dmg"><img src="assets/readme/download-mac-en.svg" width="320" alt="Download for Mac — Apple silicon"></a>
</p>

<p align="center">
  <sub>Version 0.1.1 · 18 MB · macOS 15 or later</sub><br>
  <sub><b>For Macs with Apple silicon (M1, M2, M3, M4 or later) only. Intel Macs are not supported.</b></sub><br>
  <sub><a href="README.zh-CN.md">简体中文</a> · <a href="#before-you-start">Before you start</a> · <a href="https://github.com/Cis-jujube/LiveSub/releases">All releases</a></sub>
</p>

<br>

![LiveSub main window: the original speech on the left, its translation on the right](design/previews/bilingual-1080.png)

## What LiveSub does for you

- **Understand any video, class or meeting.** LiveSub listens to your microphone or to the sound playing on your Mac and writes subtitles as people speak, in English and Chinese.
- **Read both languages side by side.** The original and its translation line up paragraph by paragraph. Press ⇄ to switch direction, or show the translation only.
- **Keep subtitles on top of anything.** Floating captions sit over your video or call without getting in the way: they're transparent, click-through and never steal focus. Adjust the size and position, and turn on a soft backdrop when the picture is bright.
- **Fast.** On recent macOS, an English sentence becomes Chinese about 21 milliseconds after it's recognised.
- **Private.** Listening, recognition and translation all happen on your Mac. Your audio never leaves it, and nothing is saved unless you export it.
- **Get the right words.** Turn on glossaries for AI, software, data, finance, quantitative finance or blockchain, and add up to 100 terms of your own.
- **Keep what matters.** Copy everything in one click, or save it as a text or Markdown file with both languages.

| When you first open it | Dark mode |
|---|---|
| ![Welcome screen](design/previews/empty-1080.png) | ![Dark mode](design/previews/bilingual-dark.png) |
| **Floating captions over a video** | **Glossaries and your own terms** |
| ![Floating captions](design/previews/overlay-backdrop.png) | ![Settings](design/previews/settings-rows.png) |

<sub>Screenshots show the real app with sample text. The app's interface is in Chinese.</sub>

## Before you start

| | What to expect |
|---|---|
| **Your Mac** | A Mac with **Apple silicon** (M1, M2, M3, M4 or later) running **macOS 15 or later**. Intel Macs are not supported. Not sure? Choose Apple menu → About This Mac and look for "Chip: Apple M…". |
| **Free space** | About **10 GB**. |
| **One-time download** | The first time you open LiveSub, it downloads its speech and translation models: about **8.6 GB**, once. After that it works offline. |
| **First open** | LiveSub is free and not notarized by Apple, so macOS asks you to confirm it once with **Open Anyway**. |
| **First start** | The first time you press Start, LiveSub needs **a minute or two** to load its models. After that it starts much faster. |

## Get started

**1. Install.** Click **Download for Mac** above. Open the downloaded `LiveSub-0.1.1.dmg` and drag **LiveSub** into **Applications**.

**2. Open LiveSub for the first time.** Double-click LiveSub in Applications. If macOS says it can't verify the developer:

- Click **Done**.
- Open **System Settings → Privacy & Security** and scroll down to the message about LiveSub.
- Click **Open Anyway**, then **Open**.

You only need to do this once.

**3. Download the models.** LiveSub opens on a welcome screen. Click **开始下载** (Download). A progress bar shows how much is left and roughly how long it will take. You can keep using your Mac in the meantime. If the download is interrupted, open LiveSub again and it picks up where it stopped. In mainland China, LiveSub switches to local mirrors automatically.

**4. Start listening.** Choose **麦克风** (microphone) or **系统音频** (sound playing on your Mac), then click **开始** (Start). When macOS asks for permission to use the microphone or record system audio, allow it. The very first start takes a minute or two; after that, subtitles appear as soon as someone speaks.

## Using LiveSub

- **Switch direction:** click ⇄ above the columns to choose English → Chinese or Chinese → English.
- **Show only the translation:** choose **仅译文** (Translation only) at the top right of the reading area.
- **Put subtitles over other windows:** click **悬浮字幕** (Floating captions). Under **字幕外观** (Caption appearance), change the size, move them, or turn on **字幕底板** (backdrop); click **完成** (Done) on the captions when you're finished.
- **Look back without losing your place:** scroll up anytime. Click **回到实时** (Back to live) to jump back to the latest line.
- **Pause, resume and stop:** ⌘R pauses or resumes, ⌘. stops.
- **Save a session:** the **导出** (Export) menu copies everything or saves a text or Markdown file.
- **Teach it your vocabulary:** open **设置** (Settings, ⌘,) to turn on glossaries and add your own fixed translations. New terms apply from the next sentence.

The LiveSub icon in the menu bar can also start, pause, show the floating captions and change their size.

## How fast is it?

Measured on an Apple M5 Pro with public and synthetic test audio. Times start when the spoken words have been recognised and don't include capturing the sound or drawing it on screen.

| What happens | How long |
|---|---|
| English → Chinese with Apple's built-in offline translation (macOS 26.4 or later, 174 sentences) | about **21 ms** typically, 35 ms at the slow end |
| The same inside the app, with continuous audio (47 translations) | about **36 ms** typically, every one under 300 ms |
| Translation with LiveSub's own Qwen model (any supported macOS) | about **225 ms** typically |
| From the start of the speech to the first translated subtitle | about **1.2 s** |
| How often the live transcript refreshes while someone is talking | about every **0.8 s** |

Methods and raw numbers: [translation round 4](docs/native-translation-round4-2026-10-03.md) and [round 2](docs/english-chinese-round2-2026-10-03.md).

## Your privacy

- Listening, recognition and translation all run on your Mac. LiveSub's parts only talk to each other on `127.0.0.1`.
- Your audio is never recorded or saved. Subtitles stay in memory for the current session until you export them.
- When LiveSub listens to system audio, it doesn't record your screen.
- After the one-time model download, LiveSub works without an internet connection.

## If something isn't working

**macOS says LiveSub "can't be opened" or "can't verify the developer."** This is expected for a free app that isn't notarized. Follow step 2 above: System Settings → Privacy & Security → **Open Anyway**.

**The model download is slow or stopped.** Click **重试** (Retry); everything already downloaded is kept. In mainland China, LiveSub uses local mirrors automatically. Make sure about 10 GB of space is free.

**No subtitles appear.** Make sure LiveSub has permission: open System Settings → Privacy & Security → **Microphone** (for the microphone) or **Screen & System Audio Recording** (for sound playing on your Mac), turn on LiveSub, then quit and reopen it. Some protected media can't be captured.

**Pressing Start seems to take a long time.** The first start after installing loads the models from scratch and can take a minute or two. Later starts are faster.

**Can I use it on an Intel Mac?** No. LiveSub needs Apple silicon (M1 or later).

**How do I uninstall LiveSub?** Quit LiveSub, drag it from Applications to the Trash, and delete the folder `~/Library/Application Support/LiveSub` (about 8.6 GB of models). In Finder, choose Go → Go to Folder… and paste that path.

## Good to know

LiveSub is a free personal project and still growing. Everyday accuracy, conversations with several speakers, very long sessions and floating captions on multiple displays are still being tested. Known issues are listed in [docs/known-issues.md](docs/known-issues.md).

---

## For developers

### Speech recognition models

LiveSub's speech-to-text has always run on local models. The first versions used NetEase Youdao's **Confucius4-R2T2**, which decoded audio incrementally every 160 ms. In a same-machine comparison on the same audio, **Qwen3-ASR-1.7B** kept key technical and financial terms more reliably, so it is now the default recognition engine. The R2T2 adapter and benchmark scripts remain in the repository for comparison.

| Engine (local, same audio) | Combined error rate |
|---|---:|
| Qwen3-ASR-1.7B (current) | **1.32%** |
| Confucius4-R2T2 Q4 | 3.97% |
| Whisper large-v3-turbo | 6.62% |

A small sample of one real recording and four synthetic ones; it is not a general accuracy claim. Details: [recognition model comparison](docs/asr-model-comparison.md). Translation uses Qwen3-4B-Instruct (MLX 4-bit), or Apple's offline translation for English → Chinese on macOS 26.4+ with the language packs installed. Model sources, revisions and hashes are in the [model manifest](docs/model-manifest.md).

### Build from source

You need Xcode Command Line Tools (with Swift) and [uv](https://docs.astral.sh/uv/). macOS ties microphone and screen & system audio permissions to the app's signature, so builds need a stable code-signing identity; a self-signed "Code Signing" certificate from Keychain Access → Certificate Assistant works.

```bash
git clone https://github.com/Cis-jujube/LiveSub.git && cd LiveSub
security find-identity -v -p codesigning        # find your certificate's SHA-1
export LIVESUB_SIGNING_IDENTITY="<40-hex SHA-1>"
./script/setup_models.sh                        # one-time: Python environment, models, signed app
./script/build_and_run.sh --run                 # build and open dist/LiveSub.app
```

### Useful scripts

```bash
./script/test.sh                     # backend tests, Swift checks and a debug build
./script/build_and_run.sh --verify   # build and verify the release .app without opening it
./script/package_release.sh          # package dist/LiveSub.app into a signed drag-to-install DMG
./script/render_design.sh            # render interface screenshots with sample text into design/previews/
dist/LiveSub.app/Contents/MacOS/LiveSub --prepare-runtime   # run first-launch setup without a window
```

### Project structure

| Folder | Contents |
|---|---|
| `app/LiveSub/MainWindow` · `App` | SwiftUI main window, first-launch setup, settings, menu bar and design tokens (`Theme.swift`) |
| `app/LiveSub/Overlay` | Transparent, non-activating, click-through floating caption panel |
| `app/LiveSub/Audio` | Microphone and ScreenCaptureKit capture, converted to 16 kHz mono PCM |
| `app/LiveSub/Subtitles` | Subtitle store, paragraph alignment, terminology settings |
| `app/LiveSub/Backend` | Python subprocess management and local WebSocket communication |
| `backend/livesub` | Qwen3-ASR recognition, translation scheduling, sessions and subtitle revisions |
| `shared/protocol.md` | Audio frame, state and subtitle event protocol |
| `design/` | Design direction, interface copy, QA records and icon explorations |

Test methods and data: [manual test matrix](docs/manual-test-matrix.md) and the [development & validation log](docs/development-log.md).

## License

LiveSub's source code is released under the [MIT License](LICENSE). Models are downloaded separately and keep their own licenses; see the [model manifest](docs/model-manifest.md).
