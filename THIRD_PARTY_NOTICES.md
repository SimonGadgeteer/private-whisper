# Third-party components

- **whisper.cpp** (vendored as `Frameworks/whisper.xcframework`) — MIT License, © ggml-org contributors. https://github.com/ggml-org/whisper.cpp
- **llama.cpp** (vendored as `vendor/llama-server`, embedded in the app bundle) — MIT License, © ggml-org contributors. https://github.com/ggml-org/llama.cpp

Model weights are **not** distributed with this repository or the app; they are downloaded by the user at first run:

- OpenAI Whisper large-v3 / large-v3-turbo (ggml conversion) — MIT. https://huggingface.co/ggerganov/whisper.cpp
- Qwen 3.5 4B (GGUF) — Apache 2.0, © Alibaba Cloud. https://huggingface.co/lmstudio-community/Qwen3.5-4B-GGUF
