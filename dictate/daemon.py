#!/usr/bin/env python3
"""Rezidentni demon: drzi Whisper model v RAM a prepisuje po castech.

Proc demon: nacteni modelu stoji ~1,1 s a start Pythonu dalsi pul sekundy.
Na kazdy diktat je to neprijatelne, jednou pri prihlaseni to nikdo nepozna.

Proc po castech: prepis roste s delkou audia linearne (45 s reci = 3,3 s
prepisu). Kdyz se kazdych ~10 s nahravky posle k prepisu uz behem mluveni,
po pusteni klavesy zbyva jen posledni kousek.

Protokol: JSON radky pres unix socket.
    {"cmd":"start"}                        -> {"session":"..."}
    {"cmd":"chunk","session":s,"path":p}   -> {"ok":true}      (nekumuluje odpoved)
    {"cmd":"finish","session":s,"path":p}  -> {"text":"...", "timing":{...}}
    {"cmd":"ping"}                         -> {"ready":true}
Pole "path" u finish je nepovinne (posledni, nedokonceny kousek).
"""
from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path

import mlx_whisper
from dotenv import load_dotenv

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from dictate.cleanup import GLOSSARY, clean_with_llm  # noqa: E402
from dictate.postprocess import clean as regex_clean  # noqa: E402

def _find_ffmpeg() -> str:
    """launchd spousti sluzby s minimalnim PATH, kde Homebrew neni —
    volat 'ffmpeg' holym jmenem tam skonci na FileNotFoundError."""
    from shutil import which
    for c in ("/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"):
        if os.access(c, os.X_OK):
            return c
    return which("ffmpeg") or ""


FFMPEG = _find_ffmpeg()

# mlx_whisper si vola ffmpeg holym jmenem sam uvnitr knihovny (audio.load_audio),
# takze absolutni cesta v nasem kodu nestaci — pod launchd (minimalni PATH)
# by to spadlo az v okamziku prepisu. PATH se proto opravuje pro cely proces.
if FFMPEG:
    _bin = os.path.dirname(FFMPEG)
    if _bin not in os.environ.get("PATH", "").split(":"):
        os.environ["PATH"] = _bin + ":" + os.environ.get("PATH", "")

APP_DIR = Path.home() / "Library" / "Application Support" / "Dictate"
SOCKET = APP_DIR / "daemon.sock"
HISTORY = APP_DIR / "history"
MODEL = "mlx-community/whisper-large-v3-mlx"

# Glosar do initial_prompt zvedl MationX z 29 % na 60 % (viz README).
ASR_PROMPT = (
    "Poznámky k práci: MationX, Passerelle, Internát.cz, TLD Hunter, kyncl.app. "
    "Stavíme SaaS a automatizace. Nasazujeme přes GitHub Actions na VPS, běží to "
    "pod PM2 za nginxem. Stack: Next.js, Vite, Node, TypeScript, React, Supabase, "
    "Tailscale, Raspberry Pi, Cloudflare, Claude Code. Petr Kynčl, Poniklá, Attio. "
    "Píšeme diktovací aplikaci: Wispr Flow, Whisper, macOS Dictate, double press, "
    "push-to-talk, hotkey, Accessibility, menu bar, Option, Xcode, Swift."
)


@dataclass
class Session:
    id: str
    parts: list[str] = field(default_factory=list)
    started: float = field(default_factory=time.perf_counter)
    asr_seconds: float = 0.0


def normalize(src: str) -> str:
    """Srovna hlasitost na -20 LUFS. Bez toho Whisper v tichych mistech
    halucinuje titulkove kredity (namereno: 3 halucinace -> 0)."""
    dst = tempfile.mktemp(suffix=".wav")
    try:
        subprocess.run([FFMPEG, "-hide_banner", "-loglevel", "error", "-y", "-i", src,
                        "-af", "loudnorm=I=-20:TP=-2:LRA=11", "-ar", "16000", "-ac", "1", dst],
                       check=True, timeout=30)
        return dst
    except Exception:
        return src


def transcribe(path: str) -> str:
    norm = normalize(path)
    try:
        r = mlx_whisper.transcribe(norm, path_or_hf_repo=MODEL, language="cs",
                                   initial_prompt=ASR_PROMPT,
                                   condition_on_previous_text=False, verbose=None)
        return r["text"].strip()
    finally:
        if norm != path:
            Path(norm).unlink(missing_ok=True)


class Daemon:
    def __init__(self) -> None:
        self.sessions: dict[str, Session] = {}
        self.lock = threading.Lock()

    # -- prikazy ----------------------------------------------------------
    def cmd_start(self, _: dict) -> dict:
        s = Session(id=uuid.uuid4().hex[:12])
        with self.lock:
            self.sessions[s.id] = s
        return {"session": s.id}

    def cmd_chunk(self, msg: dict) -> dict:
        s = self.sessions.get(msg["session"])
        if not s:
            return {"error": "neznámá session"}
        t0 = time.perf_counter()
        text = transcribe(msg["path"])
        s.asr_seconds += time.perf_counter() - t0
        if text:
            s.parts.append(text)
        return {"ok": True}

    def cmd_finish(self, msg: dict) -> dict:
        s = self.sessions.pop(msg["session"], None)
        if not s:
            return {"error": "neznámá session"}
        t_asr = 0.0
        if msg.get("path"):
            t0 = time.perf_counter()
            tail = transcribe(msg["path"])
            t_asr = time.perf_counter() - t0
            if tail:
                s.parts.append(tail)

        raw = " ".join(s.parts).strip()
        if not raw:
            return {"text": "", "timing": {"asr_tail": round(t_asr, 2),
                                          "asr_behem_mluveni": round(s.asr_seconds, 2),
                                          "llm": 0.0}}

        deterministic, info = regex_clean(raw)
        t0 = time.perf_counter()
        try:
            res = clean_with_llm(deterministic)
            final, usd = res.text, res.usd
        except Exception as e:              # sit spadla / API lezi
            final, usd = deterministic, 0.0  # radsi horsi text nez zadny
            print(f"[llm selhalo, vracím text z ASR] {type(e).__name__}: {e}", flush=True)
        t_llm = time.perf_counter() - t0

        self.archive(s.id, raw, final)
        return {"text": final,
                "timing": {"asr_tail": round(t_asr, 2),          # jen po pusteni klavesy
                           "asr_behem_mluveni": round(s.asr_seconds, 2),
                           "llm": round(t_llm, 2)},
                "usd": round(usd, 5),
                "opraveno": info["termínů_opraveno"],
                "halucinace": len(info["halucinace_smazáno"])}

    def cmd_ping(self, _: dict) -> dict:
        return {"ready": True, "model": MODEL}

    # -- historie ---------------------------------------------------------
    def archive(self, sid: str, raw: str, final: str) -> None:
        HISTORY.mkdir(parents=True, exist_ok=True)
        (HISTORY / f"{time.strftime('%Y%m%d-%H%M%S')}-{sid}.json").write_text(
            json.dumps({"raw": raw, "text": final}, ensure_ascii=False, indent=2),
            encoding="utf-8")

    # -- server -----------------------------------------------------------
    def handle(self, conn: socket.socket) -> None:
        with conn, conn.makefile("rwb") as f:
            for line in f:
                try:
                    msg = json.loads(line)
                    fn = getattr(self, f"cmd_{msg.get('cmd', '')}", None)
                    reply = fn(msg) if fn else {"error": f"neznámý příkaz {msg.get('cmd')!r}"}
                except Exception as e:
                    reply = {"error": f"{type(e).__name__}: {e}"}
                f.write(json.dumps(reply, ensure_ascii=False).encode() + b"\n")
                f.flush()

    def serve(self) -> None:
        APP_DIR.mkdir(parents=True, exist_ok=True)
        SOCKET.unlink(missing_ok=True)
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(str(SOCKET))
        os.chmod(SOCKET, 0o600)
        srv.listen(8)
        print(f"démon poslouchá na {SOCKET}", flush=True)
        while True:
            conn, _ = srv.accept()
            threading.Thread(target=self.handle, args=(conn,), daemon=True).start()


def main() -> int:
    load_dotenv(Path(__file__).resolve().parents[1] / ".env")
    if not FFMPEG:
        print("CHYBA: ffmpeg nenalezen. Nainstaluj: brew install ffmpeg", flush=True)
        return 1
    print(f"ffmpeg: {FFMPEG}", flush=True)
    if not os.environ.get("ANTHROPIC_API_KEY"):
        print("VAROVÁNÍ: ANTHROPIC_API_KEY chybí — poběží jen ASR bez úpravy textu", flush=True)
    print("načítám Whisper…", flush=True)
    t0 = time.perf_counter()
    with tempfile.NamedTemporaryFile(suffix=".wav") as tmp:
        subprocess.run([FFMPEG, "-hide_banner", "-loglevel", "error", "-y",
                        "-f", "lavfi", "-i", "anullsrc=r=16000:cl=mono", "-t", "0.4",
                        tmp.name], check=True)
        transcribe(tmp.name)          # zahreje model i Metal kernely
    print(f"model připraven za {time.perf_counter()-t0:.1f}s", flush=True)
    Daemon().serve()
    return 0


if __name__ == "__main__":
    sys.exit(main())
