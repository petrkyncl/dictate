#!/usr/bin/env python3
"""Latence a cena na REALNE delce diktatu (20-60 s reci, tj. ~50-150 slov).

Benchmark nad 18minutovymi soubory meri neco jineho nez produkt. Tohle
meri to, co uzivatel skutecne pocituje: jak dlouho ceka, nez se text objevi.
"""
from __future__ import annotations

import re
import statistics
import sys
from pathlib import Path

from anthropic import Anthropic
from dotenv import load_dotenv

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from dictate.cleanup import clean_with_llm  # noqa: E402

load_dotenv()
SRC = Path("bench/results/transcripts/large-v3_+glosář_+norm+clean")
MODELS = ["claude-haiku-4-5", "claude-sonnet-5", "claude-opus-5"]
WORD = re.compile(r"[^\W\d_]+", re.UNICODE)


def chunks(n: int = 8, words: int = 110) -> list[str]:
    """Vyrizne z korpusu useky o delce bezneho diktatu (~110 slov ≈ 45 s reci)."""
    out = []
    for f in sorted(SRC.glob("*.txt")):
        w = f.read_text(encoding="utf-8").split()
        if len(w) >= words * 2:
            mid = len(w) // 2
            out.append(" ".join(w[mid:mid + words]))
        if len(out) >= n:
            break
    return out


def main() -> int:
    samples = chunks()
    client = Anthropic()
    print(f"\n{len(samples)} úseků po ~110 slovech (≈45 s řeči)\n")
    rows = []
    for model in MODELS:
        lat, usd = [], 0.0
        for s in samples:
            r = clean_with_llm(s, model=model, client=client)
            lat.append(r.seconds)
            usd += r.usd
        rows.append((model, statistics.median(lat), min(lat), max(lat), usd / len(samples)))
        print(f"{model:<20} medián {statistics.median(lat):5.2f}s  "
              f"(min {min(lat):.2f} / max {max(lat):.2f})  ${usd/len(samples):.4f}/diktát")

    print("\n" + "=" * 86)
    print(f"{'model':<20}{'medián':>9}{'nejhorší':>10}{'$ / diktát':>13}"
          f"{'$ / měsíc*':>13}{'celková latence**':>20}")
    print("-" * 86)
    for m, med, lo, hi, u in rows:
        print(f"{m:<20}{med:>8.2f}s{hi:>9.2f}s{u:>13.4f}{u*1500:>13.2f}"
              f"{med + 1.58:>18.2f}s")
    print("=" * 86)
    print("*  50 diktátů denně × 30 dní")
    print("** LLM + 1,58 s na ASR = co uživatel čeká od puštění klávesy po vložený text\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
