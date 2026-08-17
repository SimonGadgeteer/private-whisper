# Windows Port — Analysis (no code yet)

*Written 2026-07-14. Context: Simon has a Windows notebook without admin rights; the macOS app (Swift) is feature-complete. Question: what does a Windows version take — portable and installed — and should it live in this repo or a new one?*

---

## 1. Feasibility summary

A Windows port is very feasible, and Windows is in several ways *easier* than macOS was: global hotkeys and synthetic keystrokes need **no permission grants at all** (no Accessibility/TCC equivalent), and the two inference engines ship **official prebuilt Windows binaries** — no toolchain work. The app shell itself must be rewritten (Swift/AppKit doesn't port), but it is deliberately thin: ~1,500 lines orchestrating recorder → whisper → LLM → clipboard-paste. All the *hard-won* pieces — prompt engineering, eval-verified model choices, thinking-disable knobs, backend routing, dictionary enforcement — are platform-neutral and carry over unchanged.

**Recommended stack: C# / .NET 8, WPF, tray app**, published self-contained (no .NET install needed on the target machine). Rationale: first-class tray/hotkey/clipboard/UIAutomation APIs, single-file publish, no Electron weight, mature ecosystem.

## 2. Component mapping

| macOS (today) | Windows equivalent | Notes |
|---|---|---|
| `NSStatusItem` menu bar | `NotifyIcon` system tray | trivial |
| `NSEvent` flagsChanged monitors (PTT) | `SetWindowsHookEx(WH_KEYBOARD_LL)` | low-level hook sees key-down *and* key-up (needed for hold-to-talk, e.g. Right Alt); `RegisterHotKey` can't do release events. **No permission prompt.** |
| AVAudioEngine capture | WASAPI via **NAudio** | resample to 16 kHz mono; same energy gate |
| whisper.cpp embedded (framework) | **`whisper-server.exe` sidecar** (official ggml-org release binaries) | mirrors our llama-server pattern; keeps C# free of native interop. CPU + **Vulkan** builds exist (Vulkan runs on Intel/AMD iGPUs, no driver installs) |
| Embedded `llama-server` sidecar | identical — official Windows release binary | same flags incl. `--chat-template-kwargs {"enable_thinking": false}` |
| CleanupService (URLSession) | `HttpClient` — logic copied 1:1 | prompts, glossary, tone, backend routing identical |
| Pasteboard + Cmd+V (`CGEvent`) | `Clipboard` + `SendInput` Ctrl+V, snapshot/restore | same changeCount-style guard via clipboard sequence number (`GetClipboardSequenceNumber` — cleaner than macOS!) |
| AX focused-element / secure-input checks | skip initially; UIA later | Windows has no secure-input flag; password boxes just receive paste |
| Correction learner (AX re-read) | **UIAutomation** `ValuePattern`/`TextPattern` | notably *more* reliable than macOS AX, incl. many Electron apps |
| Notch capsule | borderless, topmost, click-through WPF window, top-center | `WS_EX_TRANSPARENT \| WS_EX_NOACTIVATE` |
| SwiftUI settings/stats/dictionary window | WPF windows | mechanical rewrite |
| `~/Library/Application Support/PrivateWhisper` | `%APPDATA%\PrivateWhisper` — or **next to the exe in portable mode** | see §3 |
| Launch at login (SMAppService) | HKCU `Run` key (no admin) or Startup-folder shortcut | user-scoped, both fine without admin |
| Exit-time ggml teardown fix | n/a (sidecars are separate processes) | the sidecar architecture sidesteps that whole bug class |

**Not portable / needs rethink:** per-app tone uses bundle IDs → Windows uses the foreground window's process name (`GetForegroundWindow` → process exe, e.g. `OUTLOOK.EXE`, `slack.exe`) — arguably simpler.

**Effort estimate:** 2–3 days to parity-minus MVP (hotkey, record, transcribe, cleanup with 3-tier routing, paste, tray states, settings, model downloads with progress), +1–2 days for capsule overlay, stats, dictionary UI, correction learner via UIA.

## 3. Portable vs. installed

Both from the same codebase — the only difference is **where data lives** and how it arrives on the machine:

### Portable (priority for the no-admin notebook)
- One folder: `PrivateWhisper.exe`, `whisper-server.exe`, `llama-server.exe`, `models\`, `config.json`. Runs from Desktop, `%LOCALAPPDATA%`, or a USB stick. Delete folder = gone.
- **Portable-mode detection**: if `portable.marker` (or `config.json`) sits next to the exe → all data (models, config, stats, log) stays in the folder; otherwise `%APPDATA%`. One `if` in the config layer.
- No admin needed anywhere. Real gatekeepers are **organizational**: AppLocker/WDAC may block unsigned exes outside `Program Files` (test: run any portable app first), Defender SmartScreen shows a one-time "unrecognized app" warning (user-dismissable unless policy forbids), and the per-user microphone privacy toggle must be on.
- Distribution: a ZIP on the GitHub Releases page (+ SHA-256).

### Installed (for friends / normal machines)
- **Per-user installer, still no admin**: Inno Setup in "user mode" (`PrivilegesRequired=lowest`) installing to `%LOCALAPPDATA%\Programs\PrivateWhisper` with Start-menu entry and HKCU uninstall registration — exactly how VS Code's "User Installer" works. Recommended.
- **MSIX**: rejected — sideloading unsigned MSIX requires trusting a cert (often admin/policy-blocked); only worth it for Store distribution someday.
- **winget**: possible later (points at the Inno installer); nice-to-have.
- **Code signing**: unsigned is fine for personal use (SmartScreen warning). An Authenticode cert (~$100–400/yr, OV) removes the warning; not needed now, slot in later like Apple notarization.

### Hardware reality check (unchanged from earlier assessment)
On a typical corporate notebook without a discrete GPU, whisper large-v3-turbo runs 5–20 s per 10 s utterance on CPU; the Vulkan build on an iGPU improves this substantially but won't reach Apple-Silicon speeds. Mitigations, in order: Vulkan build by default → optional smaller whisper model → **remote mode to the Mac Mini** when on the same network (config URL, zero new code). The three 10-minute pre-checks on the notebook remain the true go/no-go: unsigned exe allowed? mic toggle available? CPU/GPU model?

## 4. Repo strategy: same repo (monorepo) — recommended

**Use this repo.** The most valuable assets are exactly the ones that must not fork:

- **The eval harness and samples** (`evals/`) — platform-neutral Python, and effectively the product spec. A Windows build must pass the same 14 samples through the same judge. Two repos = the evals drift apart.
- **The prompts and model decisions** — cleanup rules, glossary/tone construction, `enable_thinking` knobs, model URLs/quants. One source of truth prevents the platforms from silently diverging in output quality.
- **Docs** (DECISIONS.md, this file, iOS research) tell one continuous story.

Proposed structure *when Windows work starts* (one reshuffle commit, not now):

```
/                     README, LICENSE, docs/, evals/, shared/
shared/prompts/       cleanup + rewrite prompts, default app-tone map, model manifest (URLs, sizes)
macos/                today's Package.swift, Sources/, Resources/, scripts/
windows/              PrivateWhisper.sln, src/, installer/ (Inno script), scripts/
ios/                  (Phase 0 scaffold when it comes)
```

Both apps load `shared/prompts` at build time (embed as resources) so a prompt improvement lands on every platform in one commit.

**Per-platform binaries via GitHub Actions** (free for public repos): a release workflow with a matrix —
- `macos-14` runner: `build_app.sh` + `package.sh` → `PrivateWhisper-macos-<v>.dmg`
- `windows-latest` runner: `dotnet publish` + download **pinned** official whisper.cpp/llama.cpp Windows release binaries (rather than vendoring more exes into git) + Inno Setup → `PrivateWhisper-windows-<v>-setup.exe` and `-portable.zip`

One version tag (`v0.2.0`) produces all artifacts on the Releases page. (Caveat: the macOS CI build will be ad-hoc-signed — fine given users must right-click-open anyway; your locally-built DMG stays the nicer artifact until there's a Developer ID.)

**When a separate repo *would* be right:** different license/ownership, a community fork with its own maintainers, or if the Windows app shared literally nothing. None apply.

## 5. Suggested sequencing

1. **Notebook pre-checks** (10 min, Simon): portable exe allowed? mic privacy toggle? CPU/GPU?
2. **Repo reshuffle** into `macos/` + `shared/` + `windows/` skeleton (half a day incl. CI for the mac DMG).
3. **Windows MVP** (2–3 days): tray, PTT hook, NAudio capture, whisper-server + llama-server sidecars, 3-tier cleanup, clipboard inject, model downloader with per-item progress, portable-mode detection.
4. **Eval gate**: run the 14 samples through the Windows pipeline (whisper-server + llama-server) and judge on the Mac — same bar the macOS app passed.
5. **Polish + installers** (1–2 days): capsule overlay, stats, dictionary, UIA correction learner; Inno user-mode installer + portable ZIP; Release workflow.
