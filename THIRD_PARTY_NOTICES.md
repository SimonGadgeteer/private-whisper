# Third-party components

- **whisper.cpp** (vendored as `Frameworks/whisper.xcframework`) — MIT License, © ggml-org contributors. https://github.com/ggml-org/whisper.cpp
- **llama.cpp** (vendored as `vendor/llama-server`, embedded in the app bundle) — MIT License, © ggml-org contributors. https://github.com/ggml-org/llama.cpp

Model weights are **not** distributed with this repository or the app; they are downloaded by the user at first run:

- OpenAI Whisper large-v3 / large-v3-turbo (ggml conversion) — MIT. https://huggingface.co/ggerganov/whisper.cpp
- Qwen 3.5 4B (GGUF) — Apache 2.0, © Alibaba Cloud. https://huggingface.co/lmstudio-community/Qwen3.5-4B-GGUF

## iOS app (`ios/`)

- **argmax-oss-swift / WhisperKit 1.1.0** (Swift package, product `WhisperKit`, linked into the iOS container app only; the keyboard extension links no packages) — MIT License, © 2024 Argmax, Inc. https://github.com/argmaxinc/argmax-oss-swift. It incorporates portions of **swift-transformers** (Apache License 2.0, © 2022 Hugging Face SAS), as listed in its `NOTICES` file.
- **Dictus** — MIT License, © 2026 PIVI Solutions. https://github.com/getdictus/dictus-ios (revision `0fd7bad`, release 1.9.0). Techniques and portions of code were adapted, not copied file-for-file; every adapted file carries an attribution header. Adapted in:
  - `ios/Shared/AppGroup.swift`, `Protocol.swift`, `DarwinNotify.swift`, `ModelWarmth.swift` (from `DictusCore` AppGroup, SharedKeys, DictationStatus, KeyboardDictationURL, DictationSessionLiveness, DarwinNotifications, ModelWarmth)
  - `ios/App/PrivateWhisperApp.swift`, `SessionController.swift` (from `DictusApp.swift`, `DictationCoordinator.swift`, `ColdStartResolution.swift`, `DictationHandoff.swift`, `HostForegroundDebt.swift`)
  - `ios/App/Audio/AudioEngine.swift`, `TapState.swift`, `PWExceptionCatcher.h/.m` (from `UnifiedAudioEngine.swift` and its policy files, `SystemCallObserver.swift`, `ObjCExceptionCatcher`)
  - `ios/App/ASR/ASREngine.swift` (from `SpeechModelProtocol.swift`, `WarmInference.swift`, `ModelManager.swift`)
  - `ios/App/Views/SwipeBackView.swift` (concept from `SwipeBackOverlayView.swift`)
  - `ios/Keyboard/KeyboardViewController.swift`, `KeyboardState.swift`, `KeyboardView.swift`, `PWTextProxy.h/.m` (from `KeyboardViewController.swift`, `KeyboardLifecycleProbe.swift`, `KeyboardState.swift`, `KeyboardPolishCoordinator.swift`, `PendingDictation.swift`, `KeyboardRootView.swift`, `TextProxyIdentity.m`)
  - `ios/Keyboard/Cleanup/FMCleanup.swift`, `CleanupPrompt.swift`, `CleanupGuardrail.swift` (from `DictusCore/Polish`: AppleFoundationModelsPolishEngine, PolishPipeline, PolishAvailabilityGate, PolishTimeBudget, PolishContextBudget, PolishTask, PolishGuardrail, PolishPrefixAlignment, PolishGrounding, PolishLexicon, PolishSegmentation)
  - `ios/project.yml` (project configuration)

  ```
  MIT License

  Copyright (c) 2026 PIVI Solutions

  Permission is hereby granted, free of charge, to any person obtaining a copy
  of this software and associated documentation files (the "Software"), to deal
  in the Software without restriction, including without limitation the rights
  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
  copies of the Software, and to permit persons to whom the Software is
  furnished to do so, subject to the following conditions:

  The above copyright notice and this permission notice shall be included in all
  copies or substantial portions of the Software.

  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
  SOFTWARE.
  ```

Model weights downloaded by the iOS app at first run (not distributed with the repository or the app):

- OpenAI Whisper large-v3 / large-v3-turbo, Core ML conversions by Argmax (`argmaxinc/whisperkit-coreml`) — OpenAI Whisper weights are MIT. https://huggingface.co/argmaxinc/whisperkit-coreml (confirm the Hugging Face repository's licence before redistributing).
