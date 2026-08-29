# Qwen3 1.7B MLX 4-bit benchmark

## Environment

- Device: Apple M4, 10 cores, 16 GB RAM
- OS: macOS 26.5.2 (build 25F84)
- Model: `Qwen3-1.7B-MLX-4bit`
- Quantization: MLX 4-bit
- AI mode: enabled, non-thinking mode
- ASR: Parakeet TDT v3 CoreML
- Recording mode: standard
- Measurement: key release → paste
- Captured: 2026-08-29

## Results

| Run | Audio | Key release → raw result | Qwen post-processing | Paste | Total key release → paste |
|---|---:|---:|---:|---:|---:|
| 1 (first request / Metal compilation) | 1.82s | 435ms | 2,083ms | 32ms | **2,551ms** |
| 2 (warm) | 13.88s | 120ms | 1,383ms | 18ms | **1,522ms** |

### Internal stage timings

- Parakeet model load on first request: 300ms
- Parakeet transcription: 110–120ms once loaded
- Parakeet clip preparation: 0ms
- Recording handoff: 7–11ms
- Qwen model access after warm-up: 0ms
- Qwen prompt preparation: 18–36ms
- Qwen generation event consumption: 288–554ms
- Qwen first request also incurred MLX Metal kernel compilation; the original generation timer did not include generation setup, so total Qwen duration is the authoritative figure.
- Paste transport: 18–32ms

## Quality samples

- Input: `A level of the`
- Qwen output: accepted final output of 10 characters
- Input: `Yeah, which is what you're selling for in charge of the formula one driver.`
- Qwen output: accepted final output of 75 characters

Both outputs passed the existing output validator.

## Baseline conclusion

Parakeet and paste are not the bottleneck. Warm Qwen post-processing accounts for approximately 1.38s of a 1.52s total, while the first request can reach 2.55s due to Metal compilation. This is the baseline for comparing smaller local models, especially Qwen3 0.6B.

## Caveats

- This is a small real-world sample, not a statistically significant benchmark.
- The benchmark was captured before the shared Qwen warm-task/kernel-prewarm refinement was validated in a fresh run.
- Candidate models must be tested with the same prompts, inputs, app context, and warm/cold protocol.
