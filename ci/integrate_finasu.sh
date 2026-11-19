#!/usr/bin/env bash
# FinaSU 原生内核集成（finasu-native 分支专用）
#
# 与 integrate.sh 的 SukiSU-Nova 路径互斥：integrate.sh 在 KSU_VARIANT=finasu 时
# 直接 exec 本脚本。参考 LingLuo17/AnyKernel3 的 6.18 FinaSU 构建方式：
#   - 内核侧就是 LyraVoid/FinaSU 本体（不是改 SukiSU）
#   - 树内软链到 drivers/kernelsu，版本号 = 30000 + git 提交数（与管理器 versionCode 同源）
#   - 管理器识别用 FinaSU 自带的第二信任槽（证书由 build.sh 以 make 变量传入）
#   - SUSFS 内核侧仍用我们已验证的 6.18 移植（含属主豁免）
set -euo pipefail

SRC="$(cd "${SRC:-kernel}" && pwd)"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

FINASU_REPO="${FINASU_REPO:-https://github.com/LyraVoid/FinaSU.git}"
FINASU_COMMIT="${FINASU_COMMIT:-}"

echo "==> [finasu] 拉取 FinaSU 内核源码"
if [ -d "$SRC/KernelSU/.git" ]; then
    echo "    KernelSU 已存在，复用"
else
    git clone --filter=blob:none "$FINASU_REPO" "$SRC/KernelSU"
fi
cd "$SRC/KernelSU"
if [ -n "$FINASU_COMMIT" ]; then
    if ! git cat-file -e "$FINASU_COMMIT^{commit}" 2>/dev/null; then
        git fetch origin "$FINASU_COMMIT"
    fi
    git checkout --detach "$FINASU_COMMIT"
fi
KSU_SHA=$(git rev-parse --short=8 HEAD)
KSU_COUNT=$(git rev-list --count HEAD)
KSU_VERSION=$((30000 + KSU_COUNT))
echo "    FinaSU ${KSU_SHA} commit_count=${KSU_COUNT} kernel_ksu_version=${KSU_VERSION}"
cd "$SRC"

echo "==> [finasu] 树内集成到 drivers/kernelsu"
DRIVER_DIR="$SRC/drivers"
ln -sfn "$(realpath --relative-to="$DRIVER_DIR" "$SRC/KernelSU/kernel")" "$DRIVER_DIR/kernelsu"
grep -q 'kernelsu/' "$DRIVER_DIR/Makefile" || echo 'obj-$(CONFIG_KSU) += kernelsu/' >> "$DRIVER_DIR/Makefile"
grep -q 'source "drivers/kernelsu/Kconfig"' "$DRIVER_DIR/Kconfig" || sed -i '/endmenu/i source "drivers/kernelsu/Kconfig"' "$DRIVER_DIR/Kconfig"

echo "==> [finasu] 版本品牌串固定为 @finasu"
python3 - "$SRC/KernelSU/kernel/Kbuild" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "@$(KSU_VERSION_BRANCH)"
if old in s:
    open(p, "w").write(s.replace(old, "@finasu", 1))
    print("    KSU_VERSION_FULL 中的分支段已固定为 @finasu")
else:
    print("    !! 未找到 @$(KSU_VERSION_BRANCH)，跳过（仅影响版本显示）")
PY

echo "==> [finasu] 应用 SUSFS SELinux 补丁"
patch -p1 -d "$SRC" --forward < "$HERE/patches/susfs-selinux.patch"

echo "==> [finasu] 加入 bridge"
cp "$HERE/patches/susfs_bridge.c" "$SRC/fs/susfs_bridge.c"
grep -q 'susfs_bridge' "$SRC/fs/Makefile" || \
    printf '\nobj-$(CONFIG_KSU_SUSFS) += susfs_bridge.o\n' >> "$SRC/fs/Makefile"

echo "==> [finasu] 应用 SUSFS v2.4.0 内核侧移植"
KSU_VARIANT=finasu bash "$HERE/ci/susfs_upstream.sh" "$SRC" "$HERE"

echo "==> [finasu] 校验关键内容"
grep -q 'susfs_owner_record' "$SRC/fs/susfs.c" || {
    echo "!! fs/susfs.c 缺少属主豁免实现（patches/upstream/fs/susfs.c 被改动？）"
    exit 1
}
grep -q '^config KSU_SUSFS$' "$SRC/drivers/kernelsu/Kconfig"

echo "==> [finasu] 完成：kernel_ksu_version=${KSU_VERSION} (${KSU_SHA})"
