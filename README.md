# dictate

Diktovací appka pro macOS, optimalizovaná na češtinu. Náhrada za Wispr Flow.

**Cíl:** držíš pravé ⌥ → mluvíš → pustíš → text je vložený tam, kde je kurzor.
Bez ztracených vět, bez dvacetiminutových retry, s tvým slovníkem.

## Architektura

| Vrstva | Řešení | Cena |
|---|---|---|
| ASR (řeč → text) | Whisper lokálně na M5 Pro (MLX/Metal) | 0 |
| Cleanup (čeština, interpunkce, glosář) | Claude Haiku 4.5 | ~0,05 Kč / diktát |
| Offline fallback | lokální MLX model | 0 |
| Vložení textu | clipboard + syntetické ⌘V (Accessibility API) | — |

Audio se ukládá na disk **před** přepisem. Přepis je odvozený artefakt —
když spadne síť nebo API, nahrávka je pořád tam a jde přepsat znovu.

## Fáze

- [x] **1. Benchmark ASR** — který model umí nejlíp česky *na tvém hlase*
- [ ] 2. MVP menubar app (Swift, push-to-talk, vložení textu)
- [ ] 3. Cleanup vrstva (Haiku 4.5 + glosář + kontext podle aktivní appky)
- [ ] 4. Odolnost (VAD segmentace, historie, offline fallback)

## Fáze 1 — benchmark

```bash
./bench/record.sh          # nahraje 8 vzorků (vestavěný mikrofon)
./bench/record.sh 1        # …nebo přes Scarlett Solo
uv run bench/run_bench.py  # porovná modely, vypíše tabulku
```

Co se měří:
- **WER** — chybovost slov (nižší = lepší)
- **CER** — chybovost znaků, zachytí diakritiku
- **+interpunkce** — WER včetně čárek a teček
- **bez diakritiky** — rozdíl proti WER ukáže, kolik chyb dělá *jen* diakritika
- **s/20s** — jak dlouho trvá přepis 20s diktátu = tvoje reálná latence

Testované kondice: `large-v3`, `large-v3-turbo`, `medium`, každý
**s glosářem a bez něj** (Whisper `initial_prompt` biasuje slovník —
tady se rozhoduje, jestli uslyší „MationX" nebo „mejšn iks").

### Soubory

- `bench/texts/` — texty, které čteš nahlas
- `bench/refs/` — ideální *výstup*, když se liší od čteného
  (např. `4010` místo „čtyři tisíce deset")
- `bench/samples/` — tvoje nahrávky (WAV 16 kHz mono, mimo git)
- `bench/results/bench.json` — čísla + všechny přepisy k ručnímu prohlédnutí

## Vývojové prostředí

macOS 26.5, Apple M5 Pro. Python přes `uv`. Nativní app ve Swiftu
(Xcode, free Personal Team certifikát — žádný Developer Program,
žádná notarizace; lokálně buildnutá app nemá quarantine atribut).
