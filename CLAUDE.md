# Tick – Dev Notes for Agents

This file provides guidance for coding agents working in this repo.

## Project Overview

Tick is a macOS menu bar app for on-device voice-to-text, written in Rust with GPUI (via `gpui-kit`). Users hold or double-tap a hotkey to dictate; the text is formatted and pasted into the active app.

## Layout

- `crates/tick-core` – platform-free logic: settings (JSON-compatible with the old Swift app), history, hotkey processor, text rules, AI prompts, stats.
- `crates/tick-app` – the app: GPUI UI (`ui/`), app state and dictation flow (`state/`), audio capture (`audio/`), synthesized sound cues (`sound/`), macOS integration (`platform/`), on-disk storage (`storage.rs`).
- `native/TickNative` – a small Swift bridge, exposed over a C ABI (`CAPI.swift`), for what has no Rust equivalent: WhisperKit, FluidAudio (Parakeet), MLX on-device LLM, PermissionFlow and Sparkle. `crates/tick-app/build.rs` builds it with xcodebuild; set `TICK_SKIP_NATIVE_BUILD=1` to skip.
- `resources/` – `models.json`, `languages.json`, entitlements, app icon.

## Commands

```bash
cargo build -p tick-app          # build
cargo test -p tick-core          # unit tests
scripts/bundle.sh [release]      # assemble + sign the .app under target/bundle/
scripts/build-dmg.sh             # release bundle → tick.dmg
```

Releases: publishing a GitHub release tagged `vX.Y.Z` runs `.github/workflows/release.yml`, which builds `tick.dmg`, attaches it plus a signed Sparkle `appcast.xml` (the app's feed is `releases/latest/download/appcast.xml`), and bumps the cask in `DeepanshuMishraa/homebrew-tap`.

## Implementation Notes

1. **Hotkeys**: press-and-hold and double-tap lock, in `crates/tick-core/src/hotkey_processor.rs`. See `docs/hotkey-semantics.md`. Modifier-only hotkeys use a 0.3 s threshold; regular hotkeys use the `minimumKeyTime` setting.
2. **Overlays** (`ui/overlay.rs`): notch indicator, floating pill (default), and the feedback notice ("added to dictionary", "couldn't paste"). They are GPUI pop-up windows (NSPanels) configured in `platform/windows.rs`; they must not hide when Tick is inactive.
3. **Logging**: use `tracing` with a consistent `target:` (e.g. `"transcription"`, `"hotkey"`, `"settings"`). Never log transcript text or file paths at info level.
4. **UI**: square corners everywhere, minimal. Colors and type sizes come from `ui/theme.rs`; shared pieces from `ui/components.rs`.

## Storage

- App data: `~/Library/Application Support/com.dipxsy.Tick/` (`tick_settings.json`, `transcription_history.json`, `Recordings/`, `models/`, `cache/`). A legacy `hex_settings.json` is renamed on first launch.
- Parakeet caches under `cache/` because `XDG_CACHE_HOME` is set at launch.
- Groq API key: keychain service `com.dipxsy.tick.groq` (migrated from `com.dipxsy.Hex.groq`).

## Changelog Workflow

1. Any user-facing change ships with a `.changeset/*.md` fragment mentioning the impact and issue/PR number.
2. Agents create fragments non-interactively:
   ```bash
   bun run changeset:add-ai patch "Your summary here"
   ```
3. Only create changesets; don't run `changeset version`.

## Git Commit Messages

- Concise subject (50–70 chars) describing the user-facing impact.
- Body with rationale, tradeoffs and repro steps as needed. Reference issues ("Fixes #123").
