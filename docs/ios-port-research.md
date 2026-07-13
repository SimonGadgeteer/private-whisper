# Porting Private Whisper to iOS — Research Report

*Researched 2026-07-13. Target: iPhone 15 Pro class and newer (A17 Pro+, 8 GB RAM), iOS 26. Owner: Simon (EN/DE/Swiss German/FR), Mac Mini M4 16 GB as always-on home server.*

---

## Executive summary

Build a **native quick-capture app, not a keyboard extension, as Phase 1**: the Action button (or a Lock Screen/Control Center control) launches the app straight into recording, a Live Activity shows state in the Dynamic Island, and on release the polished text lands on the clipboard (plus a history list and share sheet). Transcription runs **on-device with WhisperKit large-v3-turbo** (~1.6 GB, ~5–6× real time on an iPhone 15 Pro, i.e. ~2 s for a 10 s utterance) — this is the only engine with proven Swiss German handling, matching the Mac app; Apple's new SpeechAnalyzer (`de_CH`/`fr_CH` locales, excellent German/French WER) is a lighter fast-path worth A/B-testing against real Swiss German audio. Cleanup runs **on the Mac Mini over Tailscale when reachable** (same LM Studio endpoint and qwen3.5-4b prompt as today, ~0.5 s), falling back to **Apple's on-device ~3B Foundation Model** (free, instant, designed exactly for text refinement tasks) and finally to the raw transcript — mirroring the Mac app's graceful-degradation philosophy. A **keyboard extension for true insert-at-cursor is Phase 3, not Phase 1**: extensions are hard-capped at ~60–80 MB, are kernel-blocked from recording audio, and the container-app round-trip pattern that every shipping competitor relies on was destabilized by iOS 26.4 — it's the highest-risk, lowest-necessity component. Distribute via a **paid Apple Developer account ($99/yr)**: direct Xcode installs are valid for a year and TestFlight builds for 90 days, whereas a free Apple ID means re-signing every 7 days and AltStore PAL is EU-only (Switzerland excluded).

---

## Q1 — On-device transcription on iOS in 2026

### WhisperKit (Argmax) — the pragmatic choice

- Actively maintained (repo now `argmaxinc/argmax-oss-swift`); production-proven; runs Whisper encoder on the Apple Neural Engine via Core ML.
- **large-v3-turbo on iPhone 15 Pro: ~10 min of audio in ~82 s (5–6× real time), ~1.6 GB on disk, streaming mode with < 200 ms first-word latency.** A 5–15 s push-to-talk utterance should transcribe in roughly 1–3 s. ([WhisperKit benchmarks discussion](https://github.com/argmaxinc/WhisperKit/discussions/243), [benchmark dashboard](https://huggingface.co/spaces/argmaxinc/whisperkit-benchmarks), [WhisperKit paper](https://arxiv.org/html/2507.10860v1))
- iPhone 17 generation is substantially faster still (Argmax measured 2.5–4× gains vs iPhone 16 Pro depending on compute unit); the compressed large-v3-turbo format is ANE-only-accelerated, the uncompressed one hits speed factor ~10 on iPhone 17 Air at ~4× the memory. ([Argmax iPhone 17 benchmarks](https://www.argmaxinc.com/blog/iphone-17-on-device-inference-benchmarks))
- Caveats: model download on first launch, one-time ANE compile delay on first run, and ~1.5–2 GB RAM while loaded — fine for a foreground app on an 8 GB phone, categorically impossible inside a keyboard extension (see Q3).
- **Swiss German**: Whisper has no Swiss German language token; large-v3(-turbo) transcribes dialect into Standard German "well enough" — this is exactly what the macOS Private Whisper already relies on, so WhisperKit gives behavioral parity. No other iOS engine has demonstrated this.

### Apple SpeechAnalyzer / SpeechTranscriber (iOS 26)

- New async Swift API, fully offline, system-managed models (no app bloat — models are downloaded once, shared system-wide). ([Apple docs](https://developer.apple.com/documentation/speech/speechanalyzer), [WWDC25 session 277](https://developer.apple.com/videos/play/wwdc2025/277/))
- **Supported locales include `de_CH`, `fr_CH`, `it_CH`, `de_DE`, `fr_FR`** — about 40 locales total. ([supportedLocales](https://developer.apple.com/documentation/speech/speechtranscriber/supportedlocales), [SpeechAnalyzer guide](https://antongubarenko.substack.com/p/ios-26-speechanalyzer-guide))
- Quality is genuinely strong: a 13,023-sample benchmark (Dictato, 2026) found Apple's engine **best-in-class for German (6.7% WER) and French (7.3% WER)**, beating WhisperKit there, while WhisperKit led English (5.2%). It also cut WER 3.5–4× vs the old SFSpeechRecognizer and beats Whisper-small at ~1/3 the compute. ([Dictato benchmark](https://dicta.to/blog/speech-to-text-engine-comparison-mac-2026/), [Inscribe benchmark](https://get-inscribe.com/blog/apple-speech-api-benchmark.html))
- Argmax's own comparison: Apple ~14.0% avg WER vs WhisperKit-base 15.2% (their paid Pro SDK 11.7%); Apple has no custom-vocabulary hook and fixes ship only with OS updates. ([Argmax on Apple](https://www.argmaxinc.com/blog/apple-and-argmax))
- **Open question (must test)**: `de_CH` means Swiss *Standard* German (ss/ß orthography etc.). No published data on actual spoken dialect (Züridütsch etc.). Whisper large's dialect robustness is the known quantity.

### Other options

- **whisper.cpp on iOS**: works (`whisper.objc` sample, Metal + optional Core ML encoder); would let you reuse the exact ggml models from the Mac app. But WhisperKit's ANE pipeline is better tuned for iPhone battery/thermals, and whisper.cpp large-v3-turbo needs ~1.7 GB+ RAM with less ANE offload. Viable fallback, not first choice. ([whisper.cpp repo](https://github.com/ggml-org/whisper.cpp))
- **Parakeet v3 via FluidAudio (Swift, ANE)**: 0.6B params, ~10× faster than Whisper-class models, 25 European languages incl. DE/FR, excellent on disfluent speech. Tempting for latency, but no Swiss German evidence and a different error profile than the Mac app. Worth a later experiment. ([Parakeet v3 benchmark](https://whispernotes.app/blog/parakeet-v3-default-mac-model), [Spokenly comparison](https://spokenly.app/blog/parakeet-vs-whisper))

**Verdict**: WhisperKit large-v3-turbo as the default engine (parity with Mac, proven Swiss German); SpeechAnalyzer `de_CH` as a selectable/experimental engine — if it survives a Swiss German A/B it wins on speed, battery, and zero download.

---

## Q2 — On-device LLM cleanup

### Can a 4B model run on iPhone? Yes, but you won't like it as the primary path.

- Practical on-device range in 2026 is **1–3B at Q4; 4B is the edge of comfortable on an 8 GB phone**. Qwen-class 4B at Q4 ≈ 2.3–2.6 GB weights + KV cache; combined with a resident 1.5–2 GB Whisper model you'd be flirting with the foreground-app jetsam limit (~3–4 GB on 8 GB devices, community-measured; Apple publishes no number — the `increased-memory-limit` entitlement raises it somewhat). ([On-device LLM guide 2026](https://www.buildmvpfast.com/blog/on-device-llm-mobile-llama-ios-android-2026), [jetsam reports](https://developer.apple.com/documentation/xcode/identifying-high-memory-use-with-jetsam-event-reports), [entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.kernel.increased-memory-limit))
- Speeds measured on recent iPhones: Qwen 3.5 2B ~61 tok/s on MLX; Llama 3.2 3B ~37 tok/s before **thermal throttling** kicks in — sustained inference heats the SoC fast; the guidance across benchmarks is "design for bursty inference". A 4B Q4 would land around 15–25 tok/s (speculative interpolation, marked as such), so a 100-token cleanup ≈ 4–7 s + model-load time if not resident. ([iPhone runtime shootout: MLX vs llama.cpp vs CoreML](https://dev.to/john-rocky/on-device-llm-on-iphone-which-runtime-is-fastest-mlx-vs-llamacpp-vs-litert-lm-vs-coreml-1b42), [apple-silicon-llm-bench](https://github.com/john-rocky/apple-silicon-llm-bench))
- Runtimes: MLX-Swift (fastest decode), llama.cpp (max model flexibility, GGUF reuse from LM Studio), CoreML (dramatically lower memory — Qwen 3.5 2B in ~241 MB — but conversion friction).

### The better on-device option: Apple Foundation Models framework (iOS 26)

- Every Apple-Intelligence device (iPhone 15 Pro+) ships a **system ~3B model, callable from Swift in a few lines, zero download, zero app memory for weights**. Apple's stated sweet spot is *exactly* this workload: "summarization, entity extraction, text understanding, **refinement**, short dialog" — i.e. dictation cleanup. Reported ~0.6 ms time-to-first-token and ~30 tok/s on iPhone 15 Pro. German and French are supported Apple Intelligence languages. ([Foundation Models overview](https://dev.to/arshtechpro/apples-foundation-models-framework-run-ai-on-device-with-just-a-few-lines-of-swift-lbp), [Apple ML research](https://machinelearning.apple.com/research/apple-foundation-models-2025-updates), [guided generation](https://dev.to/iniyarajan86/foundation-models-guided-generation-with-apples-ios-26-framework-2m09))
- Guided generation (typed `@Generable` output) removes the "model returned reasoning chatter" class of bugs that plagued the Qwen 3.5 eval on macOS. Quality vs qwen3.5-4b-with-`reasoning_effort:none` is unproven for Helvetism preservation — needs a run through `evals/run_eval.py`'s sample set.

### Or delegate to the Mac Mini — what apps actually do

- Every polished commercial dictation app (Wispr Flow, Willow, superwhisper cloud modes) does ASR and/or LLM formatting **off-device**; fully-local phone pipelines are the exception (Aiko, superwhisper local mode) and skip LLM cleanup entirely. Delegating cleanup to your own Mac Mini keeps the "no third-party cloud" property.
- Mechanics: LM Studio on the Mini already serves an OpenAI-compatible endpoint on the LAN (the Mac app's remote-cleanup mode uses it). Add **Tailscale** on iPhone + Mini and the same URL works from anywhere; on home Wi-Fi it's a direct LAN call. Round-trip for a cleanup request ≈ network (10–50 ms LAN, 30–150 ms Tailscale DERP-relayed worst case) + ~0.5 s inference on the M4 — comfortably under 1 s. *(Latency figures are standard Tailscale/LAN characteristics, not a benchmarked claim.)*
- Cost: Tailscale is free for personal use; iOS VPN-on-demand keeps it zero-touch. Failure mode (Mini asleep/unreachable) must fall back gracefully — same pattern as the Mac app's yellow-warning fallback.

**Verdict**: three-tier cleanup — (1) Mac Mini via Tailscale/LAN when reachable (identical prompt + model to macOS, best quality), (2) Apple Foundation Models on-device (instant, free, no memory cost), (3) raw transcript. Skip shipping your own 4B in the app; revisit only if Foundation Models fails the Helvetism eval.

---

## Q3 — Getting text into other apps (the hard part)

iOS has **no Accessibility-style injection**. The macOS trick (pasteboard + synthetic Cmd-V) does not exist. Realistic mechanisms:

### Custom keyboard extension — powerful, fragile

- Only mechanism that inserts at the cursor of any app (`textDocumentProxy.insertText`).
- **Memory**: extensions get a far lower jetsam cap than apps — community figures ~60–80 MB (some report 30–50 MB usable). Whisper large-v3-turbo (~1.6 GB) can never run in the extension. ([Fleksy on limitations](https://www.fleksy.com/blog/limitations-of-custom-keyboards-on-ios/), [inFullMobile](https://medium.com/@inFullMobile/limitations-of-custom-ios-keyboards-3be88dfb694))
- **Microphone**: keyboard extensions are blocked from recording at the entitlement level — `CMSUtility_IsAllowedToStartRecording ... NOT allowed ... because it is an extension` ([Apple dev forum thread](https://developer.apple.com/forums/thread/742601), [Apple's own archive doc](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html): "no access to the device microphone ... dictation input is not possible").
- **The shipping workaround** (Wispr Flow, Willow, superwhisper): keyboard shows a mic button → `extensionContext.open()` bounces to the **container app**, which records and transcribes → result passes back via App Group container → user returns to the host app and the keyboard inserts the text. Requires "Allow Full Access" (App Group + network). ([Wispr Flow keyboard setup](https://docs.wisprflow.ai/articles/7453988911-set-up-the-flow-keyboard-on-iphone), [WhisperBoard open-source example of the split architecture](https://github.com/fmachta/WhisperBoard))
- **Fresh instability**: iOS 26.4 broke the automatic return-to-host-app — the keyboard can no longer identify its host bundle ID, so after the round-trip users can get dumped on the Home Screen; no public API fix as of mid-2026. Wispr Flow's docs now say "activating the microphone from the Flow keyboard may take you to the Wispr Flow app... swipe back". ([Apple dev forum, iOS 26.4](https://developer.apple.com/forums/thread/826851))
- Other compromises seen in shipping keyboards: no reliable operation in custom text fields (banking apps), auto-switch to system keyboard for phone/email fields, mode switching requires restart (superwhisper). ([superwhisper iOS keyboard review](https://eiiis.substack.com/p/superwhisper-ios-keyboard), [superwhisper](https://superwhisper.com/))

### Main app + clipboard / share sheet — what fully-local apps ship

- Aiko (whisper.cpp, 100% local) is app-only: record/import → transcript → copy/export/share. No system-wide insertion, and it's a top on-device transcription app anyway. ([Aiko](https://sindresorhus.com/aiko))
- Quick-capture flow: Action button → app opens recording → speak → cleaned text auto-copied → switch app, paste. Two taps more than macOS, but 100% reliable, no memory games, full 8 GB available to Whisper + cleanup.
- A **Share/Action extension** covers the inverse direction (send selected text or audio files into the app), not insertion.

### Shortcuts / App Intents

- Expose a `DictateToClipboard` App Intent: usable from Shortcuts, the Action button, Lock Screen, and automations. Mic capture requires the app to come to the foreground (background shortcut execution can't record), so this is a launcher, not a headless pipeline.

**Verdict**: app-first with auto-copy is the dependable core; the keyboard extension is a Phase-3 add-on using the WhisperBoard-style split architecture, accepting the iOS 26.4 round-trip jank.

---

## Q4 — Push-to-talk UX on iOS

- **Action button** (iPhone 15 Pro+): assignable to a Shortcut/App Intent → app launches directly into recording. This is exactly how Wispr Flow, Ally and others do quick capture; Wispr Flow ships "Quick Dictation to Notes"-style intents. Press-and-hold PTT semantics aren't available to third parties (the button fires an intent; it doesn't stream press/release) — so the flow is *press to start, tap/press to stop*, not hold-to-talk. ([Wispr Flow Action Button](https://docs.wisprflow.ai/articles/4500510662-set-up-the-action-button-for-flow-on-iphone), [Apple: Action button](https://support.apple.com/guide/iphone/use-and-customize-the-action-button-iphe89d61d66/ios))
- **Control Center / Lock Screen controls (iOS 18+ ControlWidget)**: a third-party control can sit where the flashlight/camera controls are and launch the app via App Intent — good secondary trigger. Only *camera* experiences get the special locked-device extension (`LockedCameraCapture`); audio recording requires unlocking into the app. ([WWDC24 controls](https://developer.apple.com/videos/play/wwdc2024/10157/), [MacStories controls roundup](https://www.macstories.net/roundups/control-center-and-lock-screen-controls-a-roundupof-my-favorites/))
- **Live Activity / Dynamic Island** during recording: fully supported pattern (Voice Memos does it); show waveform-ish state + elapsed time + stop button, mirroring the Mac app's notch capsule. Recording can continue in background once started in foreground (audio background mode), so the user can switch to the target app *while still dictating*, then stop from the Dynamic Island — this meaningfully shortens the capture→paste loop. ([Apple: Dynamic Island](https://support.apple.com/guide/iphone/use-the-dynamic-island-iph28f50d10d/ios))
- In-app: a big hold-to-record button gives true PTT ergonomics when the app is already open.

---

## Q5 — Distribution without the App Store

| Option | Cost | Re-sign cadence | Notes |
|---|---|---|---|
| Free Apple ID + Xcode/AltStore/Sideloadly | $0 | **every 7 days**, max 3 apps, 10 App IDs/week | Painful for a daily-driver; AltServer Wi-Fi auto-refresh helps but needs the Mac awake and on the same network — the Mini could do this ([AltStore FAQ](https://faq.altstore.io/altstore-classic/getting-started), [App ID limits](https://faq.altstore.io/altstore-classic/app-ids)) |
| **Paid Developer Program** | $99/yr | Xcode direct install: ~1 year; TestFlight build: 90 days | The practical choice: install from Xcode onto your own phone and forget about it; TestFlight adds OTA updates and crash logs ([sideloading overview 2026](https://www.rickyspears.com/tech/how-to-sideload-apps-on-iphone-in-2025-a-comprehensive-guide/)) |
| AltStore PAL / alternative marketplaces | — | — | **EU-only under the DMA; Switzerland is not covered** — not an option for a CH Apple ID/region |

Extra push for the paid account here: keyboard extensions + App Groups + Foundation Models entitlements all behave better with a real team, and TCC-style permission grants survive rebuilds with a stable signing identity (same lesson as DECISIONS.md §9).

---

## Architecture comparison

| | A. App-only quick capture | B. + Keyboard extension | C. Mac-Mini thin client |
|---|---|---|---|
| Insert at cursor in any app | No — clipboard + paste (or dictate-in-background then paste) | Yes, via `textDocumentProxy` | Depends on A or B for delivery |
| Offline/anywhere | Fully | Fully (local ASR in container app) | Only when Mini reachable (Tailscale ≈ anywhere, but Mini must be awake) |
| ASR quality | WhisperKit large-v3-turbo (Mac parity) | Same (runs in container app, never the extension) | whisper.cpp large-v3 on M4 — best quality, phone stays cool |
| Cleanup | Foundation Models on-device; Mini when reachable | Same | qwen3.5-4b on Mini — identical to macOS |
| Latency (10 s utterance) | ~2–4 s total | Same + app-bounce round trip | ~1–2 s compute + upload of ~300 KB audio; sub-3 s on LAN |
| Engineering risk | Low | **High** (60–80 MB cap, mic block, iOS 26.4 round-trip regression) | Low-medium (server plumbing, wake/sleep handling) |
| Battery/thermal | Moderate bursts | Moderate | Minimal on phone |

**Recommended shape: A as the product, C as an automatic accelerator tier inside A, B bolted on later if the paste step grates.** This is also exactly the compromise set the market converged on: fully-local apps are app-only (Aiko), keyboard-first apps are cloud-backed and janky at the OS boundary (Wispr Flow, superwhisper).

## Phased implementation sketch

- **Phase 0 — engine spike (a weekend)**: iOS test app that runs the existing `evals/` Swiss German/DE/FR samples through (a) WhisperKit large-v3-turbo, (b) SpeechAnalyzer `de_CH`/`fr_CH`/auto, and cleanup through (c) Foundation Models vs (d) Mini-over-Tailscale with the production prompt. Decide engines on data, reusing the eval judge.
- **Phase 1 — MVP app**: SwiftUI app: hold-to-record button, AVAudioEngine capture with the same energy gate, chosen ASR engine, 3-tier cleanup (Mini → Foundation Models → raw), auto-copy + history list (counters only, like macOS). Action button App Intent that launches straight into recording. Distribute via Xcode install (paid account).
- **Phase 2 — capture ergonomics**: Live Activity/Dynamic Island during recording + stop-from-island; background-continue recording so you can switch to the target app mid-dictation; Control Center/Lock Screen control; Shortcuts intents; settings parity (server URL, model, cleanup toggle, timeout).
- **Phase 3 (optional) — keyboard extension**: KeyboardKit-based mini keyboard with one mic key; `extensionContext.open()` round-trip into the main app for record+transcribe; App Group handoff; insert via `textDocumentProxy`. Accept the iOS 26.4 return-jank; keep the extension under ~30 MB.
- **Phase 4 (optional) — Mini power mode**: when on Tailscale, stream audio to the Mini for whisper large-v3 (full, not turbo) + qwen3.5-4b — highest quality tier, phone as thin client.

## Key uncertainties (flagged speculation)

1. **SpeechAnalyzer `de_CH` on spoken dialect** — no published evidence; could be great (Apple trains on Swiss data) or poor. Phase 0 decides.
2. **Foundation Models cleanup quality on Helvetisms/multilingual** — unproven; the model is capable in DE/FR generally but the eval must confirm language preservation.
3. **iOS 26.4 keyboard round-trip** — may be fixed or further locked down in later point releases; treat any keyboard-extension plan as unstable ground.
4. On-device 4B token speeds on A17/A18 are interpolated from 2B/3B benchmarks, not directly measured.

## Sources

- https://github.com/argmaxinc/WhisperKit/discussions/243 · https://huggingface.co/spaces/argmaxinc/whisperkit-benchmarks · https://arxiv.org/html/2507.10860v1 · https://www.argmaxinc.com/blog/iphone-17-on-device-inference-benchmarks · https://www.argmaxinc.com/blog/apple-and-argmax
- https://developer.apple.com/documentation/speech/speechanalyzer · https://developer.apple.com/documentation/speech/speechtranscriber/supportedlocales · https://developer.apple.com/videos/play/wwdc2025/277/ · https://antongubarenko.substack.com/p/ios-26-speechanalyzer-guide · https://dicta.to/blog/speech-to-text-engine-comparison-mac-2026/ · https://get-inscribe.com/blog/apple-speech-api-benchmark.html
- https://github.com/ggml-org/whisper.cpp · https://whispernotes.app/blog/parakeet-v3-default-mac-model · https://spokenly.app/blog/parakeet-vs-whisper
- https://dev.to/john-rocky/on-device-llm-on-iphone-which-runtime-is-fastest-mlx-vs-llamacpp-vs-litert-lm-vs-coreml-1b42 · https://github.com/john-rocky/apple-silicon-llm-bench · https://www.buildmvpfast.com/blog/on-device-llm-mobile-llama-ios-android-2026 · https://machinelearning.apple.com/research/apple-foundation-models-2025-updates · https://dev.to/arshtechpro/apples-foundation-models-framework-run-ai-on-device-with-just-a-few-lines-of-swift-lbp · https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.kernel.increased-memory-limit
- https://developer.apple.com/forums/thread/742601 · https://developer.apple.com/forums/thread/826851 · https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html · https://www.fleksy.com/blog/limitations-of-custom-keyboards-on-ios/ · https://medium.com/@inFullMobile/limitations-of-custom-ios-keyboards-3be88dfb694 · https://github.com/fmachta/WhisperBoard
- https://docs.wisprflow.ai/articles/7453988911-set-up-the-flow-keyboard-on-iphone · https://docs.wisprflow.ai/articles/4500510662-set-up-the-action-button-for-flow-on-iphone · https://superwhisper.com/ · https://eiiis.substack.com/p/superwhisper-ios-keyboard · https://sindresorhus.com/aiko
- https://developer.apple.com/videos/play/wwdc2024/10157/ · https://www.macstories.net/roundups/control-center-and-lock-screen-controls-a-roundupof-my-favorites/ · https://support.apple.com/guide/iphone/use-and-customize-the-action-button-iphe89d61d66/ios · https://support.apple.com/guide/iphone/use-the-dynamic-island-iph28f50d10d/ios
- https://faq.altstore.io/altstore-classic/getting-started · https://faq.altstore.io/altstore-classic/app-ids · https://www.rickyspears.com/tech/how-to-sideload-apps-on-iphone-in-2025-a-comprehensive-guide/
