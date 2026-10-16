# Transcription latency architecture

## Target

For normal warm dictation on Apple Silicon, key release to one final processed insertion should be below one second at p95. Long dictation must preserve every segment and must never suppress the complete insertion because one AI segment failed.

Sub-millisecond end-to-end latency is not physically achievable. Audio finalization, ASR inference, model inference, and macOS input delivery each take measurable time. The product target is sub-second final insertion.

## Current release pipeline

```text
on-demand AVAudioEngine capture
→ WAV persistence + FluidAudio streaming ASR
→ key release flushes only the ASR tail
→ deterministic normalization
→ online: Groq edit script with a 5-second total HTTP deadline
→ no cloud key: adaptive semantic segments targeting 240 characters
→ compact local Qwen edit scripts, one Metal generation at a time
→ exact-substring edit validation
→ deterministic completion for invalid segments
→ ordered complete assembly
→ one final paste
```

Qwen returns only changes:

```json
{"edits":[{"old":"Formula Win","new":"Formula One"}]}
```

When no change is needed it returns `{"edits":[]}`. The model no longer copies the full transcript token by token. Local generation now stops at the first complete script accepted by the existing exact-edit and output validators, rather than waiting for EOS or the remaining token budget. Tick explicitly cancels and joins the MLX producer before processing the next segment. Invalid or incomplete JSON does not trigger early completion.

Groq retains the selected model. Its HTTP transport has a 5-second total deadline so slow cloud responses are awaited instead of abandoned, while a stall can never hold the paste path hostage. Expiry cancels the URLSession data task and returns without waiting for its callback. Partial response bytes cannot extend the deadline. Parent cancellation propagates instead of proceeding to paste. Groq still uses non-streaming responses; no provisional text is inserted.

When a Groq key is configured, a genuine cloud failure returns control to the transcription feature instead of starting unbounded local generation. The feature then uses the existing deterministic cleanup and proceeds to paste. ASR and paste time are additional, so the deadline does not guarantee a fixed release-to-paste latency.

Each edit target must occur exactly once in its source segment. Overlapping edits, malformed JSON, unknown targets, severe truncation, reasoning output, and wrapper text are rejected. Tick does not retry an invalid script on the release path because deterministic retries doubled latency in measured runs. It applies deterministic filler, correction, and list normalization to that segment instead. Other valid segments remain intact, and the final insertion still contains the complete dictation.

Long input creates as many bounded segments as needed. Tick runs one Metal generation at a time. Four concurrent streams made individual generations 4–6 times slower in measured runs because they contended for the same model.

## Streaming and rolling work

Tick now uses one 16 kHz mono AVAudioEngine capture path for WAV persistence and FluidAudio `StreamingAsrManager`. Standard mode starts the engine only when the hotkey is pressed. Super Fast Capture keeps its optional prearmed behavior and remains disabled by default. If streaming setup or flush fails, the complete WAV remains available for batch ASR.

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

## Verification and remaining bottlenecks

Deterministic offline tests exercise the same HTTP transport and model-stream consumer used by the app:

- A stalled URLProtocol request exceeded a 500ms test watchdog before the deadline change. With a 40ms injected deadline it completes and cancels the transport in roughly 43–49ms, including a partial-response case.
- A model-stream fixture yielded a valid script and then delayed EOS by two seconds. The previous consumer waited approximately 2.29s. The new consumer returns immediately after validating the script and joining the cancelled producer.
- Tests also cover successful response bytes, cancellation before and during transport, split Unicode and escaped JSON strings, invalid edit targets, incomplete scripts, and model producer cancellation.

These are synthetic regression timings, not measurements of Groq or MLX inference. No recent application timing logs were available during this change, and the one-second end-to-end target has **not** been measured. Cached FluidAudio source confirms `finish()` drains queued recognition and decodes accumulated tokens; it does not rerun batch inference on the complete recording. Paste has up to 80ms of deliberate focus retry and 200ms of clipboard timing, excluding AX calls.

Local long dictation still pays one prompt prefill and generation per segment after release. Early completion removes only generation after a valid script; it does not reduce prefill or time to that script. Rolling AI remains unimplemented. Whisper remains batch-based. Cold local model loads, slow hardware, and long dictation without a cloud key can exceed one second. Do not interpret the target below as an achieved performance result.

## Acceptance gates

Still to measure with the app and installed models on an M4:

- Normal dictation, 5–20 seconds: p50 below 700ms and p95 below 1,000ms from key release to paste event.
- Long dictation, 2–3 minutes: release work contains only the volatile tail and remains below 1,000ms at p95.
- Final assembled segment coverage: 100%.
- Empty insertion rate: 0% across 1,000 replayed fixtures.
- One invalid AI segment never cancels valid siblings or the final insertion.
- Model concurrency never exceeds one generation.
