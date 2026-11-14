#!/usr/bin/env bash
# 拉取 android17-6.18 内核源码。
# 优先 GitHub 镜像（Actions 上更快），失败退回 android.googlesource.com。
# 尽量对齐设备所用提交；取不到就用分支 HEAD —— 是否等价由后面的 BTF 比对给出答案。
set -euo pipefail

DEVICE_COMMIT="${DEVICE_COMMIT:-284297031c53}"
BRANCH="${BRANCH:-android17-6.18}"
DEST="${DEST:-kernel}"

rm -rf "$DEST"

clone() {
    echo "==> git clone $1"
    git clone --depth=1 --branch "$BRANCH" "$1" "$DEST" 2>&1 | tail -3
}

if ! clone https://github.com/aosp-mirror/kernel_common.git; then
    echo "==> GitHub 镜像失败，改用 android.googlesource.com"
    rm -rf "$DEST"
    clone https://android.googlesource.com/kernel/common
fi

cd "$DEST"
echo "==> 分支 HEAD: $(git log -1 --format='%h %ad %s' --date=short)"

if git cat-file -e "${DEVICE_COMMIT}^{commit}" 2>/dev/null; then
    echo "==> 已包含设备提交 $DEVICE_COMMIT"
else
    echo "==> 浅克隆里没有 $DEVICE_COMMIT，补拉历史再试"
    git fetch --deepen=800 origin "$BRANCH" >/dev/null 2>&1 || true
    if git cat-file -e "${DEVICE_COMMIT}^{commit}" 2>/dev/null; then
        git checkout "$DEVICE_COMMIT"
        echo "==> 已切到设备提交 $DEVICE_COMMIT"
    else
        echo "!! 取不到 $DEVICE_COMMIT，保留分支 HEAD"
    fi
fi

echo "==> 源码版本"
grep -E '^VERSION|^PATCHLEVEL|^SUBLEVEL' Makefile
echo "==> 实际提交 $(git rev-parse --short HEAD)"
