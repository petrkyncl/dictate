#!/usr/bin/env python3
"""Audit ulozenych prepisu. Bezi nad results/transcripts/, netranskribuje.

Meri to, co u dlouheho ceskeho diktatu doopravdy bolí:
  * zkomolene terminy    — MationX -> "Machine X", SaaS -> "SAS", Attio -> "Atyo"
  * halucinace           — Whisper po tichu dopisuje titulkove kredity
  * kolaps interpunkce   — nejdelsi usek bez tecky; dlouha forma se rozpada
  * zacykleni            — opakovany n-gram

Spust:  uv run bench/audit.py
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).parent
TX = HERE / "results" / "transcripts"

# (kanonicky tvar, regex spravne, regex zkomoleni) — zkomoleniny pochazi
# z realnych prepisu, ne z odhadu.
TERMS = [
    ("MationX",    r"\bMationX\b",        r"\b(?:Machine\s?X|Mission\s?X|Mation\s+X|Mejšn|Motion\s?X|Matron\s?X|Maceon)\b"),
    ("SaaS",       r"\bSaaS\b",           r"\b(?:SAS|Sas|sas|sasy|sasů|sasům|sase|sásy|Sass|sáz\w*)\b"),
    ("Attio",      r"\bAttio\b",          r"\b(?:Atio|Atyo|Ateo|Áčko)\b"),
    ("PM2",        r"\bPM2\b",            r"\b(?:PM\s?dva|pí\s?em\s?dva)\b"),
    ("VPS",        r"\bVPS\b",            r"\b(?:WPS|vípíes\w*|VP\s?S)\b"),
    ("nginx",      r"\bnginx\b",          r"\b(?:engine\s?x|endžin\s?iks|Nginix)\b"),
    ("niche",      r"\bniche\b",          r"\b(?:níž|nyš|niž)\b"),
    ("LinkedIn",   r"\bLinkedIn\b",       r"\blinkedin\b"),
    ("Google Play", r"\bGoogle Play\b",   r"\bobchod\s?Play\b"),
    ("GitHub",     r"\bGitHub\b",         r"\b(?:Github|Git\s?Hub|Gitchab)\b"),
    ("Claude",     r"\bClaude\b",         r"\b(?:Klaud|Klód)\b"),
    ("Supabase",   r"\bSupabase\b",       r"\b(?:Supa\s?base|Superbase)\b"),
    ("Kynčl",      r"\bKynčl\w*\b",       r"\b(?:Kinčl\w*|Kynzl\w*)\b"),
    ("trychtýř",   r"\btrychtýř\w*\b",    r"\btrichtýř\w*\b"),
]

# Whisper po delsim tichu dopisuje titulkove kredity z trenovacich dat.
# Nic z toho uzivatel nikdy nerekne.
HALLUCINATION = [
    r"[Tt]itulky (?:vytvořil|pro|a přepis|z odposlechu)[^.!?]*",
    r"[Pp]řeklad(?:\s*:|\s+titulk)[^.!?]*",
    r"www\.\s*titulky\.\s*com",
    r"[Dd]ěkuj[iu] (?:vám )?za (?:pozornost|shlédnutí|sledování)\s*[.!]?$",
    r"[Pp]odpořte nás[^.!?]*",
    r"[Ss]ubtitles? (?:by|created)[^.!?]*",
    r"\bJohnyX\b",
]

WORD = re.compile(r"[^\W\d_]+", re.UNICODE)
SENT_END = re.compile(r"[.!?]")


def longest_unpunctuated(text: str) -> tuple[int, str]:
    """Nejdelsi usek slov bez koncove interpunkce. Cesky psany projev ma
    vetu po ~12-20 slovech; 50+ znamena, ze se dlouha forma rozpadla."""
    best, sample = 0, ""
    for chunk in SENT_END.split(text):
        w = WORD.findall(chunk)
        if len(w) > best:
            best, sample = len(w), " ".join(w[:9])
    return best, sample


def loop_score(text: str, n: int = 6) -> tuple[int, str]:
    w = WORD.findall(text.lower())
    best, sample, i = 0, "", 0
    while i + n <= len(w):
        gram, reps, j = w[i:i + n], 1, i + n
        while j + n <= len(w) and w[j:j + n] == gram:
            reps, j = reps + 1, j + n
        if reps > best:
            best, sample = reps, " ".join(gram)
        i = j if reps > 1 else i + 1
    return best, sample


def main() -> int:
    conds = sorted(d for d in TX.glob("*") if d.is_dir() and any(d.glob("*.txt")))
    if not conds:
        print("Žádné přepisy. Nejdřív:  uv run bench/run_corpus.py")
        return 1

    summary = {}
    print()
    for cond in conds:
        files = sorted(cond.glob("*.txt"))
        joined = "\n".join(f.read_text(encoding="utf-8") for f in files)
        words = len(WORD.findall(joined))

        halluc = []
        for f in files:
            t = f.read_text(encoding="utf-8")
            for pat in HALLUCINATION:
                for m in re.finditer(pat, t):
                    halluc.append((f.stem, m.group(0).strip()[:60]))

        worst_unp = max((longest_unpunctuated(f.read_text(encoding="utf-8")) + (f.stem,)
                         for f in files), key=lambda x: x[0])
        worst_loop = max((loop_score(f.read_text(encoding="utf-8")) + (f.stem,)
                          for f in files), key=lambda x: x[0])

        terms = {}
        for name, ok_re, bad_re in TERMS:
            ok = len(re.findall(ok_re, joined))
            bad = len(re.findall(bad_re, joined))
            if ok or bad:
                terms[name] = (ok, bad)

        summary[cond.name] = {
            "souborů": len(files), "slov": words,
            "halucinace": halluc,
            "nejdelší_bez_tečky": worst_unp[0], "kde_bez_tečky": worst_unp[2],
            "smyčka": worst_loop[0], "kde_smyčka": worst_loop[2],
            "termíny": terms,
            "vět_na_100_slov": len(SENT_END.findall(joined)) / words * 100 if words else 0,
        }

        s = summary[cond.name]
        print(f"━━ {cond.name}   ({len(files)}/15 souborů, {words} slov)")
        print(f"   halucinace          {len(halluc)}"
              + (f"   → {halluc[0][0]}: „{halluc[0][1]}“" if halluc else ""))
        print(f"   nejdelší bez tečky  {s['nejdelší_bez_tečky']} slov ({s['kde_bez_tečky']})"
              + ("   ⚠ kolaps interpunkce" if s["nejdelší_bez_tečky"] > 50 else ""))
        print(f"   vět na 100 slov     {s['vět_na_100_slov']:.1f}"
              + ("   ⚠ málo" if s["vět_na_100_slov"] < 5 else ""))
        print(f"   zacyklení           ×{s['smyčka']}"
              + (f" ({s['kde_smyčka']}) ⚠" if s["smyčka"] >= 3 else ""))
        print()

    names = list(summary)
    allterms = sorted({t for c in summary.values() for t in c["termíny"]})
    if allterms:
        w = max(22, 78 // max(1, len(names)))
        print("AUDIT TERMÍNŮ — správně / zkomoleno")
        print("-" * (16 + w * len(names)))
        print(f"{'termín':<16}" + "".join(f"{n[:w-2]:>{w}}" for n in names))
        for t in allterms:
            row = f"{t:<16}"
            for n in names:
                v = summary[n]["termíny"].get(t)
                row += f"{(f'{v[0]} / {v[1]}' if v else '–'):>{w}}"
            print(row)
        print()

    (HERE / "results" / "audit.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    print("Detail: bench/results/audit.json\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
