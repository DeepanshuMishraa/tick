# Add On-Device MLX AI Post-Processing

## Summary

Replace Groq-dependent post-processing with an explicitly downloaded, fully offline Apple Silicon model.

Recommended default: **Qwen3 1.7B MLX 4-bit**. It is Apache-2.0 licensed, supports multilingual instruction following, supports non-thinking mode for faster responses, and is approximately **914 MB**, making it much more suitable than a 4B model for Tick. [Model card](https://huggingface.co/Qwen/Qwen3-1.7B-MLX-4bit)

Use direct `mlx-swift-lm` integration rather than launching Python or VLC-like helper processes. MLX Swift LM supports Qwen3 architectures and model-container downloads/caching. [MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm), [supported models](https://github.com/ml-explore/mlx-swift-lm/blob/main/skills/mlx-swift-lm/references/supported-models.md)

## Implementation Changes

- Add `mlx-swift-lm` as a pinned Swift package dependency.
- Replace the Groq-only client with a local MLX post-processing client:
  - Load the model once and retain it in an actor-backed model container.
  - Download weights only from Settings.
  - Never download or invoke a model during dictation.
  - Run Qwen3 with `enable_thinking=false`.
  - Use a small output limit and deterministic generation for fast corrections.
  - Return only the corrected transcription, without explanations or markdown.
- Preserve the existing post-processing modes, including app-aware formatting and `AppContext`.
- Remove Groq API-key validation and Groq model selection from the active Settings flow.
- Add local model management matching the existing speech-model experience:
  - Download button.
  - Progress indicator.
  - Cancel.
  - Retry failed download.
  - Delete model.
  - Downloaded/available status.
  - Approximate disk size.
- Store the model inside Tick’s sandboxed application-support/cache directory.
- Keep transcription reliable if local AI is unavailable:
  - Paste the raw transcription immediately.
  - Log the local post-processing failure.
  - Never fall back to a cloud API or require an API key.
- Warm the model after download or when AI post-processing is enabled, so subsequent dictation does not pay model-loading cost.
- Add safeguards against output corruption:
  - Reject empty output.
  - Reject output containing reasoning blocks, explanations, or unexpected wrapper text.
  - Fall back to the original transcription if validation fails.
- Keep post-processing asynchronous and ensure model loading/generation never blocks recording or audio cleanup.

## Settings UX

- Rename the section to clearly indicate “Tick On-Device AI Post-Processing”.
- Show:
  - “Download Qwen3 1.7B”
  - Download progress and size.
  - “Ready” once installed.
  - “Delete Model” when installed.
  - Privacy text stating that transcription text remains on the Mac.
- Preserve Off/App-Aware behavior.
- If AI is enabled but the model is not downloaded, show an actionable Settings state instead of silently pretending processing occurred.
- Migrate existing Groq settings safely, but do not send existing transcriptions to Groq.

## Test Plan

- Unit-test provider behavior for:
  - AI disabled.
  - Model unavailable.
  - Successful local generation.
  - Empty/invalid model output.
  - Model loading failure.
  - App-aware prompts.
- Test model-manager download, cancellation, retry, deletion, and availability detection.
- Test that no network request or API-key lookup occurs in local mode.
- Test warm and cold generation paths.
- Test representative corrections:
  - Grammar and punctuation.
  - Filler-word removal.
  - Self-correction cleanup.
  - Code/terminal formatting.
  - App-aware formatting.
  - Multilingual text.
- Run `cd HexCore && swift test`.
- Build with `xcodebuild -scheme Hex -configuration Release`.
- Perform a manual Apple Silicon smoke test using both built-in speakers and Bluetooth audio, confirming local post-processing does not affect recording latency.

## Assumptions

- Local-only means Groq is removed from the active post-processing workflow.
- The first release targets all supported Apple Silicon Macs with Tick’s compact Qwen3 1.7B model.
- Explicit download from Settings is mandatory.
- The model must remain under approximately 1 GB where practical; Qwen3 1.7B is the initial choice.
- A future 4B model can be evaluated separately only if the compact model fails the Hex-specific correction test set.
- The implementation will include a user-facing changeset fragment as required by `AGENTS.md`.
