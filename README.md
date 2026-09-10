# mbl

Push-to-talk dictation for macOS that cleans up what you said before it types it.

## What it does

Hold right Option, talk, then release. mbl transcribes speech locally with NVIDIA Parakeet TDT v2 through FluidAudio. Transcription runs on the Neural Engine, and nothing leaves your Mac for speech-to-text.

A cleanup pass removes ums, false starts and self-corrections, applies British spelling, and honours your vocabulary list. It uses a warm Codex app-server on your ChatGPT subscription with `gpt-5.6-luna` by default. If Codex is unavailable, an on-device Apple Foundation Models fallback keeps cleanup working offline.

mbl types the result at your cursor with keyboard events. Dictation never touches your clipboard; the history window only copies text when you choose Copy text. A draggable HUD shows a live preview and animated indicator while you talk, and remembers its position for each display layout.

## Requirements

- An Apple Silicon Mac running macOS 26 or later.
- The `codex` CLI installed and logged in, if you want Codex cleanup. Without it, mbl uses the local model.
- Apple Intelligence enabled, if you want the local cleanup fallback.

## Install

1. Download `mbl-X.Y.Z.dmg` from the [latest release](https://github.com/discorev/mbl/releases/latest).
2. Open the disk image and drag mbl to Applications. Launch it from there, not from the disk image, otherwise macOS runs it from a read-only path and in-app updates cannot install.
3. Open mbl and grant Microphone, Input Monitoring, and Accessibility access when macOS prompts you. Input Monitoring enables the hotkey, and Accessibility enables typing.

To build from source instead, see [docs/build.md](docs/build.md).

## Using mbl

mbl lives in the menu bar. Hold right Option, speak, and release. The HUD shows a live preview while you hold the key and warns you if the input level is too low. Drag the HUD to move it; its position is remembered per display layout.

Choose **Open mbl** from the menu bar to open the companion window:

- **History** searches recent dictations and shows the final text alongside the original transcript, cleanup backend, and timings. Copy text explicitly when you need it again.
- **Vocabulary** adds or removes names and terms used during cleanup.
- **Replacements** adds or removes exact phrase substitutions for links, shortcuts and recurring mistakes. Rules match the final text, so add the wording that appears in history.
- **Cleanup** selects Codex or on-device cleanup, configures the local fallback, and edits each backend's instructions.
- **Settings** changes the push-to-talk key, resets the dictation indicator, shows permission status, and configures automatic update downloads.

Closing the window keeps dictation running in the menu bar without adding a persistent Dock icon. Everything the window edits is stored as plain files under `~/.config/voice`; use **Open config folder** in Settings to reach them. See [docs/configuration.md](docs/configuration.md) for the file formats.

## How it works

1. Capture microphone audio as 16 kHz mono while you hold right Option.
2. Run preview transcription every 500 ms while held. A speech gate skips previews during silence.
3. Run the final transcription when you release the key.
4. Clean the transcript with Codex, or with the local model when needed.
5. Apply configured text replacements, then type the result at the cursor with keyboard events.

The Codex app-server keeps a warm cleanup thread. mbl rotates it after a configured number of turns, or when the prompt or vocabulary changes.

## Status

mbl is a personal tool. It is English only and tuned for one person's voice. Issues are welcome, but no support is promised.

## Licence

[MIT](LICENSE)
