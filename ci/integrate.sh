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

# 原 kernel/Makefile 是外部模块编译驱动（make -C $KDIR M=...），
# built-in 要求子目录 Makefile 只列 obj；kernelsu-objs 的清单在 Kbuild 里。
rm -f "$SRC/drivers/kernelsu/Makefile"
{
    echo 'obj-$(CONFIG_KSU) += kernelsu.o'
    cat /tmp/ksu-src/kernel/Kbuild
} > "$SRC/drivers/kernelsu/Makefile"

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
