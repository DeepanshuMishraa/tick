# Qwen3 0.6B MLX 4-bit benchmark

## Environment

- Device: Apple M4, 10 cores, 16 GB RAM
- OS: macOS 26.5.2 (build 25F84)
- Model: `Qwen3-0.6B-MLX-4bit`
- Quantization: MLX 4-bit
- AI mode: enabled, non-thinking mode
- ASR: Parakeet TDT v3 CoreML
- Recording mode: standard
- Target app: Ghostty
- Captured: 2026-08-29

## Pre-pipeline baseline

| Audio | Key release → raw result | Qwen preparation | Qwen generation | AI total | Paste transport | Total |
|---:|---:|---:|---:|---:|---:|---:|
| 16.69s | 546ms | 17ms | 1,405ms | 1,425ms | 258ms | **2,230ms** |

- Input: 322 characters across four ordinary prose sentences.
- Output: 271 validated characters.
- Qwen model access: 0ms; model and Metal kernels were warm.
- Parakeet initialization: 330ms.
- Parakeet inference: 210ms.
- Ghostty's paste measurement includes the 180ms clipboard-restoration safety window after Cmd-V is posted.

## Architectural conclusion

The serial pipeline spends 64% of measured latency autoregressively rewriting independent sentences. Reducing model size alone does not remove that dependency chain. The revised pipeline therefore:

1. Preloads the selected speech model while Hex is idle, removing model initialization from key-release latency.
2. Detects ordinary multi-sentence prose and balances it into at most four independent chunks.
3. Runs chunk generations concurrently against the already-loaded MLX container.
4. Validates every chunk independently and retries only the failed chunk.
5. Keeps emails, lists, explicit layout commands, and multiline input on the single global-context path.
6. Joins validated chunks in source order and performs one final insertion.

This is not optimistic/raw insertion: Hex still inserts exactly one final AI-processed transcript.

## First post-pipeline measurements

Warm short-dictation runs before the load-race fix:

| Raw result | AI total | Paste transport | Measured total |
|---:|---:|---:|---:|
| 117ms | 678ms | 205ms | **1,001ms** |
| 121ms | 1,002ms, including invalid-output retry | 216ms | **1,341ms** |
| 149ms | 807ms | 210ms | **1,168ms** |
| 88ms | 496ms | 215ms | **801ms** |

These runs confirm that warm Parakeet inference is already 88–149ms and a valid first-pass short completion can produce an 801ms measured result. The paste measurement still includes the 180ms clipboard restoration wait after Cmd-V is posted.

The same run exposed a startup race: Core ML and MLX compilation started together, then transcription entered a second Parakeet load while the first was suspended. Two FluidAudio loads compiled the same assets concurrently and delayed the first raw result by 10.53s. Parakeet loading now uses one shared in-flight task, and startup warms Core ML before MLX to avoid backend compilation contention.

Short prose in Ghostty also inherited strict terminal-command instructions, which led the 0.6B model to emit empty two-character artifacts. Terminal context now applies only to command-like dictation, and the prompt no longer mentions `EMPTY` for non-empty input.

## Compact edit-script experiment findings

A first JSON edit-script implementation still reused the full formatting prompt, retried invalid output, and ran four MLX streams concurrently. Runtime traces showed why that design was slower:

- Short inputs: invalid first generations took 1,241–1,299ms; retry raised AI wall time to 2,030–2,581ms.
- One-minute input: six segments, with four concurrent Metal generations taking 4,522–7,379ms each.
- Complete AI wall time: 13,458ms. Three invalid segments completed deterministically, so no text was lost.
- Warm Parakeet remained fast: 141–481ms.
- Clipboard events posted in 22–48ms; the larger paste transport number was delayed restoration, not insertion latency.

The corrected design uses a dedicated concise edit prompt, one Metal generation at a time, a 96-token hard ceiling, and no synchronous release-path retry. Invalid scripts complete immediately through the deterministic processor. Streaming Parakeet now processes audio during recording through the same on-demand AVAudioEngine path that persists the WAV.

## Next measurement

Repeat both a short prose input and a one-minute input after rebuilding. Capture:

- `Parakeet prewarmed`
- `Key-release-to-raw-result`
- `Qwen parallel pipeline chunks=`
- each `Qwen model=... chunk=... generationMs=` line
- `Accepted parallel on-device AI output ... durationMs=`
- `totalKeyReleaseToPasteMs=`

The first acceptance gate is lower AI wall time than the slowest chunk rather than the sum of all sentence output lengths. The end target remains a sub-second key-release-to-final-insertion path on an M4 for normal dictation.
