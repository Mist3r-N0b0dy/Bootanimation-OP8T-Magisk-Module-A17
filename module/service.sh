#!/system/bin/sh
sleep 12
SUM=/data/adb/bootanim-resume.txt
LOG=/data/adb/bootanim-audio.log
{
  echo "########## BOOTANIM MIST3R v1.0.0 (aide root) ##########"
  echo "date=$(date)  bootanim=$(getprop ro.boottime.bootanim)  audioserver=$(getprop ro.boottime.audioserver)"
  echo "marqueurs: $(ls -l /data/local/bootanim8 2>/dev/null | tr '\n' ' ')"
  echo
  echo "=== compteurs ==="
  for pat in "WRAP" "HELPER" "is loaded successfully" "found audio.wav" \
             "Audio service is not ready" "Created buffer queue player" \
             "playing clip for part" "CreateAudioPlayer failed" "slCreateEngine failed" \
             "sl player Realize failed" "cannot play clip" "NPC::" "bootanim:s0"; do
    printf "%-32s %s\n" "$pat" "$(grep -ac "$pat" $LOG 2>/dev/null)"
  done
  echo
  echo "=== extrait ==="
  grep -aE "WRAP|HELPER|found audio.wav|Audio service|playing clip|Created buffer|CreateAudioPlayer|slCreateEngine|Realize failed|cannot play|NPC::|bootanim:s0" $LOG 2>/dev/null | head -25
} > "$SUM" 2>&1
chmod 0644 "$SUM" 2>/dev/null
sync
