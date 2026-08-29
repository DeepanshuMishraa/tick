# Transcription latency architecture

## Target

For normal warm dictation on Apple Silicon, key release to one final processed insertion should be below one second at p95. Long dictation must preserve every segment and must never suppress the complete insertion because one AI segment failed.

Sub-millisecond end-to-end latency is not physically achievable. Audio finalization, ASR inference, model inference, and macOS input delivery each take measurable time. The product target is sub-second final insertion.

## Current bounded release pipeline

```text
on-demand AVAudioEngine capture
→ WAV persistence + FluidAudio streaming ASR
→ key release flushes only the ASR tail
→ deterministic normalization
→ adaptive semantic segments, at most 240 characters each
→ compact Qwen edit scripts, one Metal generation at a time
→ exact-substring edit validation
→ deterministic completion for invalid segments
→ ordered complete assembly
→ one final paste
```

Qwen returns only changes:

```json
{"edits":[{"old":"Formula Win","new":"Formula One"}]}
```

When no change is needed it returns `{"edits":[]}`. The model no longer copies the full transcript token by token. This bounds normal generation cost and makes latency depend on the number of edits rather than transcript length.

Each edit target must occur exactly once in its source segment. Overlapping edits, malformed JSON, unknown targets, severe truncation, reasoning output, and wrapper text are rejected. Hex does not retry an invalid script on the release path because deterministic retries doubled latency in measured runs. It applies deterministic filler, correction, and list normalization to that segment instead. Other valid segments remain intact, and the final insertion still contains the complete dictation.

Long input creates as many bounded segments as needed. Hex runs one Metal generation at a time. Four concurrent streams made individual generations 4–6 times slower in measured runs because they contended for the same model.

## Streaming and rolling work

Hex now uses one 16 kHz mono AVAudioEngine capture path for WAV persistence and FluidAudio `StreamingAsrManager`. Standard mode starts the engine only when the hotkey is pressed. Super Fast Capture keeps its optional prearmed behavior and remains disabled by default. If streaming setup or flush fails, the complete WAV remains available for batch ASR.

The remaining long-dictation optimization is rolling AI processing of confirmed ASR segments during recording:

```text
confirmed streaming ASR segment
→ deterministic normalization
→ compact Qwen edit script
→ ordered processed-segment store

key release
→ flush volatile ASR tail
→ process tail only
→ verify ordered segment coverage
→ one final paste
```

This removes all stable long-form AI work from the release path without showing or replacing provisional text.

## Acceptance gates

Measure warm runs on an M4:

- Normal dictation, 5–20 seconds: p50 below 700ms and p95 below 1,000ms from key release to paste event.
- Long dictation, 2–3 minutes: release work contains only the volatile tail and remains below 1,000ms at p95.
- Final assembled segment coverage: 100%.
- Empty insertion rate: 0% across 1,000 replayed fixtures.
- One invalid AI segment never cancels valid siblings or the final insertion.
- Model concurrency never exceeds one generation.
