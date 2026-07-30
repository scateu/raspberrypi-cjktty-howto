#!/usr/bin/env bash
#
# cjk-kernel.sh — patch & build a Raspberry Pi kernel with the cjktty patch
#                 (framebuffer console CJK / 中文 / 日本語 / 한국어 display).
#
# Designed to be reusable across Raspberry Pi kernel versions. Run it ON the Pi
# (natively). It uses the EXACT source + config of your running apt-packaged
# kernel, adds the CJK font options, applies the nearest cjktty patch, builds,
# and installs the result as a SEPARATE, fallback-safe kernel image
# (kernel8-cjk.img) so your stock kernel keeps booting if anything goes wrong.
#
# Usage:
#   ./cjk-kernel.sh all         # deps -> source -> config -> patch -> build -> install
#   ./cjk-kernel.sh deps        # install build dependencies
#   ./cjk-kernel.sh source      # fetch matching kernel source
#   ./cjk-kernel.sh config      # seed .config from running kernel + enable CJK
#   ./cjk-kernel.sh patch       # test-apply (dry run) then apply cjktty patch
#   ./cjk-kernel.sh patch --dry-run   # only test-apply, report .rej, change nothing
#   ./cjk-kernel.sh build       # compile Image + modules + dtbs
#   ./cjk-kernel.sh install     # install modules + kernel8-cjk.img (non-destructive)
#   ./cjk-kernel.sh verify      # post-reboot sanity checks
#   ./cjk-kernel.sh rollback    # remove the config.txt kernel= line (back to stock)
#
# Environment overrides (all optional):
#   PATCH_DIR   cjktty patch tree (default: script dir /cjktty-patches submodule)
#   FIXUP_DIR   Per-version reject fixups (default: script dir /fixups)
#   WORKDIR     Build directory                         (default: ~/cjk-kernel-build)
#   LOCALVERSION_SUFFIX  Appended to kernel name         (default: -cjk)
#   WANT_32x32  "1" to also apply the 32x32 hi-res font  (default: 0)
#   FUZZ        patch fuzz factor                        (default: 3)
#   JOBS        parallel build jobs                      (default: nproc)
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Setup / detection
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Upstream patch tree lives in the cjktty-patches submodule; older checkouts may
# still have it vendored as bigshans-cjktty-patches. Prefer the submodule.
if [ -d "$SCRIPT_DIR/cjktty-patches" ]; then
  PATCH_DIR="${PATCH_DIR:-$SCRIPT_DIR/cjktty-patches}"
else
  PATCH_DIR="${PATCH_DIR:-$SCRIPT_DIR/bigshans-cjktty-patches}"
fi
FIXUP_DIR="${FIXUP_DIR:-$SCRIPT_DIR/fixups}"
WORKDIR="${WORKDIR:-$HOME/cjk-kernel-build}"
LOCALVERSION_SUFFIX="${LOCALVERSION_SUFFIX:--cjk}"
WANT_32x32="${WANT_32x32:-0}"
FUZZ="${FUZZ:-3}"
JOBS="${JOBS:-$(nproc)}"

KREL="$(uname -r)"                                   # e.g. 6.18.34+rpt-rpi-v8
KVER="$(uname -r | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+')" # 6.18.34
KMAJMIN="$(echo "$KVER" | cut -d. -f1-2)"            # 6.18
BOOTDIR="/boot/firmware"; [ -d "$BOOTDIR" ] || BOOTDIR="/boot"
HDRCONFIG="/usr/src/linux-headers-${KREL}/.config"
SRCDIR="$WORKDIR/linux"                              # kernel source tree
STATE="$WORKDIR/.state"

c()  { printf '\033[1;36m==> %s\033[0m\n' "$*"; }        # step
ok() { printf '\033[1;32m  ok: %s\033[0m\n' "$*"; }
warn(){ printf '\033[1;33m  warn: %s\033[0m\n' "$*"; }
die(){ printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO="sudo"

mkdir -p "$WORKDIR"

# ---------------------------------------------------------------------------
# deps
# ---------------------------------------------------------------------------
cmd_deps() {
  c "Installing build dependencies"
  $SUDO apt-get update
  $SUDO apt-get install -y \
    bc bison flex libssl-dev libncurses-dev make gcc \
    device-tree-compiler dpkg-dev xz-utils kmod cpio \
    raspberrypi-kernel-headers 2>/dev/null || \
  $SUDO apt-get install -y \
    bc bison flex libssl-dev libncurses-dev make gcc \
    device-tree-compiler dpkg-dev xz-utils kmod cpio
  ok "dependencies installed"
}

# ---------------------------------------------------------------------------
# source — get source matching the RUNNING kernel, exactly.
#   Preferred: linux-source-<MAJ.MIN> apt package (the +rpt source that built
#   this kernel). Fallback: clone raspberrypi/linux rpi-<MAJ.MIN>.y.
# ---------------------------------------------------------------------------
cmd_source() {
  c "Fetching kernel source for $KREL (base $KVER)"
  if [ -f "$SRCDIR/Makefile" ]; then
    ok "source already present at $SRCDIR"; return
  fi

  local pkg="linux-source-${KMAJMIN}"
  local deb_ok=0
  if apt-cache show "$pkg" >/dev/null 2>&1; then
    c "Trying apt package $pkg (exact +rpt source)"
    local dl="$WORKDIR/src-deb"; mkdir -p "$dl"
    if ( cd "$dl" && $SUDO apt-get install -y "$pkg" ) ; then
      # package drops a tarball under /usr/src
      local tarball
      tarball="$(ls -1 /usr/src/${pkg}*.tar.xz /usr/src/linux-source-*.tar.xz 2>/dev/null | head -1 || true)"
      if [ -n "$tarball" ]; then
        c "Unpacking $tarball"
        mkdir -p "$WORKDIR/unpack"
        tar -C "$WORKDIR/unpack" -xf "$tarball"
        local top; top="$(ls -1d "$WORKDIR"/unpack/*/ | head -1)"
        rm -rf "$SRCDIR"; mv "$top" "$SRCDIR"
        deb_ok=1
      fi
    fi
  fi

  if [ "$deb_ok" -ne 1 ]; then
    warn "apt source unavailable; falling back to raspberrypi/linux git"
    local branch="rpi-${KMAJMIN}.y"
    c "Cloning raspberrypi/linux $branch (shallow)"
    git clone --depth=1 --branch "$branch" \
      https://github.com/raspberrypi/linux.git "$SRCDIR" \
      || die "git clone failed for branch $branch"
  fi
  [ -f "$SRCDIR/Makefile" ] || die "no kernel Makefile in $SRCDIR"
  ok "source ready at $SRCDIR"
}

# ---------------------------------------------------------------------------
# config — seed from running kernel's .config, enable CJK font options.
# ---------------------------------------------------------------------------
cmd_config() {
  c "Configuring kernel (.config)"
  [ -f "$SRCDIR/Makefile" ] || die "run 'source' first"
  cd "$SRCDIR"

  if [ -f "$HDRCONFIG" ]; then
    cp "$HDRCONFIG" .config
    ok "seeded .config from $HDRCONFIG"
  elif [ -f /proc/config.gz ]; then
    zcat /proc/config.gz > .config
    ok "seeded .config from /proc/config.gz"
  else
    warn "no running-kernel .config found; using bcm2711_defconfig"
    make ARCH=arm64 bcm2711_defconfig
  fi

  # Distinct kernel name so it never collides with the stock kernel/modules.
  local base_lv
  base_lv="$(sed -n 's/^CONFIG_LOCALVERSION="\(.*\)"/\1/p' .config)"
  local new_lv="${base_lv}${LOCALVERSION_SUFFIX}"
  ./scripts/config --set-str CONFIG_LOCALVERSION "$new_lv"
  ./scripts/config --disable CONFIG_LOCALVERSION_AUTO

  # Enable the built-in font system + CJK fonts.
  ./scripts/config --enable  CONFIG_FONT_SUPPORT
  ./scripts/config --enable  CONFIG_FONTS
  ./scripts/config --enable  CONFIG_FONT_8x16
  # Font symbol was renamed at 5.10: FONT_16x16_CJK -> FONT_CJK_16x16. Set both.
  ./scripts/config --enable  CONFIG_FONT_CJK_16x16 || true
  ./scripts/config --enable  CONFIG_FONT_16x16_CJK || true
  if [ "$WANT_32x32" = "1" ]; then
    ./scripts/config --enable CONFIG_FONT_CJK_32x32 || true
    ./scripts/config --enable CONFIG_FONT_32x32_CJK || true
    ./scripts/config --enable CONFIG_FONT_32x32     || true
  fi

  make ARCH=arm64 olddefconfig
  echo "$new_lv" > "$STATE.localversion"
  ok "config done (LOCALVERSION=$new_lv)"
  grep -E "CONFIG_FONT_CJK|CONFIG_FONT_16x16_CJK|CONFIG_FONTS=" .config || true
}

# ---------------------------------------------------------------------------
# patch — pick nearest cjktty patch for this kernel, dry-run, then apply.
# ---------------------------------------------------------------------------
# Choose the patch whose version is closest to $KVER (prefer nearest lower).
select_patch() {
  local want="$1" best="" bestscore=-1 f v
  local majmin; majmin="$(echo "$want" | cut -d. -f1-2)"
  local major;  major="$(echo "$want" | cut -d. -f1)"
  # candidate files across v*.x dirs
  while IFS= read -r f; do
    v="$(basename "$f" | sed -E 's/^cjktty-([0-9.]+)\.patch$/\1/')"
    [ "$v" = "$(basename "$f")" ] && continue
    # crude version-distance: prefer same maj.min, then nearest
    local vmajmin; vmajmin="$(echo "$v" | cut -d. -f1-2)"
    local score=0
    if [ "$vmajmin" = "$majmin" ]; then score=1000
    elif [ "$(echo "$v" | cut -d. -f1)" = "$major" ]; then
      # within same major: closeness by minor
      local dm; dm=$(( $(echo "$majmin" | cut -d. -f2) - $(echo "$vmajmin" | cut -d. -f2) ))
      # prefer nearest lower (dm>=0) slightly over higher
      if [ "$dm" -ge 0 ]; then score=$((500 - dm*10)); else score=$((490 + dm*10)); fi
    fi
    if [ "$score" -gt "$bestscore" ]; then bestscore=$score; best="$f"; fi
  done < <(find "$PATCH_DIR" -maxdepth 2 -name 'cjktty-*.patch' ! -name '*font-data*' | sort)
  echo "$best"
}

cmd_patch() {
  local dry=0; [ "${1:-}" = "--dry-run" ] && dry=1
  c "Selecting cjktty patch for kernel $KVER"
  [ -f "$SRCDIR/Makefile" ] || die "run 'source' first"
  if [ ! -d "$PATCH_DIR" ] || ! find "$PATCH_DIR" -name 'cjktty-*.patch' | grep -q .; then
    die "patch tree not found at $PATCH_DIR — did you init the submodule?
       run: git submodule update --init --recursive"
  fi
  local patch; patch="$(select_patch "$KVER")"
  [ -n "$patch" ] || die "no cjktty patch found under $PATCH_DIR"
  ok "chosen: $patch"

  cd "$SRCDIR"
  c "Dry-run test-apply (fuzz=$FUZZ)"
  if patch -p1 --fuzz="$FUZZ" --dry-run < "$patch" > "$WORKDIR/patch-dryrun.log" 2>&1; then
    ok "patch applies cleanly (see $WORKDIR/patch-dryrun.log)"
  else
    warn "dry-run reported problems:"
    grep -E 'FAILED|Hunk|saving rejects|offset' "$WORKDIR/patch-dryrun.log" | head -40 || true
    warn "full log: $WORKDIR/patch-dryrun.log"
    [ "$dry" -eq 1 ] && { warn "dry-run only; nothing changed"; return 1; }
    die "aborting apply because dry-run failed; fix context or choose another patch base"
  fi

  [ "$dry" -eq 1 ] && { ok "dry-run only; nothing changed"; return 0; }

  c "Applying patch"
  patch -p1 --fuzz="$FUZZ" --no-backup-if-mismatch < "$patch" || true

  # Known per-version fixups for the small set of hunks that reject because the
  # RPi tree drifted from the patch's base (e.g. 6.18.x vs the 6.19 patch).
  # Auto-apply the matching fixup, then require a fully clean tree.
  local fixup="$FIXUP_DIR/$KMAJMIN/rejects.fixup.patch"
  if find . -name '*.rej' | grep -q .; then
    if [ -f "$fixup" ]; then
      c "Applying bundled fixup for $KMAJMIN: $fixup"
      patch -p1 --fuzz="$FUZZ" --forward --no-backup-if-mismatch < "$fixup" || true
      find . -name '*.rej' -delete
    fi
  fi
  find . -name '*.orig' -delete 2>/dev/null || true

  # surface any rejects that survived the fixup
  if find . -name '*.rej' | grep -q .; then
    warn "reject files still present after fixup:"; find . -name '*.rej'
    die "patch left .rej files; resolve them (see README.md 'Adapting to a new version')"
  fi
  echo "$patch" > "$STATE.patch"
  ok "patch applied cleanly"

  if [ "$WANT_32x32" = "1" ]; then
    local fdp="$PATCH_DIR/cjktty-add-cjk32x32-font-data.patch"
    if [ -f "$fdp" ]; then
      c "Applying 32x32 font-data patch"
      patch -p1 --fuzz="$FUZZ" < "$fdp"
      find . -name '*.rej' | grep -q . && die "32x32 font-data patch left rejects"
      ok "32x32 font data applied"
    else
      warn "WANT_32x32=1 but $fdp not found; skipping"
    fi
  fi
}

# ---------------------------------------------------------------------------
# build
# ---------------------------------------------------------------------------
cmd_build() {
  c "Building kernel (Image + modules + dtbs) with $JOBS jobs"
  [ -f "$SRCDIR/.config" ] || die "run 'config' first"
  cd "$SRCDIR"
  make ARCH=arm64 -j"$JOBS" Image modules dtbs
  ok "build complete: $(make ARCH=arm64 -s kernelrelease)"
}

# ---------------------------------------------------------------------------
# install — non-destructive. New modules dir (versioned by LOCALVERSION),
#           kernel8-cjk.img, dtbs/overlays; original kernel8.img untouched.
# ---------------------------------------------------------------------------
cmd_install() {
  c "Installing (non-destructive)"
  [ -f "$SRCDIR/arch/arm64/boot/Image" ] || die "run 'build' first"
  cd "$SRCDIR"
  local rel; rel="$(make ARCH=arm64 -s kernelrelease)"
  c "modules_install for $rel"
  $SUDO make ARCH=arm64 modules_install

  local img="$BOOTDIR/kernel8-cjk.img"
  c "Copying Image -> $img"
  $SUDO cp arch/arm64/boot/Image "$img"

  c "Copying dtbs & overlays"
  $SUDO cp arch/arm64/boot/dts/broadcom/*.dtb "$BOOTDIR/" 2>/dev/null || true
  $SUDO mkdir -p "$BOOTDIR/overlays"
  $SUDO cp arch/arm64/boot/dts/overlays/*.dtb* "$BOOTDIR/overlays/" 2>/dev/null || true
  $SUDO cp arch/arm64/boot/dts/overlays/README "$BOOTDIR/overlays/" 2>/dev/null || true

  ok "installed kernel release: $rel"
  cat <<EOF

  Next: enable it in $BOOTDIR/config.txt (fallback-safe). Add under [all]:

      kernel=kernel8-cjk.img

  Your stock kernel8.img is untouched — to go back, remove that line (or run
  '$0 rollback') and reboot. Then reboot to try the CJK kernel:

      sudo reboot

EOF
}

# ---------------------------------------------------------------------------
# rollback / verify
# ---------------------------------------------------------------------------
cmd_rollback() {
  c "Removing 'kernel=kernel8-cjk.img' from config.txt"
  local cfg="$BOOTDIR/config.txt"
  [ -f "$cfg" ] || die "no $cfg"
  $SUDO sed -i.cjkbak '/^kernel=kernel8-cjk\.img/d' "$cfg"
  ok "reverted to stock kernel (backup: $cfg.cjkbak). Reboot to apply."
}

cmd_verify() {
  c "Verification"
  echo "  running kernel : $(uname -r)"
  local want; want="$(cat "$STATE.localversion" 2>/dev/null || echo "$LOCALVERSION_SUFFIX")"
  case "$(uname -r)" in
    *"$LOCALVERSION_SUFFIX"*) ok "CJK kernel is running" ;;
    *) warn "running kernel does not carry '$LOCALVERSION_SUFFIX' — did you set kernel= and reboot?" ;;
  esac
  echo "  CJK font in kernel config:"
  zcat /proc/config.gz 2>/dev/null | grep -E 'CONFIG_FONT_CJK|FONT_16x16_CJK' || \
    warn "no /proc/config.gz (CONFIG_IKCONFIG_PROC off) — can't confirm from running kernel"
  cat <<'EOF'

  Console test (run on the physical console / HDMI, not over ssh):
    printf '你好 世界  日本語  한국어\n'
  You should see: 你好 世界  日本語  한국어
  If glyphs are blank, set a CJK console font/locale (see README.md).
EOF
}

# ---------------------------------------------------------------------------
main() {
  local sub="${1:-all}"; shift || true
  case "$sub" in
    deps)     cmd_deps ;;
    source)   cmd_source ;;
    config)   cmd_config ;;
    patch)    cmd_patch "${1:-}" ;;
    build)    cmd_build ;;
    install)  cmd_install ;;
    verify)   cmd_verify ;;
    rollback) cmd_rollback ;;
    all)      cmd_deps; cmd_source; cmd_config; cmd_patch; cmd_build; cmd_install ;;
    *) die "unknown subcommand: $sub (try: all deps source config patch build install verify rollback)";;
  esac
}
main "$@"
