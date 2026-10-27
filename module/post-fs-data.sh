#!/system/bin/sh
# v1.8 : on ne depend plus de l'ordre de montage de Magisk.
#   Le module officiel nethunter fournit LUI AUSSI
#   /system/product/media/bootanimation.zip. Magisk n'en monte qu'un seul et ce
#   n'est pas forcement le notre (constate : nethunter gagne que notre id soit
#   trie avant ou apres le sien). Donc on force notre fichier par bind mount :
#   le helper lance juste apres herite forcement de ce namespace.
MOD=/data/adb/modules/bootanim-mist3r
ANIM_SRC=$MOD/system/product/media/bootanimation.zip
ANIM_DST=/product/media/bootanimation.zip
D=/data/local/bootanim8
LOG=/data/adb/bootanim-audio.log
mkdir -p $D; chmod 0777 $D
rm -f $D/helper-done $D/helper-pid "$LOG"

# --- notre animation, par bind mount (independant de l'overlay Magisk) --------
if [ -f "$ANIM_SRC" ]; then
  if mount -o bind "$ANIM_SRC" "$ANIM_DST" 2>/dev/null; then
    log -t bootanim8 "BIND ok : $(stat -c %s $ANIM_DST) octets sur $ANIM_DST"
  else
    log -t bootanim8 "BIND ECHEC : impossible de monter $ANIM_SRC sur $ANIM_DST"
  fi
else
  log -t bootanim8 "BIND : source absente ($ANIM_SRC)"
fi

resetprop persist.sys.bootanim.play_sound 1 2>/dev/null || setprop persist.sys.bootanim.play_sound 1 2>/dev/null
setprop log.tag.BootAnimation VERBOSE 2>/dev/null
setprop log.tag.audioplay VERBOSE 2>/dev/null

(
  logcat -b all -v time -f "$LOG" \
    -s BootAnimation:V audioplay:V libOpenSLES:V AudioTrack:V AudioFlinger:V bootanim8:V SELinux:V auditd:V 2>/dev/null &
  LC=$!
  sleep 60
  kill $LC 2>/dev/null
) >/dev/null 2>&1 &

(
  echo $$ > $D/helper-pid
  # attendre SurfaceFlinger (le display bootanim doit exister) puis demarrer vite
  i=0
  while [ $i -lt 400 ]; do
    case "$(service check SurfaceFlinger 2>/dev/null)" in *found*) break;; esac
    sleep 0.05; i=$((i+1))
  done
  # re-verifier que c'est bien NOTRE animation (taille attendue) avant de jouer
  WANT=$(stat -c %s "$ANIM_SRC" 2>/dev/null)
  GOT=$(stat -c %s "$ANIM_DST" 2>/dev/null)
  if [ -n "$WANT" ] && [ "$WANT" != "$GOT" ]; then
    mount -o bind "$ANIM_SRC" "$ANIM_DST" 2>/dev/null
    log -t bootanim8 "HELPER: bind retente (voulu=$WANT vu=$GOT -> $(stat -c %s $ANIM_DST))"
  fi
  sleep 0.4
  log -t bootanim8 "HELPER uid=$(id -u) sf_boucle=$i anim=$(stat -c %s $ANIM_DST) -> bootanimation.real (patché)"
  export ANDROID_ROOT=/system ANDROID_DATA=/data ANDROID_STORAGE=/storage
  /system/bin/bootanimation.real
  log -t bootanim8 "HELPER: animation terminee rc=$?"
  echo "$(date +%H:%M:%S)" > $D/helper-done
) >/dev/null 2>&1 &
