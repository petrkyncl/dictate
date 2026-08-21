#!/usr/bin/env bash
# Vybere audio vstup podle priority a vypise jeho avfoundation index.
#   1. Scarlett / Focusrite  (Petruv mikrofon)
#   2. vestaveny MacBook mikrofon
#   3. cokoli dalsiho, co neni kamera nebo virtualni zarizeni
# Kamery (MX Brio) a virtualni vystupy (OBS, BlackHole, Aggregate) se nikdy nevyberou.
# Pouziti:  IDX=$(./pick_mic.sh)        ->  index
#           ./pick_mic.sh --name        ->  "index<TAB>nazev"
set -uo pipefail

devices=$(ffmpeg -f avfoundation -list_devices true -i "" 2>&1 \
  | sed -n '/AVFoundation audio devices/,$p' \
  | sed -n 's/.*\[\([0-9][0-9]*\)\] \(.*\)$/\1\t\2/p')

[[ -z "$devices" ]] && { echo "Zadny audio vstup nenalezen." >&2; exit 1; }

pick() { echo "$devices" | grep -iE "$1" | head -1; }

BLOCK='brio|obs|virtual|camera|blackhole|loopback|aggregate|multi-output|soundflower'

chosen=$(pick 'scarlett|focusrite')
[[ -z "$chosen" ]] && chosen=$(pick 'macbook.*(micro|mikro)|built-?in')
[[ -z "$chosen" ]] && chosen=$(echo "$devices" | grep -ivE "$BLOCK" | head -1)
[[ -z "$chosen" ]] && { echo "Jen blokovana zarizeni (kamera/virtualni)." >&2; exit 1; }

if [[ "${1:-}" == "--name" ]]; then echo "$chosen"; else echo "$chosen" | cut -f1; fi
