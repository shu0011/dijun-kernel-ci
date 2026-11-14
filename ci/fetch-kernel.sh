#!/usr/bin/env bash
# 拉取 android17-6.18 内核源码。
# 只用 android.googlesource.com（权威）；GitHub 的 aosp-mirror 分支是旧的，
# 会让 SUBLEVEL 变成 0，绝对不能当主源。
# 拉完立刻校验版本：不是 6.18.21 就直接失败，避免在错误的树上编译半小时。
set -euo pipefail

DEVICE_COMMIT="${DEVICE_COMMIT:-284297031c53}"
BRANCH="${BRANCH:-android17-6.18}"
EXPECT_SUBLEVEL="${EXPECT_SUBLEVEL:-21}"
DEST="${DEST:-kernel}"

rm -rf "$DEST"

echo "==> git clone android.googlesource.com/kernel/common ($BRANCH)"
git clone --depth=1 --branch "$BRANCH" \
    https://android.googlesource.com/kernel/common "$DEST" 2>&1 | tail -3

cd "$DEST"
echo "==> 分支 HEAD: $(git log -1 --format='%h %ad %s' --date=short)"

SUBLEVEL=$(awk -F'= *' '/^SUBLEVEL/{print $2}' Makefile)
PATCHLEVEL=$(awk -F'= *' '/^PATCHLEVEL/{print $2}' Makefile)
echo "==> 源码版本 6.$PATCHLEVEL.$SUBLEVEL"
if [ "$SUBLEVEL" != "$EXPECT_SUBLEVEL" ]; then
    echo "!! 期望 6.$PATCHLEVEL.$EXPECT_SUBLEVEL，实际 6.$PATCHLEVEL.$SUBLEVEL —— 分支不对，终止"
    exit 1
fi

if git cat-file -e "${DEVICE_COMMIT}^{commit}" 2>/dev/null; then
    echo "==> 已包含设备提交 $DEVICE_COMMIT"
else
    echo "==> 浅克隆里没有 $DEVICE_COMMIT，补拉历史再试"
    git fetch --deepen=600 origin "$BRANCH" >/dev/null 2>&1 || true
    if git cat-file -e "${DEVICE_COMMIT}^{commit}" 2>/dev/null; then
        git checkout "$DEVICE_COMMIT"
        echo "==> 已切到设备提交 $DEVICE_COMMIT"
    else
        echo "!! 取不到 $DEVICE_COMMIT，保留分支 HEAD（ABI 比对会判定是否等价）"
    fi
fi

echo "==> 实际提交 $(git rev-parse --short HEAD)"
