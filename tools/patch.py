#!/usr/bin/env python3
"""Fabrique le binaire bootanimation patché à partir du binaire stock.

Base : bootanimation.stock.bin
       sha256 eaae9d4d6f0cc0cc9c513d49245c9236ce121eefacf0767fb7b4fc0190601fd0
       (Android 17, extrait de /system/bin/bootanimation)

Deux jeux de patches, tous deux validés en boot réel sur OnePlus 8T / crDroid 13.x :

  --set full (defaut)                     -> 754cb645dc2310ad...   (v1.0)
    1. 0x2f0c  cbz x20,0x2f58   -> nop        leve le verrou "Audio service is not ready"
    2. 0x246c  tbnz w19,#0,...  -> nop        leve le verrou sys.boot_completed
    3. 0x2ca4  ldr x8,[x0]      -> b 0x23e4   garde anti-crash si le player est nul :
          0x23e4  cbz x0, 0x2af4                 (cave de padding, jamais executee)
          0x23e8  ldr x8, [x0]                   (instruction d'origine)
          0x23ec  b 0x2ca8                       (retour au flux)

  --set minimal                           -> b67d64085b815a29...   (v1.6/v1.7)
    seulement le patch 1. Aucune garde : un player nul => SIGSEGV
    (c'est ce qui a fait un ecran noir total en v1.6).

Usage :
  ./patch.py                 # verifie et affiche
  ./patch.py --write         # ecrit module/system/bin/bootanimation.real
  ./patch.py --set minimal --write
"""
import hashlib, os, struct, sys

BASE = os.path.dirname(os.path.abspath(__file__))
SRC  = os.path.join(BASE, "bootanimation.stock.bin")
DST  = os.path.join(os.path.dirname(BASE), "module", "system", "bin", "bootanimation.real")
CAVE = 0x23E4          # 28 octets de padding dans .text (apres bl __stack_chk_fail)

HASH = {
    "full":    "754cb645dc2310ad1c2b6352c8b8014365ea1f0d19466ec0d0f8c6f6f8bc528e",
    "minimal": "b67d64085b815a29bb7d403fb44fff2f7aa8aa5dea55fd25b7905129ac6aaf54",
}
SHA_STOCK = "eaae9d4d6f0cc0cc9c513d49245c9236ce121eefacf0767fb7b4fc0190601fd0"

def enc_b(frm, to):
    d = to - frm
    assert d % 4 == 0 and -0x8000000 <= d < 0x8000000, "branche hors portee"
    return 0x14000000 | ((d >> 2) & 0x03FFFFFF)

def enc_cbz_x(rt, frm, to):
    d = to - frm
    assert d % 4 == 0 and -0x40000 <= d < 0x40000, "cbz hors portee"
    return 0xB4000000 | (((d >> 2) & 0x7FFFF) << 5) | rt

def main():
    mode = "full"
    if "--set" in sys.argv:
        mode = sys.argv[sys.argv.index("--set") + 1]
    if mode not in HASH:
        sys.exit("--set full|minimal")

    d = bytearray(open(SRC, "rb").read())
    got = hashlib.sha256(d).hexdigest()
    if got != SHA_STOCK:
        sys.exit(f"base inattendue : {got}\n  attendu {SHA_STOCK}")
    word = lambda off: struct.unpack("<I", d[off:off+4])[0]
    def put(off, new, expect, label):
        if word(off) != expect:
            sys.exit(f"@0x{off:04x} attendu {expect:#010x}, obtenu {word(off):#010x} ({label})")
        d[off:off+4] = struct.pack("<I", new)
        print(f"  0x{off:04x}  {expect:#010x} -> {new:#010x}   {label}")

    print(f"jeu de patches : {mode}")
    put(0x2F0C, 0xD503201F, 0xB4000274, "cbz x20,0x2f58 -> nop  (verrou audio_service)")
    if mode == "full":
        put(0x246C, 0xD503201F, 0x37000A33, "tbnz w19,#0 -> nop     (verrou boot_completed)")
        if d[CAVE:CAVE+28] != b"\x00" * 28:
            sys.exit("cave non vide")
        put(0x2CA4, enc_b(0x2CA4, CAVE),  0xF9400008, "ldr x8,[x0] -> b cave (garde anti-crash)")
        put(CAVE,   enc_cbz_x(0, CAVE, 0x2AF4), 0x00000000, "cbz x0,0x2af4      (player nul -> sortie)")
        put(CAVE+4, 0xF9400008,            0x00000000, "ldr x8,[x0]        (instruction d'origine)")
        put(CAVE+8, enc_b(CAVE+8, 0x2CA8), 0x00000000, "b 0x2ca8           (retour au flux)")

    out = bytes(d)
    final = hashlib.sha256(out).hexdigest()
    if final != HASH[mode]:
        sys.exit(f"resultat inattendu : {final}\n  attendu {HASH[mode]}")
    print(f"  base   : {got[:16]}  ({len(out)} octets)")
    print(f"  sortie : {final[:16]}  OK")
    if "--write" in sys.argv:
        open(DST, "wb").write(out)
        print(f"  ecrit  : {os.path.relpath(DST, os.path.dirname(BASE))}")

main()
