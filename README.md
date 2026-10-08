# EchoWave

Voice dictation for macOS, in the spirit of Wispr Flow. A small floating button sits on top of
every app: click it (or press **⌥Space**) and speak, and your words are typed wherever your cursor is.

Transcription runs **entirely on your Mac** with Apple's on-device speech model (macOS 26
`SpeechAnalyzer`). Nothing to sign up for, no API keys, and your voice never leaves the computer.

## Features

- **Floating button**: always on top, on every Space and over full-screen apps. Drag it anywhere;
  it never steals focus from the app you're typing in. It shows a live waveform and timer while
  you talk, and a live transcript bubble above it.
- **Global hotkey** (default **⌥Space**, configurable):
  - *Tap or hold* (default): tap to start and tap again to stop, or hold while speaking and release.
  - *Toggle* or *Hold to talk* modes if you prefer one behavior.
  - Optional **single-key trigger**: fn / 🌐, right ⌥, right ⌘ or right ⌃.
  - **Esc** cancels a dictation.
- **Fast, accurate, punctuated** transcripts (about 0.5 s for a 10-second clip on Apple silicon).
- **Pastes into any app**, then puts your previous clipboard back.
- **Vocabulary**: names and jargon to keep spelled right, plus `spoken -> written` replacements.
- 30+ languages (the model downloads automatically the first time you pick one).
- Microphone picker, sounds, launch at login, transcript history, and a menu bar menu with
  *Paste Last Transcript*.

## Requirements

- macOS 26 (Tahoe) or later
- Apple silicon recommended
- Xcode *or* just the Command Line Tools (`xcode-select --install`)

## Build & run

```bash
make run        # builds build/EchoWave.app and opens it
make install    # copies it to /Applications and opens it
```

Other targets: `make app` (build only), `make icon` (regenerate the icon), `make clean`.
You can also open `Package.swift` in Xcode to edit and debug.

## First launch

EchoWave lives in the menu bar (waveform icon) and shows the floating button at the bottom of
your screen. On first launch it opens **Settings → Permissions**, where you grant:

1. **Microphone**: so it can hear you.
2. **Accessibility**: so it can paste into other apps (and see the single-key trigger).
   Without it, transcripts are copied to the clipboard instead.

> **Rebuilding?** macOS ties permissions to the exact build of an app. With no Apple developer
> certificate the app is signed *ad hoc*, so after a rebuild EchoWave can look switched on in
> System Settings while EchoWave itself still says it isn't. Click **Grant…** in EchoWave again:
> it clears the old entry (`tccutil reset Accessibility com.echowave.EchoWave`) and asks again.
> If you have an Apple Development certificate, the build script uses it automatically and
> permissions persist (or set `CODESIGN_IDENTITY="…"`).

## Using it

| Action | How |
| --- | --- |
| Start dictating | Click the button, tap **⌥Space**, or hold **⌥Space** |
| Finish & insert | Click again, tap **⌥Space** again, or release it |
| Cancel | **Esc** |
| Move the button | Drag it |
| More options | Right-click the button, or use the menu bar icon |

If you use **fn** as the trigger, set **System Settings → Keyboard → “Press 🌐 key to” → Do Nothing**
so macOS doesn't also open the emoji picker or Apple's dictation.

## How it works

```
 hotkey / click ─▶ DictationController ─▶ AudioRecorder (AVAudioEngine)
                          │                     │ 48 kHz buffers
                          │                     ▼
                          │              TranscriptionSession ─▶ SpeechAnalyzer + SpeechTranscriber
                          │                     │ live + final text        (on-device model)
                          ▼                     ▼
                   TranscriptFormatter ─▶ TextInserter (clipboard + ⌘V) ─▶ the app you're typing in
```

| Path | What's there |
| --- | --- |
| `Sources/EchoWave/App` | App entry point, menus, `--transcribe` test mode |
| `Sources/EchoWave/Core` | Dictation state machine, text insertion, vocabulary, history, permissions, settings |
| `Sources/EchoWave/Audio` | Microphone capture, level metering, input-device selection |
| `Sources/EchoWave/Speech` | Model management (`SpeechEngine`) and the streaming session |
| `Sources/EchoWave/Hotkeys` | Carbon global hotkeys, fn / right-modifier monitor, tap-vs-hold logic |
| `Sources/EchoWave/UI` | Floating button, menu bar item, Settings window |

### Testing transcription without a microphone

The app binary can stream an audio file through the same pipeline the microphone uses:

```bash
say -o /tmp/test.aiff "Testing EchoWave, one two three."
build/EchoWave.app/Contents/MacOS/EchoWave --transcribe /tmp/test.aiff   # optional: --locale fr_FR
```

## Ideas for later

- AI cleanup and rewriting of transcripts (remove filler words, change tone) through an LLM
- Per-app styles (casual in Messages, formal in Mail)
- Voice commands ("new line", "delete that")
- A cloud transcription engine option for unsupported languages
