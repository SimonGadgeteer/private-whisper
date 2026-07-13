#!/usr/bin/env python3
"""Run ONE model through the same samples+judge as the main eval and compare
it against a baseline model's stored scores in results.json.

Usage: python3 compare_one.py <model-id> [baseline-id]
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from run_eval import clean_sample  # noqa: E402
from judge_results import judge  # noqa: E402

HERE = Path(__file__).parent


def main():
    model = sys.argv[1]
    baseline = sys.argv[2] if len(sys.argv) > 2 else "qwen/qwen3-8b"

    samples = json.loads((HERE / "samples.json").read_text())

    print(f"=== running {model} ===", flush=True)
    # Warm-up (JIT load, not measured)
    try:
        _, load_s, warm_rtoks = clean_sample(model, "Um, hello there.", "en")
        print(f"  load/warm-up: {load_s:.1f}s (reasoning tokens: {warm_rtoks})", flush=True)
    except Exception as exc:
        print(f"  FAILED to load: {exc}")
        return

    rows = []
    for sample in samples:
        try:
            cleaned, elapsed, rtoks = clean_sample(model, sample["raw"], sample["language"])
        except Exception as exc:
            print(f"  {sample['id']}: ERROR {exc}", flush=True)
            rows.append({"id": sample["id"], "error": str(exc)})
            continue
        scores = judge(sample["raw"], cleaned)
        total = sum(scores.values()) if scores else None
        rows.append({"id": sample["id"], "cleaned": cleaned, "seconds": round(elapsed, 2),
                     "reasoning_tokens": rtoks, "scores": scores})
        print(f"  {sample['id']}: {elapsed:5.2f}s rtoks={rtoks:4d} judge={total} {cleaned[:60]}",
              flush=True)

    scored = [r for r in rows if r.get("scores")]
    times = sorted(r["seconds"] for r in rows if "seconds" in r)
    quality = round(sum(sum(r["scores"].values()) for r in scored) / len(scored), 2) if scored else 0
    median = times[len(times) // 2] if times else None
    lang_fails = sum(1 for r in scored if r["scores"]["same_language"] == 0)

    (HERE / "compare_one_result.json").write_text(json.dumps(
        {"model": model, "quality": quality, "median_seconds": median,
         "lang_fails": lang_fails, "rows": rows}, indent=2, ensure_ascii=False))

    # Baseline from the stored eval
    base = None
    results = json.loads((HERE / "results.json").read_text())
    for r in results["detail"]:
        if r["model"] == baseline:
            brows = [x for x in r["rows"] if x.get("scores")]
            btimes = sorted(x["seconds"] for x in r["rows"] if "seconds" in x)
            base = {
                "quality": round(sum(sum(x["scores"].values()) for x in brows) / len(brows), 2),
                "median": btimes[len(btimes) // 2],
                "lang_fails": sum(1 for x in brows if x["scores"]["same_language"] == 0),
                "completed": len(brows),
            }

    print(f"\n{'':28s} {'quality/10':>10s} {'median s':>9s} {'langFail':>8s} {'done':>5s}")
    print(f"{model:28s} {quality:>10} {str(median):>9s} {lang_fails:>8d} {len(scored):>2d}/{len(samples)}")
    if base:
        print(f"{baseline:28s} {base['quality']:>10} {str(base['median']):>9s} "
              f"{base['lang_fails']:>8d} {base['completed']:>2d}/{len(samples)}")


if __name__ == "__main__":
    main()
