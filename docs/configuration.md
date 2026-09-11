# Configuration files

The companion window is the normal way to change settings. Everything it edits lives as plain files under `~/.config/voice`, and mbl picks up changes to them while it runs. This page documents the files for when you want to edit them directly or script against them.

## config.json

Created on first launch.

| Key | Default | Purpose |
| --- | --- | --- |
| `hotkey` | `{"modifiers":["rightOption"]}` | Push-to-talk shortcut with one or more modifiers and an optional `keyCode`. |
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

`hotkey.modifiers` accepts `command`, `option`, `control`, `shift`, and `fn`, plus `leftCommand`, `rightCommand`, `leftOption`, `rightOption`, `leftControl`, `rightControl`, `leftShift`, and `rightShift`. Add a layout-independent macOS virtual `keyCode` for a modifier-plus-key shortcut, for example `{"modifiers":["control","option"],"keyCode":49}` for Control-Option-Space. Sided modifiers stay side-specific on their own; modifier-plus-key shortcuts accept either side. A shortcut must include at least one modifier and use no more than three keys total. Keyboards that handle Fn in firmware never send it to macOS, so Fn cannot be recorded on those keyboards.

## prompts/

Cleanup prompts live in `prompts/<model>.md`. The supplied files are `5-6-luna.md` and `macos-26.md`. Edits apply without a restart.

## vocab.json

Names, terms and replacement rules live together:

```json
{
  "terms": ["Ollie", "mbl"],
  "replacements": [
    { "phrase": "the github repo", "replacement": "https://github.com/discorev/mbl/" }
  ]
}
```

Replacements apply after cleanup and also to short dictations or raw fallback output. Matching ignores case, respects word boundaries, and treats phrases literally. At each match, the longest phrase wins; inserted text is never replaced again. An empty replacement removes the phrase.

An older `vocab.txt` is migrated into `vocab.json` automatically on launch and then deleted. Invalid files are reported without being overwritten.

## history.jsonl

Each utterance adds one line with the raw and cleaned text, backend, and timings. Use it to tune your prompts.
