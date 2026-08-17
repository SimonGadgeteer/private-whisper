#!/usr/bin/env python3
"""Cleanup-model mini-eval (PRD §10.2).

Runs each candidate model over the multilingual dictation samples, then has a
large LOCAL judge model score the outputs. Everything runs against LM Studio —
no cloud calls.

Usage: python3 run_eval.py [--judge MODEL] [--out results]
"""
import argparse
import json
import re
import subprocess
import time
import urllib.request
from pathlib import Path

BASE = "http://localhost:1234/v1"
HERE = Path(__file__).parent

# (model id, fits 16 GB Mac Mini, note)
CANDIDATES = [
    ("qwen/qwen3-8b",                                True,  "hybrid; /no_think honored"),
    ("qwen/qwen3.5-4b",                              True,  "always-thinking"),
    ("qwen/qwen3.5-9b",                              True,  "always-thinking"),
    ("mistralai/ministral-3-3b",                     True,  "instruct, non-reasoning"),
    ("mistralai/ministral-3-14b-reasoning",          True,  "reasoning; ~8.5GB, borderline"),
    ("google/gemma-4-12b",                           True,  "thinks by default"),
    ("qwen3.6-27b-mlx",                              False, "reference only — exceeds Mini RAM"),
]

_shared = HERE.parent / "shared" / "prompts" / "cleanup_prompt.txt"
SYSTEM_PROMPT = _shared.read_text().strip() if _shared.exists() else """You clean up dictated text. Rules:
- Output ONLY the cleaned text. No preamble, no quotes, no commentary.
- Keep the same language as the input (German stays German, French stays French, English stays English).
- Remove filler words (um, äh, also, alors, you know), false starts, and repetitions.
- If the speaker corrects themselves ("next Tuesday — no wait, Wednesday", "also nein, ich meine…", "enfin, je veux dire…"), keep ONLY the corrected version.
- If the speaker enumerates items ("first… second…", "erstens… zweitens…", "premièrement…"), format them as a list, one item per line, each starting with "- ".
- Fix punctuation, capitalization, and obvious transcription errors.
- Preserve meaning, tone, names, numbers, and technical terms exactly.
- Do not summarize, do not expand, do not translate."""

JUDGE_INSTRUCTIONS = """You judge the quality of a dictation-cleanup system. Given RAW dictated text \
(with filler words) and the CLEANED output, score strictly:

- same_language (0 or 4): 4 if CLEANED is in the same language as RAW (German must stay German — \
Swiss/Helvetic German words like "parkieren", "Velo", "merci vielmal" staying in place is CORRECT \
and must NOT be penalized). 0 if any part was translated to another language.
- fillers_removed (0-2): 2 = all fillers/false starts/repetitions gone, 1 = some remain, 0 = mostly untouched.
- meaning_preserved (0-3): 3 = identical meaning incl. all names, numbers, dates, amounts; \
2 = trivial nuance lost; 1 = noticeable loss/change; 0 = wrong meaning or hallucinated content.
- format_clean (0-1): 1 = plain cleaned text only; 0 = added quotes, commentary, labels or markdown.

Reply with ONLY a JSON object: {"same_language": n, "fillers_removed": n, "meaning_preserved": n, "format_clean": n}"""


def chat(model, messages, max_tokens=4096, temperature=0.2, timeout=600, extra=None):
    body = {"model": model, "messages": messages, "temperature": temperature,
            "max_tokens": max_tokens, "stream": False}
    if extra:
        body.update(extra)
    req = urllib.request.Request(
        f"{BASE}/chat/completions", data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"})
    start = time.monotonic()
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        data = json.load(resp)
    elapsed = time.monotonic() - start
    msg = data["choices"][0]["message"]
    content = msg.get("content") or ""
    content = re.sub(r"(?s)<think>.*?</think>", "", content)
    content = content.split("<think>")[0]
    usage = data.get("usage", {})
    reasoning_tokens = (usage.get("completion_tokens_details") or {}).get("reasoning_tokens", 0)
    return content.strip(), elapsed, reasoning_tokens


def unload_all():
    subprocess.run(["lms", "unload", "--all"], capture_output=True)


def clean_sample(model, raw, language, extra=None):
    system = SYSTEM_PROMPT + f'\n- The input language is "{language}". The output must be in that same language.'
    if "qwen" in model.lower():
        system += "\n/no_think"
    max_tokens = max(256, int(len(raw) / 3 * 1.5) + 64) + 4096
    return chat(model, [
        {"role": "system", "content": system},
        {"role": "user", "content": raw},
    ], max_tokens=max_tokens, extra=extra)


def judge(judge_model, raw, cleaned):
    """Score one row. Never raises — a failed judge call (after retries) returns None."""
    content = None
    for attempt in range(3):
        try:
            content, _, _ = chat(judge_model, [
                {"role": "system", "content": JUDGE_INSTRUCTIONS},
                {"role": "user", "content": f"RAW:\n{raw}\n\nCLEANED:\n{cleaned}"},
            ], temperature=0.0)
            break
        except Exception as exc:
            print(f"    judge attempt {attempt + 1} failed: {exc}", flush=True)
            time.sleep(5 * (attempt + 1))
    if content is None:
        return None
    match = re.search(r"\{[^{}]*\}", content)
    if not match:
        return None
    try:
        scores = json.loads(match.group(0))
        return {k: int(scores.get(k, 0)) for k in
                ("same_language", "fillers_removed", "meaning_preserved", "format_clean")}
    except (ValueError, TypeError):
        return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--judge", default="openai/gpt-oss-120b")
    parser.add_argument("--out", default="results")
    args = parser.parse_args()

    samples = json.loads((HERE / "samples.json").read_text())
    results = []

    for model, fits_mini, note in CANDIDATES:
        print(f"\n=== {model} ({note}) ===", flush=True)
        unload_all()
        # Warm-up: first call JIT-loads the model; measured separately.
        # Retried because JIT loads occasionally fail transiently (HTTP 400 /
        # dropped connection right after an unload).
        load_time = None
        for attempt in range(3):
            try:
                _, load_time, _ = clean_sample(model, "Um, hello there.", "en")
                break
            except Exception as exc:
                load_exc = exc
                print(f"  load attempt {attempt + 1} failed: {exc}", flush=True)
                time.sleep(10)
        if load_time is None:
            print(f"  SKIPPED (load failed: {load_exc})", flush=True)
            results.append({"model": model, "fits_mini": fits_mini, "note": note,
                            "error": str(load_exc)})
            continue

        rows = []
        for sample in samples:
            try:
                cleaned, elapsed, rtoks = clean_sample(model, sample["raw"], sample["language"])
            except Exception as exc:
                rows.append({"id": sample["id"], "error": str(exc)})
                print(f"  {sample['id']}: ERROR {exc}", flush=True)
                continue
            rows.append({"id": sample["id"], "cleaned": cleaned, "seconds": round(elapsed, 2),
                         "reasoning_tokens": rtoks})
            print(f"  {sample['id']}: {elapsed:5.2f}s  rtoks={rtoks:4d}  {cleaned[:70]}", flush=True)
        results.append({"model": model, "fits_mini": fits_mini, "note": note,
                        "load_seconds": round(load_time, 2), "rows": rows})

    # Checkpoint: persist raw candidate outputs BEFORE judging, so a judge
    # failure can never lose the (expensive) generation work.
    (HERE / f"{args.out}-raw.json").write_text(
        json.dumps({"samples": len(samples), "detail": results}, indent=2, ensure_ascii=False))
    print(f"\nraw outputs checkpointed: {HERE / (args.out + '-raw.json')}", flush=True)

    # Judge pass — load the judge once, score everything.
    print(f"\n=== judging with {args.judge} ===", flush=True)
    unload_all()
    raw_by_id = {s["id"]: s["raw"] for s in samples}
    for result in results:
        for row in result.get("rows", []):
            if "cleaned" not in row:
                continue
            row["scores"] = judge(args.judge, raw_by_id[row["id"]], row["cleaned"])
            total = sum(row["scores"].values()) if row["scores"] else 0
            print(f"  {result['model']} / {row['id']}: {total}/10", flush=True)
    unload_all()

    # Summarize.
    summary = []
    for result in results:
        rows = [r for r in result.get("rows", []) if r.get("scores")]
        if not rows:
            summary.append({"model": result["model"], "fits_mini": result["fits_mini"],
                            "note": result.get("error", result["note"]), "quality": 0,
                            "median_seconds": None, "lang_fails": None})
            continue
        times = sorted(r["seconds"] for r in rows)
        summary.append({
            "model": result["model"],
            "fits_mini": result["fits_mini"],
            "note": result["note"],
            "quality": round(sum(sum(r["scores"].values()) for r in rows) / len(rows), 2),
            "median_seconds": times[len(times) // 2],
            "lang_fails": sum(1 for r in rows if r["scores"]["same_language"] == 0),
        })
    summary.sort(key=lambda s: (-s["quality"], s["median_seconds"] or 999))

    out = {"samples": len(samples), "judge": args.judge, "summary": summary, "detail": results}
    (HERE / f"{args.out}.json").write_text(json.dumps(out, indent=2, ensure_ascii=False))

    print(f"\n{'model':50s} {'fits16GB':>8s} {'quality/10':>10s} {'median s':>9s} {'langFail':>8s}")
    for s in summary:
        print(f"{s['model']:50s} {str(s['fits_mini']):>8s} {s['quality']:>10} "
              f"{str(s['median_seconds']):>9s} {str(s['lang_fails']):>8s}")
    print(f"\nwritten: {HERE / (args.out + '.json')}")


if __name__ == "__main__":
    main()
