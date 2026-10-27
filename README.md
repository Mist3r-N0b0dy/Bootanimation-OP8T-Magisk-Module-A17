# Bootanimation OP8T — Magisk module (Android 17)

Boot animation **with sound** for the OnePlus 8T (kebab) on Android 17, packaged as
a Magisk module. Rooted Android 17 only; Kali NetHunter is *not* required — the
NetHunter animation is simply the first variant released.

This crDroid build ships no `bootanimation.zip` at all (`/system/media` and
`/oem/media` do not even exist), so the module provides the only animation the boot
has: `/product/media/bootanimation.zip`.

## How it works

Three things must be true on this ROM, and each one is a separate layer.

**1. The file is bind-mounted, not only overlayed.** The official Kali NetHunter
module also ships `system/product/media/bootanimation.zip`, and Magisk mounts only
one of the two — with no predictable winner (measured: ours loses whether its id
sorts before or after `nethunter`'s). `post-fs-data.sh` therefore bind-mounts our
file over the contested path before anything reads it:

```sh
mount -o bind /data/adb/modules/bootanim-mist3r/system/product/media/bootanimation.zip \
               /product/media/bootanimation.zip
```

**2. The player is patched.** `/system/bin/bootanimation` is a thin shell around
`libbootanimation_preapex.so`; `system/bin/bootanimation.real` is the same binary
with two locks removed (the "Audio service is not ready" wait and the
`sys.boot_completed` wait) plus an anti-crash guard on a null player.
`tools/patch.py` rebuilds it from `tools/bootanimation.stock.bin` and refuses to run
if the base or the result hash differs — a ROM update then shows up as a build
error instead of a black screen.

**3. The sound needs root.** `bootanim` runs as uid 1003, and AudioFlinger refuses a
track from an uid that owns no package before `system_server` has filled the
attribution controller (`NPC::getPackagesForUid: uid not found: 1003`,
`createTrack status -22`). `post-fs-data.sh` starts a root helper (uid 0 is a
trusted client) that plays animation *and* sound; the shipped
`/system/bin/bootanimation` is a wrapper that keeps the `bootanim` service alive for
SurfaceFlinger and waits for that helper.

## Install

Magisk app → Modules → Install from storage, or in recovery:

```sh
adb sideload NetHunter-BootAnimation-OP8T-crDroid13-A17-MagiskModule.zip
```

Reboot. Removing the module restores the stock boot; nothing on disk is modified.

## Check it worked

```sh
unzip -p /product/media/bootanimation.zip desc.txt | head -1  # 1080 2400 24
grep -a BIND /data/adb/bootanim-audio.log                    # BIND ok : <taille> octets
cat /data/adb/bootanim-resume.txt                            # counters, written 12 s after boot
```

The report counts two `WRAP` lines (the uid-1003 wrapper), one `HELPER` line (the
root helper), `found audio.wav` and `playing clip for part0`. A missing line points
at the layer above.

## Build

Needs `ffmpeg`, ImageMagick (`convert`), `zip`, `python3`.

```sh
./build.sh                     # animation/bootanimation_a.mp4 + audio.wav
./build.sh -V myvideo.mp4      # another video, same constraints
./build.sh -a myanimation.zip  # an animation you built yourself
# on /sdcard (mounted noexec), call it as: bash build.sh
```

Output: `dist/NetHunter-BootAnimation-OP8T-crDroid13-A17-MagiskModule.zip`.

The build fails, rather than shipping something the ROM would ignore, when:

- an entry of the animation is compressed — the ROM requires *stored*, and says so
  verbatim: `bootanimation.zip is compressed; must be only stored`;
- `desc.txt` is not at the panel resolution (`1080x2400`, from
  `card0-DSI-1/modes`) or not at this variant's fps — frames are never rescaled;
- `audio.wav` is not inside a part directory (at the zip root `preloadZip()`
  compares its parent directory to the part name and ignores it);
- a declared part is missing or empty, the module is incomplete, or the patched
  player no longer matches `tools/patch.py`'s output.

## A custom video

- **1080x2400.** `-m crop` fills the panel, `-m pad` adds black bars, `-m stretch`
  distorts.
- **24 fps** by default (`FPS` in the variant file). The released animation is 237
  frames ≈ 10 s of intro, then the last frame is held.
- **Full first play, then hold:** `c 1 0 part0` + `p 0 0 part1`, which is what
  `make-bootanimation.sh -C` generates.
- **Sound:** a WAV, normalised by `-a` into `part0/audio.wav`.
- **Size:** JPEG quality 4 (`QUALITY`), ~34 MB for 10 s. At quality 2 the same
  video gives 50 MB, and the player reads this file at boot, so weight matters.

## Variants

The NetHunter animation is one release among possible ones. A variant is a file in
`variants/`:

```sh
cp variants/nethunter.conf variants/crdroid.conf  # edit id, name, version, output name
./build.sh -v crdroid
```

`PANEL_W`, `PANEL_H` and `FPS` stay as they are for this phone. `MODULE_ID` must be
unique per variant — it is also the directory name under `/data/adb/modules`. The
ASCII banner in `module/customize.sh` is NetHunter branding; edit it for another
variant.

## Known limitations

- `bootanim` is denied `getattr` on `/data/local/bootanim8/helper-pid`
  (`permissive=1` saves it). It works only because `sepolicy.rule` sets
  `permissive bootanim`: do not drop that line without a file context for that
  directory.
- The patched player is tied to one ROM build. `patch.py` stops if the stock binary
  changed; `tools/bootanimation.stock.bin` then has to be replaced.
- Never neutralise `service.bootanim.exit` to keep the animation playing: that
  freezes the phone once boot completes.

## License

MIT for everything here, except the AOSP boot animation player
(`tools/bootanimation.stock.bin` and the patched
`module/system/bin/bootanimation.real`), which stays Apache-2.0. The exact
modifications applied to it are listed in `NOTICE`, and they are reproducible
with `tools/patch.py`.
