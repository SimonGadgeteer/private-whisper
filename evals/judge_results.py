#!/usr/bin/env python3
"""Judge pass over results-raw.json → results.json. Robust: per-call retries,
progress prints, partial saves every model."""
import json
import re
import time
import urllib.request
from pathlib import Path

HERE = Path(__file__).parent
BASE = "http://localhost:1234/v1"
JUDGE = "openai/gpt-oss-120b"

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


def judge(raw, cleaned, attempts=3):
    for attempt in range(attempts):
        try:
            body = {
                "model": JUDGE,
                "messages": [
                    {"role": "system", "content": JUDGE_INSTRUCTIONS},
                    {"role": "user", "content": f"RAW:\n{raw}\n\nCLEANED:\n{cleaned}"},
                ],
                "temperature": 0.0, "max_tokens": 2048, "stream": False,
            }
            req = urllib.request.Request(
                f"{BASE}/chat/completions", data=json.dumps(body).encode(),
                headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=180) as resp:
                data = json.load(resp)
            content = data["choices"][0]["message"].get("content") or ""
            match = re.search(r"\{[^{}]*\}", content)
            if not match:
                continue
            scores = json.loads(match.group(0))
            return {k: int(scores.get(k, 0)) for k in
                    ("same_language", "fillers_removed", "meaning_preserved", "format_clean")}
        except Exception as exc:
            print(f"    judge attempt {attempt+1} failed: {exc}", flush=True)
            time.sleep(3)
    return None


def main():
    raw_doc = json.loads((HERE / "results-raw.json").read_text())
    results = raw_doc["detail"] if isinstance(raw_doc, dict) and "detail" in raw_doc else raw_doc
    samples = json.loads((HERE / "samples.json").read_text())
    raw_by_id = {s["id"]: s["raw"] for s in samples}

    for result in results:
        rows = result.get("rows", [])
        print(f"=== judging {result['model']} ===", flush=True)
        for row in rows:
            if "cleaned" not in row or row.get("scores"):
                continue
            row["scores"] = judge(raw_by_id[row["id"]], row["cleaned"])
            total = sum(row["scores"].values()) if row["scores"] else "FAIL"
            print(f"  {row['id']}: {total}", flush=True)
        (HERE / "results.json").write_text(json.dumps(
            {"judge": JUDGE, "samples": len(samples), "detail": results},
            indent=2, ensure_ascii=False))

    # Summary
    summary = []
    for result in results:
        rows = [r for r in result.get("rows", []) if r.get("scores")]
        attempted = len(result.get("rows", []))
        times = sorted(r["seconds"] for r in result.get("rows", []) if "seconds" in r)
        summary.append({
            "model": result["model"],
            "fits_mini": result["fits_mini"],
            "note": result["note"],
            "completed": sum(1 for r in result.get("rows", []) if "cleaned" in r),
            "attempted": attempted,
            "quality": round(sum(sum(r["scores"].values()) for r in rows) / len(rows), 2) if rows else 0,
            "median_seconds": times[len(times) // 2] if times else None,
            "lang_fails": sum(1 for r in rows if r["scores"]["same_language"] == 0),
        })
    summary.sort(key=lambda s: (-s["quality"], s["median_seconds"] or 999))
    doc = {"judge": JUDGE, "samples": len(samples), "summary": summary, "detail": results}
    (HERE / "results.json").write_text(json.dumps(doc, indent=2, ensure_ascii=False))

    print(f"\n{'model':45s} {'fits16':>6s} {'q/10':>5s} {'med s':>7s} {'langF':>5s} {'done':>5s}")
    for s in summary:
        print(f"{s['model']:45s} {str(s['fits_mini']):>6s} {s['quality']:>5} "
              f"{str(s['median_seconds']):>7s} {str(s['lang_fails']):>5s} {s['completed']:>2d}/{s['attempted']}")


if __name__ == "__main__":
    main()
