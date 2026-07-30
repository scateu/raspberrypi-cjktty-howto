#!/usr/bin/env bash
#
# install.sh — install a CJK Raspberry Pi kernel release package.
#
# This ships INSIDE the release tarball produced by mkrelease.sh. It has no
# dependency on the source tree, the toolchain, or the cjk-kernel repo. Run it
# on the target Pi:
#
#     tar xzf cjk-kernel-<release>-<arch>.tar.gz
#     cd cjk-kernel-<release>-<arch>
#     sudo ./install.sh                 # install (non-destructive)
#     sudo ./install.sh --enable        # install AND set kernel= in config.txt
#     sudo ./install.sh --uninstall     # remove this CJK kernel + modules
#
# Non-destructive: installs a separate boot image (default kernel8-cjk.img) and
# a versioned /lib/modules/<release> dir. Your stock kernel8.img is never touched.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[ -f "$HERE/release.env" ] && . "$HERE/release.env"
KREL="${KREL:-}"
IMAGE_NAME="${IMAGE_NAME:-kernel8-cjk.img}"

BOOTDIR="/boot/firmware"; [ -d "$BOOTDIR" ] || BOOTDIR="/boot"
CFG="$BOOTDIR/config.txt"

c()  { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
ok() { printf '\033[1;32m  ok: %s\033[0m\n' "$*"; }
warn(){ printf '\033[1;33m  warn: %s\033[0m\n' "$*"; }
die(){ printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root (sudo ./install.sh)"
[ -n "$KREL" ] || die "release.env missing KREL — is this a complete package?"

enable_cfg() {
  [ -f "$CFG" ] || { warn "no $CFG; add 'kernel=$IMAGE_NAME' manually"; return; }
  if grep -qE "^\s*kernel=$IMAGE_NAME\b" "$CFG"; then
    ok "config.txt already selects $IMAGE_NAME"
  else
    cp "$CFG" "$CFG.cjkbak.$(date +%s 2>/dev/null || echo bak)" 2>/dev/null || true
    printf '\n[all]\nkernel=%s\n' "$IMAGE_NAME" >> "$CFG"
    ok "added 'kernel=$IMAGE_NAME' to $CFG (backup saved)"
  fi
}

do_install() {
  c "Installing CJK kernel release $KREL (image: $IMAGE_NAME)"

  [ -f "$HERE/boot/$IMAGE_NAME" ] || die "missing boot/$IMAGE_NAME in package"
  [ -d "$HERE/modules/lib/modules/$KREL" ] || die "missing modules for $KREL in package"

  c "Installing modules -> /lib/modules/$KREL"
  if [ -d "/lib/modules/$KREL" ]; then
    warn "/lib/modules/$KREL exists — overwriting this CJK release only"
  fi
  cp -a "$HERE/modules/lib/modules/$KREL" /lib/modules/
  depmod "$KREL"

  c "Installing boot image -> $BOOTDIR/$IMAGE_NAME"
  if [ "$IMAGE_NAME" = "kernel8.img" ] || [ "$IMAGE_NAME" = "kernel_2712.img" ]; then
    die "refusing to overwrite the stock image name ($IMAGE_NAME)"
  fi
  cp "$HERE/boot/$IMAGE_NAME" "$BOOTDIR/$IMAGE_NAME"

  c "Installing dtbs & overlays"
  cp "$HERE"/boot/*.dtb "$BOOTDIR/" 2>/dev/null || true
  mkdir -p "$BOOTDIR/overlays"
  cp "$HERE"/boot/overlays/* "$BOOTDIR/overlays/" 2>/dev/null || true

  ok "installed kernel release: $KREL"

  if [ "${1:-}" = "--enable" ]; then
    enable_cfg
    echo; ok "enabled. Reboot to boot the CJK kernel: sudo reboot"
  else
    cat <<EOF

  To boot it, add this to $CFG (or re-run: sudo ./install.sh --enable):

      [all]
      kernel=$IMAGE_NAME

  Your stock kernel is untouched. Then: sudo reboot
  Verify with: uname -r   (should show $KREL)
EOF
  fi
}

do_uninstall() {
  c "Uninstalling CJK kernel release $KREL"
  # 1) remove the kernel= line if it points at our image
  if [ -f "$CFG" ] && grep -qE "^\s*kernel=$IMAGE_NAME\b" "$CFG"; then
    cp "$CFG" "$CFG.cjkbak.$(date +%s 2>/dev/null || echo bak)" 2>/dev/null || true
    sed -i "/^\s*kernel=$IMAGE_NAME\b/d" "$CFG"
    ok "removed 'kernel=$IMAGE_NAME' from $CFG"
  fi
  # 2) remove boot image (never the stock one)
  if [ "$IMAGE_NAME" != "kernel8.img" ] && [ "$IMAGE_NAME" != "kernel_2712.img" ]; then
    rm -f "$BOOTDIR/$IMAGE_NAME" && ok "removed $BOOTDIR/$IMAGE_NAME"
  fi
  # 3) remove the versioned modules dir
  if [ -d "/lib/modules/$KREL" ]; then
    rm -rf "/lib/modules/$KREL" && ok "removed /lib/modules/$KREL"
  fi
  warn "dtbs/overlays were left in place (shared with stock kernel; harmless)."
  ok "uninstalled. Reboot to return to the stock kernel: sudo reboot"
}

case "${1:-}" in
  ""|--install)  do_install ;;
  --enable)      do_install --enable ;;
  --uninstall|-u) do_uninstall ;;
  -h|--help)
    sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown option: $1 (try: --install | --enable | --uninstall)";;
esac
