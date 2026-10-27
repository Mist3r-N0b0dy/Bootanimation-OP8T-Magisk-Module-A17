#!/usr/bin/env bash
# =============================================================================
#  build.sh - one command: a video -> bootanimation.zip -> flashable Magisk module
#
#    ./build.sh                    animation from animation/bootanimation_a.mp4
#    ./build.sh -V other.mp4       animation from another video (same constraints)
#    ./build.sh -a anim.zip        an already built bootanimation.zip
#    ./build.sh -v crdroid         identity from variants/crdroid.conf
#    ./build.sh -o /tmp/test.zip   output path
#
#  The constraints the ROM enforces are checked here, not documented and hoped
#  for: every zip entry stored, desc.txt resolution = panel, audio.wav inside a
#  part directory, patched player derived from the stock binary.
# =============================================================================
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
VARIANT=nethunter
ANIM=""
VIDEO=""
AUDIO=""
OUT=""

die() { echo "build: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    -v|--variant) VARIANT=$2; shift 2 ;;
    -a|--anim)    ANIM=$2;    shift 2 ;;
    -V|--video)   VIDEO=$2;   shift 2 ;;
    -A|--audio)   AUDIO=$2;   shift 2 ;;
    -o|--out)     OUT=$2;     shift 2 ;;
    -h|--help)    sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1 (try -h)" ;;
  esac
done

CONF=$HERE/variants/$VARIANT.conf
[ -f "$CONF" ] || die "variants/$VARIANT.conf not found.
  A variant file defines: MODULE_ID MODULE_NAME MODULE_VERSION MODULE_VERSION_CODE
  MODULE_AUTHOR MODULE_DESCRIPTION OUTPUT_NAME PANEL_W PANEL_H FPS"
# shellcheck disable=SC1090
. "$CONF"
for v in MODULE_ID MODULE_NAME MODULE_VERSION MODULE_VERSION_CODE MODULE_AUTHOR \
         MODULE_DESCRIPTION OUTPUT_NAME PANEL_W PANEL_H FPS QUALITY; do
  eval "[ -n \"\${$v:-}\" ]" || die "variants/$VARIANT.conf does not set $v"
done
echo "== $MODULE_NAME $MODULE_VERSION (versionCode $MODULE_VERSION_CODE, variant $VARIANT) =="

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

# --- the module tree, minus what we regenerate --------------------------------
# Kept at $W/module so tools/patch.py, which writes to <dir of tools>/module/…,
# lands in the tree that is about to be zipped.
TREE=$W/module
mkdir -p "$TREE"
cp -a "$HERE/module/." "$TREE"/
rm -f "$TREE/module.prop" "$TREE/system/bin/bootanimation.real"
mkdir -p "$TREE/system/product/media"
ANIM_DST="$TREE/system/product/media/bootanimation.zip"

# --- module identity ----------------------------------------------------------
cat > "$TREE/module.prop" <<EOF
id=$MODULE_ID
name=$MODULE_NAME
version=$MODULE_VERSION
versionCode=$MODULE_VERSION_CODE
author=$MODULE_AUTHOR
description=$MODULE_DESCRIPTION
EOF

# The published variant is the one module/module.prop in git describes: if the
# two ever drift, the git file is the liar and this stops.
if [ "$MODULE_ID" = "$(sed -n 's/^id=//p' "$HERE/module/module.prop")" ]; then
  cmp -s "$TREE/module.prop" "$HERE/module/module.prop" ||
    die "module/module.prop and variants/$VARIANT.conf disagree (variant is $MODULE_ID)"
fi

# The installer banner prints the version by hand: keep it in step.
grep -q "$MODULE_VERSION" "$TREE/customize.sh" ||
  die "module/customize.sh does not print version $MODULE_VERSION"

# post-fs-data.sh points at its own directory by absolute path: the module id is
# part of that path, so it follows the variant.
sed -i "s|^MOD=/data/adb/modules/.*|MOD=/data/adb/modules/$MODULE_ID|" "$TREE/post-fs-data.sh"
grep -qx "MOD=/data/adb/modules/$MODULE_ID" "$TREE/post-fs-data.sh" ||
  die "could not set MOD= in post-fs-data.sh"

# --- the player: stock binary + the two validated patches ---------------------
# Never trusted from git: patch.py rebuilds it from tools/bootanimation.stock.bin
# and refuses to run if either end hash is wrong.
cp -a "$HERE/tools" "$W/tools"
python3 "$W/tools/patch.py" --set full --write 2>&1 | sed 's/^/  /' ||
  die "tools/patch.py failed: wrong stock binary, or it could not write"
rm -rf "$W/tools"
cmp -s "$TREE/system/bin/bootanimation.real" "$HERE/module/system/bin/bootanimation.real" ||
  die "module/system/bin/bootanimation.real is stale: run tools/patch.py --write"

# --- the animation ------------------------------------------------------------
if [ -z "$ANIM" ] && [ -f "$HERE/animation/bootanimation.zip" ]; then
  ANIM=$HERE/animation/bootanimation.zip
fi
if [ -n "$ANIM" ]; then
  [ -f "$ANIM" ] || die "animation not found: $ANIM"
  cp -f "$ANIM" "$ANIM_DST"
  echo "  animation  : $ANIM (used as is)"
else
  [ -n "$VIDEO" ] || VIDEO=$HERE/animation/bootanimation_a.mp4
  [ -f "$VIDEO" ] || die "no video to build from ($VIDEO)"
  [ -n "$AUDIO" ] || AUDIO=$HERE/animation/audio.wav
  [ -f "$AUDIO" ] || die "no audio to build from ($AUDIO)"
  echo "  animation  : generating from $(basename "$VIDEO")"
  # Last line of make-bootanimation.sh is `[ "$KEEP" -eq 1 ] && echo ...`, which
  # returns 1 when the work directory is not kept: judge the artefact, not rc.
  rc=0
  bash "$HERE/tools/make-bootanimation.sh" "$VIDEO" -m crop \
      -r "${PANEL_W}x${PANEL_H}" -f "$FPS" -q "$QUALITY" -C -a "$AUDIO" \
      -o "$ANIM_DST" 2>&1 | sed 's/^/  /' || rc=$?
  [ -f "$ANIM_DST" ] || die "make-bootanimation.sh produced nothing (rc=$rc)"
fi

# --- what the ROM will accept, and what the module must contain ---------------
python3 - "$ANIM_DST" "$TREE" "$PANEL_W" "$PANEL_H" "$FPS" <<'PY'
import os, sys, zipfile
anim, tree, pw, ph, fps = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), str(sys.argv[5])

z = zipfile.ZipFile(anim)
infa = z.infolist()
bad = [i.filename for i in infa if i.compress_type != zipfile.ZIP_STORED]
if bad:
    sys.exit(f"stored: these entries are compressed, the ROM refuses the zip: {bad[:5]}")
names = z.namelist()
if "desc.txt" not in names:
    sys.exit("desc.txt missing from the animation")

lines = z.read("desc.txt").decode().splitlines()
head = lines[0].split()
if len(head) < 3:
    sys.exit(f"desc.txt: first line must be '<w> <h> <fps>', got {lines[0]!r}")
w, h, f = int(head[0]), int(head[1]), head[2]
if (w, h) != (pw, ph):
    sys.exit(f"desc.txt: {w}x{h} but the panel is {pw}x{ph} (never rescaled at boot)")
if f != fps:
    sys.exit(f"desc.txt: {f} fps but this variant builds {fps} fps")

parts = [l.split()[3] for l in lines[1:] if len(l.split()) == 4]
if not parts:
    sys.exit("desc.txt: no part declared")
missing = [p for p in parts if f"{p}/" not in names]
if missing:
    sys.exit(f"desc.txt: part(s) absent from the zip: {missing}")

frames = {p: sum(1 for n in names
                 if n.startswith(p + "/") and not n.endswith(("/", ".wav")))
          for p in parts}
empty = [p for p, n in frames.items() if n == 0]
if empty:
    sys.exit(f"empty part(s): {empty}")

audio = [n for n in names if n.endswith("audio.wav")]
if not audio:
    sys.exit("audio.wav must be inside a part directory (part0/audio.wav);"
             " at the zip root the ROM ignores it")
if not any(n.startswith(tuple(p + "/" for p in parts)) for n in audio):
    sys.exit(f"audio.wav is not inside a part directory: {audio}")

required = ["module.prop", "customize.sh", "post-fs-data.sh", "service.sh",
            "sepolicy.rule", "system.prop",
            "system/bin/bootanimation", "system/bin/bootanimation.real",
            "META-INF/com/google/android/update-binary",
            "META-INF/com/google/android/updater-script"]
gone = [r for r in required if not os.path.isfile(os.path.join(tree, r))]
if gone:
    sys.exit(f"module is incomplete: {gone}")

real = os.path.join(tree, "system/bin/bootanimation.real")
wrap = os.path.join(tree, "system/bin/bootanimation")
if b"/system/bin/bootanimation.real" not in open(wrap, "rb").read():
    sys.exit("the wrapper does not exec /system/bin/bootanimation.real")
if b"mount -o bind" not in open(os.path.join(tree, "post-fs-data.sh"), "rb").read():
    sys.exit("post-fs-data.sh does not bind-mount the animation")

print(f"  desc.txt   : {w}x{h} @ {f} fps, parts {' '.join(f'{p}({frames[p]})' for p in parts)}")
print(f"  sound      : {audio[0]}, {z.getinfo(audio[0]).file_size} bytes")
print(f"  animation  : {len(names)} entries, all stored, {os.path.getsize(anim)} bytes")
print(f"  player     : {os.path.getsize(real)} bytes, patched, {os.path.getsize(wrap)} byte wrapper")
PY

# --- modes: the tree comes off a FAT/fuse volume, where everything is 0660 ------
find "$TREE" -type d -exec chmod 0755 {} +
find "$TREE" -type f -exec chmod 0644 {} +
chmod 0755 "$TREE/system/bin/bootanimation" "$TREE/system/bin/bootanimation.real" \
           "$TREE/customize.sh"

# --- assemble -----------------------------------------------------------------
OUT=${OUT:-$HERE/dist/$OUTPUT_NAME}
mkdir -p "$(dirname "$OUT")"
OUT=$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")
rm -f "$OUT"
( cd "$TREE" && zip -0 -r -q "$OUT" . -x '.*' )
echo "  module     : $OUT"
echo "  sha256     : $(sha256sum "$OUT" | cut -d' ' -f1)"
echo "  size       : $(stat -c%s "$OUT") bytes"
