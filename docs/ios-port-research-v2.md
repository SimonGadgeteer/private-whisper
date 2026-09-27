# Private Whisper on iPhone: how close can we get to Wispr Flow? (research update, 2026-09-27, revised)

Supersedes the keyboard conclusions of `docs/ios-port-research.md` (2026-07-13). All other sections of that report still hold unless this report says otherwise.

**Status tags used below**
- **[Confirmed]**: two independent checkers verified it against primary sources.
- **[Partially confirmed]**: the core holds, with the caveats stated next to it. This includes follow-up findings that one researcher checked against primary sources on 27 Sep.
- **[Contested]**: the sources conflict.
- **[Unverified]**: a single source, an inference, or something nobody could check.
- **[Estimate]**: a number scaled from measurements on other hardware (usually Simon's M4 Max) using published ratios. Nobody measured it on the target device.

**Target device for the estimates below:** iPhone 15 Pro Max (8 GB RAM) on iOS 27.0 — the same model Dictus used for its iOS 26.6 memory/battery measurements and its iOS 27.0 hand-off test.

---

## 1. TL;DR

**Yes. A much more seamless iPhone flow is feasible, and MIT-licensed code already implements most of it. On an iPhone, "seamless" means one app bounce per session and then in-place dictation. Nobody, Wispr included, gets zero bounces.**

Wispr Flow did not find a hidden API. Apple's current keyboard documentation still says "No access to microphone and speaker", so Wispr works like this:
- **The first dictation of a session bounces you into the Flow app.** The app starts the microphone while it is in the foreground, starts a Live Activity, and keeps running in the background under the audio background mode.
- **It then sends you back to your app.** This is automatic for apps it can identify and reopen. For any other app you swipe back.
- **For the rest of the session, the keyboard's mic button starts and stops dictation in place.** The session ends on an idle timeout (5 min by default) or when a phone call, Siri, an audio-route change or a memory kill interrupts it.
- **All speech recognition and cleanup run in Wispr's US cloud.** Wispr's stated target is 700 ms from the end of speech to formatted text.

Dictus, KeyVox and VocaPhone already ship the same hot-mic session with on-device speech recognition.

Private Whisper has two problems Wispr does not:
- **The container app is in the background when it would transcribe.** Backgrounded iPhone apps get no GPU, and iOS 27 (released 14 Sep 2026) requires a new entitlement for background Neural Engine use. The answer is to shrink the container app to just the microphone. Networking, the offline ASR fallback and cleanup then run in the keyboard, which is in the foreground while you dictate, and on the Mac Mini.
- **The Mini is not fast enough without streaming.** Sending a 15 s dictation to a base M4 Mini after you stop is estimated at about 3 s (optimised, on LAN) to 5 s (today's Mac pipeline, over 5G). Cleanup, not ASR, is the biggest cost [Estimate]. So streaming ASR and incremental cleanup during recording belong in the first build, not in later polish.

**Do this before writing any code:** a two-minute check on Simon's phone.
- Do work Outlook and Teams block third-party keyboards?
- Is a corporate VPN occupying the single VPN slot that Tailscale needs?

The answers decide whether the keyboard or the Action-button quick capture ships first.

---

## 2. How Wispr Flow actually does it

### 2.1 The user flow (from Wispr's own help center, pages updated Sep 2026)

1. **Setup.**
   - You add the Flow keyboard and turn on Full Access, which Wispr requires for transcription.
   - The microphone permission prompt has to come from the main app. Wispr's docs say keyboard extensions cannot show iOS permission dialogs.
   - The keyboard "needs Wi-Fi or cellular data to transcribe".
   - [Confirmed] ([keyboard setup](https://docs.wisprflow.ai/articles/7453988911-set-up-the-flow-keyboard-on-iphone))
2. **First dictation in, say, WhatsApp.** You tap "Start Flow" or the mic. Wispr's docs:
   - *"in other apps, the keyboard opens Flow to record"*
   - *"Apple requires Flow to briefly switch apps to activate the microphone."*

   Flow starts recording during the bounce, and *"Dictation continues once you're back."* [Partially confirmed]
3. **Getting back.**
   - Before iOS 26.4, the return to your app was automatic in many apps.
   - iOS 26.4 (Wispr v1.46, 31 Mar 2026) broke that. Users landed on a "Flow is on – swipe right across the bottom edge" screen.
   - Wispr v1.63 restored "auto-switchback" for a named list of apps: Claude, ChatGPT, Gemini, Grok, Perplexity, Kin, LinkedIn "and many more". The App Store build is dated 19 Jun 2026; the web changelog lists it on 2 Jul. The changelog says it works "including the iOS 27 beta".
   - The current docs say automatic return *"requires Flow to identify your app and that app to support reopening"*. The first automatic return asks you to confirm.

   [Partially confirmed] No primary source confirms it on the final iOS 27 release.
4. **Later dictations.**
   - While the session is alive, the keyboard's mic starts dictation and the checkmark stops it, without leaving the host app.
   - The Live Activity *"persists across a keyboard session so you can start another dictation quickly."*

   [Partially confirmed] ([orange-dot article](https://docs.wisprflow.ai/articles/3634682593-why-the-orange-dot-or-mic-indicator-stays-on-after-dictating-ios))
5. **Session end.**
   - The setting "Disable Flow after" offers Never, 1 h, 15 min, **5 min (default)** or Immediately. It only applies while Flow is in the background and its keyboard is inactive.
   - These also end the session: phone calls, Siri, other audio interruptions, headset or Bluetooth changes, another app taking the mic, low memory (which cancels the dictation and discards the audio), and force-quit.
   - Each dictation is capped at 5 minutes.
   - After any of these, the next dictation bounces again.

   [Partially confirmed]
6. **Offline.**
   - "No Network" replaces the dictation controls.
   - On iOS only, if the connection drops mid-dictation, Flow saves an "on-device draft" and upgrades it later.
   - Wispr does not disclose the on-device engine.

   [Partially confirmed]
7. **Where the keyboard can't go.**
   - Password fields and phone-pad fields always get Apple's keyboard. This is Apple's rule for every custom keyboard.
   - Wispr says its keyboard works "in any app that uses standard iOS text input — Messages, Mail, Notes, Slack", and not in some banking apps with custom text fields.

   [Partially confirmed]

**Real-world consequence:** with the 5-minute default, occasional users bounce on most dictations. A January 2026 App Store review complains about exactly that, and Spokenly's competitor review lists it as a con. The seamlessness depends on a long timeout. [Unverified: two reviews plus inference]

### 2.2 The technical mechanism

- **The keyboard never records.**
  - Apple's current "Configuring open access for a custom keyboard" page still lists "No access to microphone and speaker" among the limits that apply even with Full Access. We re-checked this on 27 Sep 2026.
  - Wispr: *"Dictation runs in the main Flow app even when started from the keyboard."*
  - The keyboard only relays start and stop, shows the waveform and timer, and inserts the returned text into the focused field.
  - Wispr does not document how the keyboard and app talk to each other. App Group plus Darwin notifications is the standard design, but for Wispr that is an inference.

  [Confirmed for the no-mic rule; Partially confirmed for the relay design]
- **Why the bounce exists.**
  - iOS will not let an app *start* recording while it is in the background. The audio background mode only lets it *continue* a session it started in the foreground.
  - Apple documents two related errors: `cannotStartRecording` ("usually occurs when an app starts a mixable recording from the background") and `cannotInterruptOthers`.
  - In January 2026 an Apple DTS engineer explained that allowing recording to start from the background "basically allows an app to start recording whenever it wants".

  [Partially confirmed]
- **What the idle session holds. [Contested]**
  - Wispr's current docs say *"Flow releases the microphone when recording stops"* and that a lingering orange dot "is UI state… not an active recording". Another Wispr page calls the idle state "background listening", and says it "resumes recording" after an interruption.
  - Every open-source clone (Dictus, VocaPhone, KeyVox, OpenWhispr) keeps the input engine running while idle, discards the samples, and shows the orange dot the whole time. They do this because starting the mic cold from the background fails (`AUIOClient_StartIO failed (2003329396)`).
  - Typeless is reported to resume after long idle periods with no idle mic indicator. The mechanism is unknown. [Unverified]
  - So how Wispr re-arms capture without holding the mic is undocumented. Do not design around it until a device test reproduces it.
- **How it gets you back. [Unverified for Wispr specifically]**
  - Apple DTS confirmed in June 2026 that there is no public API for a keyboard or its container app to identify the host app ([forum 826851](https://developer.apple.com/forums/thread/826851); FB22247647 still open). KeyboardKit's docs say `hostApplicationBundleId` has been nil since iOS 26.4.
  - The Dictus maintainers captured iOS 27.0 system logs in which Wispr's keyboard re-registers with the system keyboard arbiter and then opens the host through its URL scheme (`open … url "claude:" … on behalf of Flow`) ([dictus #543](https://github.com/getdictus/dictus-ios/issues/543)).
  - That fits a private host lookup plus a bundle-ID→URL-scheme allowlist. It is a third party's observation, not something Wispr has documented.
  - Reopening through a URL scheme *launches* the app rather than *resuming* it. VivaDicta measured that `claude://` opens a new chat and `sms://` opens a blank compose sheet ([VivaDicta commit](https://github.com/n0an/VivaDicta/commit/2c9efdd97f185dc80c747b5b29c7133b83f835ce)).
- **Siri.** A 2025 Wispr article said Siri can't be used during a Flow session. It has been withdrawn (the URL now returns 404). Current docs, and Dictus device logs on iOS 26.6.1, show Siri *interrupting* the session instead. [Partially confirmed]
- **App Store.**
  - Wispr v1.76 (24 Sep 2026, minimum iOS 18.3) is live.
  - Its design conflicts with the letter of guideline 4.4.1, which says keyboards must work without Full Access and must not launch other apps besides Settings. Apple tolerates it anyway.
  - This does not matter for Simon's personal Xcode build.

### 2.3 What Wispr gets for free by being cloud-only

All ASR and cleanup run in Wispr's US cloud:
- its own "Canto" speech model since 17 Sep 2026
- fine-tuned Llama models on Baseten ([security FAQ](https://docs.wisprflow.ai/articles/3467817258-security-and-compliance-faq), [Baseten case study](https://www.baseten.co/resources/customers/wispr-flow/))

**The 700 ms figure is a target, not a measurement.** Wispr's engineering blog (Sahaj Garg, 11 Sep 2025) says users *"expect full transcription and LLM formatting/interpretation of their speech within 700ms of when they stop speaking"*. It budgets ASR under 200 ms, the LLM under 200 ms and at most 200 ms for the network ([technical challenges](https://wisprflow.ai/post/technical-challenges)). No measured p99 is published. [Partially confirmed; corrects the first pass, which called it a p99]

**Why this matters for Private Whisper:**
- Wispr's background app only captures and uploads audio. It never hits the constraints a local pipeline hits in the background: no GPU, the Neural Engine behind an entitlement, the CPU watchdog, and memory kills (jetsam) of a resident 1.6 GB model.
- Wispr's servers can also afford an LLM step of about 200 ms. A 4B model on a base Mac Mini generates about 29–41 tokens/s [Estimate, §6.5], so a 50-token cleanup alone takes about 2 s.
- The Mini is Simon's equivalent of Wispr's cloud, but a much slower one. Private Whisper has to design around both gaps.

---

## 3. Peer landscape

| App | Distribution / licence | Keyboard mechanism | ASR | Return after bounce | Warm window | Notable compromises |
|---|---|---|---|---|---|---|
| **Wispr Flow** | App Store, closed (v1.76) | Session in the container app; the keyboard signals it | **Cloud** (US). iOS-only on-device draft when the connection drops | Automatic for allowlisted apps since v1.63, otherwise swipe back. Mechanism undisclosed | 5 min default; Never…Immediately | Needs network and Full Access; 5-min dictation cap; Live Activity; idle-mic behaviour **[Contested]** |
| **Willow** | App Store | App opens once to start a "background microphone session" | Cloud-first. Offline Mode marketed; keyboard support **[Unverified]** | Not documented | Times out (value unpublished) | — |
| **Monologue** | App Store | "Microphone session owned by the main app" | Cloud (third-party review) | Tries automatic, else swipe | Configurable | Ends on call, interruption, route change, force-quit |
| **Aqua Voice** | App Store | Bounces into the app on the first dictation, then dictates from the keyboard | Cloud only | Manual | Once per session or once per host app? **[Unverified]** | No offline mode |
| **Typeless** | App Store | Undocumented. Observed resuming after long idle with no mic indicator **[Unverified]** | Cloud | Passes `hostAppBundleId` in its launch URL (iOS 26.5.2 log) | Unknown | A reviewer reports a 6-min recording cap |
| **superwhisper** | App Store | Keyboard opens the app; manual swipe back since 26.4 | Local models usable from the keyboard (v2.23) | Manual | Undocumented | Users report getting "stuck" in the app |
| **Spokenly** | App Store, closed | Keyboard plus Shortcut "Background Dictation" (Live Activities required) | Local Parakeet or cloud. The developer says online models are "preferred" for the keyboard | — | A user reports a bounce after "a couple of minutes" | Mechanism not public |
| **KeyVox** | App Store (1.4.5), MIT, individual seller | Warm session plus `AudioRecordingIntent` on the Action button | **On-device** Whisper Base (whisper.cpp) and Parakeet TDT v3. **Ships the iOS 27 background Neural Engine entitlement** (PR #112, commit 9a4090a3c0, App Store 1.2.15 on 16 Jul 2026, after a CPU-only workaround in 1.2.11 on 12 Jun) | Manual ("Swipe back, and speak") | 300 s default, can be Never | Small Whisper only. Cold-start Action-button recording not proven on a device **[Contested]** |
| **VocaPhone** | Public TestFlight, AGPL | Persistent `AVAudioEngine` standby, samples discarded | **On-device** WhisperKit 1.1.0 and sherpa-onnx; optional self-hosted gateway | Manual (added a swipe tutorial Sep 2026) | 10 / 20 min / until closed | Rejected under App Review 2.5.4 in Sep 2026. No Neural Engine entitlement. Hit about 3 GB per-process limit within an hour with the model kept warm |
| **Dictus** | App Store 1.9.0 (24 Sep 2026), **MIT, Swift** | Warm engine; Darwin start; URL fallback after 500 ms | **On-device** WhisperKit, Parakeet, Nemotron (FR) | **Automatic in ~87 apps** via a private keyboard-arbiter swizzle | 10 min | Orange dot; ~3.3 %/h battery (iPhone 15 Pro Max). **No inference entitlement, built with Xcode 26.4.1, yet transcribes in the background on iOS 27.0.** Reason unexplained (§4) |
| **VivaDicta** | App Store 3.11.0, MIT | Hot-mic prewarm | On-device (Neural Engine) and cloud options | KeyboardKit 10.9 resolver plus scheme map | 180 s default, Never optional | Resolver once named an app that had quit 3 s earlier |
| **OpenWhispr** (mobile) | App Store 1.2, MIT | Warm mic plus 1 s App Group heartbeat | Not verified in this research | Private host lookups. An alternative approach (PR #2365) is unmerged | 10 min | `isRunning` can report true for a frozen engine after suspension |
| **Sayboard** | Open source, fully on-device | Background audio session; "Swipe right to return" screen | Parakeet/WhisperKit **forced CPU-only on iOS 27**; llama.cpp on CPU, LLMs ≤ 2B | Manual | — | Shows what happens without the Neural Engine entitlement |
| **KeyboardKit Pro** | Commercial SDK (Gold tier $500/mo), closed binary | Same pattern, documented: "must open the main app to start dictation"; the main app records in the background | SFSpeechRecognizer in the main app | 10.9 resolver ("sensitive system API usages") | "As long as the main app is alive" | Too expensive for a personal project |

Sources for each row are in §9.
- **[Partially confirmed]:** the Wispr, Willow, Monologue, KeyVox, VocaPhone and Dictus mechanism rows.
- **[Unverified]:** the Typeless, Aqua, superwhisper and Spokenly details, which rest on single reviews or observations.

**Takeaways:**
- The only open-source apps that ship on-device ASR plus automatic return are Dictus and VivaDicta.
- None of the fully local apps runs anything larger than WhisperKit in the background.
- No reviewed app runs ASR *inside* the keyboard extension. That is an absence of evidence, not a proof that it can't be done.
- Nobody has a published Swiss German result from a keyboard flow.

---

## 4. Platform reality as of iOS 27 (Sept 2026)

**What shipped:**
- iOS 27.0 (build 24A437) and Xcode 27 shipped on **14 Sep 2026**, alongside iOS 26.7.
- The release notes for 27.0 and 27.2 beta 2 contain **nothing for third-party keyboard extensions**. The Keyboard section has a single paste-candidate localization fix.
- WWDC26 added no third-party dictation extension point and no App Intent that inserts text at the cursor.
- New non-beta Speech APIs in 27.0: `AssetInputSequenceProvider` and `CaptureInputSequenceProvider`.
- MetricKit now reports `MemoryExceptionDiagnostic` for extensions killed for exceeding their memory limit.
- The App Store still accepts builds made with the iOS 26 SDK (the minimum since 28 Apr 2026).

| Topic | Reality in Sept 2026 | Changed since 13 July? | Status |
|---|---|---|---|
| Recording inside a keyboard extension | Not allowed. Apple's current open-access page lists "No access to microphone and speaker" even with Full Access (re-checked 27 Sep). Device logs show "NOT allowed to start recording because it is an extension" and error `!rec` (561145187). It may *appear* to work in the Simulator. An Apple forum engineer asked for a bug report (FB16791704, unresolved). No first-hand repro on an iOS 27 device was found. | No | [Confirmed] (documented); device repro on iOS 27 missing |
| Keyboard opens its container app | Allowed. DTS said in Jan 2026 that App Review reads 4.4.1 as permitting the container app. Working routes: responder-chain `UIApplication.open`, or a SwiftUI `Link`/`openURL` overlay on the mic key. **Needs Full Access since iOS 26** (DTS: intentional). `NSExtensionContext.open` is documented only for Today and iMessage extensions. | Refines July (July named `extensionContext.open()`) | [Partially confirmed] |
| Returning to the host app | **No public API** (DTS, June 2026; FB22247647 open; FB24235692 filed Aug 2026). The public path is the system back link in the top-left, or a swipe. **Private workarounds are working again:** KeyboardKit 10.9 (27 Aug 2026); Dictus PR #538 (keyboard-arbiter swizzle, 11 Sep). iOS 27.0 also needs PR #563 (`startConnection`, 15 Sep). | **Yes.** July said "broken, no fix" | [Partially confirmed] |
| Apps that refuse custom keyboards | Any app can refuse all custom keyboards via `application(_:shouldAllowExtensionPointIdentifier:)` returning false for `.keyboard`. Password and phone-pad fields always use Apple's keyboard. **Microsoft Intune App Protection** has an iOS setting "Third party keyboards": default Allow. Microsoft's framework recommends Block only at Level 3 ("enterprise high"). When set to Block, it applies to the work *and* personal accounts inside Outlook, Teams and other Intune-SDK apps, and works on phones not enrolled in MDM. Apple's MDM schema has no device-wide third-party-keyboard switch (through Release-v27.0). On GitHub the veto appears mainly in crypto wallets, password managers (Dashlane), ID/health wallets and security apps; Olvid makes it a setting. Threema and Signal source has no veto. WhatsApp, SBB and Swiss banking/TWINT apps are unverified. | New topic | [Partially confirmed] |
| Starting recording from the background | Not allowed for ordinary apps. A backgrounded app may **continue** a session it started in the foreground (`UIBackgroundModes: audio`). CallKit and PushToTalk are system-mediated exceptions but count as misuse for dictation (2.5.4), and PTT only starts in the foreground or from a Bluetooth accessory event. | No | [Partially confirmed] |
| After an interruption (call, Siri) | Reactivating from the background fails (`!int`) until the app returns to the foreground (forum report Jan 2026; Dictus device logs). | — | [Unverified: forum report plus one project's logs] |
| `AudioRecordingIntent` (iOS 18+) | Needs a Live Activity for the whole recording, and iOS enforces this. KeyVox fixed a Live Activity crash in its App Intents (PR #230). Works when the app is already warm. **Cold start from a terminated or suspended app is [Contested]:** KeyVox ships it, but independent device tests failed on iOS 27.0 (Sorla) and iOS 26.3.1 (Jot). Wispr's own Action-button flow still bounces. | July said intents "can't record". Only partly right | [Contested] |
| Keyboard ↔ app IPC | App Group plus Darwin notifications works; Dictus, OpenWhispr and VivaDicta ship it. The keyboard's shared container is writable only with Full Access (read-only without). Darwin notifications carry no data and **do not wake a suspended app** (Quinn, DTS). | No | [Partially confirmed] |
| Keyboard as a network client | With Full Access, a keyboard has network access. Extensions can use `URLSession`; background sessions must set `sharedContainerIdentifier`. **App Transport Security** has blocked connections to raw IP addresses by default since iOS 17: add an exception for the Tailscale range (100.64.0.0/10) or use an HTTPS hostname. Whether the exception belongs in the extension's own Info.plist is inferred, not verified. | New | [Partially confirmed] |
| Background GPU (Metal) | Blocked (`MTLCommandBufferError.notPermitted` / `…BackgroundExecutionNotPermitted`). One rejected buffer latches ggml-metal into an error state. The iOS 26 `BGContinuedProcessingTask` GPU exception applies only where `supportedResources` contains `.gpu`, which DTS says means M3-or-newer iPads, **no iPhone**. No evidence iOS 27 changed that. | Not addressed in July | [Partially confirmed] |
| Background Neural Engine: the rule | **New in iOS 27.** The release notes say "the system now restricts background access to the Neural Engine". Background use requires `com.apple.developer.background-tasks.continued-processing.inference`. The entitlement page says it is needed "for any Neural Engine access while your app is in the background" and names Core AI, Core ML and MPSGraph, **but not the Speech framework**. Neural Engine memory "is now attributed to your app process instead of the system". The notes mark other changes as SDK-gated ("When linked on iOS 27…", "In apps built with the iOS 27.0 SDK…") but **not** these. Apple compares it to the GPU restriction, which applies regardless of SDK. The phrase "for Apple Intelligence capable devices" is ambiguous, but Simon's iPhone 15 Pro Max is capable, so it applies to him either way. | **Yes, new** | Rule [Confirmed]; not SDK-gated as far as any evidence shows [Partially confirmed] |
| Background Neural Engine: what happens without the entitlement | **Beta 1:** KeyVox saw hard failures only while backgrounded (`ANEProgramProcessRequestDirect() failed`, `Code=8`, "Unable to compute the prediction using ML Program"). **Later betas:** the kernel driver strings changed. Beta 1 blocked a "client application with large model". Beta 3 added `isEntitledToRunBackgroundInference`. Beta 5 added "Allowing/Blocking inference… isBackGround/isSuspended" and `scheduleInferenceIfNeeded`. No SDK field appears in any string. **Dictus (no entitlement, Xcode 26.4.1) still transcribed 7/7 keyboard dictations in the background on an iPhone 15 Pro Max running iOS 27.0.** Nobody recorded which chip ran them. Possible explanations: silent CPU fallback, deferral, a model-size threshold, a policy that allows backgrounded-but-not-suspended apps (e.g. with an active audio session), or a different ANE driver on A17 Pro (the diffed driver is for iPhone18,1). | **Yes, new** | Error behaviour at 27.0 release [Unverified]. The first pass's "[Confirmed] requests fail, no silent CPU fallback" is **downgraded**: it rested on beta 1 |
| …how to get the entitlement | Apple publishes no statement. Circumstantial evidence that a paid team can enable it itself: the entitlement page has no "request access" wording, unlike approval-only entitlements (Private Cloud Compute, Family Controls). KeyVox's individual developer enabled it "for the App ID in the Apple Developer portal" with automatic signing, about a week after beta 3. Yapper lists it as "Background Inference" in Signing & Capabilities. Argmax's sample only says "choose your team". Apple gave it to its own ordinary apps (App Store, News, Books, Stocks). Apple's capability-by-membership table is outdated and lists neither Background GPU nor Background Inference. Free personal teams: unverified, probably not. | — | [Partially confirmed] for paid teams; [Unverified] for free teams |
| Background CPU | Allowed, but watched by the CPU monitor: `cpu_resource_fatal`, "exceeding limit of 80% cpu over 60 seconds", seen on iOS 27.0. Whether it applies to an app actively recording audio is unknown. | — | [Unverified] |
| Background task after audio stops | An app that leaves the foreground, or stops its audio session while backgrounded, is suspended shortly afterwards unless it holds a background task. `beginBackgroundTask` must be called *before* the work starts. | New detail | [Partially confirmed] |
| Apple Foundation Models | Can be called from a backgrounded app but is rate-limited. Dictus field data (iOS 26.5–26.6): once the budget is exhausted, calls are refused instantly and do not recover over time; only a process restart helps. **From the keyboard extension, calls succeeded (30/30)** at +3.7 to 9 MB. iOS 27 replaces the error with `LanguageModelError.rateLimited(resetDate:)`, and the docs no longer say "background only". New models: AFM 3 Core (3B, 8 GB phones, so **Simon's**) and Core Advanced (20B sparse, 12 GB phones). | **Yes.** July treated it as "instant, free" | [Partially confirmed] |
| Apple SpeechAnalyzer / SpeechTranscriber | **Out of process.** Apple: the model "operates outside of your application's memory space" (WWDC25-277). On macOS 27, a client transcribing 70 s of audio peaked at about 20 MB resident while `localspeechrecognition.xpc` did the work. The iOS 26.2 runtime ships the same XPC service. **No speech-recognition permission** appears to be needed: Apple's permission article says that flow "only applies to" SFSpeechRecognizer. The iOS 26.2 SDK has **no extension-unavailable markings** on SpeechAnalyzer, SpeechTranscriber or AssetInventory. **Locales on macOS 27.0:** 45 for SpeechTranscriber, including de-CH, fr-CH, it-CH, de-DE, en-*, and 54 for DictationTranscriber. There is **no Swiss German dialect (gsw) locale**; de-CH is Swiss Standard German. **Assets:** reservations are per app (max 5); installed assets are system-wide. Whether an extension can reserve or install, or sees the container app's assets, is undocumented. On macOS a de-CH request without assets failed with `SFSpeechErrorDomain` code 3. The **simulator cannot test** it (unavailable, empty locale list). **Not yet tested in a keyboard extension or on an iOS 27 iPhone.** | **Yes:** new candidate for keyboard-side ASR | Macro facts [Partially confirmed]; keyboard use [Unverified] |
| Keyboard extension memory | Undocumented. Reports range from about 48 MB to about 70 MB. Dictus settles at 66–70 MB and is reclaimed before smaller keyboards. iOS 27 adds `MemoryExceptionDiagnostic` for extensions. Because Neural Engine memory is now charged to the calling process, **in-process Core ML (e.g. WhisperKit) inside a keyboard is even less viable**. Whether the out-of-process speech service's Neural Engine memory is charged to the calling keyboard is unknown. | Refines July's "60–80 MB" | [Unverified] |
| Background app memory | Dictus measured about 3.3 GB of headroom on an 8 GB iPhone 15 Pro Max (iOS 26.6). Neural Engine weights were mapped rather than allocated: a 1.8 GB model had a footprint of about 284 MB. VocaPhone hit a ~3 GB per-process limit within an hour with a warm model. **iOS 27 now charges Neural Engine memory to the app, so Dictus's iOS 26 result may not carry over.** | New risk | [Unverified] |
| Network: permissions | Works from a backgrounded app while audio I/O keeps it alive. **Local Network (TN3179):** extensions share the container app's Local Network permission state. Trigger the prompt in the foreground, or the request is silently denied. **VPN interfaces such as Tailscale's 100.x addresses are not "local network"**, so the Tailscale path needs no Local Network permission. | New detail | [Partially confirmed] |
| Network: VPN slot | iOS runs **one active device-wide VPN** at a time. Only one VPN app can have On Demand enabled. If another VPN connects, iOS disables Tailscale's On Demand until Tailscale is reconnected by hand. Likely conflicts: Microsoft Defender for Endpoint web protection (a local loopback VPN with Connect On Demand) and Microsoft Tunnel on MDM-enrolled phones. "Tunnel for MAM" runs inside individual apps and does not take the slot. Supervised phones with `allowVPNCreation=false` cannot add Tailscale at all. Tailscale can connect on demand when the phone contacts a `*.ts.net` name, if the interface rule is "Do Nothing". | New | [Partially confirmed] |
| New Apple dictation | iOS 27 "Advanced Dictation Preview": English only, 12 GB RAM devices, **no developer API**. Simon's 8 GB iPhone 15 Pro Max is not eligible. | — | [Partially confirmed] |

---

## 5. What the July research got wrong or missed

1. **It modelled the keyboard as "bounce on every dictation".** Every serious competitor uses one bounce per *session*, followed by in-place dictation. The July report noted that background recording can continue once started, but never tied that to the keyboard. This is the core of Simon's objection, and he was right.
2. **"Keyboard = highest-risk, lowest-necessity, Phase 3" is outdated.** Three MIT-licensed App Store apps (Dictus, VivaDicta, OpenWhispr) ship the complete pattern in readable source, and Dictus uses on-device WhisperKit.
3. **"iOS 26.4 broke auto-return, no fix" is half right.**
   - There is still no *public* fix.
   - Private host detection has worked again since late August and September 2026: KeyboardKit 10.9, Dictus, and Wispr v1.63.
   - App Review's public-API rule (2.5.1) does not apply to a personal Xcode build, so this is a real option. The risk is breakage in an iOS point release.
4. **The example it cited was weak.** `fmachta/WhisperBoard` has 1 star and three days of commits, and its README claims the extension records audio, which Apple's own documentation contradicts. Use Dictus, VivaDicta or OpenWhispr instead.
5. **`extensionContext.open()` is the wrong call.** It is documented only for Today and iMessage extensions. Shipping apps use a SwiftUI `Link`/`openURL` or a responder-chain `UIApplication.open`, which needs Full Access since iOS 26.
6. **"Background shortcut execution can't record" is too strong.** `AudioRecordingIntent` plus `LiveActivityIntent` records without opening the app when the app is warm. Cold start is contested, not ruled out.
7. **It missed that keyboard-driven transcription runs in the background, and what follows from that:**
   - The Mac's whisper.cpp on Metal will fail, because iPhones get no background GPU.
   - WhisperKit's default mel stage (`melCompute = .cpuAndGPU`) fails in the background and must be moved to the CPU.
   - iOS 27's Neural Engine entitlement was already in the beta 3 release notes around 6 July. The report did not catch it.
8. **Foundation Models as the "instant, free" tier 2 ignored background rate limiting.** In a keyboard flow, cleanup has to run in the extension, which is in the foreground, or on the Mini.
9. **Swiss German "parity" was overstated as a quality claim.**
   - The best published zero-shot result for Whisper large-v3 is 28.56 % WER on the All Swiss German Dialects Test Set, with Standard German references ([arXiv 2606.07608](https://arxiv.org/html/2606.07608v1)).
   - The "~14 %" style-adjusted figure that circulated is **unsourced**. The paper's 13.8 % "content WER" belongs to a *fine-tuned* model.
   - **large-v3-turbo, which the Mac app uses, is noticeably worse on Swiss German than full large-v3:** 26.5 % vs 21.1 % WER on SRB-300 ([arXiv 2506.08836](https://arxiv.org/abs/2506.08836)). A model card that is not peer-reviewed reports 43.9 % vs 28.8 % averaged over five datasets.
   - WhisperKit supports compressed builds of *both* models on A16–A19 iPhones (626 MB turbo, 947 MB large-v3).
   - Whisper is not the only engine with Swiss German results (XLS-R, Conformer and commercial systems have them), but it is the only one *among the iOS candidates*.
   - Apple's SpeechTranscriber has a de-CH locale, but that is Swiss Standard German, not dialect.
10. **The Action-button flow is not bounce-free either.** Wispr's own docs say it briefly switches apps to activate the mic.
11. **Still correct:** the distribution advice (paid developer account, $99/yr), Tailscale for reaching the Mini, and the three-tier cleanup philosophy. The tiers just need to be placed differently (see §6).

**…and what the first pass of this update got wrong**

12. **It never checked Mini latency.** It assumed "1–2 s on LAN" without a benchmark.
    - Measurements on Simon's M4 Max, scaled to a base M4, give about 3 s (optimised, LAN) to about 5 s (as shipped, 5G via relay) for a 15 s dictation, and 5–7.5 s with full large-v3 [Estimate].
    - Cleanup, not ASR, is the largest term.
    - Real usage logs from the macOS app show that dictations of 15–30 s and longer are common. Long dictations are normal, not edge cases.
    - It also recommended full large-v3 on the Mini for Swiss German accuracy. That is incompatible with interactive latency on a base Mini.
13. **It put too much work in the backgrounded container app.** ASR routing, network upload and cleanup all sat there, exposed to the background Neural Engine gate, the Local Network prompt problem and suspension. The keyboard is in the foreground while the user dictates, has network with Full Access, and can reach an out-of-process speech model. The container app should do audio capture only.
14. **It said Apple's explicit "no mic" wording exists only in legacy docs.** It is also on the current open-access page.
15. **It marked the Neural Engine failure mode [Confirmed]** ("requests fail, no silent CPU fallback"). That rested on beta 1 evidence. The requirement is confirmed; the release behaviour is not.
16. **It ignored managed work apps and the VPN slot.** Intune App Protection can remove the keyboard from Outlook and Teams, and a corporate or security VPN can displace Tailscale.
17. **It cited KeyVox PR #230 for the entitlement.** #230 is a Live Activity crash fix. The entitlement came in PR #112 (commit 9a4090a3c0).

---

## 6. Recommended architecture for Private Whisper on iPhone

### 6.1 The shape in one paragraph

Three processes, each doing only what iOS lets it do well:

- **Container app = microphone only.**
  - A hot-mic session is started in the foreground on the first mic tap and kept running in the background under `UIBackgroundModes: audio`, with a Live Activity and a configurable idle timeout.
  - It writes audio chunks to the App Group.
  - In the normal path it does no ML and no networking.
- **Keyboard = control, network, cleanup, insertion.** It is in the foreground whenever the user is dictating.
  - It starts and stops the session over Darwin notifications.
  - It streams the chunks to the Mac Mini as they arrive.
  - It runs Foundation Models cleanup when the Mini is unavailable.
  - It inserts the text.
  - Offline, it tries Apple's SpeechTranscriber on the recorded file. The model runs out of process, so it does not load the keyboard's memory [Unverified; spike].
- **Mac Mini = streaming ASR plus incremental cleanup.**
  - whisper.cpp **large-v3-turbo** with a Core ML encoder and a language hint, transcribing chunks during recording.
  - Qwen cleans finalised sentences while you are still talking; after ✓ it re-cleans only the tail.
  - Models are pinned in memory.

**Container-side fallbacks** run only when the keyboard is gone or the offline dialect tier is needed: upload under `beginBackgroundTask`, and WhisperKit on the Neural Engine with the iOS 27 inference entitlement.

**Auto-return** uses Dictus's MIT host resolver plus a verified URL-scheme catalogue, with a swipe-back screen as fallback.

**Why this split:** it keeps networking and on-device ML out of the backgrounded process, which sidesteps most of the background constraints in §4. That the keyboard can do networking is documented. That it can run SpeechAnalyzer is not yet tested.

### 6.2 Components

```
┌──────────────── PrivateWhisperKeyboard.appex (target ≤30–40 MB) ────────────────┐
│ mic/✓ key (SwiftUI Link overlay for cold path) · waveform from App Group levels │
│ globe/next-keyboard · minimal typing · own 1 s heartbeat while visible          │
│ HostAppResolver (port of Dictus: arbiter swizzle + _hostProcessIdentifier       │
│   + startConnection)                                                            │
│ MiniClient: URLSession stream of App Group chunks → https://<mini>.<tailnet>    │
│   .ts.net (LAN name at home); ATS-compliant HTTPS; health check cache           │
│ LocalASR [spike]: SpeechAnalyzer/SpeechTranscriber (de-CH, fr-CH, en-*) on the  │
│   App Group file; assets installed by the container app; status check first     │
│ FMCleanup: SystemLanguageModel (on-device only), String output,                 │
│   .permissiveContentTransformations, language stated explicitly                 │
│ textDocumentProxy.insertText                                                    │
└──────────── Darwin notifications ▲▼  App Group (UserDefaults + files) ──────────┘
┌──────────────── PrivateWhisper.app (container) ─────────────────────────────────┐
│ SessionManager: AVAudioSession .playAndRecord + .mixWithOthers,                 │
│   allowHapticsAndSystemSoundsDuringRecording, built-in mic preferred;           │
│   AVAudioEngine input tap (idle = discard, or small in-RAM pre-roll)            │
│ ChunkWriter: 16 kHz mono PCM (or Opus) chunks of ~1–2 s / VAD-cut → App Group   │
│ Heartbeat writer (1 s) · idle timer · interruption/route handlers → DEAD state  │
│ Live Activity (ActivityKit): "listening / idle / transcribing", stop button     │
│ Fallback workers (keyboard heartbeat stale, or tier 2b chosen):                 │
│   RemoteClient under beginBackgroundTask · WhisperKit (ANE + inference          │
│   entitlement, mel on CPU) · CPU small model                                    │
│ HostReturn: bundle ID → verified URL scheme → UIApplication.open                │
│   within ~250–500 ms of foregrounding                                           │
│ App Intents: ArmSession / QuickDictation (AudioRecordingIntent +                │
│   LiveActivityIntent, supportedModes [.background, .foreground(.dynamic)])      │
│ Onboarding (foreground): mic, Local Network (only if a LAN IP is used), Live    │
│   Activities, notifications, AssetInventory reserve+install de-CH/fr-CH/en,     │
│   WhisperKit download + ANE compile                                             │
└─────────────────────────────────────────────────────────────────────────────────┘
┌──────────────── Mac Mini (Tailscale, always-on) ────────────────────────────────┐
│ Streaming endpoint (WebSocket or chunked HTTP), keyed by requestId:             │
│   whisper.cpp large-v3-turbo + Core ML encoder, language hint (no auto double-  │
│   encode), temperature-fallback cap/timeout                                     │
│   → Qwen 3.5 4B cleans finalised sentences during recording, re-cleans tail     │
│     after stop → JSON {raw, clean, partials}                                    │
│ llama-server --checkpoint-min-step 0, or MLX; models pinned (no TTL/idle stop)  │
│ Bind to tailnet/LAN only; HTTPS on the *.ts.net name; Tailscale ACLs as auth;   │
│ optional UDP 41641 port-forward on the home router for direct 5G paths          │
└─────────────────────────────────────────────────────────────────────────────────┘
```

HTTPS on the Mini's `*.ts.net` name (Tailscale-issued certificates) was not checked in this research. The alternative is an ATS exception for 100.64.0.0/10.

### 6.3 IPC protocol

The heartbeat, Darwin start and 500 ms fallback, and cold URL rows are proven in the three MIT repos. The chunk, keyboard-heartbeat and upload-ownership rows are new design choices, untested.

| Signal | Direction | Payload location | Notes |
|---|---|---|---|
| `…heartbeat` key | app → App Group every 1 s | timestamp, `state ∈ {warm_idle, recording, transcribing, dead}` | The keyboard treats the session as alive only if the heartbeat is < 5 s old (OpenWhispr). Also check that input buffers are actually arriving, because `isRunning` can report true for a frozen engine. |
| `…kbHeartbeat` key | keyboard → App Group every 1 s while visible | timestamp | If it is stale when a dictation stops, the container app takes over upload or transcription under `beginBackgroundTask`. |
| `startRecording` | keyboard → app (Darwin) | App Group: request id, resolved host bundle ID, language hint | If the heartbeat is stale, skip Darwin and open the cold URL directly. Otherwise, if status is still `requested` after 500 ms, open the URL (Dictus). |
| `chunkReady` | app → keyboard (Darwin) | App Group: request id, sequence number, chunk file | The keyboard streams each chunk to the Mini as it arrives. |
| `stopRecording` | keyboard → app (Darwin) | — | The app flushes the last chunk and marks the utterance complete. |
| `levels` | app → App Group ~15 Hz | RMS values | Drives the keyboard waveform. |
| `transcriptReady` | app → keyboard (Darwin) | App Group: `{raw, clean?, source, requestId}` | Only on container-side paths (WhisperKit tier or keyboard-gone fallback). If `clean` is missing, the keyboard runs Foundation Models cleanup. |
| `warmStateReleased` / `dead` | app → keyboard (Darwin) | reason | The keyboard switches the mic key to the cold path immediately. |
| Cold URL `pwhisper://record?req=…&host=…` | keyboard → app | — | The app starts capture first, then returns. |

If the keyboard is dismissed or the field changes before the result arrives, save the transcript to history and the clipboard, and post a notification. Wispr does this.

### 6.4 Audio session strategy

- **Start only from the foreground.** Activate the session on the cold-path URL, when the app launches for onboarding, or through `ArmSession`. Never try `setActive(true)` from the background.
- **Warm idle:**
  - The engine keeps running and samples are discarded.
  - Optionally keep a ~300–500 ms in-memory pre-roll so the first syllable after a tap is not lost. This is a design choice with no measured evidence behind it.
  - **Accept the orange dot.** Whether a mic-off idle state like Wispr's or Typeless's can be reproduced is **[Contested]**. It is a spike candidate (§7), not a baseline assumption.
- **Chunking:** write ~1–2 s or VAD-cut chunks so the Mini can transcribe while you talk. Use 16 kHz PCM on LAN; Opus shortens uploads on 5G [Estimate: ~0.1 s saved after stop for 15 s].
- **`.mixWithOthers`** so music keeps playing (Wispr does the same; it means music can bleed into the transcript).
- **Haptics:** set `allowHapticsAndSystemSoundsDuringRecording = true`. Otherwise iOS mutes haptics and keyboard clicks device-wide while recording.
- **Mic choice:** prefer the built-in mic to keep Bluetooth hands-free profiles out. Wispr's default is the same.
- **Idle timeout:** default 10–15 min, with options for 5 min, 1 h and Never. Dictus measured about 3.3 %/h battery while warm on an iPhone 15 Pro Max, the same model as Simon's. Confirm on his own device before choosing the default.
- **Interruptions** (call, Siri, route change, another app taking the mic): tear down, write `dead`, end the Live Activity. Do not try to recover in the background. The next tap takes the cold path.
- **Session ends at stop** ("Immediately" timeout, or teardown): call `beginBackgroundTask` *before* deactivating the audio session, so any container-side upload or ASR finishes before suspension.
- **Per-dictation cap:** 5 min, matching Wispr.

### 6.5 Where ASR runs

| Tier | Where | When | Engine | Why / status |
|---|---|---|---|---|
| 1. Mac Mini | Streamed from the keyboard during recording | The Mini answered a cached health check | whisper.cpp **large-v3-turbo**, Core ML encoder, language hint | Same privacy model as the Mac app; no background GPU, Neural Engine, CPU-monitor or jetsam exposure on the phone. **Full large-v3 stays out of the live path:** on a base M4 it needs about 2.6–4.0 s of ASR alone for 15 s [Estimate]. The price is Swiss German accuracy (turbo 26.5 % vs large-v3 21.1 % WER on SRB-300). A Swiss-German fine-tuned turbo (model card, not peer-reviewed) is an A/B candidate. |
| 2a. On-device, keyboard | Keyboard (foreground); model runs in a system process | Mini unreachable; standard DE/FR/EN | Apple SpeechTranscriber de-CH / fr-CH / en-* on the App Group file | No app memory for weights, no permission prompt (per Apple), and a foreground caller, so the background Neural Engine gate probably doesn't apply. No Swiss German dialect locale. **[Unverified]: needs the 1-day device spike (§7 #5).** |
| 2b. On-device, container | Container app (background) | Mini unreachable and dialect matters, or 2a fails | **WhisperKit** compressed turbo (626 MB) or large-v3 (947 MB). Encoder and decoder `.cpuAndNeuralEngine`, **mel on CPU**, **with the iOS 27 inference entitlement** | The only on-device engine with published Swiss German numbers. Compile and prewarm **in the foreground during onboarding**: Dictus measured a first large-v3-turbo compile at about 3 min in the foreground vs more than 22 min in the background (iOS 26.6.1). |
| 3. Last resort | Container app, CPU | No entitlement, or the Neural Engine fails | WhisperKit or whisper.cpp **CPU-only**, small model | Risks the 80 %/60 s CPU watchdog on long utterances **[Unverified]**. |

The order of 2a and 2b is decided by the Phase 0 A/B.

**Mini latency after stop, base M4, 15 s utterance, no streaming [Estimate].** Scaled from M4 Max measurements on 27 Sep with the app's own whisper.xcframework and bundled llama-server; ratios from llama.cpp discussion #4167 and whisper.cpp issue #89.

| Configuration | ASR | Cleanup (~50 tokens) | Network | Total |
|---|---|---|---|---|
| As the Mac app ships (turbo on Metal, language auto, default llama-server), 5G via Tailscale relay | ~2.0 s (auto runs the encoder twice) | ~2.1–3.0 s | 0.2–0.6 s | **~5 s** |
| Optimised, LAN (Core ML encoder, fixed language, `--checkpoint-min-step 0` or MLX) | ~0.8 s | ~2.1 s | 0.03–0.1 s | **~3 s** |
| Full large-v3, fixed language | 2.6–3.0 s | ~2.1–3.0 s | — | **5–7.5 s** |

Other data points:
- A 5 s utterance is about 1.5–2.1 s at best and 3.5–4 s as shipped.
- A 30 s utterance is about 4–7 s.
- A new M6 Mini (the current base model per Apple's spec page) would still be about 1.8–2.7 s for 15 s, because token generation is limited by memory bandwidth and M6 improves it only about 1.3×.
- An M5 Pro Mini (307 GB/s) would roughly halve cleanup generation time.
- None of these configurations reliably meets 1.5 s. Hence streaming ASR plus incremental cleanup, in Phase 1.

**Specific Mini settings, from the latency follow-up:**
- **Language hint.** With language set to auto, whisper.cpp runs the encoder twice (confirmed in source and measured). Use a per-host-app or last-used language, a patch that reuses the encoder output, or a cheap separate language-ID step. Simon switches between EN, DE and FR, so a fixed language is not an option.
- **Core ML encoder.** A published base-M4 result encodes turbo in about 0.46 s on the Neural Engine, vs about 0.85–0.97 s estimated on the 10-core GPU. The Mac app currently ships without one.
- **Cap temperature fallback.** whisper.cpp re-decodes failed segments with 5 samples. On hard audio, likely including dialect, that multiplies decode time [Unverified on Swiss German].

Not recommended:
- whisper.cpp on Metal *on the phone* (fails in the background)
- Parakeet as the primary engine (no Swiss German)
- Qwen3-ASR (Argmax Pro SDK only, no Swiss German)
- in-process WhisperKit inside the keyboard (Neural Engine memory is now charged to the process)

### 6.6 Where cleanup runs

1. **Mini, incremental.**
   - Clean finalised sentences while the user is still talking. After ✓, re-clean only the tail (the last sentence or two), so the backtracking rule ("no wait, Wednesday") and list formatting still work across chunk boundaries. Whether quality holds needs an eval run [Unverified].
   - **Engine choice:**
     - llama-server with `--checkpoint-min-step 0` reuses the shared system prompt. Measured on the M4 Max, prompt reading dropped from about 280 ms to about 90 ms; on a base M4 that is about 1.1 s → 0.35–0.45 s [Estimate].
     - MLX generates about 1.4× faster but showed no prefix reuse.
   - **Pin the models:** no LM Studio TTL, no idle shutdown of the embedded llama-server. On the M4 Max itself, stop-to-paste has a median of about 1 s but a 90th percentile of about 6 s, most likely from idle unloads (13 "idle — stopping" events and a 1 h TTL in the logs).
   - Untested options to cut generated tokens: a smaller model (Qwen 3.5 2B/0.8B) or a diff/edit-style output format.
2. **Foundation Models, called from the keyboard extension.**
   - The keyboard is in the foreground and was not rate-limited in Dictus's tests.
   - Use `SystemLanguageModel` explicitly, never `PrivateCloudComputeLanguageModel` (that is Apple's cloud, with quotas).
   - Use plain `String` output with `.permissiveContentTransformations`.
   - **State the transcript's language in the prompt.** Without it, English examples pulled German output into English on an M1 Mac ([pladder PR #54](https://github.com/dinooo13/pladder/pull/54)).
   - Simon's 8 GB phone gets AFM 3 Core (3B).
3. **Raw transcript**, with a visible "not cleaned" indicator in the keyboard, like the Mac app's yellow warning.

Optional, untested UX idea: insert the raw text as soon as ASR finishes and replace it with the cleaned text when that arrives. It is risky, because the keyboard would have to delete exactly the inserted characters with `deleteBackward`, which breaks if the user moves the cursor.

Do not ship an on-device Qwen. The closest measured model, Qwen3-4B on an iPhone 17 Pro, decodes at about 28 tok/s using about 2.3 GB, needs the GPU (blocked in the background), and throttles under sustained load.

### 6.7 Fallback ladder, end to end

- **Session:** warm → dictate in place. Cold → one bounce, automatic return if the host resolves and its scheme is verified, otherwise the swipe-back screen.
- **Reaching the Mini:**
  - Home LAN name first.
  - Then the Tailscale `*.ts.net` name. This also triggers Tailscale's connect-on-demand, provided no other VPN has taken the slot.
  - Optionally Tailscale Funnel with an auth token. The phone then needs no VPN; the relays don't decrypt and TLS ends on the Mini. But it exposes an endpoint to the public internet, which is a privacy-model decision for Simon.
  - Otherwise, on-device.
- **ASR:** Mini → SpeechTranscriber in the keyboard or WhisperKit in the container (order set by Phase 0) → CPU small model.
- **Cleanup:** Mini → Foundation Models in the keyboard → raw.
- **Delivery:** `insertText` → clipboard + notification + history if the keyboard is gone.
- **Where the keyboard can't go** (password and phone-pad fields, apps that veto custom keyboards, Intune-managed apps with "Third party keyboards: Block"):
  - Action-button quick capture to the clipboard, then paste. Paste-in is allowed under Intune's default and Microsoft's Level 2/3 recommendation; it is blocked only if an admin chose "Blocked" or "Policy managed apps", or by MDM managed-pasteboard rules.
  - Or Apple's own dictation on the system keyboard. Intune App Protection has no dictation control; only a supervised MDM profile can disable it. You lose the Qwen cleanup there.

### 6.8 Start from existing code instead of from scratch

- **Dictus** (MIT, native Swift, WhisperKit/Parakeet, keyboard + app + shared core, French-first with DE/EN) is the closest template.
  - Take `UnifiedAudioEngine.swift`, `DictationCoordinator.swift`, `KeyboardState.swift` (Darwin start + 500 ms fallback), `HostAppResolver.swift` + `HostArbiterActivation.m`, and `KnownAppSchemes.swift`.
  - Dictus lacks the iOS 27 inference entitlement, so add it.
  - Dictus does ASR in the container app. Moving networking and SpeechAnalyzer into the keyboard is new work.
- **OpenWhispr** (MIT): the heartbeat and "frozen engine" detection in `AppGroupStorageModule.swift`, and the `DictationLinkView` cold-path overlay.
- **KeyVox** (MIT): the `ToggleKeyVoxDictationIntent` (AudioRecordingIntent + LiveActivityIntent), and the entitlement setup from PR #112 / commit 9a4090a3c0.

Whether to fork Dictus or copy these pieces into a fresh project is a Phase 1 decision. Forking saves weeks but inherits Dictus's product decisions, including its container-side ASR.

### 6.9 Walkthrough: a typical morning

*One-time setup:*
- Install from Xcode on the paid team, with the Background Inference capability enabled.
- Open the app and grant the microphone, Live Activities and notifications. Grant Local Network only if the app uses the Mini's LAN IP; the Tailscale path does not need it.
- The app reserves and installs SpeechTranscriber de-CH, fr-CH and en assets, and downloads and compiles WhisperKit, in the foreground.
- Add the keyboard and turn on Full Access.
- Tailscale runs with VPN On Demand. Check in Settings > VPN that no other VPN holds the slot.

**1. First dictation, WhatsApp chat (cold path).**
1. Tap the message field, then the Private Whisper mic key. The container heartbeat is stale, so the key's `Link` opens `pwhisper://record?req=…&host=net.whatsapp.WhatsApp`. The keyboard's arbiter lookup resolved the host at tap time.
2. The app comes to the front. It activates the audio session, starts the engine and the Live Activity, and begins writing chunks. Within ~250–500 ms it calls `open()` with WhatsApp's scheme.
   - Dictus measured `open()` being accepted up to 523 ms after foregrounding, and recording starting 420–639 ms after the tap, i.e. usually *after* the return. That race is still open as Dictus issue #569.
   - **[Unverified]:** whether `whatsapp://` resumes the chat or lands on the chat list. Test it.
   - If it doesn't resume, or the host didn't resolve, show a full-screen "◀ swipe right along the bottom edge" hint.
3. Back in WhatsApp, still talking. The keyboard reappears, receives `chunkReady` for each chunk and streams it to the Mini. The Mini transcribes and cleans completed sentences as they arrive.
4. Tap ✓. The app flushes the last chunk. The Mini transcribes it, re-cleans the tail and returns `{raw, clean}`. The keyboard inserts the text.
   - Phase 0 target: under ~1.5 s after ✓ for a 15 s dictation. Not measured.
   - Without streaming, the estimate is ~3 s on LAN, optimised, to ~5 s as the Mac stack ships today [Estimate].

**2. Four minutes later, a reply in Mail (warm path).**
- Switch to Mail and tap the mic. The heartbeat is fresh, so a Darwin `startRecording` fires and recording starts in place, with no app switch. The orange dot and Live Activity are already on. ✓ → insert.
- On a train with the Mini unreachable, the keyboard either:
  - runs SpeechTranscriber on the file (standard DE/FR/EN, if the spike passes), or
  - asks the container app to run WhisperKit on the Neural Engine (Swiss German).

  Then the keyboard runs Foundation Models cleanup and inserts.

**3. After a phone call.**
The interruption killed the session and the app wrote `dead`. The next mic tap goes straight to the cold path: one bounce, then warm again.

**4. Action button while reading something.**
- `QuickDictation` fires.
- If the app is warm, it records in the background. The text goes into the Private Whisper keyboard if it is visible, otherwise to the clipboard with a notification.
- If the app is cold, the `.foreground(.dynamic)` fallback bounces once **[Contested; spike]**. As a side effect the session is now warm, so the next keyboard tap won't bounce.

**5. Work Outlook, if the employer blocks third-party keyboards.**
- Long-pressing the globe key shows only Apple keyboards; the Private Whisper keyboard is not offered, even in a personal account inside Outlook.
- Press the Action button, dictate, and paste. Pasting works unless the admin restricted paste-in.
- Or use Apple's dictation on the system keyboard, without cleanup.
- Whether this applies is unknown until checked on the actual phone; the setting can't be seen from outside.

---

## 7. Risks and unknowns

| # | Risk / unknown | Status | Phase 0 test that resolves it | Decision it drives |
|---|---|---|---|---|
| 0 | **Keyboard blocked in the apps Simon dictates into most** (Intune "Third party keyboards: Block", app-level veto); paste-in restricted; corporate VPN holding the VPN slot (Defender web protection, Microsoft Tunnel) or supervision blocking VPN creation | [Unverified] for Simon's phone; mechanisms [Partially confirmed] | **Two minutes, before any code.** In work Outlook, start a new mail, long-press the globe key and check whether third-party keyboards appear. Copy text from Notes and paste it. Check Settings > VPN, VPN & Device Management, Company Portal, and About for "supervised". Try WhatsApp, SBB and banking/TWINT with any third-party keyboard. List his top 5 dictation targets. | Whether the keyboard or the Action-button quick capture ships first; whether the Tailscale path is viable or Funnel/LAN-only is needed. |
| 1 | **Mini latency after stop** exceeds ~1.5 s even when optimised | [Estimate]: ~3 s (LAN, optimised) to ~5 s (as shipped) for 15 s on a base M4; cleanup dominates | Run the scratch harness (`wbench.c` + curl cleanup timing) on the real Mini, or decide hardware first. Prototype streaming + incremental cleanup and measure stop-to-insert across Simon's real length distribution (from the macOS app's usage logs). | Which Mini to buy if not yet bought (M6 24 GB vs M5 Pro); cleanup model size; streaming design. |
| 2 | Chunked ASR and incremental cleanup hurt quality: Swiss German, code-switching, backtracking across chunk boundaries, list formatting | [Unverified] | Run `evals/` in chunked mode vs whole-file mode on the Mini. | Chunk size, VAD cutting, and how much tail to re-clean. |
| 3 | The iOS 27 inference entitlement is self-service for Simon's paid team | [Partially confirmed] (circumstantial) | Ten minutes: add "Background Inference" in Xcode 27 Signing & Capabilities with his team, build, and check `embedded.mobileprovision` with `security cms -D -i`. | Whether tier 2b keeps the Neural Engine. |
| 4 | What an unentitled backgrounded app gets on 27.0 (error, silent CPU fallback, deferral or success), and why Dictus works | [Unverified]. Not SDK-gated as far as any evidence shows. Simon's phone is the same model as Dictus's test device. | 2×2 matrix: Xcode 26.4 vs 27 × entitlement on/off. Run a backgrounded Core ML inference that allows the Neural Engine, read the kernel "Inference not permitted"/"Blocking inference" lines in Console, and time it to spot CPU fallback. | Whether the entitlement is strictly needed; do not rely on building with Xcode 26 to escape the gate. |
| 5 | **SpeechAnalyzer inside the keyboard extension**: does the XPC service accept a keyboard client under the device sandbox; can the keyboard see container-installed assets; locales on an iOS 27 iPhone; whose jetsam budget the service's Neural Engine memory counts against; does the background gate apply to it for a backgrounded container app | [Unverified]; plausible from docs and the macOS test | One day on the physical iPhone (the simulator can't test it): a Full Access keyboard transcribes an App Group WAV the container wrote. Log errors, check `status`/`installedLocales`, and watch memory via the Xcode gauge and `MemoryExceptionDiagnostic`. | Whether tier 2a exists. |
| 6 | Jetsam with WhisperKit resident in a backgrounded app on iOS 27 (Neural Engine memory now charged to the app; VocaPhone hit ~3 GB within an hour) | [Unverified] | One-hour soak with compressed turbo and large-v3 while using the camera and Safari; memory graph; count kills. | Keep the model resident vs load on demand vs Mini-first only. |
| 7 | CPU watchdog (80 %/60 s) for the CPU fallback | [Unverified] | Transcribe a 60 s utterance CPU-only in the background; watch for `cpu_resource_fatal`. | Whether the CPU fallback is viable, and at which model size. |
| 8 | Private auto-return breaks on 27.x, or misses in Simon's apps | [Partially confirmed]: one developer, one device, ~7 % misses in ordinary use; 7/7 on iOS 27.0 but only in Notes and Telegram | Port HostAppResolver and test 20 hand-offs each in WhatsApp, Mail, Messages, Threema, Slack, SBB and Safari on iOS 27.x. | Ship auto-return, or rely on the swipe-back screen. |
| 9 | URL schemes launch rather than resume (e.g. `sms://` opens compose; Safari can't resume) | [Partially confirmed] | Per-app check of where each scheme lands. | Which apps go in the catalogue. |
| 10 | Wispr/Typeless-style mic-off idle state (no orange dot) | [Contested] | Start a playback-only engine in the foreground, background the app, enable input when the keyboard signals, on iOS 27. Expect `cannotStartRecording`. | Whether the always-on orange dot is avoidable. |
| 11 | `AudioRecordingIntent` cold start from a terminated app | [Contested] (KeyVox ships it; Sorla failed on 27.0, Jot on 26.3.1) | Force-quit the app, press the Action button, check whether capture starts. | Whether the Action button can arm a session without a bounce. |
| 12 | Battery and thermal cost of a warm session | [Unverified] (Dictus ~3.3 %/h on the same iPhone model; the "40→5 %/h" Wispr figure comes from an unofficial guide) | Two hours of warm idle plus 20 dictations; read battery drain. | Default idle timeout. |
| 13 | Swiss German accuracy per engine | Published data only for Whisper; turbo is worse than large-v3; SpeechTranscriber has no dialect locale | Run the `evals/` samples through: WhisperKit turbo 626 MB, WhisperKit large-v3 947 MB, SpeechTranscriber de-CH, Mini turbo, Mini full large-v3, and a Swiss-German fine-tuned turbo. | Engine per tier; whether turbo's accuracy is acceptable in the live path. |
| 14 | Foundation Models cleanup quality (Helvetisms, language preservation), and keyboard memory headroom with network + FM + SpeechAnalyzer client at a real ~60 MB working set | [Unverified]; only M1 Mac latency known (1.5–1.8 s warm) | Eval set through FM from inside the keyboard on Simon's phone (AFM 3 Core, 3B); Instruments memory check; keep ≤ 30–40 MB baseline. | Whether FM is a usable offline tier, and how much can live in the keyboard. |
| 15 | Mini reachability over Tailscale on Swiss 5G: DERP relay (nearest are Frankfurt, Nuremberg and Paris; none in Switzerland), first packet after idle, ATS, Mini asleep | [Estimate]: network 0.03–0.6 s after stop | Round-trip timings from the keyboard on LAN, 5G direct and 5G via DERP; test with UDP 41641 forwarded. | Health-check threshold; port-forward; Funnel. |
| 16 | First Neural Engine compile is very slow in the background | [Unverified] (one project) | Measure a compile at onboarding vs a background compile. | Onboarding must compile in the foreground. |
| 17 | Core ML memory growth with Xcode 27 builds on iOS 27 (forum report, no Apple reply) | [Unverified], low confidence | Watch memory during the soak (#6). | Pin build settings or file a bug. |
| 18 | How often calls, Siri and AirPods route changes kill the session | [Partially confirmed] that they do | One week of daily use with a counter. | Whether the cold path needs more polish. |
| 19 | Recording inside the keyboard with Full Access + `hasDictationKey` (FB16791704) | Documented as not allowed | Optional 30-minute device test on iOS 27; low priority. | If it worked (very unlikely), audio could stream straight to the Mini with no container app. |
| 20 | App Review (2.5.1, 2.5.4, 4.4.1) | Not applicable to a personal Xcode or internal-TestFlight build | — | Matters only if the app is ever distributed. VocaPhone's 2.5.4 rejection is the precedent. |

---

## 8. Phased plan

Effort is in focused developer-days, assuming Claude-assisted Swift development, and is rough.

**Step 0: phone check (30 minutes, Simon, no code).** Risk #0. The answers decide the order of Phases 1 and 3:
- Keyboard and paste test in work Outlook/Teams.
- VPN and profile check.
- Supervision check.
- A list of the top dictation targets.

**Also: a Mini hardware decision.** Is the Mini already bought (M4), or still to be bought (M6 or M5 Pro)? An M5 Pro (307 GB/s) roughly halves cleanup generation time and changes the latency outcome more than any software fix [Estimate].

**Phase 0: device spike (7–10 days).** One throwaway app, keyboard and shared core on Simon's iPhone 15 Pro Max running iOS 27.x.
- Minimal hot-mic session: foreground start, background warm idle, Darwin start and stop, App Group chunks, keyboard-side upload, `insertText`.
- Entitlement checks (#3, #4): about 1 day including the 2×2 matrix.
- SpeechAnalyzer-in-keyboard spike (#5): 1 day.
- Other risks: #6, #7, #10, #11, #12, #14 and #16.
- Mini streaming endpoint prototype and latency on real hardware (#1, #2, #15).
- Swiss German and DE/FR A/B across all ASR candidates using `evals/` (#13).
- Dictus HostAppResolver ported and tested in Simon's top apps (#8, #9).

*Exit criteria:* engine per tier chosen, entitlement status known, keyboard-side ASR viability known, streaming latency measured, warm-session battery known, auto-return viability known.

**Phase 1: keyboard + hot-mic + streaming MVP (10–15 days).**
- **Container app:** SessionManager, ChunkWriter, heartbeat, idle timeout, interruption handling, Live Activity, `beginBackgroundTask` guard.
- **Keyboard:** mic/✓, waveform, globe key, cold-path `Link`, swipe-back hint screen (no auto-return yet), MiniClient streaming, keyboard heartbeat.
- **Mini service**, reusing the Mac app's whisper.cpp and llama-server pieces:
  - streaming turbo with a Core ML encoder and a language hint
  - incremental cleanup with tail re-clean
  - `--checkpoint-min-step 0` or MLX
  - pinned models
  - fallback cap
  - HTTPS on the tailnet name
- **Offline tier:** whichever on-device ASR Phase 0 picked. Raw fallback; clipboard/history fallback when the keyboard is gone.
- Paid-team Xcode install.
- **If Step 0 finds that Simon's main targets are keyboard-blocked work apps:** move the Action-button `QuickDictation` → clipboard flow from Phase 3 into this phase.

**Phase 2: seamlessness (6–10 days).**
- Auto-return: host resolver plus a *verified* scheme catalogue for Simon's apps, with confirmed-resume checks. Unknown hosts fall back to the hint screen.
- Foundation Models cleanup in the keyboard as the offline tier.
- Pre-roll buffer.
- Tuned idle-timeout defaults.
- Reachability ladder (LAN → `*.ts.net` → optional Funnel → on-device) with a visible indicator when the VPN slot is taken.
- Instrumentation: bounce rate, return success, stop-to-insert latency per tier, session kills.

**Phase 3: triggers and parity (4–6 days).**
- `ArmSession` and `QuickDictation` App Intents (Action button, Control Center), with the fallback that Phase 0 #11 dictates.
- Settings parity with macOS: server URL, model, cleanup toggle, timeouts.
- Optional per-app cleanup styles and language hints using the resolved host bundle ID (for example casual German in WhatsApp, formal English in Mail). Wispr lost this in iOS 26.4 and partly regained it.

**Phase 4: optional polish.**
- Battery tuning.
- Smaller or diff-style cleanup model if latency is still above target.
- Re-validate the private host detection on every iOS point release. Add a simple self-test screen so breakage is noticed on day one.

The quick-capture app from July's Phase 1 comes along almost for free: it is the same container app, triggered from the Action button, delivering to the clipboard.

---

## 9. Sources

**Wispr Flow**
- https://docs.wisprflow.ai/articles/7453988911-set-up-the-flow-keyboard-on-iphone
- https://docs.wisprflow.ai/articles/3634682593-why-the-orange-dot-or-mic-indicator-stays-on-after-dictating-ios
- https://docs.wisprflow.ai/articles/6269634092-adapting-to-ios-26-4
- https://web.archive.org/web/20260414111813/https://docs.wisprflow.ai/articles/6269634092-adapting-to-ios-26-4?lang=en
- https://docs.wisprflow.ai/articles/1986921789-how-to-set-up-flow-shortcuts-for-iphone
- https://docs.wisprflow.ai/articles/4500510662-set-up-the-action-button-for-flow-on-iphone
- https://docs.wisprflow.ai/articles/8415579688-why-wispr-flow-doesn-t-pause-background-audio-on-iphone-ios
- https://docs.wisprflow.ai/articles/9620169737-ios-missing-audio-chunks-during-unstable-internet
- https://docs.wisprflow.ai/articles/7143508770-play-back-your-recordings-from-history-on-ios
- https://docs.wisprflow.ai/articles/7148015379-turn-off-or-remove-the-flow-keyboard-on-iphone
- https://docs.wisprflow.ai/articles/3467817258-security-and-compliance-faq
- https://docs.wisprflow.ai/articles/9609615338-private-cloud-sync-and-data-sharing-preferences-in-wispr-flow
- https://docs.wisprflow.ai/articles/2772472373-what-is-flow
- https://web.archive.org/web/20251127045705/https://docs.wisprflow.ai/articles/4898971676-customizing-ios
- https://web.archive.org/web/20250829080146/https://docs.wisprflow.ai/articles/3264364421-why-can-t-i-use-siri-during-my-flow-session
- https://wisprflow.ai/whats-new
- https://wisprflow.ai/post/technical-challenges (700 ms target and budget)
- https://wisprflow.ai/privacy
- https://wisprflow.ai/data-controls
- https://wisprflow.ai/canto
- https://www.baseten.co/resources/customers/wispr-flow/
- https://apps.apple.com/us/app/wispr-flow-ai-voice-keyboard/id6497229487
- https://9to5mac.com/2025/06/30/wispr-flow-is-an-ai-that-transcribes-what-you-say-right-from-the-iphone-keyboard/
- https://spokenly.app/blog/wispr-flow-review
- https://github.com/vkorost/wispr-flow-field-guide/blob/main/book/chapters/05-iphone.md (unofficial)

**Peers and reference code**
- Dictus:
  - https://github.com/getdictus/dictus-ios
  - https://github.com/getdictus/dictus-ios/pull/538
  - https://github.com/getdictus/dictus-ios/pull/563
  - https://github.com/getdictus/dictus-ios/pull/568
  - https://github.com/getdictus/dictus-ios/issues/23
  - https://github.com/getdictus/dictus-ios/issues/106
  - https://github.com/getdictus/dictus-ios/issues/268
  - https://github.com/getdictus/dictus-ios/issues/315
  - https://github.com/getdictus/dictus-ios/issues/361
  - https://github.com/getdictus/dictus-ios/issues/430
  - https://github.com/getdictus/dictus-ios/issues/472
  - https://github.com/getdictus/dictus-ios/issues/515
  - https://github.com/getdictus/dictus-ios/issues/543
  - https://github.com/getdictus/dictus-ios/issues/555
  - https://github.com/getdictus/dictus-ios/issues/569
  - https://github.com/getdictus/dictus-ios/blob/main/DEVELOPMENT_AUDIO.md
  - https://github.com/getdictus/dictus-ios/blob/main/DictusKeyboard/HostAppResolver.swift
  - https://github.com/getdictus/dictus-ios/blob/main/DictusApp/Audio/UnifiedAudioEngine.swift
  - https://github.com/getdictus/dictus-ios/blob/main/DictusApp/Audio/ParakeetEngine.swift
  - https://github.com/getdictus/dictus-ios/blob/main/DictusApp/DictusApp.entitlements
  - https://github.com/getdictus/dictus-ios/blob/main/.github/workflows/ci.yml
  - https://github.com/getdictus/dictus-ios/commit/a1469acfa5
  - https://github.com/getdictus/dictus-ios/blob/main/docs/research/570-structured-fidelity/findings.md
  - https://github.com/getdictus/dictus-ios/blob/main/docs/research/572-message/corpus.json
  - https://github.com/getdictus/dictus-ios/blob/main/tools/ane-harness/README.md
  - https://github.com/getdictus/dictus-ios/blob/main/docs/auto-return-catalogue.md
  - https://github.com/getdictus/dictus-ios/blob/main/docs/research/268-ane-background-llm.md
  - https://github.com/getdictus/dictus-ios/releases/tag/v1.9.0
  - https://apps.apple.com/ch/app/dictus-ai-voice-keyboard/id6761262378
- VivaDicta:
  - https://github.com/n0an/VivaDicta
  - https://github.com/n0an/VivaDicta/blob/main/documentation/Hot-Mic-Audio-Prewarm-Architecture.md
  - https://github.com/n0an/VivaDicta/commit/2c9efdd97f185dc80c747b5b29c7133b83f835ce
  - https://github.com/n0an/VivaDicta/issues/388
- OpenWhispr:
  - https://github.com/OpenWhispr/openwhispr/tree/main/openwhispr-mobile
  - https://github.com/OpenWhispr/openwhispr/pull/2365
- KeyVox:
  - https://github.com/macmixing/keyvox
  - https://github.com/macmixing/keyvox/pull/112 (inference entitlement)
  - https://github.com/macmixing/keyvox/commit/9a4090a3c0
  - https://github.com/macmixing/keyvox/commit/88a3e2e8ab (CPU-only workaround)
  - https://github.com/macmixing/keyvox/blob/main/iOS/CHANGELOG.md
  - https://github.com/macmixing/keyvox/blob/main/iOS/KeyVox%20iOS/KeyVoxiOS.entitlements
  - https://github.com/macmixing/keyvox/pull/155
  - https://github.com/macmixing/keyvox/pull/230 (Live Activity crash fix in App Intents; not the entitlement)
  - https://apps.apple.com/us/app/keyvox-ai-voice-keyboard/id6760396964
- VocaPhone:
  - https://github.com/VocaHQ/vocaphone
  - https://github.com/VocaHQ/vocaphone/pull/312
  - https://github.com/VocaHQ/vocaphone/pull/324
- Sayboard: https://github.com/stanlsv/sayboard
- Other device tests, entitlement usage and research notes:
  - https://github.com/markstrom/sorla/issues/66
  - https://github.com/vineetu/jot-mobile/blob/main/docs/research/ios26-audiorecording-action-button.md
  - https://github.com/justingluska/yapper/blob/main/project.yml
  - https://github.com/argmaxinc/argmax-sdk-swift-playground/blob/main/Playground/Resources/Playground.entitlements
  - https://github.com/aarif86/MultilingualWhisper
  - https://github.com/Muesli-HQ/muesli-ios
  - https://dev.to/nr666_dev/an-ios-keyboard-extension-cannot-learn-the-host-apps-bundle-id-the-containing-app-can-4o9a
- KeyboardKit:
  - https://keyboardkit.com/blog/2026/03/02/ios-26-4-host-application-bundle-id-bug
  - https://keyboardkit.com/blog/2026/07/02/keyboardkit-10.6.1
  - https://keyboardkit.com/blog/2026/08/24/evaluating-a-new-host-application-approach
  - https://github.com/KeyboardKit/KeyboardKit/releases/tag/10.9.0
  - https://keyboardkit.com/blog/2026/01/03/a-brand-new-keyboard-dictation-experience
  - https://docs.keyboardkit.com/documentation/keyboardkit/developer-dictation
  - https://docs.keyboardkit.com/documentation/keyboardkit/dictation-article
  - https://docs.keyboardkit.com/documentation/keyboardkit/host-article
  - https://keyboardkit.com/pricing
- Apps that veto custom keyboards:
  - https://github.com/Dashlane/apple-apps/blob/main/Dashlane/AppDelegate.swift
  - https://github.com/olvid-io/olvid-ios/blob/main/Sources/App/AppAndExtensions/App/Sources/AppDelegate.swift
  - https://github.com/threema-ch/threema-ios/blob/main/Threema/ApplicationDelegate.swift (no veto)
  - https://github.com/signalapp/Signal-iOS/blob/main/Signal/AppLaunch/AppDelegate.swift (no veto)
  - https://github.com/search?q=shouldAllowExtensionPointIdentifier&type=code
- Other vendors:
  - https://help.willowvoice.com/en/articles/12855752-why-am-i-taken-back-to-the-willow-ios-app-before-i-can-dictate
  - https://www.monologue.to/docs/troubleshooting/iphone-and-ipad
  - https://9to5mac.com/2026/04/17/aqua-voice-the-best-dictation-app-ive-ever-used-is-now-available-on-iphone/
  - https://superwhisper.com/docs/common-issues/ios-26-keyboard-changes
  - https://spokenly.app/docs/ios/background-dictation
  - https://www.typeless.com/data-controls

**Apple platform**
- Release notes and releases:
  - https://developer.apple.com/documentation/ios-ipados-release-notes
  - https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes
  - https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27_2-release-notes
  - https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes
  - https://developer.apple.com/news/releases/
  - https://developer.apple.com/news/upcoming-requirements/
  - https://support.apple.com/en-us/100100 (iOS 27 release date)
- Background Neural Engine and GPU:
  - https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.background-tasks.continued-processing.inference
  - https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.background-tasks.continued-processing.gpu
  - https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.private-cloud-compute
  - https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.family-controls
  - https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados
  - https://developer.apple.com/documentation/metal/preparing-your-metal-app-to-run-in-the-background
  - https://developer.apple.com/documentation/coreml/mlcomputeunits
- Kernel ANE driver string diffs:
  - https://github.com/blacktop/ipsw-diffs/blob/main/26_5_23F77_vs_27_0_24A5355q/KEXTS/com.apple.driver.AppleH16ANEInterface.md
  - https://github.com/blacktop/ipsw-diffs/blob/main/27_0_24A5370h_vs_27_0_24A5380h/KEXTS/com.apple.driver.AppleH16ANEInterface.md
  - https://github.com/blacktop/ipsw-diffs/blob/main/27_0_24A5390f_vs_27_0_24A5408d/KEXTS/com.apple.driver.AppleH16ANEInterface.md
  - https://github.com/blacktop/ipsw-diffs/blob/main/27_0_24A5370h_vs_27_0_24A5380h/README.md
- Entitlement grants in Apple's own apps:
  - https://github.com/blacktop/ipsw-diffs/blob/main/27_0_24A5370h_vs_27_0_24A5380h/Entitlements.md
  - https://github.com/blacktop/ipsw-diffs/blob/main/27_0_24A5390f_vs_27_0_24A5408d/Entitlements.md
  - https://github.com/blacktop/ipsw-diffs/blob/main/27_0_24A437_vs_27_2_24B5084k/Entitlements.md
- Capabilities and provisioning:
  - https://developer.apple.com/help/account/reference/supported-capabilities-ios
  - https://developer.apple.com/help/account/capabilities/capability-requests
  - https://developer.apple.com/help/account/reference/provisioning-with-managed-capabilities
- Audio session errors, background execution and App Intents:
  - https://developer.apple.com/documentation/coreaudiotypes/avaudiosession/errorcode/cannotstartrecording
  - https://developer.apple.com/documentation/coreaudiotypes/avaudiosession/errorcode/cannotinterruptothers
  - https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time
  - https://developer.apple.com/documentation/uikit/uiapplication/beginbackgroundtask(withname:expirationhandler:)
  - https://developer.apple.com/documentation/appintents/audiorecordingintent
  - https://developer.apple.com/documentation/appintents/liveactivityintent
- Foundation Models:
  - https://developer.apple.com/documentation/foundationmodels/languagemodelsession/generationerror/ratelimited(_:)
  - https://developer.apple.com/documentation/foundationmodels/languagemodelerror/ratelimited(_:)
  - https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/guardrails/permissivecontenttransformations
  - https://machinelearning.apple.com/research/introducing-third-generation-of-apple-foundation-models
- Speech:
  - https://developer.apple.com/documentation/speech/speechtranscriber
  - https://developer.apple.com/documentation/speech/speechtranscriber/supportedlocales
  - https://developer.apple.com/documentation/speech/asking-permission-to-use-speech-recognition
  - https://developer.apple.com/documentation/speech/assetinventory
  - https://developer.apple.com/documentation/speech/assetinventory/maximumreservedlocales
  - https://developer.apple.com/documentation/speech/assetinstallationrequest/downloadandinstall()
  - https://developer.apple.com/documentation/speech/sfspeecherror/code
  - https://developer.apple.com/documentation/speech/assetinputsequenceprovider
  - https://developer.apple.com/videos/play/wwdc2025/277/
  - https://antongubarenko.substack.com/p/ios-26-speechanalyzer-guide
- Keyboard extensions:
  - https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard ("No access to microphone and speaker", re-checked 2026-09-27)
  - https://developer.apple.com/documentation/uikit/uiapplicationdelegate/application(_:shouldallowextensionpointidentifier:)
  - https://developer.apple.com/documentation/uikit/uiapplication/extensionpointidentifier/keyboard
  - https://developer.apple.com/documentation/foundation/nsextensioncontext/open(_:completionhandler:)
  - https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html
  - https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionOverview.html
- Networking:
  - https://developer.apple.com/documentation/foundation/urlsessionconfiguration/sharedcontaineridentifier
  - https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking
  - https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy
- Device management:
  - https://developer.apple.com/documentation/devicemanagement/restrictions
  - https://github.com/apple/device-management/blob/release/mdm/profiles/com.apple.applicationaccess.yaml
  - https://github.com/apple/device-management/blob/release/declarative/declarations/configurations/keyboard.settings.yaml
  - https://github.com/apple/device-management/commits/release
  - https://support.apple.com/guide/deployment/vpn-overview-depae3d361d0/web
  - https://developer.apple.com/app-store/review/guidelines/
- Developer forum threads:
  - https://developer.apple.com/forums/thread/826851
  - https://developer.apple.com/forums/thread/812091
  - https://developer.apple.com/forums/thread/812592
  - https://developer.apple.com/forums/thread/742601
  - https://developer.apple.com/forums/thread/775077
  - https://developer.apple.com/forums/thread/769398
  - https://developer.apple.com/forums/thread/65604
  - https://developer.apple.com/forums/thread/120038
  - https://developer.apple.com/forums/thread/797538
  - https://developer.apple.com/forums/thread/807957
  - https://developer.apple.com/forums/thread/813278
  - https://developer.apple.com/forums/thread/791086
  - https://developer.apple.com/forums/thread/839109
  - https://developer.apple.com/forums/thread/843063
  - The forums returned HTTP 403 to automated fetches during the 27 Sep follow-ups, so no additional threads were checked.
- Runtime and library issues:
  - https://github.com/ggml-org/whisper.cpp/issues/3914
  - https://github.com/ggml-org/ggml/issues/1545
  - https://github.com/argmaxinc/argmax-oss-swift/issues/194
  - https://github.com/FluidInference/FluidAudio/blob/main/Documentation/TTS/KokoroAne.md
  - https://github.com/ryanbr/noop/issues/2521

**Microsoft Intune, Defender and Tunnel**
- https://learn.microsoft.com/en-us/intune/app-management/protection/ref-settings-ios
- https://learn.microsoft.com/en-us/intune/intune-service/apps/app-protection-policy-settings-ios
- https://learn.microsoft.com/en-us/intune/intune-service/apps/app-protection-framework
- https://learn.microsoft.com/en-us/intune/intune-service/apps/apps-supported-intune-apps
- https://learn.microsoft.com/en-us/intune/intune-service/apps/app-protection-policy
- https://techcommunity.microsoft.com/t5/Intune-Customer-Success/Updated-Known-issue-Third-party-keyboards-are-not-blocked-in-iOS/ba-p/339486
- https://learn.microsoft.com/en-us/defender-endpoint/ios-configure-features
- https://learn.microsoft.com/en-us/defender-endpoint/ios-troubleshoot
- https://learn.microsoft.com/en-us/intune/intune-service/protect/microsoft-tunnel-overview
- https://learn.microsoft.com/en-us/intune/intune-service/protect/microsoft-tunnel-mam-ios

**Tailscale and network**
- https://tailscale.com/docs/features/client/ios-vpn-on-demand
- https://tailscale.com/kb/1291/ios-vpn-on-demand
- https://tailscale.com/kb/1105/other-vpns
- https://tailscale.com/kb/1223/funnel
- https://tailscale.com/docs/reference/derp-servers
- https://tailscale.com/docs/reference/connection-types
- https://www.speedtest.net/global-index/switzerland
- https://wondernetwork.com/pings/Zurich/Frankfurt

**Mac Mini hardware and Mini-side latency**
- https://www.apple.com/mac-mini/specs/
- https://www.apple.com/mac-mini/
- https://github.com/ggml-org/llama.cpp/discussions/4167
- https://github.com/ggml-org/llama.cpp/discussions/4167#discussioncomment-18210351
- https://github.com/ggml-org/llama.cpp/discussions/4167#discussioncomment-18154396
- https://github.com/ggml-org/llama.cpp/pull/15293 (checkpoint-min-step)
- https://github.com/ggml-org/whisper.cpp/issues/89#issuecomment-2827317514
- https://github.com/ggml-org/whisper.cpp/issues/89#issuecomment-2076059931
- https://github.com/ggml-org/whisper.cpp/issues/89#issuecomment-1742441700
- https://github.com/ggml-org/whisper.cpp/blob/398997ed68095e39a6a0df3bc05c7dd880d0c607/src/whisper.cpp#L4152-L4185 (auto language runs the encoder)
- https://github.com/ggml-org/whisper.cpp/blob/398997ed68095e39a6a0df3bc05c7dd880d0c607/src/whisper.cpp#L6985-L7000
- https://github.com/ggml-org/whisper.cpp/blob/398997ed68095e39a6a0df3bc05c7dd880d0c607/src/whisper.cpp#L6128-L6175 (temperature fallback)

**Models and Swiss German**
- Swiss German ASR papers and model cards:
  - https://arxiv.org/html/2606.07608v1
  - https://arxiv.org/abs/2506.08836
  - https://arxiv.org/abs/2404.19310
  - https://huggingface.co/nizarmichaud/whisper-large-v3-turbo-swissgerman (not peer-reviewed)
  - https://huggingface.co/gcoli/whisper-large-v3-swiss-german-mit
- WhisperKit:
  - https://huggingface.co/argmaxinc/whisperkit-coreml/raw/main/config.json
  - https://github.com/argmaxinc/argmax-oss-swift/releases/tag/v1.1.0
  - https://www.argmaxinc.com/blog/iphone-17-on-device-inference-benchmarks
- Other ASR engines:
  - https://github.com/FluidInference/FluidAudio/releases/tag/v0.17.3
  - https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3
  - https://huggingface.co/Qwen/Qwen3-ASR-1.7B
- Benchmarks and cleanup tests:
  - https://dicta.to/blog/speech-to-text-engine-comparison-mac-2026/
  - https://github.com/john-rocky/apple-silicon-llm-bench
  - https://github.com/dinooo13/pladder/pull/54

**Local measurements and data (27 Sep 2026; not public)**

The scratch files live in the session scratchpad at `/private/tmp/claude-501/-Users-simon-Documents-claude-whisper-local/e86b618b-56b1-4eba-8f78-9f9bc2457157/scratchpad/`, which may be deleted. No repository files were modified.
- **M4 Max whisper benchmark:** `wbench.c`, `a6/a15/a25.wav`, `turbo.txt`, `large.txt`, `turbo_de.txt`, `large_de.txt`, run against `macos/Frameworks/whisper.xcframework` with the decode settings from `macos/Sources/PrivateWhisper/Transcriber.swift`.
- **M4 Max cleanup timings:** bundled `macos/vendor/llama-server` and LM Studio, with `shared/prompts/cleanup_prompt.txt`. Cross-checked against `evals/results.md`, `evals/qwen35-4b-14samples.json`, `evals/compare_one.py` and `shared/model_manifest.json`.
- **Simon's usage and latency distribution:** `~/Library/Application Support/PrivateWhisper/app.log` (13 Jul – 27 Sep 2026, 250 dictations).
- **macOS 27 SpeechAnalyzer tests:** `locales.swift`, `transcribe.swift`, `transcribe2.swift`. iOS simulator results: `sim_out.txt`. iOS 26.2 SDK Speech `swiftinterface` and the simulator runtime's `localspeechrecognition.xpc/Info.plist`.
- **Device and host facts:**
  - `xcrun devicectl` device info (iPhone 15 Pro Max, iOS 27.0).
  - `profiles status -type enrollment` (Mac not enrolled in MDM).