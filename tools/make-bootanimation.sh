#!/bin/bash
# =============================================================================
#  make-bootanimation.sh
#  Assemble une bootanimation.zip pour OnePlus 8T (dalle 1080x2400)
#  à partir d'une vidéo (yt-dlp, capture personnelle, n'importe quelle source).
#
#  Usage :
#    ./make-bootanimation.sh video.mp4 [options]
#
#  Options :
#    -m, --mode crop|pad|stretch   crop = plein écran (rogne) | pad = bandes noires
#                                  | stretch = étire (déforme).   [defaut: pad]
#    -r, --res 1080x2400           résolution cible               [defaut: 1080x2400]
#    -f, --fps 30                  images/seconde                 [defaut: 30]
#    -s, --start 0                 # de la frame où commence la BOUCLE (0 = tout en boucle)
#    -q, --quality 2               qualité JPEG (1=best .. 31)    [defaut: 2]
#    -a, --audio son.wav           ajoute audio.wav DANS part0/ (son de démarrage)
#    -C, --complete                force la lecture EN ENTIER ('c') + maintien d'1 frame
#    -o, --out nom.zip             fichier de sortie             [defaut: ./bootanimation.zip]
#    -k, --keep                    garde le dossier de travail
#    -i, --install                 installe dans /system/media (remount auto)
#    -h, --help
#
#  Exemples :
#    ./make-bootanimation.sh video.mp4 -m crop
#    ./make-bootanimation.sh video.mp4 -m crop -f 30 -i
#    ./make-bootanimation.sh video.mp4 -s 90        # frames 0-89 = intro, 90+ = boucle
# =============================================================================
set -euo pipefail

# ---------- paramètres par défaut ----------
MODE="pad"
W=1080; H=2400
FPS=30
LOOP_START=0
QUALITY=2
OUT="./bootanimation.zip"
KEEP=0
INSTALL=0
INPUT=""
AUDIO=""
TARGET_PEAK=-0.3
COMPLETE=0

# ---------- lecture des arguments ----------
while [ $# -gt 0 ]; do
  case "$1" in
    -m|--mode)    MODE="$2"; shift 2 ;;
    -r|--res)     W="${2%x*}"; H="${2#*x}"; shift 2 ;;
    -f|--fps)     FPS="$2"; shift 2 ;;
    -s|--start)   LOOP_START="$2"; shift 2 ;;
    -q|--quality) QUALITY="$2"; shift 2 ;;
    -a|--audio)   AUDIO="$2"; shift 2 ;;
    -C|--complete) COMPLETE=1; shift ;;
    -o|--out)     OUT="$2"; shift 2 ;;
    -k|--keep)    KEEP=1; shift ;;
    -i|--install) INSTALL=1; shift ;;
    -h|--help)    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)           echo "Option inconnue : $1" >&2; exit 1 ;;
    *)            INPUT="$1"; shift ;;
  esac
done

[ -n "$INPUT" ]  || { echo "ERREUR : donne une vidéo en entrée. (-h pour l'aide)" >&2; exit 1; }
[ -f "$INPUT" ]  || { echo "ERREUR : fichier introuvable : $INPUT" >&2; exit 1; }
case "$MODE" in crop|pad|stretch) ;; *) echo "ERREUR : --mode doit être crop|pad|stretch" >&2; exit 1 ;; esac

command -v ffmpeg >/dev/null || { echo "ERREUR : ffmpeg absent." >&2; exit 1; }
command -v zip    >/dev/null || { echo "ERREUR : zip absent." >&2; exit 1; }

# ---------- filtre vidéo ----------
case "$MODE" in
  crop)    VF="scale=${W}:${H}:force_original_aspect_ratio=increase,crop=${W}:${H}" ;;
  pad)     VF="scale=${W}:${H}:force_original_aspect_ratio=decrease,pad=${W}:${H}:(ow-iw)/2:(oh-ih)/2:color=black" ;;
  stretch) VF="scale=${W}:${H}" ;;
esac

# ---------- dossier de travail ----------
WORK="$(mktemp -d /tmp/bootanim.XXXXXX)"
cleanup(){ [ "$KEEP" -eq 1 ] || rm -rf "$WORK"; }
trap cleanup EXIT

echo "======================================================="
echo " BootAnimation builder"
echo "   source   : $INPUT"
echo "   cible    : ${W}x${H} @ ${FPS}fps"
echo "   mode     : $MODE"
echo "   qualité  : $QUALITY"
echo "======================================================="

# ---------- 1) extraction des frames ----------
echo "[1/5] Extraction des frames..."
mkdir -p "$WORK/raw"
ffmpeg -hide_banner -loglevel error -stats \
  -i "$INPUT" -vf "$VF" -r "$FPS" -q:v "$QUALITY" -start_number 0 \
  "$WORK/raw/%04d.jpg"
TOTAL=$(find "$WORK/raw" -name '*.jpg' | wc -l)
[ "$TOTAL" -gt 0 ] || { echo "ERREUR : aucune frame extraite." >&2; exit 1; }
DIM=$(identify -format '%wx%h' "$WORK/raw/0000.jpg" 2>/dev/null || echo "?")
echo "      -> $TOTAL frames, $DIM, $(du -sh "$WORK/raw" | cut -f1)"

# ---------- 2) répartition intro / boucle ----------
echo "[2/5] Structure des parties..."
mkdir -p "$WORK/part0"
if [ "$LOOP_START" -gt 0 ] && [ "$LOOP_START" -lt "$TOTAL" ]; then
  # part0 = intro jouée 1 fois ; part1 = boucle infinie
  i=0
  for f in "$WORK"/raw/*.jpg; do
    if [ "$i" -lt "$LOOP_START" ]; then mkdir -p "$WORK/part0"; mv "$f" "$WORK/part0/$(printf '%04d' $i).jpg"
    else mkdir -p "$WORK/part1"; mv "$f" "$WORK/part1/$(printf '%04d' $((i-LOOP_START))).jpg"; fi
    i=$((i+1))
  done
  N0=$(find "$WORK/part0" -name '*.jpg' | wc -l); N1=$(find "$WORK/part1" -name '*.jpg' | wc -l)
  DESC="p 1 0 part0
p 0 0 part1"
  echo "      -> part0 (intro)  : $N0 frames, jouée 1x"
  echo "      -> part1 (boucle) : $N1 frames, boucle infinie"
else
  mv "$WORK"/raw/*.jpg "$WORK/part0/"
  rmdir "$WORK/raw"
  if [ "$COMPLETE" -eq 1 ]; then
    # 'c' = playUntilComplete : la part n'est PAS interrompue par service.bootanim.exit.
    # part1 = maintien d'UNE frame (la derniere) -> remplit l'attente sans rejouer le son.
    mkdir -p "$WORK/part1"
    LASTF=$(ls "$WORK/part0" | sort | tail -1)
    cp "$WORK/part0/$LASTF" "$WORK/part1/0000.jpg"
    DESC="c 1 0 part0
p 0 0 part1"
    echo "      -> part0 : $TOTAL frames, jouee EN ENTIER (c, non interruptible)"
    echo "      -> part1 : maintien 1 frame ($LASTF), boucle"
  else
    DESC="p 0 0 part0"
    echo "      -> part0 : $TOTAL frames, boucle infinie"
  fi
fi

# ---------- 3) desc.txt ----------
printf '%s %s %s\n%s\n' "$W" "$H" "$FPS" "$DESC" > "$WORK/desc.txt"
echo "[3/5] desc.txt :"
sed 's/^/        /' "$WORK/desc.txt"

# ---------- 3b) audio.wav (optionnel) ----------
ZIP_ITEMS="desc.txt part0"
[ -d "$WORK/part1" ] && ZIP_ITEMS="$ZIP_ITEMS part1"
if [ -n "$AUDIO" ]; then
  [ -f "$AUDIO" ] || { echo "ERREUR : audio introuvable : $AUDIO" >&2; exit 1; }
  echo "[3b/5] Audio -> audio.wav (RIFF/WAVE PCM)..."
  # --- normalisation en crête : on monte au max sans dépasser la cible ---
  PEAK=$(ffmpeg -hide_banner -i "$AUDIO" -vn -af volumedetect -f null - 2>&1 \
         | sed -n 's/.*max_volume: \(-\{0,1\}[0-9.]*\) dB.*/\1/p' | head -1)
  if [ -z "$PEAK" ]; then
    echo "        !! pic non mesurable (piste vide ?) -> aucun gain appliqué"
    GAIN=0
  else
    GAIN=$(awk -v p="$PEAK" -v t="$TARGET_PEAK" 'BEGIN{g=t-p; if(g<0)g=0; printf "%.2f", g}')
    echo "        pic source : ${PEAK} dBFS  +  gain ${GAIN} dB  ->  cible ${TARGET_PEAK} dBFS"
  fi
  # le lecteur exige un vrai RIFF/WAVE : PCM signé 16 bits, 48 kHz, stéréo
  # ⚠️ IL DOIT ÊTRE DANS LE DOSSIER D'UNE PART (part0/audio.wav) :
  #    BootAnimation::preloadZip() ne retient audio.wav que si son dossier parent
  #    == le chemin d'une part de desc.txt. À la racine du zip, il est IGNORÉ.
  ffmpeg -hide_banner -loglevel error -i "$AUDIO" -vn -ac 2 -ar 48000 \
         -af "volume=${GAIN}dB" -c:a pcm_s16le -y "$WORK/part0/audio.wav"
  ffmpeg -hide_banner -i "$WORK/part0/audio.wav" -af volumedetect -f null - 2>&1 \
         | grep -E 'max_volume' | sed 's/.*\(max_volume.*\)/        pic final : \1/'
  python3 - "$WORK/part0/audio.wav" <<'PY'
import sys
d=open(sys.argv[1],'rb').read(12)
assert d[:4]==b'RIFF' and d[8:12]==b'WAVE', "ce n'est pas un RIFF/WAVE valide !"
print("        -> RIFF/WAVE OK, placé dans part0/")
PY
  ZIP_ITEMS="$ZIP_ITEMS part0/audio.wav"
fi

# ---------- 4) zip SANS compression ----------
echo "[4/5] Création du zip (mode Stored)..."
OUT_ABS="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
rm -f "$OUT_ABS"   # IMPORTANT : 'zip' MET À JOUR une archive existante au lieu de la remplacer
( cd "$WORK" && zip -0 -r -q "$OUT_ABS" $ZIP_ITEMS )

# ---------- 5) vérification ----------
echo "[5/5] Vérification..."
python3 - "$OUT_ABS" <<'PY'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
bad = [i.filename for i in z.infolist() if i.compress_type != zipfile.ZIP_STORED]
names = z.namelist()
ok_desc = "desc.txt" in names
print(f"        entrées         : {len(names)}")
print(f"        desc.txt lisible: {ok_desc}")
print(f"        compressions KO : {len(bad)}" + ("" if not bad else f" -> {bad[:5]}"))
if not ok_desc or bad:
    print("        !! ZIP INVALIDE pour Android"); sys.exit(1)
print("        -> VALIDE (toutes les entrées en 'Stored')")
PY
ls -la "$OUT_ABS" | awk '{printf "        taille : %.1f Mo\n", $5/1048576}'

# ---------- installation optionnelle ----------
if [ "$INSTALL" -eq 1 ]; then
  echo "[+] Installation dans /system/media ..."
  DEST=/system/media/bootanimation.zip
  FREEMB=$(( $(df -k /system | awk 'NR==2{print $4}') / 1024 ))
  SZMB=$(( $(stat -c%s "$OUT_ABS") / 1048576 ))
  echo "        /system libre : ${FREEMB} Mo | zip : ${SZMB} Mo"
  [ "$SZMB" -lt "$FREEMB" ] || { echo "ERREUR : pas assez d'espace sur /system." >&2; exit 1; }
  blockdev --setrw /dev/block/dm-2
  mount -o rw,remount /system
  mkdir -p /system/media
  cp -f "$OUT_ABS" "$DEST"
  cmp -s "$OUT_ABS" "$DEST" || { echo "ERREUR : copie corrompue." >&2; exit 1; }
  chmod 644 "$DEST"; chown 0:0 "$DEST" 2>/dev/null || true
  sync
  mount -o ro,remount /system
  blockdev --setro /dev/block/dm-2
  echo "        installé : $DEST"
  echo "        -> REDÉMARRE pour voir l'animation."
fi

echo
echo "OK : $OUT_ABS"
[ "$KEEP" -eq 1 ] && echo "Dossier de travail conservé : $WORK"
