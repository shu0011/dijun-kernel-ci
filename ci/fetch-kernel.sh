#!/usr/bin/env bash
# 拉取 android17-6.18 内核源码，并切到**设备所用的那个提交**。
#
# 为什么必须切：分支 HEAD 已经跑到 6.18.33（2026-11-13），而设备是 6.18.21
# （g284297031c53）。直接用 HEAD 编出来的内核，结构体/符号都可能与厂商模块不匹配。
#
# 为什么不能直接 --depth=1 取那个提交：googlesource 不允许按 SHA 拉单个提交，
# 只能先拿到历史再 checkout。所以这里先浅克隆，失败就逐步加深，最后才 unshallow。
set -euo pipefail

DEVICE_COMMIT="${DEVICE_COMMIT:-284297031c53}"
BRANCH="${BRANCH:-android17-6.18}"
EXPECT_SUBLEVEL="${EXPECT_SUBLEVEL:-21}"
DEST="${DEST:-kernel}"

rm -rf "$DEST"

echo "==> git clone android.googlesource.com/kernel/common ($BRANCH, depth=1)"
git clone --depth=1 --branch "$BRANCH" \
    https://android.googlesource.com/kernel/common "$DEST" 2>&1 | tail -2

cd "$DEST"

have_commit() { git cat-file -e "${DEVICE_COMMIT}^{commit}" 2>/dev/null; }

echo "==> 分支 HEAD: $(git log -1 --format='%h %ad %s' --date=short)"

if ! have_commit; then
    for depth in 500 2000 6000; do
        echo "==> 加深历史 depth=$depth 以定位 $DEVICE_COMMIT"
        git fetch --deepen="$depth" origin "$BRANCH" >/dev/null 2>&1 || true
        have_commit && break
    done
fi

if ! have_commit; then
    echo "==> 仍未取到，改为完整历史（会慢几分钟）"
    git fetch --unshallow origin "$BRANCH" >/dev/null 2>&1 || true
fi

if have_commit; then
    git checkout -q "$DEVICE_COMMIT"
    echo "==> 已切到设备提交 $(git rev-parse --short HEAD)"
else
    echo "!! 整个历史里都没有 $DEVICE_COMMIT —— 设备内核可能来自厂商私有分支"
    echo "!! 保留分支 HEAD，ABI 比对会告出差异；届时需要向小米索取该构建的内核源码"
fi

PATCHLEVEL=$(awk -F'= *' '/^PATCHLEVEL/{print $2}' Makefile)
SUBLEVEL=$(awk -F'= *' '/^SUBLEVEL/{print $2}' Makefile)
echo "==> 源码版本 6.$PATCHLEVEL.$SUBLEVEL"
if [ "$PATCHLEVEL" != "18" ] || [ "$SUBLEVEL" != "$EXPECT_SUBLEVEL" ]; then
    echo "!! 期望 6.18.$EXPECT_SUBLEVEL，实际 6.$PATCHLEVEL.$SUBLEVEL"
    if have_commit; then
        echo "!! 设备提交本身就是这个版本，说明 EXPECT_SUBLEVEL 设错了"
        exit 1
    fi
    echo "!! 没有设备提交时不允许用别的版本编译，终止"
    exit 1
fi

echo "==> 实际提交 $(git rev-parse --short HEAD)"
