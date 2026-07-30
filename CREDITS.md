# Credits & licensing

## This repository

- `cjk-kernel.sh`, `fixups/`, and the docs (`README.md`, `HOWTO.md`) are original
  work in this repo, released under **GPL-2.0** (see `LICENSE`) to stay consistent
  with the Linux kernel and the cjktty patches they build on. The files under
  `fixups/` are Linux kernel source diffs and are GPL-2.0 as derivatives of the
  kernel.

## Upstream projects (not authored here)

- **cjktty patch set** — vendored as the `cjktty-patches/` git submodule from
  [bigshans/cjktty-patches](https://github.com/bigshans/cjktty-patches), which is
  based on [Gentoo-zh/linux-cjktty](https://github.com/Gentoo-zh/linux-cjktty).
- **Original cjktty / univt work** — 蔡万钊 (cjktty) and
  [youbest](http://blog.chinaunix.net/uid/436750.html) (original univt patches);
  see `docs/cjktty-principles.zh.txt` for the author's write-up.
- **Font data** — [GNU Unifont](https://savannah.gnu.org/projects/unifont) and
  [Terminus Font](http://terminus-font.sourceforge.net), as bundled in the
  cjktty patches.

The Linux kernel itself is GPL-2.0. Kernels you build with this tool remain
subject to the kernel's own license.
