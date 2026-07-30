# cjk-kernel — build a Raspberry Pi kernel with CJK console support

`cjk-kernel.sh` patches, builds, and installs a Raspberry Pi kernel with the
**cjktty** patch, so the *framebuffer console* (the plain HDMI/serial text
console, no X/Wayland) can display 中文 / 日本語 / 한국어 glyphs instead of
`▯▯▯` tofu. It's built to be **reusable across kernel versions** and safe:
your stock kernel keeps booting as a fallback.

Background on how cjktty works is in `docs/cjktty-principles.zh.txt` (by the patch author, 蔡万钊).
The patch tree is the `cjktty-patches/` submodule (from bigshans/cjktty-patches, itself from Gentoo-zh / zhmars).

## Get it

The upstream patch set is a git **submodule**, so clone recursively:

```bash
git clone --recurse-submodules https://github.com/<you>/cjk-kernel.git
# already cloned without submodules?
git submodule update --init --recursive
```

Then copy the whole directory onto your Pi (or run in place) and use
`./cjk-kernel.sh`. See [HOWTO.md](HOWTO.md) (中文: [HOWTO-ZH_CN.md](HOWTO-ZH_CN.md)) for native build, cross-compile,
re-patching a new kernel version, and switching kernels.

---

## TL;DR (what was done on this CM4S)

Target: `6.18.34+rpt-rpi-v8`, Compute Module 4S, Debian 13 (trixie), aarch64.

```bash
# on the Pi, from ~/cjk-tool
./cjk-kernel.sh deps      # build tools
./cjk-kernel.sh source    # exact +rpt source via `linux-source-6.18` apt pkg
./cjk-kernel.sh config    # seed .config from running kernel, LOCALVERSION=-v8-cjk
./cjk-kernel.sh patch     # apply nearest cjktty patch (6.19) + 6.18 fixups
./cjk-kernel.sh build     # make -j4 Image modules dtbs   (~1.5–2.5 h)
./cjk-kernel.sh install   # modules_install + /boot/firmware/kernel8-cjk.img
# then enable it (see below) and reboot
```

`./cjk-kernel.sh all` runs deps→…→install in one shot.

---

## How it stays safe (non-destructive install)

- New kernel image is `kernel8-cjk.img` — the stock `kernel8.img` is **never**
  overwritten.
- Modules install under a distinct release dir (`…-v8-cjk`) via
  `CONFIG_LOCALVERSION`, so they don't collide with the apt kernel's modules.
- You opt in by adding **one line** to `/boot/firmware/config.txt`:

  ```ini
  [all]
  kernel=kernel8-cjk.img
  ```

- To roll back: `./cjk-kernel.sh rollback` (removes that line) and reboot, or
  just delete the line yourself. apt kernel upgrades continue to work untouched.

> Tip: to A/B test without editing every boot, you can put the `kernel=` line
> under a filtered section, or keep a second `config.txt` — but the simple line
> above is enough for most people.

---

## After first boot with the CJK kernel

```bash
uname -r          # should end in -v8-cjk
./cjk-kernel.sh verify
```

The kernel now *contains* the CJK glyph data, but you still want a UTF-8 locale
and a matching console font so text renders at a sensible size:

```bash
sudo apt install -y locales console-setup
sudo dpkg-reconfigure locales          # enable e.g. en_US.UTF-8 and/or zh_CN.UTF-8
# Console is UTF-8 by default on Debian; verify:
localectl status 2>/dev/null || cat /etc/default/locale
```

The cjktty patch expects an **8x16** (→ CJK 16x16) or **16x32** (→ CJK 32x32)
font. On a hi-res HDMI panel the 16x16 glyphs are tiny; for the larger font the
kernel was built with `CONFIG_FONT_CJK_32x32=y`. Select font size with
`setfont`/`console-setup` (a 16x32 Latin font pairs with the 32x32 CJK data).

**Test on the physical console (not over ssh):**

```bash
printf '你好 世界  日本語  한국어  ①②③  ★\n'
```

You should see the characters, not boxes. Over SSH this always works (that's your
terminal emulator); the whole point of the patch is the *local* console.

---

## Adapting to a new / different kernel version

The script auto-detects everything from `uname -r`, so on another Pi you usually
just run `./cjk-kernel.sh all`. The two things that can need attention:

1. **Source.** `source` first tries `linux-source-<MAJ.MIN>` (the exact `+rpt`
   Raspberry Pi source that built your running kernel — best provenance). If that
   apt package doesn't exist for your version, it falls back to cloning
   `raspberrypi/linux` branch `rpi-<MAJ.MIN>.y`.

2. **Patch base + rejects.** the `cjktty-patches/` submodule ships one patch per
   upstream version. The script picks the **nearest** one to your kernel and
   applies it with `--fuzz`. Line-offset drift is absorbed automatically. When
   the RPi tree has diverged in a few hunks, `patch` leaves `.rej` files.

   - Bundled fixups live in `fixups/<MAJ.MIN>/rejects.fixup.patch`
     and are applied automatically. `fixups/6.18/` is included (2 hunks:
     `include/linux/font.h` extern list + `fbcon_rotate.c` `kfree→kvfree`).
   - If your version has *no* bundled fixup and rejects remain, the script stops
     and lists the `.rej` files. To create a fixup:

     ```bash
     ./cjk-kernel.sh patch          # applies main patch, stops on rejects
     cd ~/cjk-kernel-build/linux
     find . -name '*.rej'           # inspect each; edit the target file by hand
     # then regenerate the fixup by diffing pristine vs fixed (see git history of
     # fixups/6.18 for the exact recipe), drop it in fixups/<MAJ.MIN>/, re-run.
     ```

     Rejects are almost always tiny: a renamed symbol, a moved `kfree`, a context
     line that upstream changed. Read the `.rej`, find the equivalent spot in the
     real file, make the same change.

### Dry-run gate (recommended before the long build)

```bash
./cjk-kernel.sh patch --dry-run
```

Reports whether the chosen patch applies (and what would reject) **without**
touching the tree — cheap insurance before a multi-hour compile. A fast extra
check after patching: compile just the touched objects, e.g.
`make ARCH=arm64 -j$(nproc) lib/fonts/fonts.o drivers/video/fbdev/core/fbcon.o …`.

---

## Subcommands

| command | what it does |
|---|---|
| `deps` | apt-install `bc bison flex libssl-dev libncurses-dev …` |
| `source` | fetch exact matching kernel source (apt `linux-source-*`, else git) |
| `config` | seed `.config` from the running kernel, set `-cjk` LOCALVERSION, enable CJK fonts, `olddefconfig` |
| `patch [--dry-run]` | pick nearest cjktty patch, test/apply, auto-apply version fixups |
| `build` | `make -j$JOBS Image modules dtbs` (arm64) |
| `install` | `modules_install` + copy `kernel8-cjk.img`, dtbs, overlays (non-destructive) |
| `verify` | post-reboot checks + console test string |
| `rollback` | remove the `kernel=kernel8-cjk.img` line from config.txt |

### Distributable releases

`mkrelease.sh` (run on the build machine) packages a finished build into a
self-contained `dist/cjk-kernel-<release>-<arch>.tar.gz` that installs on any Pi
with the bundled `install.sh` — no repo or toolchain needed. Ideal after a
cross-compile. See [HOWTO.md § 2c](HOWTO.md#2c-package-a-redistributable-release-recommended-for-cross-builds).

### Env overrides

| var | default | meaning |
|---|---|---|
| `PATCH_DIR` | `<script dir>/cjktty-patches` | patch tree (the submodule) |
| `FIXUP_DIR` | `<script dir>/fixups` | per-version reject fixups |
| `WORKDIR` | `~/cjk-kernel-build` | build directory |
| `LOCALVERSION_SUFFIX` | `-cjk` | appended to kernel name |
| `WANT_32x32` | `0` | also apply the separate 32x32 font-data patch |
| `FUZZ` | `3` | `patch --fuzz` factor |
| `JOBS` | `$(nproc)` | parallel build jobs |

---

## Notes / gotchas

- **Build natively on the Pi.** A CM4S (4 cores, ~8 GB) builds in ~1.5–2.5 h.
  Cross-compiling is possible but not what this script does.
- The patch targets **8x16 / 16x32** fonts specifically; other console font
  sizes can render CJK incorrectly (upstream caveat).
- `CONFIG_FONTS` must be `=y` (it is off in the stock RPi config); the script
  enables it. The CJK Kconfig symbols only exist *after* the patch is applied,
  which is why `config` is re-run (or run after `patch`) to select them.
- Symbol name history: `FONT_16x16_CJK` was renamed to `FONT_CJK_16x16` in Linux
  5.10. The script tries both.
- `+rpt` kernels are Raspberry Pi's Debian-packaged builds; the matching source
  is the `linux-source-<MAJ.MIN>` apt package, **not** stock kernel.org.
