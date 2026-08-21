#!/usr/bin/env bash
# Nahraje referencni vzorky pro ASR benchmark.
# Pouziti:  ./record.sh [index_mikrofonu]   (bez argumentu = autodetekce)
set -uo pipefail
cd "$(dirname "$0")"

# Mikrofon: 1) explicitni argument, 2) autodetekce (Scarlett > vestaveny, nikdy kamera)
if [[ -n "${1:-}" ]]; then
  MIC="$1"
  MIC_NAME=$(ffmpeg -f avfoundation -list_devices true -i "" 2>&1 \
    | sed -n '/AVFoundation audio devices/,$p' \
    | sed -n "s/.*\\[${MIC}\\] \\(.*\\)$/\\1/p" | head -1)
  MIC_NAME="${MIC_NAME:-zařízení #$MIC}"
  MIC_SRC="ručně"
else
  picked=$("$(dirname "$0")/pick_mic.sh" --name) || exit 1
  MIC=$(cut -f1 <<<"$picked")
  MIC_NAME=$(cut -f2 <<<"$picked")
  MIC_SRC="auto"
fi

bold=$'\033[1m'; dim=$'\033[2m'; grn=$'\033[32m'; ylw=$'\033[33m'; rst=$'\033[0m'

echo
echo "${bold}ASR benchmark — nahrávání vzorků${rst}"
echo "${dim}Mikrofon: ${bold}${MIC_NAME}${rst}${dim} (${MIC_SRC})  ·  jiný: ./record.sh <index>${rst}"
echo
echo "Postup u každého vzorku:"
echo "  1. přečti si text"
echo "  2. ${grn}Enter${rst} → začne nahrávat"
echo "  3. přečti text nahlas, ${bold}přirozeně, svým normálním tempem${rst}"
echo "  4. ${ylw}q${rst} + Enter → nahrávání stop"
echo
echo "${dim}Zkratky a čísla čti tak, jak bys je řekl v reálu.${rst}"
echo "${dim}Nevadí drobné přeřeknutí — vadí, když vynecháš nebo přidáš slovo.${rst}"
echo

for f in texts/*.txt; do
  base=$(basename "$f" .txt)
  out="samples/${base}.wav"

  if [[ -f "$out" ]]; then
    dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$out" 2>/dev/null | cut -d. -f1)
    printf "%s✓ %-24s%s ${dim}už nahráno (%ss)${rst} — přenahrát? [a/N] " "$grn" "$base" "$rst" "${dur:-?}"
    read -r ans < /dev/tty
    [[ "$ans" != "a" && "$ans" != "A" ]] && continue
  fi

  echo
  echo "${bold}── ${base} ──────────────────────────────${rst}"
  echo
  fold -s -w 76 "$f" | sed 's/^/   /'
  echo
  printf "%s" "   ${grn}Enter = nahrávat${rst} ${dim}(s = přeskočit)${rst} "
  read -r go < /dev/tty
  [[ "$go" == "s" || "$go" == "S" ]] && { echo "   přeskočeno"; continue; }

  echo "   ${ylw}● NAHRÁVÁM${rst} — mluv, pak ${bold}q${rst}+Enter"
  ffmpeg -hide_banner -loglevel error \
         -f avfoundation -i ":${MIC}" \
         -ar 16000 -ac 1 -c:a pcm_s16le \
         -y "$out" < /dev/tty

  if [[ -f "$out" ]]; then
    dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$out" 2>/dev/null)
    printf "   %s✓ uloženo%s ${dim}(%.1f s)${rst}\n" "$grn" "$rst" "${dur:-0}"
  fi
done

echo
n=$(ls -1 samples/*.wav 2>/dev/null | wc -l | tr -d ' ')
t=$(ls -1 texts/*.txt | wc -l | tr -d ' ')
echo "${bold}Hotovo: ${n}/${t} vzorků${rst}"
[[ "$n" == "$t" ]] && echo "${grn}Můžeš pustit benchmark.${rst}" || echo "${ylw}Chybí ${rst}$((t-n))${ylw} — spusť ./record.sh znovu.${rst}"
echo
