# Building mbl

Most people should install the signed build from [GitHub Releases](https://github.com/discorev/mbl/releases/latest). This page is for working on mbl itself.

## Requirements

- An Apple Silicon Mac running macOS 26 or later.
- A Swift 6.4 toolchain from Xcode or the Command Line Tools.
- Xcode, if you want to regenerate the app icon.

## Build and test

Build the executable with Swift Package Manager:

```sh
swift build
```

Run the persistence tests with:

```sh
scripts/test.sh
```

The script also prepares Sparkle's framework for the SwiftPM test runner.

## App bundle

Create an app bundle with:

```sh
scripts/bundle.sh
```

The script writes `build/mbl.app` and signs it with the first Apple Development identity in your keychain. If no identity is available, it exits with an error so rebuilding cannot silently invalidate macOS privacy grants. A stable Apple Development identity matters because an ad-hoc signature loses its Accessibility grant on every rebuild.

| Variable | Effect |
| --- | --- |
| `VOICE_SIGN_IDENTITY` | Sign with a specific identity instead of the first one found. |
| `VOICE_ALLOW_ADHOC_SIGNING=1` | Deliberately permit an ad-hoc signature. |
| `VOICE_VERSION` | Write both app version fields. Defaults to `0.0.0`. |
| `VOICE_RELEASE=1` | Use the first Developer ID Application identity, enable the hardened runtime, and add the Sparkle release feed. `VOICE_SIGN_IDENTITY` still overrides the identity. |

Open the bundle and grant Microphone, Input Monitoring, and Accessibility access when macOS prompts you. Local builds do not self-update.

## App icon

The app icon is committed as `assets/icon/Voice.icns` and `assets/icon/Assets.car`. Regenerate both from `assets/icon/mbl.svg` with:

```sh
scripts/make-icon.sh
```

This needs Xcode for `actool`.

## Companion window preview

For an isolated companion-window preview, run the debug executable with a temporary configuration directory:

```sh
VOICE_COMPANION_PREVIEW=1 VOICE_CONFIG_DIR=/tmp/mbl-preview .build/debug/Voice
```

This skips microphone, hotkey, model and updater startup. Set `VOICE_COMPANION_PREVIEW_UPDATE=available` or `downloaded` to inspect the update button; preview download and restart actions are simulated.

## Related

- [Releasing](release.md)
- [Configuration files](configuration.md)
