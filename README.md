# Tick — Voice → Text

Press-and-hold a hotkey to transcribe your voice and paste the result wherever you're typing.

**[Download Tick for macOS](https://github.com/DeepanshuMishraa/tick/releases/latest/download/tick.dmg)**

> **Note:** Tick only runs on **Apple Silicon** Macs.

Or install with Homebrew:
```bash
brew install --cask deepanshumishraa/tap/tick
```

Tick is a native Rust app built with [GPUI](https://www.gpui.rs). English dictation uses [Parakeet Unified](https://github.com/handy-computer/parakeet-unified-en-0.6b-gguf), which transcribes while you speak. Other languages use [Parakeet TDT v3](https://github.com/FluidInference/FluidAudio). [WhisperKit](https://github.com/argmaxinc/WhisperKit) models are there too.

## Instructions

When you first open Tick, grant it microphone and accessibility permissions. The microphone records your voice; accessibility lets Tick paste the text into any app.

Once you've set a global hotkey, there are **two recording modes**:

1. **Press-and-hold** the hotkey to begin recording, say whatever you want, and then release the hotkey to start the transcription process.
2. **Double-tap** the hotkey to *lock recording*, say whatever you want, and then **tap** the hotkey once more to start the transcription process.

## Building

```bash
scripts/bundle.sh            # debug build → target/bundle/debug/tick Debug.app
scripts/bundle.sh release    # release build → target/bundle/release/tick.app
scripts/build-dmg.sh         # release build packaged as tick.dmg
cargo test -p tick-core      # unit tests
```

## Contributing

**Issue reports are welcome!** If you hit a bug or want a feature, please [open an issue](https://github.com/DeepanshuMishraa/tick/issues).

For pull requests, please open an issue first so we can discuss the change before you invest time in it.

### Changelog workflow

- **For AI agents:** Run `bun run changeset:add-ai <type> "summary"` (e.g., `bun run changeset:add-ai patch "Fix clipboard timing"`) to create a changeset non-interactively.
- **For humans:** Run `bunx changeset` when your PR needs release notes. Pick `patch`, `minor`, or `major` and write a short summary. This creates a `.changeset/*.md` fragment.
- Check what will ship with `bunx changeset status --verbose`.

## License

This project is licensed under the MIT License. See `LICENSE` for details.
