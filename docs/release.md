# Releasing mbl

Create and push a version tag:

```sh
git tag vX.Y.Z
git push origin vX.Y.Z
```

The release workflow signs and notarizes the app, then publishes three assets to the GitHub release:

- `mbl-X.Y.Z.dmg` for people to install from.
- `mbl-X.Y.Z.zip` for in-app updates.
- `appcast.xml`, the Sparkle feed that points at the zip.

## Pre-releases

A tag with a pre-release suffix such as `v0.8.0-beta.1` is published as a GitHub pre-release. The app's feed follows the latest full release, so nobody on a release build is offered a beta; install it from the pre-release's DMG. Versions are compared as semantic versions, so a beta build is offered the final release when it ships.

## Local release builds

`VOICE_RELEASE=1 scripts/bundle.sh` and `VOICE_RELEASE=1 scripts/make-dmg.sh` produce the same signed bundle and disk image locally, without notarization. See [build.md](build.md) for the signing variables.
