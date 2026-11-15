#!/usr/bin/env bash
# 把 SukiSU（built-in，不是 LKM）和 SUSFS 的 SELinux 隐藏合进内核源码树。
#
# 为什么 built-in：
#   LKM 形态下模块改不了 security/selinux/ 的源码，只能用 kprobe 挂钩，
#   会留下 /sys/kernel/debug/kprobes/list 痕迹。编进 Image 后这些补丁是
#   直接改函数体，一个 kprobe 都不用。
set -euo pipefail

SRC="${SRC:-kernel}"
KSU_REPO="${KSU_REPO:-https://github.com/SukiSU-Ultra/SukiSU-Ultra}"
KSU_REF="${KSU_REF:-v4.3.0-r2}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> A 拉取 SukiSU $KSU_REF"
rm -rf /tmp/ksu-src
git clone --depth=1 --branch "$KSU_REF" "$KSU_REPO" /tmp/ksu-src

echo "==> B 装到 drivers/kernelsu（built-in）"
rm -rf "$SRC/drivers/kernelsu"
mkdir -p "$SRC/drivers/kernelsu"
cp -a /tmp/ksu-src/kernel/. "$SRC/drivers/kernelsu/"

# 原 kernel/Makefile 是外部模块编译驱动（make -C $KDIR M=...），built-in 用不上。
# Kbuild 里已经自带 "obj-$(CONFIG_KSU) += kernelsu.o" 和全部 kernelsu-objs 清单，
# 直接把它当子目录 Makefile 即可 —— 再补一行 obj- 会导致 kernelsu.o 重复链接。
rm -f "$SRC/drivers/kernelsu/Makefile"
cp /tmp/ksu-src/kernel/Kbuild "$SRC/drivers/kernelsu/Makefile"

# 版本串：Kbuild 靠 `cd $(KSU_SRC) && git rev-parse` 取 sha/branch，而拷进来的
# 目录没有 .git，会降级成 v4.3.0-r2-SukiSU-Ultra-unknown@unknown。
# 用 clone 时拿到的 sha 和用户要的 @shushu 直接写死。
KSU_SHA=$(git -C /tmp/ksu-src rev-parse --short=8 HEAD)
KSU_TAG="${KSU_REF#v}"
sed -i "s|^KSU_VERSION_FULL := .*|KSU_VERSION_FULL := v${KSU_TAG}-${KSU_SHA}@shushu|" \
    "$SRC/drivers/kernelsu/Makefile"
grep -n 'KSU_VERSION_FULL :=' "$SRC/drivers/kernelsu/Makefile"

# built-in 时 Kbuild 用 $(srctree)/$(src) 拼 -I，kbuild 递归到子目录后这个相对
# 路径解析不到 include/uapi/xxx.h（报 uapi/app_profile.h not found）。
# 用 abspath 兜一条绝对路径，并把 include 情况打出来方便核对。
cat >> "$SRC/drivers/kernelsu/Makefile" <<'EOF'

# --- 本项目追加：built-in 的 -I 兜底 ---
KSU_ABS := $(abspath $(srctree)/drivers/kernelsu)
ccflags-y += -I$(KSU_ABS) -I$(KSU_ABS)/include
$(info -- KSU include dirs: $(KSU_ABS) $(KSU_ABS)/include)
EOF

# KSU 源码里 #include "uapi/xxx.h" 是按 -I<根>/-I<根>/include 两种布局都能命中的
# 写法；保险起见把 uapi 也在根下放一份，少一条路径依赖。
if [ -d "$SRC/drivers/kernelsu/include/uapi" ]; then
    cp -r "$SRC/drivers/kernelsu/include/uapi" "$SRC/drivers/kernelsu/uapi"
    echo "    uapi 头文件已在 include/ 与根目录各放一份"
fi
ls "$SRC/drivers/kernelsu/uapi" 2>&1 | head -4

# 挂进 drivers 的 Kconfig 与 Makefile（幂等）
grep -q 'kernelsu/Kconfig' "$SRC/drivers/Kconfig" || \
    printf '\nsource "drivers/kernelsu/Kconfig"\n' >> "$SRC/drivers/Kconfig"
grep -q 'kernelsu/' "$SRC/drivers/Makefile" || \
    printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$SRC/drivers/Makefile"

echo "==> C 注册 CONFIG_KSU_SUSFS"
if ! grep -q '^config KSU_SUSFS' "$SRC/drivers/kernelsu/Kconfig"; then
    cat >> "$SRC/drivers/kernelsu/Kconfig" <<'EOF'

config KSU_SUSFS
	bool "SUSFS (SELinux hiding only)"
	depends on KSU
	default n
	help
	  SUSFS 的 SELinux 隐藏部分：伪造 getenforce 的返回值、拦截
	  /sys/fs/selinux 的读写路径、过滤 AVC 日志里的 ksu 痕迹。
	  不含 sus_path / sus_mount / open_redirect 这些必须改 VFS 的功能。
EOF
fi

echo "==> D 合 SUSFS 的 SELinux 补丁（5 个文件 / 134 行上下文已验证可套）"
patch -p1 -d "$SRC" --forward < "$HERE/patches/susfs-selinux.patch"

echo "==> E 加桥接层"
cp "$HERE/patches/susfs_bridge.c" "$SRC/fs/susfs_bridge.c"
grep -q 'susfs_bridge' "$SRC/fs/Makefile" || \
    printf '\nobj-$(CONFIG_KSU_SUSFS) += susfs_bridge.o\n' >> "$SRC/fs/Makefile"

echo "==> F 集成完成"
grep -c 'CONFIG_KSU_SUSFS' "$SRC/security/selinux/status.c" "$SRC/security/selinux/avc.c" \
     "$SRC/security/selinux/hooks.c" "$SRC/security/selinux/selinuxfs.c" \
     "$SRC/security/selinux/ss/services.c" || true
