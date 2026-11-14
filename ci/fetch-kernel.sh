#!/usr/bin/env bash
# 取得用于编译的内核源码。
#
# 事实（已实测，不是推测）：
#   - 公开仓库 android17-6.18 的历史覆盖 2025-12-19 .. 2026-11-13（9727 个提交）
#   - 其中包含 5a4f1906f（6.18.21, 2026-11-06）
#   - 但不包含设备那个 284297031c53
# 结论：小米在 AOSP 6.18.21 之上加了自己的提交，SUBLEVEL 仍是 21、hash 变了，
# 所以公开仓库里不会有那个提交。用 5a4f1906f 作基线，差异由 BTF 比对量化。
set -euo pipefail

BRANCH="${BRANCH:-android17-6.18}"
BASE_COMMIT="${BASE_COMMIT:-5a4f1906ff98323c5a56a9290e43a6a1d295d699}"
EXPECT_SUBLEVEL="${EXPECT_SUBLEVEL:-21}"
DEST="${DEST:-kernel}"
# 默认走 GitHub 镜像；它同步了 kernel/common 全部分支，但注意：曾出现过某个分支
# 是旧快照（SUBLEVEL=0）的情况，所以下面有版本校验兜底。失败则退回 googlesource。
# 主源用 googlesource（权威且稳定）；GitHub 镜像曾出现某分支是旧快照的情况，只作备份。
PRIMARY="${PRIMARY:-https://android.googlesource.com/kernel/common}"
FALLBACK="${FALLBACK:-https://github.com/aosp-mirror/kernel_common.git}"

rm -rf "$DEST"

clone() {
    echo "==> clone $1 ($BRANCH, depth=2500)"
    git clone --depth=2500 --branch "$BRANCH" "$1" "$DEST" 2>&1 | tail -2
}

if ! clone "$PRIMARY"; then
    echo "==> 主源失败，改用镜像 $FALLBACK"
    rm -rf "$DEST"
    clone "$FALLBACK"
fi

cd "$DEST"

if ! git cat-file -e "${BASE_COMMIT}^{commit}" 2>/dev/null; then
    echo "==> depth=2500 内没有基线提交，继续加深"
    git fetch --deepen=2500 origin "$BRANCH" >/dev/null 2>&1 || true
fi

if ! git cat-file -e "${BASE_COMMIT}^{commit}" 2>/dev/null; then
    echo "!! 取不到基线提交 $BASE_COMMIT —— 浅克隆没覆盖到，终止（不要用别的版本硬编）"
    exit 1
fi

git checkout -q "$BASE_COMMIT"
echo "==> 已切到基线提交 $(git rev-parse --short HEAD)  $(git log -1 --format='%ad %s' --date=short)"

PATCHLEVEL=$(awk -F'= *' '/^PATCHLEVEL/{print $2}' Makefile)
SUBLEVEL=$(awk -F'= *' '/^SUBLEVEL/{print $2}' Makefile)
echo "==> 源码版本 6.$PATCHLEVEL.$SUBLEVEL"
if [ "$PATCHLEVEL" != "18" ] || [ "$SUBLEVEL" != "$EXPECT_SUBLEVEL" ]; then
    echo "!! 期望 6.18.$EXPECT_SUBLEVEL，实际 6.$PATCHLEVEL.$SUBLEVEL —— 终止"
    exit 1
fi

echo "==> 说明：设备构建提交 284297031c53 属于小米私有分支，公开仓库不可得；"
echo "==>      本构建基于 AOSP 6.18.21，厂商差异由 btf_compare 给出量化结果。"
