#!/usr/bin/env bash
# 把 maxsteeel/nomount 的 kernel 源码以 built-in 方式集成进 GKI 内核。
# 参考上游 kernel/setup.sh 的 Method 3，但用拷贝而非 symlink（kallsyms 隐藏更稳），
# 并锁定到带 6.16+ 适配、协议 v23 的 tag（与 FinaSU 用户态兼容）。
#
# 入参：$1 = 内核源码根目录（$SRC）。
# 由 ci/integrate.sh 和 ci/integrate_finasu.sh 在收尾前调用，两个变体都编入 nomount。
set -euo pipefail

SRC="${1:?用法: integrate_nomount.sh <kernel-src-root>}"
SRC="$(cd "$SRC" && pwd)"

NOMOUNT_TAG="${NOMOUNT_TAG:-v2.3.1}"
NOMOUNT_REPO="${NOMOUNT_REPO:-https://github.com/maxsteeel/nomount}"
WORK="${NOMOUNT_WORK:-/tmp/nomount-src-$$}"

echo "==> [nomount] 集成 built-in (tag ${NOMOUNT_TAG})"

# 取指定 tag 的 kernel/src 源码（浅克隆单 tag，避免拉全历史耗时/超时）
rm -rf "$WORK"
git clone --depth 1 --branch "$NOMOUNT_TAG" "$NOMOUNT_REPO" "$WORK" >/dev/null 2>&1 \
  || { echo "!! [nomount] clone $NOMOUNT_TAG 失败"; rm -rf "$WORK"; exit 1; }

[ -f "$WORK/kernel/src/nomount.c" ] || { echo "!! [nomount] 源码缺 nomount.c"; rm -rf "$WORK"; exit 1; }

# 1) 拷源码到 fs/nomount（实体目录，不用 symlink）
mkdir -p "$SRC/fs/nomount"
cp -f "$WORK/kernel/src/"* "$SRC/fs/nomount/"

# 2) fs/Makefile 加 obj-$(CONFIG_NOMOUNT) += nomount/
if ! grep -q 'nomount/' "$SRC/fs/Makefile"; then
    printf '\nobj-$(CONFIG_NOMOUNT) += nomount/\n' >> "$SRC/fs/Makefile"
fi

# 3) fs/Kconfig 加 source（插在最后一个 endmenu 前，与上游脚本一致）
if ! grep -q 'source "fs/nomount/Kconfig"' "$SRC/fs/Kconfig"; then
    awk '
        /^endmenu/ { last = NR }
        { lines[NR] = $0 }
        END {
            for (i = 1; i <= NR; i++) {
                if (i == last) print "source \"fs/nomount/Kconfig\""
                print lines[i]
            }
        }
    ' "$SRC/fs/Kconfig" > "$SRC/fs/Kconfig.tmp" && mv "$SRC/fs/Kconfig.tmp" "$SRC/fs/Kconfig"
fi

rm -rf "$WORK"

# 校验
grep -q 'source "fs/nomount/Kconfig"' "$SRC/fs/Kconfig" || { echo "!! [nomount] Kconfig 未写入"; exit 1; }
grep -q 'nomount/' "$SRC/fs/Makefile" || { echo "!! [nomount] Makefile 未写入"; exit 1; }
[ -f "$SRC/fs/nomount/nomount.c" ] || { echo "!! [nomount] nomount.c 缺失"; exit 1; }

echo "==> [nomount] built-in 集成完成（CONFIG_NOMOUNT，Kconfig default y）"
