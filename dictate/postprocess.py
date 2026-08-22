"""Deterministicka cisticka prepisu — bezi pred LLM vrstvou.

Resi jen to, co je jistota: zname halucinace a zkomoleniny, u kterych
neexistuje kontext, ve kterem by byl puvodni tvar spravne. Vsechno
nejednoznacne (sklonovana 'sasy', 'níž' vs 'niche', interpunkce)
se necha na LLM — regex by tam napachal vic skody nez uzitku.
"""
from __future__ import annotations

import re

# --- Halucinace ------------------------------------------------------------
# Whisper ma v trenovacich datech titulkove kredity a po delsim tichu
# je zacne dopisovat. Uzivatel nic z toho nikdy nerekne.
HALLUCINATIONS = [
    re.compile(p, re.IGNORECASE)
    for p in (
        r"\s*Titulky\s+(?:vytvořil|pro|a\s+přepis|z\s+odposlechu)\b[^.!?]*[.!?]?",
        r"\s*Překlad\s*:\s*[^.!?]*[.!?]?",
        r"\s*(?:www\.)?titulky\.com\b",
        r"\s*Děkuj[iu]\s+(?:vám\s+)?za\s+(?:pozornost|shlédnutí|sledování)\s*[.!]?\s*$",
        r"\s*Podpořte\s+nás\b[^.!?]*[.!?]?",
        r"\s*Subtitles?\s+(?:by|created)\b[^.!?]*[.!?]?",
        r"\s*JohnyX\b\s*\.?",
    )
]

# --- Zkomoleniny -----------------------------------------------------------
# Jen tvary, ktere jsou v tomhle kontextu VZDY chybne.
# (regex, nahrada) — poradi zalezi, delsi vzory prvni.
TERM_FIXES: list[tuple[re.Pattern, str]] = [
    (re.compile(r"\b(?:Machine|Mission|Motion|Matron)\s?X\b", re.IGNORECASE), "MationX"),
    (re.compile(r"\bMation\s+X\b", re.IGNORECASE), "MationX"),
    (re.compile(r"\bmationx\b"), "MationX"),          # sjednoceni velikosti pismen
    (re.compile(r"\bMationx\b"), "MationX"),
    (re.compile(r"\bAt[iy]o\b"), "Attio"),
    (re.compile(r"\b(?:Spr\s?flow|Whisper\s?flow|Wisper\s?flow|Visp\w*\s?flow)\b",
                re.IGNORECASE), "Wispr Flow"),
    (re.compile(r"\btrichtýř(\w*)\b", re.IGNORECASE), r"trychtýř\1"),
    (re.compile(r"\bSAS\b"), "SaaS"),                 # verzalky = vzdy SaaS
    (re.compile(r"\bWPS\b"), "VPS"),
    (re.compile(r"\bGithub\b"), "GitHub"),
    (re.compile(r"\blinkedin\b", re.IGNORECASE), "LinkedIn"),
    (re.compile(r"\bwhatsappu\b", re.IGNORECASE), "WhatsAppu"),
    (re.compile(r"\bwhatsapp\b", re.IGNORECASE), "WhatsApp"),
]

# Necha se na LLM (regex by je rozbil):
#   'níž' -> 'niche'   ... 'níž' je bezne ceske slovo
#   'sasy/sasů/sase'   ... sklonovane tvary SaaS vs. skutecne slovo
#   'WordPress'        ... uzivatel dela weby, WordPress zminuje doopravdy;
#                          jestli mel na mysli 'double press', pozna jen kontext
#   interpunkce        ... vyzaduje porozumeni vete
LLM_TERRITORY = ("níž → niche", "sklonované tvary SaaS", "interpunkce", "velká písmena ve větě")

WS = re.compile(r"[ \t]{2,}")


def strip_hallucinations(text: str) -> tuple[str, list[str]]:
    removed = []
    for pat in HALLUCINATIONS:
        for m in pat.finditer(text):
            if m.group(0).strip():
                removed.append(m.group(0).strip())
        text = pat.sub("", text)
    return text.strip(), removed


def fix_terms(text: str) -> tuple[str, int]:
    n = 0
    for pat, repl in TERM_FIXES:
        text, k = pat.subn(repl, text)
        n += k
    return text, n


def clean(text: str) -> tuple[str, dict]:
    """Vrati (vycisteny_text, co_se_stalo)."""
    text, removed = strip_hallucinations(text)
    text, n = fix_terms(text)
    text = WS.sub(" ", text).strip()
    return text, {"halucinace_smazáno": removed, "termínů_opraveno": n}
