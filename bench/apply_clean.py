#!/usr/bin/env python3
"""Pusti deterministickou cistici vrstvu na ulozene prepisy.

Vytvori vedle kazde kondice novou '<kondice>+clean', aby sla porovnat
v auditu proti neupravene verzi.
"""
import shutil, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from dictate.postprocess import clean  # noqa: E402

TX = Path(__file__).parent / "results" / "transcripts"

total_h, total_t = 0, 0
for src in sorted(d for d in TX.iterdir() if d.is_dir() and not d.name.endswith("+clean")):
    dst = TX / f"{src.name}+clean"
    shutil.rmtree(dst, ignore_errors=True)
    dst.mkdir(parents=True)
    h = t = 0
    for f in sorted(src.glob("*.txt")):
        out, info = clean(f.read_text(encoding="utf-8"))
        (dst / f.name).write_text(out, encoding="utf-8")
        h += len(info["halucinace_smazáno"])
        t += info["termínů_opraveno"]
    total_h, total_t = total_h + h, total_t + t
    print(f"{src.name:<30} halucinace -{h:<3} termíny {t:>4} opraveno")
print(f"\nCelkem: smazáno {total_h} halucinací, opraveno {total_t} termínů")
