#!/usr/bin/env bash
#
# mkrelease.sh — package a built CJK kernel into a distributable release tarball.
#
# Run this on the machine that COMPILED the kernel (a cross-compile box, or the
# Pi itself) after `cjk-kernel.sh build` (or a manual `make … Image modules dtbs`)
# has succeeded. It collects the kernel image, modules, dtbs, overlays and a
# self-contained installer into:
#
#     dist/cjk-kernel-<release>-<arch>.tar.gz   (+ .sha256)
#
# The tarball has NO dependency on this repo, the toolchain, or the kernel
# source — an end user just unpacks it on their Pi and runs ./install.sh.
#
# Usage:
#   ./mkrelease.sh [SRCDIR] [OUTDIR]
#     SRCDIR   kernel source tree that was built  (default: ~/cjk-kernel-build/linux)
#     OUTDIR   where to write the tarball          (default: <repo>/dist)
#
# Environment:
#   ARCH           default arm64
#   CROSS_COMPILE  set if you cross-compiled (e.g. aarch64-linux-gnu-)
#   IMAGE_NAME     boot image filename to install as (default: kernel8-cjk.img;
#                  use kernel_2712-cjk.img for Pi 5 / CM5 / 2712)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRCDIR="${1:-$HOME/cjk-kernel-build/linux}"
OUTDIR="${2:-$SCRIPT_DIR/dist}"
ARCH="${ARCH:-arm64}"
CROSS_COMPILE="${CROSS_COMPILE:-}"
IMAGE_NAME="${IMAGE_NAME:-kernel8-cjk.img}"

c()  { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
ok() { printf '\033[1;32m  ok: %s\033[0m\n' "$*"; }
die(){ printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

MK=(make ARCH="$ARCH")
[ -n "$CROSS_COMPILE" ] && MK+=(CROSS_COMPILE="$CROSS_COMPILE")

[ -f "$SRCDIR/arch/arm64/boot/Image" ] || \
  die "no built Image in $SRCDIR — run the build first"

c "Reading kernel release"
REL="$(cd "$SRCDIR" && "${MK[@]}" -s kernelrelease)"
[ -n "$REL" ] || die "could not determine kernelrelease"
ok "release: $REL"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
PKG="$STAGE/cjk-kernel-$REL-$ARCH"
mkdir -p "$PKG/boot/overlays" "$PKG/modules"

c "Collecting kernel image"
cp "$SRCDIR/arch/arm64/boot/Image" "$PKG/boot/$IMAGE_NAME"

c "Collecting dtbs & overlays"
cp "$SRCDIR"/arch/arm64/boot/dts/broadcom/*.dtb "$PKG/boot/" 2>/dev/null || true
cp "$SRCDIR"/arch/arm64/boot/dts/overlays/*.dtb* "$PKG/boot/overlays/" 2>/dev/null || true
cp "$SRCDIR"/arch/arm64/boot/dts/overlays/README "$PKG/boot/overlays/" 2>/dev/null || true

c "Staging modules for $REL"
( cd "$SRCDIR" && "${MK[@]}" INSTALL_MOD_PATH="$PKG/modules" \
    modules_install >/dev/null )
# strip the build/source symlinks that point at the compile machine
rm -f "$PKG/modules/lib/modules/$REL/build" \
      "$PKG/modules/lib/modules/$REL/source" 2>/dev/null || true

c "Writing manifest"
BUILT_ON="$(uname -srm 2>/dev/null || echo unknown)"
cat > "$PKG/MANIFEST.txt" <<EOF
CJK Raspberry Pi kernel — release package
kernel release : $REL
arch           : $ARCH
boot image     : $IMAGE_NAME
cross compiled : ${CROSS_COMPILE:-no (native)}
built on host  : $BUILT_ON
contents:
  boot/$IMAGE_NAME        -> /boot/firmware/$IMAGE_NAME  (non-destructive)
  boot/*.dtb              -> /boot/firmware/
  boot/overlays/*         -> /boot/firmware/overlays/
  modules/lib/modules/$REL -> /lib/modules/$REL
Install: ./install.sh    Uninstall: ./install.sh --uninstall
EOF

c "Bundling installer"
install -m 0755 "$SCRIPT_DIR/release/install-release.sh" "$PKG/install.sh" 2>/dev/null \
  || die "missing release/install-release.sh next to mkrelease.sh"
# record the values the installer needs, so the tarball is self-describing
cat > "$PKG/release.env" <<EOF
KREL="$REL"
IMAGE_NAME="$IMAGE_NAME"
ARCH="$ARCH"
EOF

c "Creating tarball"
mkdir -p "$OUTDIR"
TARBALL="$OUTDIR/cjk-kernel-$REL-$ARCH.tar.gz"
tar -C "$STAGE" -czf "$TARBALL" "cjk-kernel-$REL-$ARCH"
( cd "$OUTDIR" && sha256sum "$(basename "$TARBALL")" > "$(basename "$TARBALL").sha256" 2>/dev/null \
  || shasum -a 256 "$(basename "$TARBALL")" > "$(basename "$TARBALL").sha256" )

ok "release: $TARBALL"
ok "sha256 : $TARBALL.sha256"
echo
echo "  Ship the tarball to a Pi and:"
echo "      tar xzf $(basename "$TARBALL") && cd cjk-kernel-$REL-$ARCH && sudo ./install.sh"
