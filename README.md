# mbl

Push-to-talk dictation for macOS that cleans up what you said before it types it.

## What it does

Hold right Option, talk, then release. mbl transcribes speech locally with NVIDIA Parakeet TDT v2 through FluidAudio. Transcription runs on the Neural Engine, and nothing leaves your Mac for speech-to-text.

A cleanup pass removes ums, false starts and self-corrections, applies British spelling, and honours your vocabulary list. It uses a warm Codex app-server on your ChatGPT subscription with `gpt-5.6-luna` by default. If Codex is unavailable, an on-device Apple Foundation Models fallback keeps cleanup working offline.

mbl types the result at your cursor with keyboard events. It never touches your clipboard. A draggable HUD shows a live preview and animated indicator while you talk, and remembers its position for each display layout.

## Requirements

- An Apple Silicon Mac running macOS 26 or later.
- A Swift 6.4 toolchain from Xcode or the Command Line Tools.
- The `codex` CLI installed and logged in, if you want Codex cleanup. Without it, mbl uses the local model.
- Apple Intelligence enabled, if you want the local cleanup fallback.

## Build and run

Build the executable with Swift Package Manager:

```sh
swift build
```

Create an app bundle with:

```sh
scripts/bundle.sh
```

The script writes `build/Voice.app` and signs it with the first Apple Development identity in your keychain. If no identity is available, it exits with an error so rebuilding cannot silently invalidate macOS privacy grants. You can select a specific identity with `VOICE_SIGN_IDENTITY`, or deliberately permit an ad-hoc signature with `VOICE_ALLOW_ADHOC_SIGNING=1 scripts/bundle.sh`.

Open the app and grant Microphone, Input Monitoring, and Accessibility access when macOS prompts you. Input Monitoring enables the hotkey, and Accessibility enables typing.

A stable Apple Development identity matters because an ad-hoc signature loses its Accessibility grant on every rebuild.

## Configuration

mbl creates `~/.config/voice/config.json` on first launch.

| Key | Default | Purpose |
| --- | --- | --- |
| `hotkey` | `rightOption` | Push-to-talk key: `rightOption` or `rightControl`. Restart mbl after changing it. |
| `backend` | `codex` | Primary cleanup backend: `codex` or `local`. |
| `codexModel` | `gpt-5.6-luna` | Model used by Codex. |
| `codexThreadMaxTurns` | `50` | Cleanup turns before rotating the warm thread. |
| `fallback` | `local` | Behaviour after Codex fails: `local` or `none`. |
| `minWordsForCleanup` | `4` | Shorter transcripts skip cleanup. |
| `cleanupTimeoutSeconds` | `6` | Codex cleanup timeout. |
| `previewTickMs` | `500` | Live preview interval in milliseconds. |
| `hudBottomInset` | `80` | Default HUD distance from the bottom of the display. |
| `minInputVolume` | `0.5` | Input level below which the HUD warns you. |

Cleanup prompts live in `~/.config/voice/prompts/<model>.md`. The supplied files are `5-6-luna.md` and `macos-26.md`. You can edit them while mbl is running; the changes apply without a restart.

Add names and terms to `~/.config/voice/vocab.txt`, one term per line. Blank lines and lines beginning with `#` are ignored.

Each utterance adds one line to `~/.config/voice/history.jsonl` with the raw and cleaned text, backend, and timings. Use it to tune your prompts.

The menu bar menu can open the config folder, open the history file, and reset the HUD position.

## How it works

1. Capture microphone audio as 16 kHz mono while you hold right Option.
2. Run preview transcription every 500 ms while held. A speech gate skips previews during silence.
3. Run the final transcription when you release the key.
4. Clean the transcript with Codex, or with the local model when needed.
5. Type the result at the cursor with keyboard events.

The Codex app-server keeps a warm cleanup thread. mbl rotates it after the configured number of turns, or when the prompt or vocabulary changes.

## Status

mbl is a personal tool. It is English only and tuned for one person's voice. Issues are welcome, but no support is promised.

## Licence

[MIT](LICENSE)
