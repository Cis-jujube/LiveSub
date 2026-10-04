# LiveSub local protocol (version 1)

The app starts one backend process, which binds only to `127.0.0.1` on an
ephemeral port. It announces a single JSON ready line on stdout:
`{"kind":"ready","version":1,"port":12345}`. Logs go to stderr and must not
contain audio or transcript text. The app generates a random token for every
launch, passes it in the child environment, and connects with an
`Authorization: Bearer <token>` WebSocket header. The token is never printed.

All application messages are JSON text frames. Audio is base64-encoded PCM16
little endian inside a JSON message. At 160 ms per frame this is approximately
32 KB/s before base64; simplicity and strict validation outweigh the small
local overhead. A final partial frame is allowed at stop or source switch.

## Commands from the app

`start`: `{"kind":"start","session_id":"uuid","generation":1,
"source_language":"en","target_language":"zh"}`. Source is chosen in Swift
and does not cause a second backend stream. A duplicate start is a no-op.

`audio`: `{"kind":"audio","session_id":"uuid","generation":1,
"sequence":0,"start_sample":0,"sample_rate":16000,"channels":1,
"pcm16":"<base64>","speaker_id":"A"}`. Frames are mono, 16 kHz, PCM16 and normally 2560 samples.
The backend rejects malformed or out-of-order frames before model inference.
`speaker_id` is optional (`A`–`E`); null means the detector could not assign a voice.

`select_speakers`: `{"kind":"select_speakers","session_id":"uuid",
"generation":1,"speaker_ids":["A","C"]}`. The list accepts up to five distinct
IDs. Null selects all speakers. Selection affects subsequent translation work;
the source transcript still records other detected speakers. A resumed generation
must send the selection again before sending audio.

`pause`, `resume`, `stop`: carry `session_id` and `generation`. For `resume`,
`generation` is the new generation and `source_language` / `target_language`
are required so that source or direction changes take effect without creating
a second backend session. Resume requires a strictly newer generation and audio
sequence/sample offset restart at zero. Pause and stop identify the current
generation; stale control messages are rejected.
Pausing or stopping flushes received audio; the app stops native capture first.

## Events from the backend

`state`: `{"kind":"state","session_id":"uuid","generation":1,
"state":"listening","detail":null}`. States are `idle`, `loading`,
`listening`, `paused`, `stopping`, and `error`.

`subtitle`: `{"kind":"subtitle","segment":{...}}`, where the segment has:

- Identity: `session_id`, `generation`, `segment_id`, `sequence`.
- Approximate audio times: `start_ms`, `end_ms`, relative to the current
  generation's accepted audio. These are not word-level timestamps.
- Direction: `source_language` and `target_language` (`en` or `zh`).
- Source: `source_text`, `source_revision`, `source_final`.
- Optional speaker: `speaker_id` (`A`–`E` or null).
- Translation: `target_text`, `translated_source_text`,
  `translated_source_revision`, and `translation_state` (`pending`, `preview`,
  `final`, `failed`, `skipped`). `skipped` means the speaker was not selected;
  its target fields are empty.

The source can change while a segment is active. A translation must carry the
exact source snapshot and revision it translated. The main window shows the
latest source and marks an older translation as updating; the overlay shows
the paired translated source snapshot and target. After a final source update,
stale previews are rejected. An earlier valid preview may be shown while an
active source continues to grow. A newer revision never regresses to an older
revision.

`error`: `{"kind":"error","code":"audio_overflow","detail":"..."}`.
Errors are specific and never imply that recording is still healthy. Audio
buffering is limited to five seconds. The final translation queue is limited
to 32 tasks; overflow pauses capture visibly rather than discarding history.
