# Per-version reject fixups

When the nearest cjktty patch doesn't apply 100% cleanly to your kernel tree
(because the Raspberry Pi / upstream source drifted in a few lines), `patch`
leaves `.rej` files. The small diffs that resolve those rejects live here, one
directory per kernel `MAJOR.MINOR`:

```
fixups/<MAJ.MIN>/rejects.fixup.patch
```

`cjk-kernel.sh patch` applies the main patch, then auto-applies
`fixups/$(uname -r major.minor)/rejects.fixup.patch` if present, and finally
refuses to continue if any `.rej` remain.

## Included

- **`6.18/`** — for RPi kernel `6.18.x` built with the `v6.x/cjktty-6.19.patch`
  base (nearest higher). Two hunks:
  1. `include/linux/font.h` — 6.18's `extern` font list ends at `font_6x8;`
     (no `font_ter_10x18`), so the CJK fonts are appended there instead.
  2. `drivers/video/fbdev/core/fbcon_rotate.c` — the rotate buffer is
     `kvmalloc_array`'d, so its free must be `kvfree`, not `kfree`.

## Adding a fixup for a new version

See [../HOWTO.md](../HOWTO.md) → "Patch a new kernel version". In short: apply the
main patch, hand-resolve each `.rej` in the source tree, then `diff -u` the
pristine vs. fixed file (rewriting paths to `a/` and `b/`) into a new
`fixups/<MAJ.MIN>/rejects.fixup.patch`.
