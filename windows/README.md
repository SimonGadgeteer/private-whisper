# Private Whisper — Windows

C# / .NET 8 / WPF port of the macOS app: local push-to-talk dictation.
Hold **Right Alt**, speak, release — the transcript is cleaned up by a local
LLM and pasted at the cursor. Hold **Right Ctrl** with text selected to
voice-edit it (command mode). Everything runs on-device; audio never leaves
the machine.

Architecture and rationale: see [`../docs/windows-port-analysis.md`](../docs/windows-port-analysis.md).
Prompts and model choices are shared with the macOS app via [`../shared/`](../shared/)
(embedded at build time — they are eval-verified; do not fork them).

## How it works

| Piece | Implementation |
|---|---|
| Push-to-talk | `WH_KEYBOARD_LL` low-level keyboard hook (sees key-up, no permissions needed) |
| Audio | WASAPI via NAudio → 16 kHz mono float, energy gate (≥0.5 s, RMS > 0.002) |
| Transcription | official `whisper-server.exe` sidecar (ggml-org release binary), `POST /inference`, `language=auto` |
| Cleanup | LM Studio if reachable → embedded `llama-server.exe` sidecar (Qwen 3.5 4B, thinking disabled) → raw transcript |
| Injection | clipboard + synthetic Ctrl+V, previous clipboard restored (sequence-number guarded) |
| Correction learner | UI Automation re-read of the injected field; suggestion-only dictionary learning |

Sidecars listen on a random localhost port (49152–65499), are health-checked,
stop after 10 minutes idle, and are killed on app exit.

## Build

Requirements: Windows 10/11 x64, .NET 8 SDK. (The app itself is published
self-contained — end users need no .NET install.)

```powershell
# Debug build (runtime sidecars not required to compile)
dotnet build windows\PrivateWhisper.sln

# Full package: publish + pinned sidecar download + portable zip
powershell -ExecutionPolicy Bypass -File windows\scripts\package.ps1

# Additionally compile the per-user installer (requires Inno Setup 6)
powershell -ExecutionPolicy Bypass -File windows\scripts\package.ps1 -Installer
```

Outputs land in `windows\dist\`:

- `PrivateWhisper-windows-<v>-portable.zip` (+ SHA-256 printed)
- `PrivateWhisper-windows-<v>-setup.exe` (with `-Installer`)

Sidecar binaries are **pinned** official releases (URLs at the top of
`scripts/package.ps1`): llama.cpp `b10472` (Vulkan build — uses Intel/AMD
iGPUs through the standard driver, falls back to CPU) and whisper.cpp
`v1.9.2` (CPU build; no Vulkan Windows asset is published upstream). They are
placed in `runtime\llama\` and `runtime\whisper\` — separate directories
because the two zips ship different, incompatible `ggml*.dll` builds.

## Portable vs. installed

Same binary, one difference — where data lives:

- **Portable** (the no-admin notebook case): unzip anywhere and run
  `PrivateWhisper.exe`. The `portable.marker` file next to the exe keeps
  config, models (~4 GB after first-run download), stats, and log inside the
  folder. Delete the folder = fully uninstalled.
- **Installed**: the setup exe installs per-user to
  `%LOCALAPPDATA%\Programs\PrivateWhisper` (Start-menu shortcut, HKCU
  uninstall entry, no UAC prompt). Data goes to `%APPDATA%\PrivateWhisper`.

Models are downloaded on first run (per-item progress in the setup window):
Whisper large-v3-turbo (1.5 GB, required) and Qwen 3.5 4B (2.7 GB, optional —
skip it if LM Studio provides cleanup, e.g. from a Mac Mini on the LAN via
Settings → LM Studio URL).

## The three no-admin gatekeeper checks

Run these on the target machine **before** anything else (10 minutes total):

1. **Unsigned portable exe allowed?** Unzip and start any portable app (or
   this one). If AppLocker/WDAC blocks executables outside `Program Files`,
   stop here — that's an org-policy conversation, not a technical one.
   Defender SmartScreen's one-time "unrecognized app" warning is normal:
   More info → Run anyway.
2. **Microphone privacy toggle available?** Settings → Privacy & security →
   Microphone: "Let desktop apps access your microphone" must be On (it's a
   per-user toggle, no admin needed — unless policy has locked it).
3. **CPU/GPU reality check.** No discrete GPU means whisper large-v3-turbo
   runs 5–20 s per 10 s utterance on CPU. Mitigations in order: smaller
   whisper model, or remote cleanup/LM Studio to a faster machine on the LAN.

## Configuration

`config.json` (in `%APPDATA%\PrivateWhisper` or next to the exe in portable
mode) — all fields optional, missing keys keep defaults:

- `hotkey` / `commandHotkey`: `rightAlt`, `leftAlt`, `rightCtrl`,
  `rightShift` (commandHotkey may be `null` to disable command mode)
- `lmStudioUrl`: e.g. `http://mac-mini.local:1234/v1` for remote cleanup
- `appTones`: per-app tone hints keyed by process name, lowercase, e.g.
  `"outlook.exe": "formal email register"`
- `dictionary`: personal names/jargon (also editable in the Dictionary window)
- `overlayX`/`overlayY`: overlay position (set via Settings → "Move overlay…";
  `null` = top-center of the primary display)

## Uninstall

- Portable: delete the folder.
- Installed: Settings → Apps → Private Whisper → Uninstall, then optionally
  delete `%APPDATA%\PrivateWhisper` (models, config, stats).
- Launch-at-login uses an HKCU `Run` entry; it is removed when the setting is
  turned off (or delete value `PrivateWhisper` under
  `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`).
