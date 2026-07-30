# HOWTO — build, cross-compile, re-patch, and switch a CJK Raspberry Pi kernel

> 中文版本见 [HOWTO-ZH_CN.md](HOWTO-ZH_CN.md).

This is the practical companion to `cjk-kernel.sh` and `README.md`.
It answers four things:

1. [Compile on the Raspberry Pi (native)](#1-compile-on-the-raspberry-pi-native)
2. [Cross-compile (on a fast x86_64 / another machine)](#2-cross-compile)
3. [Patch a **new** kernel version (handling rejects)](#3-patch-a-new-kernel-version)
4. [Switch between kernels (and roll back)](#4-switch-between-kernels)

Reference hardware for the examples: **Compute Module 4S**, kernel
`6.18.34+rpt-rpi-v8`, Debian 13 (trixie), aarch64. `+rpt` = the Raspberry Pi
Debian-packaged kernel, so the matching source is the `linux-source-<MAJ.MIN>`
apt package (not kernel.org).

> **Which "v8"?** `-rpi-v8` is the 64-bit config used by Pi 3 / 4 / Zero 2 / CM3 /
> CM4 / CM4S → boot image `kernel8.img`, defconfig family `bcm2711_defconfig`.
> Pi 5 / CM5 are `-rpi-2712` → `kernel_2712.img`, `bcm2712_defconfig`. Pick the
> one that matches *your* `uname -r`.

---

## 1. Compile on the Raspberry Pi (native)

Easiest and most reliable — no toolchain juggling, the source/config come from
the running system, and a CM4S (4 cores, ~8 GB RAM, ≥15 GB free) finishes in
roughly **1.5–2.5 hours**.

```bash
# copy the tool + patch tree onto the Pi, then:
cd ~/cjk-tool
./cjk-kernel.sh deps       # bc bison flex libssl-dev libncurses-dev, etc.
./cjk-kernel.sh source     # downloads linux-source-6.18 (exact +rpt source), unpacks
./cjk-kernel.sh config      # seeds .config from running kernel; LOCALVERSION -> -v8-cjk
./cjk-kernel.sh patch       # nearest cjktty patch + bundled 6.18 fixups
./cjk-kernel.sh build       # make -j4 Image modules dtbs
./cjk-kernel.sh install     # modules_install + /boot/firmware/kernel8-cjk.img (safe)
```

Or all at once: `./cjk-kernel.sh all`.

Manual equivalent (what the script does), in case you want to run it by hand:

```bash
sudo apt install -y bc bison flex libssl-dev libncurses-dev make gcc \
                    device-tree-compiler dpkg-dev
sudo apt install -y linux-source-6.18          # exact +rpt source
mkdir -p ~/cjk-kernel-build && cd ~/cjk-kernel-build
tar xf /usr/src/linux-source-6.18.tar.xz && mv linux-source-6.18 linux && cd linux

cp /usr/src/linux-headers-$(uname -r)/.config .config      # running kernel's config
./scripts/config --set-str CONFIG_LOCALVERSION "-v8-cjk"   # unique name (safe fallback)
./scripts/config -d CONFIG_LOCALVERSION_AUTO

patch -p1 --fuzz=3 < $REPO/cjktty-patches/v6.x/cjktty-6.19.patch                 # nearest patch to 6.18.34
patch -p1 --fuzz=3 < $REPO/fixups/6.18/rejects.fixup.patch   # 2 drifted hunks

./scripts/config -e CONFIG_FONTS \
                 -e CONFIG_FONT_CJK_16x16 -e CONFIG_FONT_CJK_32x32
make ARCH=arm64 olddefconfig

make ARCH=arm64 -j$(nproc) Image modules dtbs

sudo make ARCH=arm64 modules_install
sudo cp arch/arm64/boot/Image /boot/firmware/kernel8-cjk.img
sudo cp arch/arm64/boot/dts/broadcom/*.dtb        /boot/firmware/
sudo cp arch/arm64/boot/dts/overlays/*.dtb*       /boot/firmware/overlays/
```

Then enable it → see [section 4](#4-switch-between-kernels).

**Keep the build alive if your SSH drops.** Long builds outlive flaky links if
you start them detached:

```bash
nohup ./cjk-kernel.sh build > ~/cjk-kernel-build/build.log 2>&1 &
tail -f ~/cjk-kernel-build/build.log      # watch; Ctrl-C just stops watching
# or use tmux/screen:  tmux new -s k  →  ./cjk-kernel.sh build  →  detach Ctrl-b d
```

---

## 2. Cross-compile

Building on a fast x86_64 box (or an M-series Mac via a Linux container) turns
hours into minutes. You need an **aarch64 cross toolchain** and then you copy
the artifacts to the Pi. The kernel *source and .config* still come from the Pi
(so the build matches your running system).

### 2a. On a Linux x86_64 host (Debian/Ubuntu)

```bash
sudo apt install -y crossbuild-essential-arm64 bc bison flex libssl-dev \
                    libncurses-dev make git device-tree-compiler

export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-

# Get the SAME source + config as the Pi:
#   Option A (recommended): copy them off the Pi
scp pi@PI:/usr/src/linux-source-6.18.tar.xz .     # if not there: `sudo apt install linux-source-6.18` on the Pi first
scp pi@PI:/usr/src/linux-headers-$(ssh pi@PI uname -r)/.config  ./running.config
tar xf linux-source-6.18.tar.xz && cd linux-source-6.18
cp ../running.config .config
#   Option B: clone raspberrypi/linux, branch rpi-6.18.y, and `make bcm2711_defconfig`

# Patch + configure exactly as native:
./scripts/config --set-str CONFIG_LOCALVERSION "-v8-cjk"
./scripts/config -d CONFIG_LOCALVERSION_AUTO
patch -p1 --fuzz=3 < $REPO/cjktty-patches/v6.x/cjktty-6.19.patch
patch -p1 --fuzz=3 < $REPO/fixups/6.18/rejects.fixup.patch
./scripts/config -e CONFIG_FONTS -e CONFIG_FONT_CJK_16x16 -e CONFIG_FONT_CJK_32x32
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig

# Build (all cores of the fast box):
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc) Image modules dtbs
```

Package the modules and ship everything to the Pi:

```bash
# stage modules into a tarball with the right layout
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
     INSTALL_MOD_PATH=./stage modules_install
KREL=$(make -s ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- kernelrelease)   # e.g. 6.18.34-v8-cjk
tar -C ./stage -czf modules-$KREL.tgz lib/modules/$KREL

# copy to the Pi
scp arch/arm64/boot/Image                    pi@PI:/tmp/kernel8-cjk.img
scp modules-$KREL.tgz                        pi@PI:/tmp/
scp arch/arm64/boot/dts/broadcom/*.dtb       pi@PI:/tmp/dtb/
scp arch/arm64/boot/dts/overlays/*.dtb*      pi@PI:/tmp/overlays/
```

On the Pi, install (non-destructive):

```bash
sudo tar -C / -xzf /tmp/modules-*.tgz                 # -> /lib/modules/<rel>
sudo depmod <rel>
sudo cp /tmp/kernel8-cjk.img /boot/firmware/kernel8-cjk.img
sudo cp /tmp/dtb/*.dtb       /boot/firmware/
sudo cp /tmp/overlays/*      /boot/firmware/overlays/
```

Then enable in `config.txt` → [section 4](#4-switch-between-kernels).

### 2c. Package a redistributable release (recommended for cross-builds)

Instead of hand-copying files, turn the build into a single self-contained
tarball with `mkrelease.sh`. Run it on the machine that compiled the kernel:

```bash
# native (on the Pi):
./mkrelease.sh
# cross-compiled (on an x86_64 box):
CROSS_COMPILE=aarch64-linux-gnu- ./mkrelease.sh [SRCDIR] [OUTDIR]
#   SRCDIR default ~/cjk-kernel-build/linux ; OUTDIR default <repo>/dist
# Pi 5 / CM5 (2712): also set the boot image name
IMAGE_NAME=kernel_2712-cjk.img CROSS_COMPILE=aarch64-linux-gnu- ./mkrelease.sh
```

It produces `dist/cjk-kernel-<release>-<arch>.tar.gz` (+ `.sha256`) containing
the kernel image, dtbs, overlays, the versioned modules tree, a `MANIFEST.txt`,
and a bundled `install.sh`. The tarball needs **nothing** from this repo or the
toolchain. On the target Pi:

```bash
tar xzf cjk-kernel-<release>-arm64.tar.gz
cd cjk-kernel-<release>-arm64
sudo ./install.sh            # non-destructive install (stock kernel untouched)
sudo ./install.sh --enable   # also add kernel=…-cjk.img to config.txt
sudo ./install.sh --uninstall# remove this CJK kernel + its modules
sudo reboot
```

### 2b. On an Apple-silicon / Intel Mac

macOS has no native aarch64-linux cross toolchain, so run the Linux steps above
inside a container. On Apple silicon this is *native* speed (arm64 host running
an arm64 target — no emulation):

```bash
# from the repo root that contains cjk-kernel.sh + cjktty-patches submodule
docker run --rm -it -v "$PWD":/work -w /work debian:trixie bash
# inside the container, run the section-2a apt+build commands
# (ARCH=arm64 host means CROSS_COMPILE can even be empty and you just use gcc)
```

If you don't want containers, the standard "official" cross toolchain is
Raspberry Pi's `tools` repo:

```bash
git clone --depth=1 https://github.com/raspberrypi/tools
export PATH=$PWD/tools/arm-bcm2708/gcc-linaro-*aarch64*/bin:$PATH
```

> **Rule of thumb:** cross-compiling saves the most time on a slow Pi (Zero 2,
> Pi 3). On a CM4S/Pi 4/Pi 5 the native build is already tolerable and avoids
> all toolchain/ABI mismatch risk — prefer native unless you rebuild often.

---

## 3. Patch a new kernel version

`cjk-kernel.sh` is version-aware: it reads `uname -r`, fetches matching source,
picks the **nearest** cjktty patch, and applies bundled fixups. Most of the time
a new version "just works":

```bash
./cjk-kernel.sh all
```

When it doesn't, it's because upstream/RPi changed a few lines the patch didn't
expect. Handle it in three moves.

### Step 1 — dry-run gate (cheap, do this first)

```bash
./cjk-kernel.sh source
./cjk-kernel.sh config
./cjk-kernel.sh patch --dry-run     # reports what would reject; changes NOTHING
```

- **"patch applies cleanly"** → go straight to `build`.
- Some **`Hunk … FAILED`** lines → note which *files* they're in (the log at
  `~/cjk-kernel-build/patch-dryrun.log` lists them) and continue.

The script already chooses the closest patch. You can force another base to
compare:

```bash
# e.g. try the next-higher patch instead of the auto pick
cd ~/cjk-kernel-build/linux
patch -p1 --fuzz=3 --dry-run < cjktty-patches/v6.x/cjktty-6.19.patch 2>&1 \
  | grep -E 'checking file|FAILED|hunks FAILED'
```

Pick whichever base rejects the fewest hunks. (For 6.18.34, the **6.19** patch
rejected only 2 hunks vs many for 6.17.8 — nearest-higher won.)

### Step 2 — apply and read the rejects

```bash
./cjk-kernel.sh patch          # applies main patch; if a fixup for your MAJ.MIN
                               # exists it's auto-applied; else it stops here
cd ~/cjk-kernel-build/linux
find . -name '*.rej'           # each is one failed hunk
cat drivers/video/fbdev/core/fbcon_rotate.c.rej   # example
```

A `.rej` is small and mechanical. Typical causes and fixes:

| what the reject shows | why it drifted | fix |
|---|---|---|
| a `-`/`+` on `kfree(...)`→`kvfree(...)` that "FAILED" | upstream moved the alloc/free block | make the same one-word change at the real call site |
| an `extern` list ending `font_6x8;` but patch expected `font_ter_10x18;` | that font doesn't exist in your tree | append the `+font_cjk_16x16, font_cjk_32x32;` onto whatever the real terminator is |
| a context line renamed (e.g. `FONT6x10_IDX` vs `TER16x32_IDX`) | macro/name churn | locate the equivalent line, apply the `+` additions there |

Open the target file, find the spot the reject's context points to, and hand-apply
the `+`/`-` lines. Then delete the `.rej`.

### Step 3 — capture it as a reusable fixup

So the next person on that version doesn't repeat the work, save your edits as a
`fixups/<MAJ.MIN>/rejects.fixup.patch`. Recipe used for `fixups/6.18`:

```bash
cd ~/cjk-kernel-build/linux
# 1) make a copy of the file in its "still-rejected" state (undo just your manual edit),
#    OR keep a pristine copy from the source tarball before patching.
# 2) diff pristine-rejected -> your-fixed, rewrite paths to a/ and b/:
diff -u OLD/include/linux/font.h include/linux/font.h \
  | sed -e 's|^--- OLD/|--- a/|' -e 's|^+++ .*|+++ b/include/linux/font.h|' \
  >> fixups/6.18/rejects.fixup.patch
```

Now `./cjk-kernel.sh patch` on any 6.18.x applies main-patch + your fixup and
verifies a fully clean tree before letting you build.

### Step 4 — smoke-compile before the long build

Confirm the patched C actually compiles without waiting 2 hours:

```bash
make ARCH=arm64 -j$(nproc) \
  lib/fonts/font_cjk_16x16.o lib/fonts/font_cjk_32x32.o lib/fonts/fonts.o \
  drivers/video/fbdev/core/{fbcon,bitblit,fbcon_rotate,fbcon_ccw,fbcon_cw,fbcon_ud}.o \
  drivers/tty/vt/{vt,selection}.o
```

Clean output → `./cjk-kernel.sh build`.

### If no patch is remotely close

The cjktty patch set only goes up to certain versions. If your kernel is far
newer than any available patch and rejects are large (whole functions moved),
either wait for an updated cjktty patch upstream
(`Gentoo-zh/linux-cjktty` / `zhmars/cjktty-patches`), or pin to a kernel version
a patch exists for. Framebuffer-console internals change rarely, so nearest patch
+ a few fixups is usually enough.

---

## 4. Switch between kernels

Because the CJK kernel installs as a **separate** `kernel8-cjk.img` (stock
`kernel8.img` untouched), switching is just one line in
`/boot/firmware/config.txt` plus a reboot.

### Boot the CJK kernel

```ini
# /boot/firmware/config.txt
[all]
kernel=kernel8-cjk.img
```

```bash
sudo reboot
uname -r        # -> 6.18.34-v8-cjk  (proof you're on the patched kernel)
```

### Go back to the stock kernel

```bash
./cjk-kernel.sh rollback     # removes the kernel= line (backup: config.txt.cjkbak)
# or edit config.txt yourself and delete the line
sudo reboot
```

### Per-model switching (mixed CM4/CM5 fleet)

`config.txt` supports conditional filters, so one card can serve both:

```ini
[cm4]
kernel=kernel8-cjk.img       # CM4/CM4S -> v8 CJK kernel
[pi5]
kernel=kernel_2712-cjk.img   # if you also built a 2712 CJK kernel
[all]
```

### Recover a bad build (won't boot)

The stock kernel is still on the card. Two ways back:

1. **Pull the card** into any computer, open the `bootfs`/`firmware` partition
   (FAT, mountable anywhere), and delete the `kernel=kernel8-cjk.img` line from
   `config.txt`. Reboot → stock kernel.
2. If you have serial/HDMI+keyboard, interrupt and fix `config.txt` the same way.

Because you never overwrote `kernel8.img` and the modules live under a distinct
`-v8-cjk` directory, a failed CJK kernel can't break the stock one.

### Note on apt kernel upgrades

`sudo apt upgrade` updates the stock `kernel8.img` and its modules as usual and
does **not** touch your `kernel8-cjk.img`. But after a version bump, your CJK
kernel is now *older* than the stock one and its modules won't match the new
`uname -r` if you switch back and forth carelessly — each kernel only uses its
own `/lib/modules/<its-release>`, so they don't collide. To get CJK on the new
version, just re-run `./cjk-kernel.sh all` (it re-detects the new `uname -r`).
```
