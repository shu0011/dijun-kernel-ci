#!/usr/bin/env bash
# 取得内核源码：AOSP kernel/common 的 6.18.21 快照分支（android17-6.18-2026-06）。
#
# 为什么用这一条：
#   - android17-6.18（主分支）已经漂到 6.18.33 并会继续往前走，不可复现
#   - 冻结快照按日期切：2026-04→6.18.20、2026-06→6.18.21、2026-09→6.18.32
#   - 设备是 6.18.21，所以要 2026-06 这份。之前用 2026-09（6.18.32）虽然 BTF
#     布局对得上，但导出符号 CRC 与厂商 .ko 的 __versions 不一致，
#     check_version() 拒载 vendor_dlkm 里的驱动（含 UFS），init 挂不到 /data。
#
# 实测（刷了作者 LingLuo17 的 6.18.21 包）：启动后 dmesg 里
#   "disagrees about version of symbol" 出现 0 次
# 而 6.18.32 版是 1 次（securelib 的 module_layout）。CRC 必须同版本才对得上。
set -euo pipefail

BRANCH="${BRANCH:-android17-6.18-2026-06}"
EXPECT_SUBLEVEL="${EXPECT_SUBLEVEL:-21}"
DEST="${DEST:-kernel}"
PRIMARY="${PRIMARY:-https://android.googlesource.com/kernel/common}"
FALLBACK="${FALLBACK:-https://github.com/aosp-mirror/kernel_common.git}"

rm -rf "$DEST"

# 优先用 repo + kernel/manifest，与作者的构建方式完全一致。
# manifest 分支（common-android17-6.18-2026-06）里写的 kernel/common revision
# 与直接 clone 分支 HEAD 可能不是同一个 commit —— 如果不同，编出来的
# struct module 等类型虽然 sizeof 一致，gendwarfksyms 算出的 CRC 却不一样。
fetch_by_repo() {
    command -v repo >/dev/null 2>&1 || return 1
    local work=/tmp/ksrc-ws
    rm -rf "$work"; mkdir -p "$work"; cd "$work" || return 1
    repo init -u https://android.googlesource.com/kernel/manifest \
              -b "common-${BRANCH}" --depth=1 --no-repo-verify -q 2>/dev/null || return 1
    repo sync -c -j4 --no-tags --no-clone-bundle -q common 2>/dev/null || return 1
    [ -d "$work/common" ] || return 1
    mv "$work/common" "$OLDPWD/$DEST"
    cd "$OLDPWD" || return 1
    echo "==> repo 拉取完成，commit $(git -C "$DEST" rev-parse --short HEAD 2>/dev/null)"
    return 0
}

clone() {
    echo "==> clone $1 ($BRANCH)"
    # googlesource 偶尔在 "Updating files" 阶段断掉（实测 43% 处），重试即可
    for attempt in 1 2 3; do
        if git clone --depth=1 --branch "$BRANCH" "$1" "$DEST"; then
            return 0
        fi
        echo "    clone 中断（第 $attempt 次），清理后重试"
        rm -rf "$DEST"
        sleep 10
    done
    return 1
}

if fetch_by_repo; then
    :
elif clone "$PRIMARY"; then
    :
else
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
