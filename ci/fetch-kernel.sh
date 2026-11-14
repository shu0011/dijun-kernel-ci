#!/usr/bin/env bash
# 取得内核源码：AOSP kernel/common 的 6.18.32 快照分支。
#
# 为什么用这一条：
#   - android17-6.18（主分支）已经漂到 6.18.33 并会继续往前走，不可复现
#   - android17-6.18-2026-09 是冻结快照，实测 SUBLEVEL = 32，正合需要
#   - 现有的 kernelsu.ko / susfs LKM 都是 6.18.32 KMI 编的，基线一致便于对照
#
# 设备实际是 6.18.21（小米在其上又加了提交）。6.18 分支内 KMI 稳定，
# 所以"6.18.32 的内核 vs 6.18.21 的设备"差多少，由 BTF 比对给出量化结论。
set -euo pipefail

BRANCH="${BRANCH:-android17-6.18-2026-09}"
EXPECT_SUBLEVEL="${EXPECT_SUBLEVEL:-32}"
DEST="${DEST:-kernel}"
PRIMARY="${PRIMARY:-https://android.googlesource.com/kernel/common}"
FALLBACK="${FALLBACK:-https://github.com/aosp-mirror/kernel_common.git}"

rm -rf "$DEST"

clone() {
    echo "==> clone $1 ($BRANCH)"
    git clone --depth=1 --branch "$BRANCH" "$1" "$DEST"
}

if ! clone "$PRIMARY"; then
    echo "==> 主源失败，改用镜像"
    rm -rf "$DEST"
    clone "$FALLBACK"
fi

cd "$DEST"

PATCHLEVEL=$(awk -F'= *' '/^PATCHLEVEL/{print $2}' Makefile)
SUBLEVEL=$(awk -F'= *' '/^SUBLEVEL/{print $2}' Makefile)
COMMIT=$(git rev-parse --short HEAD)
echo "==> 源码 $COMMIT  版本 6.$PATCHLEVEL.$SUBLEVEL  $(git log -1 --format='%ad' --date=short)"

if [ "$PATCHLEVEL" != "18" ] || [ "$SUBLEVEL" != "$EXPECT_SUBLEVEL" ]; then
    echo "!! 期望 6.18.$EXPECT_SUBLEVEL，实际 6.$PATCHLEVEL.$SUBLEVEL —— 分支不对，终止"
    exit 1
fi

echo "==> OK"
