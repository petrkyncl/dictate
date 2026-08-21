#!/usr/bin/env python3
"""ASR benchmark pro ceskou diktovaci appku.

Porovna nekolik Whisper modelu na tvych vlastnich nahravkach a spocita,
jak moc se lisi od toho, co jsi doopravdy rekl.

Spust:  uv run bench/run_bench.py
"""
from __future__ import annotations

import json
import re
import sys
import time
import unicodedata
from pathlib import Path

import jiwer
import mlx_whisper

HERE = Path(__file__).parent
TEXTS, REFS, SAMPLES, RESULTS = HERE / "texts", HERE / "refs", HERE / "samples", HERE / "results"

# Glosar do initial_prompt: Whisper jim biasuje slovnik. Klicovy experiment —
# presne tady se lame, jestli uslysi "MationX" nebo "mejšn iks".
GLOSSARY = (
    "Poznámky k projektům: MationX, Passerelle, Internát.cz, TLD Hunter, kyncl.app. "
    "Nasazujeme přes GitHub Actions na VPS, běží to pod PM2 za nginxem. "
    "Stack: Next.js, Vite, Node, TypeScript, Python, Tailscale, Raspberry Pi. "
    "Petr Kynčl, Poniklá, WhatsApp, Claude Code."
)

MODELS = [
    ("large-v3",       "mlx-community/whisper-large-v3-mlx"),
    ("large-v3-turbo", "mlx-community/whisper-large-v3-turbo"),
    ("medium",         "mlx-community/whisper-medium-mlx"),
]

PUNCT = re.compile(r"[^\w\s]", re.UNICODE)
WS = re.compile(r"\s+")


def norm(s: str, *, keep_punct: bool = False, keep_diacritics: bool = True) -> str:
    """Normalizace pro WER. Default: lowercase, bez interpunkce, s diakritikou."""
    s = s.strip().lower()
    if not keep_punct:
        s = PUNCT.sub(" ", s)
    if not keep_diacritics:
        s = "".join(c for c in unicodedata.normalize("NFD", s) if not unicodedata.combining(c))
    return WS.sub(" ", s).strip()


def reference(stem: str) -> str:
    """refs/ (idealni vystup) ma prednost pred texts/ (co se cetlo nahlas)."""
    for d in (REFS, TEXTS):
        p = d / f"{stem}.txt"
        if p.exists():
            return p.read_text(encoding="utf-8").strip()
    raise FileNotFoundError(stem)


def audio_seconds(path: Path) -> float:
    import wave
    with wave.open(str(path)) as w:
        return w.getnframes() / w.getframerate()


def main() -> int:
    wavs = sorted(SAMPLES.glob("*.wav"))
    if not wavs:
        print("Zadne nahravky v bench/samples/. Spust nejdriv:  ./bench/record.sh")
        return 1

    total_audio = sum(audio_seconds(w) for w in wavs)
    print(f"\n{len(wavs)} vzorku, {total_audio:.0f}s audia celkem")
    print("Prvni beh stahuje modely (~5 GB), pak uz jsou v cache.\n")

    rows, transcripts = [], {}

    for model_label, repo in MODELS:
        for use_glossary in (False, True):
            cond = f"{model_label} {'+glosář' if use_glossary else ''}".strip()
            print(f"── {cond}")
            hyps, refs_l, elapsed = [], [], 0.0
            try:
                for wav in wavs:
                    t0 = time.perf_counter()
                    out = mlx_whisper.transcribe(
                        str(wav),
                        path_or_hf_repo=repo,
                        language="cs",
                        initial_prompt=GLOSSARY if use_glossary else None,
                        condition_on_previous_text=False,
                        verbose=None,
                    )
                    elapsed += time.perf_counter() - t0
                    hyp = out["text"].strip()
                    hyps.append(hyp)
                    refs_l.append(reference(wav.stem))
                    transcripts.setdefault(wav.stem, {})[cond] = hyp
                    print(f"   {wav.stem:<22} {hyp[:64]}…")
            except Exception as e:  # model se nestahl / neexistuje
                print(f"   ⚠ přeskočeno: {type(e).__name__}: {e}\n")
                continue

            r_loose = [norm(r) for r in refs_l]
            h_loose = [norm(h) for h in hyps]
            rows.append({
                "kondice": cond,
                "wer": jiwer.wer(r_loose, h_loose) * 100,
                "cer": jiwer.cer(r_loose, h_loose) * 100,
                "wer_interpunkce": jiwer.wer([norm(r, keep_punct=True) for r in refs_l],
                                             [norm(h, keep_punct=True) for h in hyps]) * 100,
                "wer_bez_diakritiky": jiwer.wer([norm(r, keep_diacritics=False) for r in refs_l],
                                                [norm(h, keep_diacritics=False) for h in hyps]) * 100,
                "sekundy": elapsed,
                "rtf": total_audio / elapsed if elapsed else 0.0,
                "s_na_20s_diktat": elapsed / total_audio * 20 if total_audio else 0.0,
            })
            print()

    if not rows:
        print("Nic neprobehlo.")
        return 1

    rows.sort(key=lambda r: r["wer"])

    print("=" * 92)
    print(f"{'kondice':<26}{'WER%':>8}{'CER%':>8}{'+interp%':>10}{'bez diakr%':>12}{'RTF':>8}{'s/20s':>9}")
    print("-" * 92)
    for r in rows:
        print(f"{r['kondice']:<26}{r['wer']:>8.1f}{r['cer']:>8.1f}"
              f"{r['wer_interpunkce']:>10.1f}{r['wer_bez_diakritiky']:>12.1f}"
              f"{r['rtf']:>8.1f}{r['s_na_20s_diktat']:>9.2f}")
    print("=" * 92)
    print("WER = chybovost slov (nižší lepší) · RTF = kolikrát rychleji než realtime")
    print("s/20s = jak dlouho trvá přepis 20s diktátu → tvoje reálná latence")
    print(f"\nVítěz: {rows[0]['kondice']} — WER {rows[0]['wer']:.1f} %,"
          f" latence {rows[0]['s_na_20s_diktat']:.2f} s na 20s diktát")

    RESULTS.mkdir(exist_ok=True)
    (RESULTS / "bench.json").write_text(
        json.dumps({"souhrn": rows, "prepisy": transcripts}, ensure_ascii=False, indent=2),
        encoding="utf-8")
    print(f"Detail (včetně všech přepisů): bench/results/bench.json\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
