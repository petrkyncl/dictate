#!/usr/bin/env python3
"""Kolik kvality stoji deleni nahravky na kousky?

Latence se resila tim, ze se prepisuje po ~10s kouscich uz behem mluveni.
Kvalita se ale po te zmene znovu nemerila. Tenhle skript to dohani:
tentyz zvuk vcelku vs. narezany na kousky.
"""
import re, subprocess, sys, tempfile, time, wave
from pathlib import Path
import mlx_whisper

R = "mlx-community/whisper-large-v3-mlx"
PROMPT = ("Poznámky k práci: MationX, Passerelle, Internát.cz. Nasazujeme přes GitHub "
          "Actions na VPS, běží to pod PM2 za nginxem. Stack: Next.js, Vite, Node.")
HALL = re.compile(r"[Tt]itulky vytvořil|[Pp]řeklad:|titulky\.com|JohnyX", re.I)
WORD = re.compile(r"[^\W\d_]+", re.UNICODE)


def norm(src, dst):
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", src,
                    "-af", "loudnorm=I=-20:TP=-2:LRA=11", "-ar", "16000", "-ac", "1", dst],
                   check=True)


def tr(path):
    return mlx_whisper.transcribe(path, path_or_hf_repo=R, language="cs",
                                  initial_prompt=PROMPT,
                                  condition_on_previous_text=False,
                                  verbose=None)["text"].strip()


def main():
    files = sorted(Path("bench/corpus").glob("*.wav"))[:6]
    tmp = tempfile.mkdtemp()
    print(f"\n{len(files)} nahrávek\n")
    print(f"{'soubor':<8}{'délka':>7}{'vcelku':>9}{'po 10s':>9}{'rozdíl':>9}"
          f"{'halucinace':>13}")
    print("-" * 56)
    tw = tc = th = thc = 0
    for f in files:
        with wave.open(str(f)) as w:
            dur = w.getnframes() / w.getframerate()

        whole = f"{tmp}/{f.stem}_w.wav"
        norm(str(f), whole)
        t_whole = tr(whole)

        parts = []
        for i in range(0, int(dur), 10):
            c = f"{tmp}/{f.stem}_{i}.wav"
            subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                            "-ss", str(i), "-t", "10", "-i", str(f),
                            "-af", "loudnorm=I=-20:TP=-2:LRA=11",
                            "-ar", "16000", "-ac", "1", c], check=True)
            parts.append(tr(c))
            Path(c).unlink(missing_ok=True)
        t_chunk = " ".join(p for p in parts if p)

        ww, wc = len(WORD.findall(t_whole)), len(WORD.findall(t_chunk))
        hw, hc = len(HALL.findall(t_whole)), len(HALL.findall(t_chunk))
        tw += ww; tc += wc; th += hw; thc += hc
        print(f"{f.stem:<8}{dur:>6.0f}s{ww:>9}{wc:>9}{wc-ww:>+9}"
              f"{f'{hw} → {hc}':>13}")

    print("-" * 56)
    print(f"{'CELKEM':<8}{'':>7}{tw:>9}{tc:>9}{tc-tw:>+9}{f'{th} → {thc}':>13}")
    print(f"\nHalucinace vcelku: {th}   ·   po kouscích: {thc}")
    print(f"Rozdíl v počtu slov: {(tc-tw)/max(1,tw)*100:+.1f} %\n")


if __name__ == "__main__":
    sys.exit(main())
