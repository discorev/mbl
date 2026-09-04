# mbl

Push-to-talk dictation for macOS that cleans up what you said before it types it.

## What it does

Hold right Option, talk, then release. mbl transcribes speech locally with NVIDIA Parakeet TDT v2 through FluidAudio. Transcription runs on the Neural Engine, and nothing leaves your Mac for speech-to-text.

A cleanup pass removes ums, false starts and self-corrections, applies British spelling, and honours your vocabulary list. It uses a warm Codex app-server on your ChatGPT subscription with `gpt-5.6-luna` by default. If Codex is unavailable, an on-device Apple Foundation Models fallback keeps cleanup working offline.

mbl types the result at your cursor with keyboard events. Dictation never touches your clipboard; the history window only copies text when you choose Copy text. A draggable HUD shows a live preview and animated indicator while you talk, and remembers its position for each display layout.

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

Run the persistence tests with `scripts/test.sh`. The script also prepares Sparkle’s framework for the SwiftPM test runner.

Create an app bundle with:

```sh
scripts/bundle.sh
```

The script writes `build/mbl.app` and signs it with the first Apple Development identity in your keychain. If no identity is available, it exits with an error so rebuilding cannot silently invalidate macOS privacy grants. You can select a specific identity with `VOICE_SIGN_IDENTITY`, or deliberately permit an ad-hoc signature with `VOICE_ALLOW_ADHOC_SIGNING=1 scripts/bundle.sh`. The bundle version defaults to `0.0.0`; set `VOICE_VERSION` to write both app version fields. Set `VOICE_RELEASE=1` to use the first Developer ID Application identity, enable the hardened runtime, and add the Sparkle release feed; `VOICE_SIGN_IDENTITY` still overrides the selected identity.

Open the app and grant Microphone, Input Monitoring, and Accessibility access when macOS prompts you. Input Monitoring enables the hotkey, and Accessibility enables typing.

A stable Apple Development identity matters because an ad-hoc signature loses its Accessibility grant on every rebuild.

The app icon is committed as `assets/icon/Voice.icns` and `assets/icon/Assets.car`. Run `scripts/make-icon.sh` to regenerate both from `assets/icon/mbl.svg`; it needs Xcode for `actool`.

## Releases

Create and push a version tag:

```sh
git tag vX.Y.Z
git push origin vX.Y.Z
```

The release workflow signs and notarizes the app, then publishes `mbl-X.Y.Z.dmg` for people, plus `mbl-X.Y.Z.zip` and `appcast.xml` for in-app updates. Drag mbl to Applications from the disk image before first launch, otherwise macOS runs it from a read-only translocated path and in-app updates cannot install. Local builds do not self-update.

The following secrets live in the GitHub `release` environment, which is restricted to `v*` tags:

- `DEVID_P12_BASE64`
- `DEVID_P12_PASSWORD`
- `ASC_KEY_ID`
- `ASC_ISSUER_ID`
- `ASC_KEY_P8`

## Configuration

mbl creates `~/.config/voice/config.json` on first launch. Changes to this file are picked up automatically while mbl runs.

| Key | Default | Purpose |
| --- | --- | --- |
| `hotkey` | `rightOption` | Push-to-talk key: `rightOption` or `rightControl`. |
| `backend` | `codex` | Primary cleanup backend: `codex` or `local`. |
| `codexModel` | `gpt-5.6-luna` | Model used by Codex. |
| `codexThreadMaxTurns` | `50` | Cleanup turns before rotating the warm thread. |
| `fallback` | `local` | Behaviour after Codex fails: `local` or `none`. |
| `minWordsForCleanup` | `4` | Shorter transcripts skip cleanup. |
| `cleanupTimeoutSeconds` | `6` | Codex cleanup timeout. |
| `previewTickMs` | `500` | Live preview interval in milliseconds. |
| `hudBottomInset` | `80` | Default HUD distance from the bottom of the display. |
| `minInputVolume` | `0.5` | Input level below which the HUD warns you. |
| `autoDownloadUpdates` | `false` | Download updates as soon as they are found; installing still needs a click. |

Cleanup prompts live in `~/.config/voice/prompts/<model>.md`. The supplied files are `5-6-luna.md` and `macos-26.md`. You can edit them while mbl is running; the changes apply without a restart.

Add names and terms to `~/.config/voice/vocab.txt`, one term per line. Blank lines and lines beginning with `#` are ignored.

Each utterance adds one line to `~/.config/voice/history.jsonl` with the raw and cleaned text, backend, and timings. Use it to tune your prompts.

Choose **Open mbl** from the menu bar to open the companion window:

- **History** searches recent dictations and shows the final text alongside the original transcript, cleanup backend, and timings. Copy text explicitly when you need it again.
- **Vocabulary** adds or removes names and terms used during cleanup.
- **Cleanup** selects Codex or on-device cleanup, configures the local fallback, and edits each backend’s instructions.
- **Settings** changes the push-to-talk key, resets the dictation indicator, shows permission status, and configures automatic update downloads.

Closing the window keeps dictation running in the menu bar without adding a persistent Dock icon. The sidebar shows the installed version. When an update is available, a small download button appears beside it; once downloaded, it becomes an install-and-restart button. Local builds without an update feed do not show update actions.

The menu bar retains the version, update action, HUD reset, and Quit. Use **Open config folder** in Settings to access settings, prompts, vocabulary and history. You can edit these files directly; the window writes to these same files.

For an isolated companion-window preview, run the debug executable with a temporary configuration directory:

```sh
VOICE_COMPANION_PREVIEW=1 VOICE_CONFIG_DIR=/tmp/mbl-preview .build/debug/Voice
```

This skips microphone, hotkey, model and updater startup. Set `VOICE_COMPANION_PREVIEW_UPDATE=available` or `downloaded` to inspect the update button; preview download/restart actions are simulated.

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
