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

- [x] **1. Benchmark ASR** — hotovo, výsledky níž
- [x] **2. MVP menubar app** — hotovo, viz Spuštění
- [x] **3. Cleanup vrstva** — hotovo, Haiku 4.5
- [ ] 4. Odolnost (VAD segmentace, historie v menu, offline fallback) ← další

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


## Výsledky fáze 1

Testováno na 75 minutách vlastního českého diktátu (15 nahrávek z Wispr Flow),
2 modely × glosář × normalizace hlasitosti = 8 kondic.

**Vítěz: `large-v3` + glosář v `initial_prompt` + normalizace na −20 LUFS.**

| Termín | large-v3 samotný | vítězná kombinace |
|---|---|---|
| MationX | 4/14 (29 %) | **14/14 (100 %)** |
| Attio | 0/3 (0 %) | **3/3 (100 %)** |
| trychtýř | 0/1 | **1/1** |
| SaaS | 1/11 (9 %) | 5/11 (45 %) |
| halucinace | 3 | **0** |

Latence 1,58 s na 20s diktát (Whisper počítá ve 30s oknech, takže
kratší diktát stojí totéž). `large-v3-turbo` je 2× rychlejší, ale
zacykluje se (×9 na r05) a MationX trefí hůř — nestojí to za to.

### Co která páka dělá

- **Glosář** (`initial_prompt`) — MationX 29 % → 60 %. Zároveň mírně
  zvyšuje halucinace, protože model víc táhne k „pokračování textu".
- **Normalizace** na −20 LUFS — nahrávky jsou o 10–20 dB pod řečovým
  standardem. Sama o sobě smaže **všechny** halucinace a zkrotí
  zacyklení turba (×9 → ×1).
- **Deterministická čistička** ([dictate/postprocess.py](dictate/postprocess.py)) —
  halucinace na nulu, MationX/Attio/trychtýř na 100 %.

### Co zbývá na LLM vrstvu

Regex by tady napáchal víc škody než užitku, takže se to nechává na model:

- **interpunkce** — nejdelší úsek bez tečky je pořád 294–419 slov;
  žádné nastavení ASR to neřeší, dlouhá forma se prostě rozpadne
- **skloňované tvary SaaS** („sasy", „sasů") — proto je SaaS jen na 45 %
- **`níž` → `niche`** — „níž" je běžné české slovo, plošně nahradit nejde
- velká písmena uprostřed věty


## Výsledky fáze 3 — LLM vrstva

Testováno na stejném korpusu. Kvalita vyrovnaná, rozhoduje latence a cena.

| model | medián | nejhorší | $ / diktát | $ / měsíc¹ | celková latence² |
|---|---|---|---|---|---|
| **Haiku 4.5** | **1,93 s** | 2,92 s | **$0,0022** | **$3,25** | **3,51 s** |
| Sonnet 5 | 4,75 s | 5,71 s | $0,0055 | $8,30 | 6,33 s |
| Opus 5 | 5,40 s | 6,26 s | $0,0142 | $21,26 | 6,98 s |

¹ 50 diktátů denně × 30 dní · ² včetně 1,58 s na ASR

**Vítěz: Haiku 4.5** — 2,5× rychlejší a 2,5× levnější než Sonnet, kvalita stejná
nebo lepší. Opus u jednoho souboru spadl na poměr slov 0,81, tedy začal shrnovat.

### Co LLM vrstva opravila nad rámec regexu

| | před | po |
|---|---|---|
| nejdelší úsek bez tečky | 418 slov | **95 slov** |
| vět na 100 slov | 4,7 | 7,9 |
| SaaS (vč. skloňování) | 5 | **12** |
| MationX | 14 | 15 |
| poměr slov vstup/výstup | — | **0,99** (nic se neztrácí) |

`niche` vs `níž` rozlišilo Haiku správně podle kontextu — „specifické **niche**
B2B Lead Gen" opravilo, „ceník byl mnohem **níž**" nechalo. Sonnet to minul.

## Celková bilance

```
mikrofon → Whisper large-v3 (lokálně, 1,58 s) → regex čistička (0 s)
         → Haiku 4.5 (1,93 s) → vložený text
```

### Latence po nasazení démona

Přepis běží **během mluvení** po ~10s kouscích, takže po puštění klávesy
zbývá jen poslední kousek. Naměřeno end-to-end proti běžícímu démonovi:

| délka diktátu | po puštění klávesy | cena |
|---|---|---|
| 10 s | **1,40 s** | $0,0014 |
| 20 s | **1,33 s** | $0,0018 |
| 45 s | **2,42 s** | $0,0026 |

Bez chunkingu to bylo 3,5 s (20 s) a 5,7 s (45 s).

Prompt caching se **nevyplatil na rychlost** — TTFT je 0,81 s, ale generování
odpovědi 1,67 s, takže cache ušetří 0,1 s. Nasazuje se kvůli ceně (−43 %).

Zbývající latenci drží generování LLM. Dál by šlo: nechat model vracet jen
seznam oprav místo celého textu, nebo vložit text z ASR okamžitě a tiše ho
přepsat, až dorazí verze z LLM.


## Spuštění

```bash
./install-daemon.sh          # démon jako LaunchAgent (drží Whisper v RAM)
cd app && ./build.sh         # zkompiluje a podepíše Dictate.app
open app/build/Dictate.app
```

Pak v **System Settings → Privacy & Security** povolit:
**Accessibility** (odchyt klávesy + vkládání textu) a **Microphone**.

**Podrž pravý ⌥ → mluv → pusť → text se vloží tam, kde je kurzor.**

### Stabilní oprávnění

Ad-hoc podpis mění otisk binárky při každém buildu, takže macOS appku
považuje za novou a **smaže udělená oprávnění**. `make-cert.sh` vyrobí
self-signed certifikát (zdarma, žádný Developer Program), ale macOS
k němu nepustí `codesign`, dokud jednou nespustíš:

```bash
security set-key-partition-list -S apple-tool:,apple:,codesign: \
  -s -l "Dictate Local Signing" ~/Library/Keychains/login.keychain-db
```

Chce to heslo ke klíčence. Bez toho kroku build spadne na ad-hoc podpis —
appka funguje, jen budeš po každém rebuildu znovu povolovat oprávnění.

## Architektura appky

| Soubor | Co dělá |
|---|---|
| [HotkeyMonitor.swift](app/Sources/Dictate/HotkeyMonitor.swift) | `CGEventTap` na pravý ⌥, událost se nepohlcuje |
| [Recorder.swift](app/Sources/Dictate/Recorder.swift) | ffmpeg se segmentací na 10s kousky |
| [MicPicker.swift](app/Sources/Dictate/MicPicker.swift) | priorita Scarlett > vestavěný, kamery blokované |
| [DaemonClient.swift](app/Sources/Dictate/DaemonClient.swift) | unix socket, JSON po řádcích |
| [TextInserter.swift](app/Sources/Dictate/TextInserter.swift) | schránka + syntetické ⌘V, původní obsah se vrátí |

**Proč pravý ⌥ a ne levý:** levý je pracovní klávesa (⌥+Delete maže slovo,
⌥+šipky skáčou po slovech, na české klávesnici se přes něj píše @ a #).
Pravý je na většině rozložení nepoužívaný.

**Proč ne Fn:** systém na ni má vlastní akci (přepnutí jazyka nebo emoji
paleta) a spolehlivě ji spolknout nejde — řeší ji WindowServer níž,
než kam `CGEventTap` dosáhne.

**Proč ffmpeg a ne AVAudioEngine:** segmentový muxer zapisuje kousky na
disk průběžně sám, takže „audio je na disku dřív, než se přepisuje" platí
z principu. A přepis se rozjede už během mluvení.
