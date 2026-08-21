#!/usr/bin/env python3
"""Simuluje realny prubeh diktatu proti demonovi a meri, co uzivatel ceka.

Klicove cislo je 'po release' — cas od pusteni klavesy po vlozeny text.
Vsechno, co se stihlo behem mluveni, uzivatel nevnima.
"""
import json, socket, subprocess, sys, tempfile, time
from pathlib import Path

SOCK = Path.home() / "Library/Application Support/Dictate/daemon.sock"
CHUNK = 10  # sekund; po tolika se kousek posle k prepisu uz behem mluveni


def rpc(f, **msg):
    f.write(json.dumps(msg).encode() + b"\n"); f.flush()
    return json.loads(f.readline())


def slice_wav(src, start, dur):
    dst = tempfile.mktemp(suffix=".wav")
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                    "-ss", str(start), "-t", str(dur), "-i", src,
                    "-ar", "16000", "-ac", "1", dst], check=True)
    return dst


def main():
    src, total = sys.argv[1], float(sys.argv[2])
    c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); c.connect(str(SOCK))
    f = c.makefile("rwb")

    if not rpc(f, cmd="ping").get("ready"):
        print("démon není připraven"); return 1

    sid = rpc(f, cmd="start")["session"]
    print(f"diktát {total:.0f}s, kousky po {CHUNK}s")

    # kousky, ktere by se odeslaly uz behem mluveni
    pos = 0.0
    while pos + CHUNK <= total:
        p = slice_wav(src, pos, CHUNK)
        t0 = time.perf_counter()
        rpc(f, cmd="chunk", session=sid, path=p)
        print(f"   kousek {pos:.0f}–{pos+CHUNK:.0f}s přepsán za {time.perf_counter()-t0:.2f}s "
              f"(běží během mluvení, uživatel to nevidí)")
        Path(p).unlink(missing_ok=True)
        pos += CHUNK

    tail = slice_wav(src, pos, total - pos) if total - pos > 0.3 else None
    print(f"\n── PUŠTĚNÍ KLÁVESY (zbývá {total-pos:.1f}s zvuku) ──")
    t0 = time.perf_counter()
    r = rpc(f, cmd="finish", session=sid, path=tail)
    wall = time.perf_counter() - t0
    if tail:
        Path(tail).unlink(missing_ok=True)

    if "error" in r:
        print("chyba:", r["error"]); return 1
    print(f"   ASR zbytku  {r['timing']['asr_tail']:.2f}s"
          f"   (během mluvení už proběhlo {r['timing']['asr_behem_mluveni']:.2f}s)")
    print(f"   LLM         {r['timing']['llm']:.2f}s")
    print(f"   ► PO RELEASE CELKEM {wall:.2f}s   (${r.get('usd',0):.4f})")
    print(f"\n{r['text'][:400]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
