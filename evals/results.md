# Cleanup-Model Mini-Eval — Results (2026-07-13)

10 multilingual dictation samples (3 EN, 3 DE, 2 Swiss-German-flavored DE, 2 FR) with fillers, false starts, names, numbers and Swiss currency formats. Each candidate cleans every sample via LM Studio; a local judge (openai/gpt-oss-120b) scores language preservation (0/4, Helvetisms must survive), filler removal (0–2), meaning/numbers preservation (0–3), and output format (0–1). Latency measured per call, model warm, on the M4 Max.

| model | fits 16 GB Mini | quality /10 | median s | lang fails | completed |
|---|---|---|---|---|---|
| ministral-3-14b-reasoning | ⚠️ 9.1 GB — borderline | **10.0** | 1.84 | 0 | 10/10 |
| gemma-4-12b | yes | 10.0 | 32.4 | 0 | 7/10 |
| qwen3.6-27b (reference) | **no** | 10.0 | 164.7 | 0 | 7/10 |
| **qwen3-8b** (`/no_think`) | **yes (4.6 GB)** | **9.9** | **0.67** | 0 | 10/10 |
| ministral-3-3b | yes (3.0 GB) | 9.4 | 0.44 | 0 | 10/10 |
| qwen3.5-4b | yes | 5.3 | 71.6 | **2** | 7/10 |
| qwen3.5-9b | yes | 4.6 | 98.4 | **4** | 10/10 |

("completed 7/10" = three calls exceeded the 600 s eval timeout — these models think for minutes.)

## Verdict: default = `qwen/qwen3-8b`

- **9.9/10 quality at 0.67 s median** — near-perfect fidelity, fast enough to be invisible in the dictation flow, and at 4.6 GB it comfortably fits the future 16 GB Mac Mini next to Whisper (~3 GB). Only blemish: one Swiss sample kept an "Ähm also" (9/10).
- **ministral-3-14b-reasoning** scored a perfect 10/10 at 1.84 s — the quality-max choice for the 128 GB M4 Max (selectable in Settings), but at 9.1 GB it doesn't fit the Mini's memory budget, and its latency is ~3× the default.
- **ministral-3-3b** is the speed king (0.44 s) but takes liberties: added markdown bold, restructured sentences, dropped clause openers (5 samples docked).
- **Qwen 3.5 (4B & 9B) are disqualified**: always-thinking (no way to disable), 70–100 s median, and the only models that *translated* samples into the wrong language (2 and 4 language failures). Qwen 3.6 has no Mini-sized variant and thinks for minutes.
- Gemma-4-12b writes perfect output but thinks for ~30 s per utterance — unusable interactively.

Full per-sample detail: results.json (git-ignored; regenerate with `run_eval.py` + `judge_results.py`).

## Addendum (2026-07-13): `localdictate-cleanup` preset

Simon's pre-existing LM Studio preset `localdictate-cleanup` (an alias for **qwen3.5-4b**, ctx 4096) was compared against the chosen default on the identical samples+judge: **5.5/10 quality, 67 s median, 3/10 wrong-language outputs** — it exhausts ~4,300 reasoning tokens per utterance and truncates. qwen3-8b (9.9/10, 0.67 s) remains the single model to keep loaded; it also fits the Mac Mini. Rerun anytime with `python3 evals/compare_one.py <model-id>`.
