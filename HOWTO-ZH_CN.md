# HOWTO —— 构建、交叉编译、重新打补丁、切换 CJK 树莓派内核

这是 `cjk-kernel.sh` 与 `README.md` 的实操配套文档（English: [HOWTO.md](HOWTO.md)）。
它回答四件事：

1. [在树莓派上本机编译](#1-在树莓派上本机编译)
2. [交叉编译（在更快的 x86_64 / 其他机器上）](#2-交叉编译)
3. [为**新的**内核版本打补丁（处理 reject）](#3-为新的内核版本打补丁)
4. [在不同内核间切换（以及回滚）](#4-在不同内核间切换)

示例硬件：**Compute Module 4S**，内核 `6.18.34+rpt-rpi-v8`，Debian 13（trixie），
aarch64。`+rpt` 表示这是树莓派官方 Debian 打包的内核，因此匹配的源码是
`linux-source-<主.次>` 这个 apt 软件包（不是 kernel.org 的原版）。

> **哪个 “v8”？** `-rpi-v8` 是 64 位配置，用于 Pi 3 / 4 / Zero 2 / CM3 / CM4 /
> CM4S → 启动镜像 `kernel8.img`，defconfig 家族 `bcm2711_defconfig`。
> Pi 5 / CM5 是 `-rpi-2712` → `kernel_2712.img`，`bcm2712_defconfig`。
> 请对照你自己的 `uname -r` 选择。

---

## 1. 在树莓派上本机编译

最简单、最可靠——无需折腾工具链，源码/配置都来自正在运行的系统。一台 CM4S
（4 核、约 8 GB 内存、≥15 GB 空闲）大约 **1.5–2.5 小时**完成。

```bash
# 把工具 + 补丁树复制到树莓派后：
cd ~/cjk-tool
./cjk-kernel.sh deps       # bc bison flex libssl-dev libncurses-dev 等
./cjk-kernel.sh source     # 下载 linux-source-6.18（精确的 +rpt 源码）并解包
./cjk-kernel.sh config      # 用运行内核的配置初始化 .config；LOCALVERSION -> -v8-cjk
./cjk-kernel.sh patch       # 最接近的 cjktty 补丁 + 自带的 6.18 fixup
./cjk-kernel.sh build       # make -j4 Image modules dtbs
./cjk-kernel.sh install     # modules_install + /boot/firmware/kernel8-cjk.img（安全）
```

或者一步到位：`./cjk-kernel.sh all`。

手动等价流程（脚本内部做的事），供你想手工操作时参考：

```bash
sudo apt install -y bc bison flex libssl-dev libncurses-dev make gcc \
                    device-tree-compiler dpkg-dev
sudo apt install -y linux-source-6.18          # 精确的 +rpt 源码
mkdir -p ~/cjk-kernel-build && cd ~/cjk-kernel-build
tar xf /usr/src/linux-source-6.18.tar.xz && mv linux-source-6.18 linux && cd linux

cp /usr/src/linux-headers-$(uname -r)/.config .config      # 运行内核的配置
./scripts/config --set-str CONFIG_LOCALVERSION "-v8-cjk"   # 独立名字（可安全回退）
./scripts/config -d CONFIG_LOCALVERSION_AUTO

patch -p1 --fuzz=3 < $REPO/cjktty-patches/v6.x/cjktty-6.19.patch   # 最接近 6.18.34 的补丁
patch -p1 --fuzz=3 < $REPO/fixups/6.18/rejects.fixup.patch         # 2 处漂移的 hunk

./scripts/config -e CONFIG_FONTS \
                 -e CONFIG_FONT_CJK_16x16 -e CONFIG_FONT_CJK_32x32
make ARCH=arm64 olddefconfig

make ARCH=arm64 -j$(nproc) Image modules dtbs

sudo make ARCH=arm64 modules_install
sudo cp arch/arm64/boot/Image /boot/firmware/kernel8-cjk.img
sudo cp arch/arm64/boot/dts/broadcom/*.dtb        /boot/firmware/
sudo cp arch/arm64/boot/dts/overlays/*.dtb*       /boot/firmware/overlays/
```

然后启用它 → 见[第 4 节](#4-在不同内核间切换)。

**SSH 断了也别让编译中断。** 把编译放到后台，长任务就能挺过不稳定的连接：

```bash
nohup ./cjk-kernel.sh build > ~/cjk-kernel-build/build.log 2>&1 &
tail -f ~/cjk-kernel-build/build.log      # 观察；Ctrl-C 只是停止观察，不停编译
# 或用 tmux/screen：tmux new -s k  →  ./cjk-kernel.sh build  →  Ctrl-b d 脱离
```

---

## 2. 交叉编译

在更快的 x86_64 机器（或用 Linux 容器的 M 系列 Mac）上编译，能把几小时缩短到几分钟。
你需要一套 **aarch64 交叉工具链**，然后把产物拷到树莓派。内核的*源码和 .config*
仍然来自树莓派（这样构建才与你运行的系统一致）。

### 2a. 在 Linux x86_64 主机上（Debian/Ubuntu）

```bash
sudo apt install -y crossbuild-essential-arm64 bc bison flex libssl-dev \
                    libncurses-dev make git device-tree-compiler

export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-

# 取得与树莓派相同的源码 + 配置：
#   方案 A（推荐）：从树莓派上拷过来
scp pi@PI:/usr/src/linux-source-6.18.tar.xz .     # 若没有：先在树莓派上 `sudo apt install linux-source-6.18`
scp pi@PI:/usr/src/linux-headers-$(ssh pi@PI uname -r)/.config  ./running.config
tar xf linux-source-6.18.tar.xz && cd linux-source-6.18
cp ../running.config .config
#   方案 B：克隆 raspberrypi/linux，分支 rpi-6.18.y，再 `make bcm2711_defconfig`

# 打补丁 + 配置，与本机流程完全一致：
./scripts/config --set-str CONFIG_LOCALVERSION "-v8-cjk"
./scripts/config -d CONFIG_LOCALVERSION_AUTO
patch -p1 --fuzz=3 < $REPO/cjktty-patches/v6.x/cjktty-6.19.patch
patch -p1 --fuzz=3 < $REPO/fixups/6.18/rejects.fixup.patch
./scripts/config -e CONFIG_FONTS -e CONFIG_FONT_CJK_16x16 -e CONFIG_FONT_CJK_32x32
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig

# 编译（用这台快机器的全部核心）：
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc) Image modules dtbs
```

打包模块并把所有东西发到树莓派：

```bash
# 用正确的目录布局把模块暂存成 tar 包
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
     INSTALL_MOD_PATH=./stage modules_install
KREL=$(make -s ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- kernelrelease)   # 例如 6.18.34-v8-cjk
tar -C ./stage -czf modules-$KREL.tgz lib/modules/$KREL

# 拷到树莓派
scp arch/arm64/boot/Image                    pi@PI:/tmp/kernel8-cjk.img
scp modules-$KREL.tgz                        pi@PI:/tmp/
scp arch/arm64/boot/dts/broadcom/*.dtb       pi@PI:/tmp/dtb/
scp arch/arm64/boot/dts/overlays/*.dtb*      pi@PI:/tmp/overlays/
```

在树莓派上安装（非破坏性）：

```bash
sudo tar -C / -xzf /tmp/modules-*.tgz                 # -> /lib/modules/<rel>
sudo depmod <rel>
sudo cp /tmp/kernel8-cjk.img /boot/firmware/kernel8-cjk.img
sudo cp /tmp/dtb/*.dtb       /boot/firmware/
sudo cp /tmp/overlays/*      /boot/firmware/overlays/
```

然后在 `config.txt` 里启用 → 见[第 4 节](#4-在不同内核间切换)。

### 2c. 打包成可分发的发行版（交叉编译时强烈推荐）

不必手工拷贝文件，用 `mkrelease.sh` 把一次构建变成一个自包含的 tar 包。
在**编译内核的那台机器**上运行：

```bash
# 本机（在树莓派上）：
./mkrelease.sh
# 交叉编译（在 x86_64 机器上）：
CROSS_COMPILE=aarch64-linux-gnu- ./mkrelease.sh [SRCDIR] [OUTDIR]
#   SRCDIR 默认 ~/cjk-kernel-build/linux ；OUTDIR 默认 <仓库>/dist
# Pi 5 / CM5（2712）：同时指定启动镜像名
IMAGE_NAME=kernel_2712-cjk.img CROSS_COMPILE=aarch64-linux-gnu- ./mkrelease.sh
```

它会生成 `dist/cjk-kernel-<release>-<arch>.tar.gz`（外加 `.sha256`），里面包含
内核镜像、dtb、overlay、带版本号的模块树、一个 `MANIFEST.txt` 和一个内置的
`install.sh`。这个 tar 包**不依赖**本仓库或工具链。在目标树莓派上：

```bash
tar xzf cjk-kernel-<release>-arm64.tar.gz
cd cjk-kernel-<release>-arm64
sudo ./install.sh            # 非破坏性安装（原厂内核不动）
sudo ./install.sh --enable   # 顺便把 kernel=…-cjk.img 写进 config.txt
sudo ./install.sh --uninstall# 删除这个 CJK 内核及其模块
sudo reboot
```

### 2b. 在 Apple 芯片 / Intel 的 Mac 上

macOS 没有原生的 aarch64-linux 交叉工具链，所以把上面的 Linux 步骤放进容器里跑。
在 Apple 芯片上这是*原生*速度（arm64 宿主机跑 arm64 目标——无需模拟）：

```bash
# 在包含 cjk-kernel.sh + cjktty-patches 子模块的仓库根目录下
docker run --rm -it -v "$PWD":/work -w /work debian:trixie bash
# 进入容器后，运行 2a 节的 apt + 编译命令
#（宿主机是 arm64 时，CROSS_COMPILE 甚至可以留空，直接用 gcc）
```

如果你不想用容器，官方标准交叉工具链是树莓派的 `tools` 仓库：

```bash
git clone --depth=1 https://github.com/raspberrypi/tools
export PATH=$PWD/tools/arm-bcm2708/gcc-linaro-*aarch64*/bin:$PATH
```

> **经验法则：** 交叉编译在慢速树莓派（Zero 2、Pi 3）上收益最大。CM4S/Pi 4/Pi 5
> 本机编译已经可以接受，而且避免了工具链/ABI 不匹配的风险——除非你要频繁重建，
> 否则优先本机编译。

---

## 3. 为新的内核版本打补丁

`cjk-kernel.sh` 是版本感知的：它读取 `uname -r`，取得匹配源码，挑选**最接近的**
cjktty 补丁，并应用自带的 fixup。多数情况下换新版本“开箱即用”：

```bash
./cjk-kernel.sh all
```

如果没那么顺，通常是上游/树莓派改动了补丁没预料到的少数几行。分三步处理。

### 第 1 步 —— 先做 dry-run 闸门（便宜，务必先做）

```bash
./cjk-kernel.sh source
./cjk-kernel.sh config
./cjk-kernel.sh patch --dry-run     # 报告哪些会 reject；不改动任何东西
```

- **“patch applies cleanly”** → 直接去 `build`。
- 出现若干 **`Hunk … FAILED`** 行 → 记下它们在哪些*文件*里（日志在
  `~/cjk-kernel-build/patch-dryrun.log`），继续下一步。

脚本已经会挑最接近的补丁。你也可以强制换个基线来对比：

```bash
# 例如试试下一个更高版本的补丁，而不是自动挑的那个
cd ~/cjk-kernel-build/linux
patch -p1 --fuzz=3 --dry-run < cjktty-patches/v6.x/cjktty-6.19.patch 2>&1 \
  | grep -E 'checking file|FAILED|hunks FAILED'
```

选 reject 最少的那个基线。（对 6.18.34，**6.19** 补丁只 reject 了 2 个 hunk，
而 6.17.8 reject 了很多——就近取高者胜出。）

### 第 2 步 —— 应用补丁并阅读 reject

```bash
./cjk-kernel.sh patch          # 应用主补丁；若存在你 MAJ.MIN 的 fixup 会自动套用，
                               # 否则就停在这里
cd ~/cjk-kernel-build/linux
find . -name '*.rej'           # 每个都是一个失败的 hunk
cat drivers/video/fbdev/core/fbcon_rotate.c.rej   # 举例
```

`.rej` 都很小、很机械。常见原因与修法：

| reject 里显示什么 | 为什么漂移 | 怎么修 |
|---|---|---|
| 一处 `kfree(...)`→`kvfree(...)` 的 `-`/`+` “FAILED” | 上游挪动了分配/释放的代码块 | 在真正的调用点做同样的一词改动 |
| `extern` 列表以 `font_6x8;` 结尾，但补丁期望 `font_ter_10x18;` | 你的树里没有那个 font | 把 `+font_cjk_16x16, font_cjk_32x32;` 追加到真正的结尾项上 |
| 某个上下文行被改名（如 `FONT6x10_IDX` vs `TER16x32_IDX`） | 宏/名字变动 | 找到等价的行，把 `+` 的新增内容加在那里 |

打开目标文件，找到 reject 上下文指向的位置，手工套用那些 `+`/`-` 行，然后删除 `.rej`。

### 第 3 步 —— 把它固化成可复用的 fixup

为了让下一个用同版本的人不用重复劳动，把你的改动保存为
`fixups/<MAJ.MIN>/rejects.fixup.patch`。`fixups/6.18` 用的配方：

```bash
cd ~/cjk-kernel-build/linux
# 1) 把该文件复制一份处于“仍未修复”状态（只撤销你的手工编辑），
#    或者在打补丁前从源码 tar 包留一份原始副本。
# 2) diff 原始-未修复 -> 你的-已修复，并把路径改写成 a/ 和 b/：
diff -u OLD/include/linux/font.h include/linux/font.h \
  | sed -e 's|^--- OLD/|--- a/|' -e 's|^+++ .*|+++ b/include/linux/font.h|' \
  >> fixups/6.18/rejects.fixup.patch
```

此后在任何 6.18.x 上 `./cjk-kernel.sh patch` 都会先套主补丁再套你的 fixup，
并在允许你构建前校验补丁树完全干净。

### 第 4 步 —— 在漫长编译前先做冒烟编译

不等 2 小时，先确认打过补丁的 C 代码确实能编译：

```bash
make ARCH=arm64 -j$(nproc) \
  lib/fonts/font_cjk_16x16.o lib/fonts/font_cjk_32x32.o lib/fonts/fonts.o \
  drivers/video/fbdev/core/{fbcon,bitblit,fbcon_rotate,fbcon_ccw,fbcon_cw,fbcon_ud}.o \
  drivers/tty/vt/{vt,selection}.o
```

输出干净 → `./cjk-kernel.sh build`。

### 如果没有任何补丁足够接近

cjktty 补丁集只更新到某些版本。如果你的内核比任何可用补丁都新很多，而且 reject
很大（整个函数被搬走），要么等上游更新 cjktty 补丁
（`Gentoo-zh/linux-cjktty` / `zhmars/cjktty-patches`），要么固定到有补丁的内核
版本。帧缓冲控制台内部很少变，所以“最接近的补丁 + 几处 fixup”通常就够了。

---

## 4. 在不同内核间切换

因为 CJK 内核安装成一个**独立的** `kernel8-cjk.img`（原厂 `kernel8.img` 不动），
切换只需在 `/boot/firmware/config.txt` 里加一行再重启。

### 启动 CJK 内核

```ini
# /boot/firmware/config.txt
[all]
kernel=kernel8-cjk.img
```

```bash
sudo reboot
uname -r        # -> 6.18.34-v8-cjk （证明你在打过补丁的内核上）
```

### 回到原厂内核

```bash
./cjk-kernel.sh rollback     # 删除那行 kernel=（备份：config.txt.cjkbak）
# 或者自己编辑 config.txt 删掉那行
sudo reboot
```

### 按机型切换（CM4/CM5 混合部署）

`config.txt` 支持条件过滤段，一张卡可以同时服务两种机型：

```ini
[cm4]
kernel=kernel8-cjk.img       # CM4/CM4S -> v8 CJK 内核
[pi5]
kernel=kernel_2712-cjk.img   # 如果你也构建了 2712 的 CJK 内核
[all]
```

### 挽救坏掉的构建（起不来）

原厂内核还在卡上。两种回退方式：

1. **拔出 SD 卡**插到任意电脑，打开 `bootfs`/`firmware` 分区（FAT，哪里都能挂载），
   从 `config.txt` 删掉 `kernel=kernel8-cjk.img` 那行。重启 → 原厂内核。
2. 如果你有串口 / HDMI+键盘，进去用同样办法改 `config.txt`。

因为你从未覆盖 `kernel8.img`，模块也在独立的 `-v8-cjk` 目录下，坏掉的 CJK 内核
不可能破坏原厂内核。

### 关于 apt 内核升级

`sudo apt upgrade` 会照常更新原厂 `kernel8.img` 及其模块，**不会**动你的
`kernel8-cjk.img`。但版本跳动后，你的 CJK 内核就比原厂*旧*了，如果来回切换不小心，
它的模块和新的 `uname -r` 会对不上——不过每个内核只用自己
`/lib/modules/<各自的 release>`，所以不会冲突。要在新版本上获得 CJK，
重新跑 `./cjk-kernel.sh all` 即可（它会重新检测新的 `uname -r`）。
