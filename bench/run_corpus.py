#!/usr/bin/env python3
"""Benchmark nad realnymi nahravkami z Wispr Flow (bench/corpus/).

Referencni prepis neexistuje, takze se nemeri WER. Misto toho se meri to,
co u dlouhych diktatu doopravdy boli:

  * audit terminu  — jak model napsal MationX, SaaS, PM2, nginx…
  * dlouha forma   — zacykleni (halucinacni smycka), utnuty konec, chybejici obsah
  * latence        — RTF a kolik sekund zabere 20s diktat

Vsechny prepisy se ukladaji do results/transcripts/, aby sly precist.

Spust:
    uv run bench/run_corpus.py                    # large-v3, s glosarem i bez
    uv run bench/run_corpus.py --files r01 r12    # jen nektere nahravky
    uv run bench/run_corpus.py --models large-v3 large-v3-turbo
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import tempfile
import time
import wave
from collections import Counter
from pathlib import Path

import mlx_whisper

HERE = Path(__file__).parent
CORPUS = HERE / "corpus"
RESULTS = HERE / "results"

REPOS = {
    "large-v3": "mlx-community/whisper-large-v3-mlx",
    "large-v3-turbo": "mlx-community/whisper-large-v3-turbo",
    "medium": "mlx-community/whisper-medium-mlx",
}

GLOSSARY = (
    "Poznámky k práci: MationX, Passerelle, Internát.cz, TLD Hunter, kyncl.app, Bleu Reign. "
    "Stavíme SaaS a automatizace. Nasazujeme přes GitHub Actions na VPS, běží to pod PM2 "
    "za nginxem. Stack: Next.js, Vite, Node, TypeScript, React, Python, Supabase, Tailscale, "
    "Raspberry Pi, Cloudflare, Claude Code. Petr Kynčl, Poniklá, WhatsApp, Amazon, ASIN."
)

# Terminy, u kterych nas zajima, jestli je model napsal spravne.
# (kanonicky tvar, regex na spravny zapis, regex na zname zkomoleniny)
TERMS = [
    ("MationX",    r"\bMationX\b",              r"\b(?:Mation\s?[Xx]|Mejšn|Majšn|Motion\s?X|Maceon|Mation(?:s|u|em)?)\b"),
    ("SaaS",       r"\bSaaS\b",                 r"\b(?:SAS|Sas|sás|sáz|Sass|sazu|sásu)\b"),
    ("PM2",        r"\bPM2\b",                  r"\b(?:PM\s?dva|pí\s?em\s?dva|PM\s?2)\b"),
    ("VPS",        r"\bVPS\b",                  r"\b(?:vípíes\w*|VP\s?S|Vipies)\b"),
    ("nginx",      r"\bnginx\b",                r"\b(?:engine\s?x|endžin\s?iks|Nginix|Enginex)\b"),
    ("Next.js",    r"\bNext\.js\b",             r"\b(?:Next\s?JS|nextjs|Next\b)\b"),
    ("TypeScript", r"\bTypeScript\b",           r"\b(?:Type\s?Script|Tajpskript)\b"),
    ("GitHub",     r"\bGitHub\b",               r"\b(?:Git\s?Hub|Github|Gitchab|Gitchup)\b"),
    ("Claude",     r"\bClaude\b",               r"\b(?:Klaud|Cloud\s?Code|Klód)\b"),
    ("Supabase",   r"\bSupabase\b",             r"\b(?:Supa\s?base|Superbase|Supabáze)\b"),
    ("Tailscale",  r"\bTailscale\b",            r"\b(?:Tail\s?scale|Tejlskejl|Telescale)\b"),
    ("Poniklá",    r"\bPoniklé?á?\b",           r"\b(?:Poniklo|Ponikla\b)\b"),
    ("Kynčl",      r"\bKynčl\w*\b",             r"\b(?:Kinčl\w*|Kynzl\w*|Kynčel)\b"),
]

WORD = re.compile(r"[^\W\d_]+", re.UNICODE)


def normalized(src: Path, tmpdir: Path) -> Path:
    """Srovna hlasitost na -20 LUFS. Nahravky z Wispru jsou o 10-20 dB tissi,
    nez by mely byt, coz zhorsuje odstup od sumu."""
    dst = tmpdir / src.name
    subprocess.run(
        ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(src),
         "-af", "loudnorm=I=-20:TP=-2:LRA=11", "-ar", "16000", "-ac", "1", str(dst)],
        check=True)
    return dst


def audio_seconds(p: Path) -> float:
    with wave.open(str(p)) as w:
        return w.getnframes() / w.getframerate()


def loop_score(text: str, n: int = 6) -> tuple[int, str]:
    """Nejdelsi serie bezprostrednich opakovani stejneho n-gramu.

    Whisperova halucinacni smycka vypada jako 'a tak dále a tak dále a tak dále…'.
    Vraci (pocet opakovani, ukazka)."""
    w = WORD.findall(text.lower())
    if len(w) < 2 * n:
        return 0, ""
    best, sample = 0, ""
    i = 0
    while i + n <= len(w):
        gram = w[i:i + n]
        reps, j = 1, i + n
        while j + n <= len(w) and w[j:j + n] == gram:
            reps += 1
            j += n
        if reps > best:
            best, sample = reps, " ".join(gram)
        i = j if reps > 1 else i + 1
    return best, sample


def analyse(text: str, segments: list, seconds: float) -> dict:
    words = WORD.findall(text)
    reps, sample = loop_score(text)
    last_end = max((s.get("end", 0.0) for s in segments), default=0.0)
    return {
        "slov": len(words),
        "wpm": len(words) / (seconds / 60) if seconds else 0.0,
        "opakovani": reps,
        "opakovani_ukazka": sample,
        "pokryti_%": min(100.0, last_end / seconds * 100) if seconds else 0.0,
        "segmentu": len(segments),
    }


def term_audit(text: str) -> dict:
    out = {}
    for name, ok_re, bad_re in TERMS:
        ok = len(re.findall(ok_re, text))
        bad = len(re.findall(bad_re, text, re.IGNORECASE))
        if ok or bad:
            out[name] = {"správně": ok, "zkomoleno": bad}
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", nargs="+", default=["large-v3"], choices=list(REPOS))
    ap.add_argument("--files", nargs="+", default=None, help="napr. r01 r12 (default: vše)")
    ap.add_argument("--glossary", choices=["both", "on", "off"], default="both")
    ap.add_argument("--normalize", choices=["both", "on", "off"], default="off",
                    help="srovnat hlasitost na -20 LUFS před přepisem")
    args = ap.parse_args()

    wavs = sorted(CORPUS.glob("*.wav"))
    if args.files:
        keep = {f if f.endswith(".wav") else f + ".wav" for f in args.files}
        wavs = [w for w in wavs if w.name in keep]
    if not wavs:
        print("Prázdný korpus. Nahrávky patří do bench/corpus/.")
        return 1

    tri = {"both": [False, True], "on": [True], "off": [False]}
    conds = tri[args.glossary]
    norms = tri[args.normalize]
    durations = {w.name: audio_seconds(w) for w in wavs}
    total_audio = sum(durations.values())
    print(f"\n{len(wavs)} nahrávek · {total_audio/60:.0f} min audia · "
          f"{len(args.models)} model(ů) × {len(conds)*len(norms)} kondic\n")

    report, all_terms = [], {}
    tmp = tempfile.TemporaryDirectory()
    norm_cache: dict[str, Path] = {}

    for model in args.models:
      for norm in norms:
        for glos in conds:
            cond = f"{model}{' +glosář' if glos else ''}{' +norm' if norm else ''}"
            outdir = RESULTS / "transcripts" / cond.replace(" ", "_")
            outdir.mkdir(parents=True, exist_ok=True)
            print(f"━━ {cond}")
            elapsed, per_file, joined = 0.0, [], []

            for w in wavs:
                src = w
                if norm:
                    if w.name not in norm_cache:
                        norm_cache[w.name] = normalized(w, Path(tmp.name))
                    src = norm_cache[w.name]
                t0 = time.perf_counter()
                r = mlx_whisper.transcribe(
                    str(src), path_or_hf_repo=REPOS[model], language="cs",
                    initial_prompt=GLOSSARY if glos else None,
                    condition_on_previous_text=False, verbose=None,
                )
                dt = time.perf_counter() - t0
                elapsed += dt
                text = r["text"].strip()
                joined.append(text)
                (outdir / f"{w.stem}.txt").write_text(text, encoding="utf-8")

                st = analyse(text, r.get("segments", []), durations[w.name])
                st |= {"soubor": w.stem, "audio_s": durations[w.name], "prepis_s": dt}
                per_file.append(st)

                flag = ""
                if st["opakovani"] >= 3:
                    flag += f"  ⚠ smyčka ×{st['opakovani']}"
                if st["pokryti_%"] < 97:
                    flag += f"  ⚠ pokrytí {st['pokryti_%']:.0f}%"
                print(f"   {w.stem}  {durations[w.name]/60:5.1f}min  "
                      f"{st['slov']:5d} slov  {st['wpm']:5.0f} wpm  "
                      f"{dt:6.1f}s{flag}")

            terms = term_audit("\n".join(joined))
            all_terms[cond] = terms
            report.append({
                "kondice": cond, "sekundy": elapsed,
                "rtf": total_audio / elapsed if elapsed else 0,
                "s_na_20s": elapsed / total_audio * 20 if total_audio else 0,
                "slov_celkem": sum(f["slov"] for f in per_file),
                "smycky": sum(1 for f in per_file if f["opakovani"] >= 3),
                "utnute": sum(1 for f in per_file if f["pokryti_%"] < 97),
                "soubory": per_file, "terminy": terms,
            })
            print(f"   └ {elapsed:.0f}s celkem · RTF {total_audio/elapsed:.0f}× · "
                  f"{elapsed/total_audio*20:.2f}s na 20s diktát\n")

    print("=" * 78)
    print(f"{'kondice':<24}{'slov':>8}{'smyčky':>9}{'utnuté':>9}{'RTF':>8}{'s/20s':>9}")
    print("-" * 78)
    for r in report:
        print(f"{r['kondice']:<24}{r['slov_celkem']:>8}{r['smycky']:>9}"
              f"{r['utnute']:>9}{r['rtf']:>8.0f}{r['s_na_20s']:>9.2f}")
    print("=" * 78)

    names = list(all_terms)
    if names:
        print(f"\nAUDIT TERMÍNŮ   (správně / zkomoleno)\n" + "-" * 78)
        print(f"{'termín':<14}" + "".join(f"{n[:22]:>22}" for n in names))
        for t, _, _ in TERMS:
            if not any(t in all_terms[n] for n in names):
                continue
            row = f"{t:<14}"
            for n in names:
                d = all_terms[n].get(t)
                cell = f"{d['správně']} / {d['zkomoleno']}" if d else "–"
                row += f"{cell:>22}"
            print(row)

    RESULTS.mkdir(exist_ok=True)
    (RESULTS / "corpus.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\nPřepisy: bench/results/transcripts/<kondice>/*.txt")
    print(f"Čísla:   bench/results/corpus.json\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
