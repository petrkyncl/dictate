#!/usr/bin/env python3
"""Da se vratit latence bez ztraty kvality?

Deleni po pevnych 10 s stalo 40 % slov. Tenhle skript zkousi variantu,
ktera obe zjistene priciny odstranuje:
  * rez se vede v TICHU, ne uprostred slova
  * zesileni se spocita JEDNOU pro celou nahravku, ne pro kazdy kousek
    (loudnorm na kousku plnem ticha vytahne sum na uroven reci)
  * kousek ma aspon MIN_CHUNK sekund, aby mel model kontext
"""
import re, subprocess, sys, tempfile, wave
from pathlib import Path
import mlx_whisper

R = "mlx-community/whisper-large-v3-mlx"
PROMPT = ("Poznámky k práci: MationX, Passerelle, Internát.cz. Nasazujeme přes GitHub "
          "Actions na VPS, běží to pod PM2 za nginxem. Stack: Next.js, Vite, Node.")
HALL = re.compile(r"[Tt]itulky vytvořil|[Pp]řeklad:|titulky\.com|JohnyX", re.I)
WORD = re.compile(r"[^\W\d_]+", re.UNICODE)
MIN_CHUNK = 20.0     # kratsi kousek uz modelu bere kontext
MAX_CHUNK = 45.0     # nad tim se ceka zbytecne dlouho


def run(args):
    return subprocess.run(args, capture_output=True, text=True)


def session_gain(src: str) -> float:
    """Zesileni v dB spoctene JEDNOU z cele nahravky."""
    out = run(["ffmpeg", "-hide_banner", "-nostats", "-i", src,
               "-af", "ebur128", "-f", "null", "-"]).stderr
    m = re.findall(r"I:\s*(-?[\d.]+)\s*LUFS", out)
    return (-20.0 - float(m[-1])) if m else 0.0


def cut_points(src: str, dur: float) -> list[float]:
    """Casy ticha, kde se da rezat, aby rez nepadl doprostred slova."""
    out = run(["ffmpeg", "-hide_banner", "-nostats", "-i", src,
               "-af", "silencedetect=noise=-35dB:d=0.45", "-f", "null", "-"]).stderr
    sil = [float(x) for x in re.findall(r"silence_end:\s*([\d.]+)", out)]
    points, last = [], 0.0
    for t in sil:
        if t - last >= MIN_CHUNK:
            points.append(t); last = t
    # kdyz je ticha malo, dorovnej tvrdym rezem, at kousek nepresahne MAX
    final, last = [], 0.0
    for t in points + [dur]:
        while t - last > MAX_CHUNK:
            last += MAX_CHUNK
            final.append(last)
        if t < dur:
            final.append(t); last = t
    return final


def tr(path):
    return mlx_whisper.transcribe(path, path_or_hf_repo=R, language="cs",
                                  initial_prompt=PROMPT,
                                  condition_on_previous_text=False,
                                  verbose=None)["text"].strip()


def slice_gain(src, start, dur, gain, dst):
    args = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-ss", str(start)]
    if dur is not None:
        args += ["-t", str(dur)]
    args += ["-i", src, "-af", f"volume={gain}dB", "-ar", "16000", "-ac", "1", dst]
    subprocess.run(args, check=True)


def main():
    files = sorted(Path("bench/corpus").glob("*.wav"))[:6]
    tmp = tempfile.mkdtemp()
    print(f"\n{len(files)} nahrávek · řez v tichu, zesílení jednotné pro celou nahrávku\n")
    print(f"{'soubor':<8}{'délka':>7}{'vcelku':>9}{'v tichu':>9}{'rozdíl':>9}"
          f"{'kousků':>8}{'halucinace':>13}")
    print("-" * 63)
    tw = tc = th = thc = 0
    for f in files:
        with wave.open(str(f)) as w:
            dur = w.getnframes() / w.getframerate()
        g = session_gain(str(f))

        whole = f"{tmp}/{f.stem}_w.wav"
        slice_gain(str(f), 0, None, g, whole)
        t_whole = tr(whole)

        pts = cut_points(str(f), dur)
        bounds = [0.0] + pts + [dur]
        parts = []
        for i in range(len(bounds) - 1):
            a, b = bounds[i], bounds[i + 1]
            if b - a < 0.5:
                continue
            c = f"{tmp}/{f.stem}_{i}.wav"
            slice_gain(str(f), a, b - a, g, c)
            parts.append(tr(c))
            Path(c).unlink(missing_ok=True)
        t_chunk = " ".join(p for p in parts if p)

        ww, wc = len(WORD.findall(t_whole)), len(WORD.findall(t_chunk))
        hw, hc = len(HALL.findall(t_whole)), len(HALL.findall(t_chunk))
        tw += ww; tc += wc; th += hw; thc += hc
        print(f"{f.stem:<8}{dur:>6.0f}s{ww:>9}{wc:>9}{wc-ww:>+9}{len(parts):>8}"
              f"{f'{hw} → {hc}':>13}")

    print("-" * 63)
    print(f"{'CELKEM':<8}{'':>7}{tw:>9}{tc:>9}{tc-tw:>+9}{'':>8}{f'{th} → {thc}':>13}")
    print(f"\nRozdíl v počtu slov: {(tc-tw)/max(1,tw)*100:+.1f} %")
    print(f"(dělení po pevných 10 s dávalo −39,8 % a 2 → 75 halucinací)\n")


if __name__ == "__main__":
    sys.exit(main())
