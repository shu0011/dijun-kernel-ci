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

echo "==> [finasu] 版本品牌串固定为 @shushu"
python3 - "$SRC/KernelSU/kernel/Kbuild" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "@$(KSU_VERSION_BRANCH)"
if old in s:
    open(p, "w").write(s.replace(old, "@shushu", 1))
    print("    KSU_VERSION_FULL 中的分支段已固定为 @shushu")
else:
    print("    !! 未找到 @$(KSU_VERSION_BRANCH)，跳过（仅影响版本显示）")
PY

echo "==> [finasu] 应用 SUSFS SELinux 补丁"
patch -p1 -d "$SRC" --forward < "$HERE/patches/susfs-selinux.patch"

echo "==> [finasu] 跳过 bridge（FinaSU selinux.c 已提供 SID 与 ksu_domain 判定）"
# SukiSU 模式下 bridge 负责补 susfs_ksu_sid/susfs_priv_app_sid/
# susfs_is_current_ksu_domain；FinaSU 的 selinux/selinux.c 已经原生提供，
# 再编 bridge 会 duplicate symbol。

echo "==> [finasu] 应用 SUSFS v2.4.0 内核侧移植"
KSU_VARIANT=finasu bash "$HERE/ci/susfs_upstream.sh" "$SRC" "$HERE"

echo "==> [finasu] mount_view_filter 改走 SUSFS 号段挂载隐藏"
# 本机型 EL2 保护禁止 fixmap 改 rodata，FinaSU 的 ksu_patch_text 改
# proc_mounts_operations.open 会返回 -EFAULT（dmesg 实测 -14），
# 「隐藏挂载记录」因此永远启用失败。改成复用 SUSFS 的
# susfs_is_hide_sus_mnts_for_non_su_procs_enabled：
# 对非 su 进程隐藏 mnt_id >= DEFAULT_KSU_MNT_ID 的 root/模块挂载。
python3 - "$SRC/drivers/kernelsu/feature/mount_view_filter.c" <<'PYMVF'
import sys
p = sys.argv[1]
s = open(p).read()
GUARD = "#if defined(CONFIG_KSU_SUSFS) && defined(CONFIG_KSU_SUSFS_SUS_MOUNT)"
if "susfs_is_hide_sus_mnts_for_non_su_procs_enabled" not in s:
    inc = '#include "mount_view_filter.h"\n'
    assert s.count(inc) == 1, "mvf: include 锚点"
    s = s.replace(
        inc,
        inc
        + "\n" + GUARD + "\n"
        + "#include <linux/jump_label.h>\n"
        + "/* SUSFS 的号段挂载隐藏开关，定义在 fs/susfs.c */\n"
        + "extern struct static_key_false susfs_is_hide_sus_mnts_for_non_su_procs_enabled;\n"
        + "#endif\n",
        1,
    )

    old_get = (
        "static int ksu_mvf_feature_get(u64 *value)\n"
        "{\n"
        "    *value = READ_ONCE(ksu_mvf_enabled) ? 1 : 0;\n"
        "    return 0;\n"
        "}"
    )
    assert s.count(old_get) == 1, "mvf: get 锚点"
    new_get = (
        "static int ksu_mvf_feature_get(u64 *value)\n"
        "{\n"
        + GUARD + "\n"
        "    *value = static_branch_unlikely(&susfs_is_hide_sus_mnts_for_non_su_procs_enabled) ? 1 : 0;\n"
        "    return 0;\n"
        "#else\n"
        "    *value = READ_ONCE(ksu_mvf_enabled) ? 1 : 0;\n"
        "    return 0;\n"
        "#endif\n"
        "}"
    )
    s = s.replace(old_get, new_get, 1)

    old_set = (
        "static int ksu_mvf_feature_set(u64 value)\n"
        "{\n"
        "    bool enable = value != 0;\n"
        "    int ret = 0;\n"
        "\n"
        "    mutex_lock(&ksu_mvf_mutex);\n"
        "    if (enable) {\n"
        "        if (!smp_load_acquire(&ksu_mvf_enabled)) {\n"
        "            ret = ksu_mvf_resolve_symbols();\n"
        "            if (!ret)\n"
        "                ret = ksu_mvf_install_hooks();\n"
        "            if (!ret)\n"
        "                smp_store_release(&ksu_mvf_enabled, true);\n"
        "            else {\n"
        "                ksu_mvf_restore_hooks();\n"
        "                synchronize_rcu();\n"
        "            }\n"
        "        }\n"
        "    } else if (smp_load_acquire(&ksu_mvf_enabled)) {\n"
        "        smp_store_release(&ksu_mvf_enabled, false);\n"
        "        ret = ksu_mvf_restore_hooks();\n"
        "        synchronize_rcu();\n"
        "    }\n"
        "    mutex_unlock(&ksu_mvf_mutex);\n"
        "    return ret;\n"
        "}"
    )
    assert s.count(old_set) == 1, "mvf: set 锚点"
    new_set = (
        "static int ksu_mvf_feature_set(u64 value)\n"
        "{\n"
        + GUARD + "\n"
        "    if (value)\n"
        "        static_branch_enable(&susfs_is_hide_sus_mnts_for_non_su_procs_enabled);\n"
        "    else\n"
        "        static_branch_disable(&susfs_is_hide_sus_mnts_for_non_su_procs_enabled);\n"
        "    return 0;\n"
        "#else\n"
        "    bool enable = value != 0;\n"
        "    int ret = 0;\n"
        "\n"
        "    mutex_lock(&ksu_mvf_mutex);\n"
        "    if (enable) {\n"
        "        if (!smp_load_acquire(&ksu_mvf_enabled)) {\n"
        "            ret = ksu_mvf_resolve_symbols();\n"
        "            if (!ret)\n"
        "                ret = ksu_mvf_install_hooks();\n"
        "            if (!ret)\n"
        "                smp_store_release(&ksu_mvf_enabled, true);\n"
        "            else {\n"
        "                ksu_mvf_restore_hooks();\n"
        "                synchronize_rcu();\n"
        "            }\n"
        "        }\n"
        "    } else if (smp_load_acquire(&ksu_mvf_enabled)) {\n"
        "        smp_store_release(&ksu_mvf_enabled, false);\n"
        "        ret = ksu_mvf_restore_hooks();\n"
        "        synchronize_rcu();\n"
        "    }\n"
        "    mutex_unlock(&ksu_mvf_mutex);\n"
        "    return ret;\n"
        "#endif\n"
        "}"
    )
    s = s.replace(old_set, new_set, 1)
    open(p, "w").write(s)
    print("    mount_view_filter 已切换为 SUSFS 号段隐藏")
PYMVF

echo "==> [finasu] 校验关键内容"
grep -q 'susfs_owner_record' "$SRC/fs/susfs.c" || {
    echo "!! fs/susfs.c 缺少属主豁免实现（patches/upstream/fs/susfs.c 被改动？）"
    exit 1
}
grep -q '^config KSU_SUSFS$' "$SRC/drivers/kernelsu/Kconfig"

echo "==> [finasu] 完成：kernel_ksu_version=${KSU_VERSION} (${KSU_SHA})"
