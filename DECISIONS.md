# Build Decisions (PRD §10 + deviations)

## 1. Transcription engine: whisper.cpp embedded (per Simon's choice)

- Built `whisper.xcframework` from ggml-org/whisper.cpp master via `build-xcframework.sh` (Metal + Accelerate), vendored in `Frameworks/`, linked as an SPM `binaryTarget`, embedded in the app bundle.
- **Measured:** large-v3-turbo transcribes a 10 s utterance in ~0.5 s on the M4 Max (model kept loaded between dictations; load itself ~0.4 s, done once at app start). The faster-whisper sidecar was not needed — the `Transcriber` protocol keeps it swappable.
- The framework was compiled with CoreML support; it probes for a CoreML encoder (`ggml-large-v3-turbo-encoder.mlmodelc`), doesn't find one, and falls back to Metal. Generating the CoreML encoder is an optional future encoder speedup; at 0.5 s/10 s it's not needed.

## 2. Whisper model: large-v3-turbo default — PRD deviation

The PRD listed **distil-large-v3** as the latency fallback, but distil-whisper is **English-only**, which violates the DE/CH/FR hard requirement. Replaced with **large-v3-turbo** (multilingual, ~6× faster than large-v3, minor quality loss). Both large-v3-turbo (default) and large-v3 (best quality) are downloaded and selectable in Settings.

## 3. Hotkey: NSEvent flagsChanged monitors, Right Option default

- `NSEvent.addGlobalMonitorForEvents(.flagsChanged)` + a local monitor, keyed on `keyCode` (61 = Right Option) so left/right modifiers are distinguished. Simpler and more robust than a `CGEventTap` (no Input Monitoring permission, no tap-disable-on-timeout failure mode), and push-to-talk only needs to observe, not intercept.
- Fn/Globe was rejected as the default: macOS reserves Fn-hold for Apple dictation/emoji. It's still offered in Settings (plus Left Option / Right Command).

## 4. Cleanup model: see eval results below

- Qwen3.5 / Qwen3.6 / Gemma-4 turned out to be **thinking models**; for a latency-critical, mechanical rewrite task, reasoning is pure overhead (qwen3.5-4b spent >15 s thinking about removing "um"). Neither `/no_think` nor `chat_template_kwargs: {enable_thinking: false}` disables Qwen 3.5/3.6 thinking; **qwen3-8b does honor `/no_think`** and the app appends it for qwen-family models.
- `max_tokens` includes +2048 headroom so reasoning models don't hit the cap mid-thought and return empty content (harmless for non-thinking models).
- No Qwen3.6 model fits the 16 GB Mac Mini (smallest is 27B dense ≈ 15 GB at 4-bit); the installed 27B was evaluated as an out-of-budget reference only.

### Mini-eval results (10 multilingual samples, judged by local gpt-oss-120b)

| model | fits 16 GB Mini | quality /10 | median s | lang fails |
|---|---|---|---|---|
| ministral-3-14b-reasoning | ⚠️ 9.1 GB | 10.0 | 1.84 | 0 |
| gemma-4-12b | yes | 10.0 | 32.4 | 0 |
| qwen3.6-27b (reference) | no | 10.0 | 164.7 | 0 |
| **qwen3-8b** (`/no_think`) | **yes (4.6 GB)** | **9.9** | **0.67** | 0 |
| ministral-3-3b | yes (3.0 GB) | 9.4 | 0.44 | 0 |
| qwen3.5-4b | yes | 5.3 | 71.6 | 2 |
| qwen3.5-9b | yes | 4.6 | 98.4 | 4 |

**Default: `qwen/qwen3-8b`** — 9.9/10 at 0.67 s median, fits the Mini. `ministral-3-14b-reasoning` is the quality-max option (10/10 @ 1.84 s) for the 128 GB machine but exceeds the Mini budget; `ministral-3-3b` is fastest but restructures text and adds markdown. Qwen 3.5 models are disqualified: always-thinking (70–100 s) and the only candidates that translated samples into the wrong language. Full analysis: evals/results.md.

## 5. Re-trigger while processing: reject (PRD §7.7)

A press while the previous dictation is still processing is rejected with a "Still processing…" flash. Queuing was rejected because the queued text would be injected into whatever app has focus seconds later — too surprising.

## 6. Recording HUD (PRD §10.4): not built

The menu-bar icon state (red mic while recording) is sufficient feedback for the POC; a waveform HUD adds no information the user needs mid-dictation.

## 7. Injection heuristics

- Pasteboard + synthetic Cmd+V (`CGEvent`), previous pasteboard contents snapshotted (all items/types) and restored after 600 ms. Known caveat: clipboard-manager apps will still record the transient entry.
- HUD-instead-of-inject triggers on: no Accessibility permission, secure input active (`IsSecureEventInputEnabled`), no AX focused element, or focused element role in a small known non-text set (button, menu, slider, …). Unknown roles inject anyway — a stray Cmd+V into a non-text target is a no-op, while a false HUD interrupts the flow.

## 8. Silence handling

Whisper hallucinates fragments ("you", "Thank you.") on near-silence, and its `no_speech_prob` is ~0 for those, so it can't be the gate. Defense is an energy gate before transcription (≥0.5 s duration AND RMS > 0.002), shared by the app and test mode, plus a no-speech-prob segment filter and bracket-artifact stripping as second lines. A Silero VAD pass (supported by whisper.cpp) is the Phase 2 upgrade if breath noise ever slips through.

## 9. App identity / signing

Signed with the local Apple Development identity (stable designated requirement) so Accessibility/Microphone grants survive rebuilds — ad-hoc signing would reset TCC on every build. Bundle ID: `ch.simonschwarz.PrivateWhisper`.

## 10. Config

JSON at `~/Library/Application Support/PrivateWhisper/config.json`, tolerant decoding (missing keys → defaults) so the file survives app updates that add fields.
