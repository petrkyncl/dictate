#!/usr/bin/env python3
"""A/B LLM cistici vrstvy napric modely nad realnymi prepisy.

Meri kvalitu (interpunkce, terminy) proti cene a latenci. Klicova
kontrola je zachovani obsahu — kdyz model zacne shrnovat, pomer slov
spadne pod 0.95 a je to k nicemu, at je text sebehezci.

Spust:  PYTHONPATH=. uv run bench/run_cleanup.py
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

from anthropic import Anthropic
from dotenv import load_dotenv

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from dictate.cleanup import clean_with_llm  # noqa: E402

load_dotenv()

SRC = Path("bench/results/transcripts/large-v3_+glosář_+norm+clean")
OUT = Path("bench/results/cleanup")
MODELS = ["claude-haiku-4-5", "claude-sonnet-5", "claude-opus-5"]

WORD = re.compile(r"[^\W\d_]+", re.UNICODE)
SENT = re.compile(r"[.!?]")

TERMS = [("MationX", r"MationX", r"Machine ?X|Mission ?X|Mation X"),
         ("SaaS", r"SaaS", r"\bSAS\b|\bsas\b|\bsasy\b|\bsasů\b|\bsase\b"),
         ("Attio", r"Attio", r"\bAt[iy]o\b"),
         ("niche", r"niche", r"\bníž\b")]


def longest_unpunct(t: str) -> int:
    return max((len(WORD.findall(c)) for c in SENT.split(t)), default=0)


def stats(text: str) -> dict:
    w = WORD.findall(text)
    return {"slov": len(w),
            "vět_na_100": len(SENT.findall(text)) / len(w) * 100 if w else 0,
            "nejdelší_bez_tečky": longest_unpunct(text)}


def main() -> int:
    files = sorted(SRC.glob("*.txt"))
    if not files:
        print(f"Chybí přepisy v {SRC}")
        return 1
    client = Anthropic()
    raw = {f.stem: f.read_text(encoding="utf-8") for f in files}
    base = stats("\n".join(raw.values()))
    print(f"\nVSTUP (po ASR + deterministické čističce)")
    print(f"  {base['slov']} slov · {base['vět_na_100']:.1f} vět/100 slov · "
          f"nejdelší bez tečky {base['nejdelší_bez_tečky']}\n")

    report = []
    for model in MODELS:
        outdir = OUT / model
        outdir.mkdir(parents=True, exist_ok=True)
        print(f"━━ {model}", flush=True)
        texts, usd, secs, tin, tout = [], 0.0, 0.0, 0, 0
        done = 0
        for f in files:
            cached = outdir / f.name
            if cached.exists() and cached.stat().st_size > 0:
                # uz hotovo z drivejsiho behu — necti znovu, jen zapocitej
                text = cached.read_text(encoding="utf-8")
                texts.append(text)
                done += 1
                continue
            r = clean_with_llm(raw[f.stem], model=model, client=client)
            cached.write_text(r.text, encoding="utf-8")
            texts.append(r.text)
            usd += r.usd; secs += r.seconds; tin += r.in_tokens; tout += r.out_tokens
            ratio = len(WORD.findall(r.text)) / max(1, len(WORD.findall(raw[f.stem])))
            warn = "  ⚠ ZKRACUJE" if ratio < 0.95 else ("  ⚠ přidává" if ratio > 1.08 else "")
            print(f"   {f.stem}  {r.seconds:5.1f}s  poměr slov {ratio:.2f}{warn}", flush=True)
        if done:
            print(f"   ({done} souborů z dřívějšího běhu — cena a čas se za ně nepočítají)")

        joined = "\n".join(texts)
        st = stats(joined)
        terms = {}
        for name, ok, bad in TERMS:
            o, b = len(re.findall(ok, joined)), len(re.findall(bad, joined))
            terms[name] = (o, b)
        report.append({"model": model, **st, "usd": usd, "sekundy": secs,
                       "tok_in": tin, "tok_out": tout,
                       "poměr_slov": st["slov"] / base["slov"], "termíny": terms})
        print(f"   └ {secs:.0f}s · ${usd:.3f} · {tin}+{tout} tok\n")

    print("=" * 96)
    print(f"{'model':<20}{'slov':>7}{'poměr':>8}{'vět/100':>9}{'max bez .':>11}"
          f"{'s/diktát':>10}{'$ korpus':>10}{'$ / 1000 diktátů':>18}")
    print("-" * 96)
    for r in report:
        per_call = r["sekundy"] / len(files)
        # realny diktat ~50 slov: system prompt dominuje, text je maly
        print(f"{r['model']:<20}{r['slov']:>7}{r['poměr_slov']:>8.2f}"
              f"{r['vět_na_100']:>9.1f}{r['nejdelší_bez_tečky']:>11}"
              f"{per_call:>10.1f}{r['usd']:>10.3f}{r['usd']/len(files)*1000:>18.2f}")
    print("=" * 96)

    print(f"\n{'termín':<12}" + "".join(f"{m.replace('claude-',''):>22}" for m in MODELS))
    for name, _, _ in TERMS:
        row = f"{name:<12}"
        for r in report:
            o, b = r["termíny"][name]
            row += f"{f'{o} / {b}':>22}"
        print(row)
    print("\n(správně / zkomoleno)")

    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2),
                                     encoding="utf-8")
    print(f"\nVýstupy: bench/results/cleanup/<model>/*.txt\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
