#!/usr/bin/env bash
# 集成 SukiSU + SUSFS 的 SELinux 隐藏。
#
# KSU 部分严格按官方指南来（docs/guide/how-to-integrate.md）：
#   curl -LSs .../kernel/setup.sh | bash -s <branch>
# 官方脚本负责 clone、链到 drivers/kernelsu、改 drivers/Makefile 与 drivers/Kconfig。
# 之前手写这套搬运，在 symlink、obj- 重复、版本串上连踩三个坑，没必要重复。
#
# 分支：
#   main     kprobe/kretprobe + sys_enter tracepoint 运行时注册（built-in 也照注册）
#   builtin  不注册 kprobe，需在内核源码手动调用 hook 入口 —— 想让
#            kprobes/list 彻底干净必须用它，但要改 execveat/faccessat/stat/read
#            等七处，先让系统能起来再切
set -euo pipefail

# 必须转成绝对路径：下面会 cd "$SRC"，之后再拿相对路径拼 "$SRC/drivers/..."
# 就会变成 kernel/kernel/drivers/...，symlink 检查全部落空。
SRC="$(cd "${SRC:-kernel}" && pwd)"
KSU_BRANCH="${KSU_BRANCH:-main}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> A 按官方指南集成 KernelSU（分支 $KSU_BRANCH）"
cd "$SRC"
curl -LSs "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh" \
    | bash -s "$KSU_BRANCH"

echo "==> B symlink 换成实目录"
# setup.sh 用 ln -s 链过去。打 SUSFS 补丁会污染上游仓库，而且 kbuild 在
# symlink 下解析 $(src) 容易出岔子，换成实拷贝。
if [ -L "$SRC/drivers/kernelsu" ]; then
    target=$(readlink -f "$SRC/drivers/kernelsu")
    rm -f "$SRC/drivers/kernelsu"
    cp -aL "$target" "$SRC/drivers/kernelsu"
    echo "    $target -> drivers/kernelsu"
fi
[ -d "$SRC/drivers/kernelsu" ] || { echo "!! drivers/kernelsu 不存在"; exit 1; }

echo "==> C 注册 CONFIG_KSU_SUSFS"
# 上游没有 SUSFS 开关，补一个。放 drivers/Kconfig 而非 kernelsu 的 Kconfig，
# 让 KSU 目录保持与上游一致，方便日后 diff。
python3 - "$SRC/drivers/Kconfig" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
if 'config KSU_SUSFS' in s:
    print("    已存在，跳过")
    sys.exit(0)
block = """
config KSU_SUSFS
	bool "SUSFS (SELinux hiding only)"
	depends on KSU
	default y
	help
	  SUSFS 的 SELinux 隐藏：伪造 getenforce 返回值、拦截 /sys/fs/selinux
	  读写路径、过滤 AVC 日志里的 ksu 痕迹。不含 sus_path / sus_mount /
	  open_redirect 这些必须改 VFS 的功能。

"""
i = s.rfind("endmenu")
if i < 0:
    s = s + block
else:
    s = s[:i] + block + s[i:]
open(p, "w").write(s)
print("    KSU_SUSFS 已插入 drivers/Kconfig 的 endmenu 之前")
PYEOF

echo "==> D 合 SUSFS 的 SELinux 补丁"
patch -p1 -d "$SRC" --forward < "$HERE/patches/susfs-selinux.patch"

echo "==> E 加桥接层"
cp "$HERE/patches/susfs_bridge.c" "$SRC/fs/susfs_bridge.c"
grep -q 'susfs_bridge' "$SRC/fs/Makefile" || \
    printf '\nobj-$(CONFIG_KSU_SUSFS) += susfs_bridge.o\n' >> "$SRC/fs/Makefile"

echo "==> F 导出 KSU selinux_hide 的状态符号"
# SUSFS 的 hooks.c 补丁要读：
#   extern bool ksu_selinux_hide_running __read_mostly;
# 这几个在 KSU 里是 static，编译期各文件互不干扰，链接时才报 undefined。
SH="$SRC/drivers/kernelsu/feature/selinux_hide.c"
python3 - "$SH" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
subs = [
    ("static bool ksu_selinux_hide_running __read_mostly = false;",
     "bool ksu_selinux_hide_running __read_mostly = false;"),
    ("static DEFINE_STATIC_KEY_FALSE(fake_status_initialize_key);",
     "void initialize_fake_status(void);\nDEFINE_STATIC_KEY_FALSE(fake_status_initialize_key);"),
    ("static struct page *fake_status = NULL;",
     "struct page *fake_status;"),
    ("static void initialize_fake_status()",
     "void initialize_fake_status(void)"),
]
for old, new in subs:
    if old not in s:
        sys.exit("selinux_hide.c 里找不到: " + old)
    s = s.replace(old, new, 1)
open(p, "w").write(s)
print("    已导出 4 个符号")
PYEOF

echo "==> G 固定 KSU 版本串"
# Kbuild 里 KSU_VERSION_FULL 靠 git describe 拼，分支名会是 main。
# 用户要 @shushu，直接写死；sha 和 tag 从 setup.sh 克隆的仓库里读。
KSU_SHA=$(git -C "$SRC/KernelSU" rev-parse --short=8 HEAD 2>/dev/null || echo unknown)
KSU_TAG=$(git -C "$SRC/KernelSU" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)
[ -n "${KSU_TAG:-}" ] || KSU_TAG=4.3.0
sed -i "s|^KSU_VERSION_FULL := .*|KSU_VERSION_FULL := v${KSU_TAG}-${KSU_SHA}@shushu|" \
    "$SRC/drivers/kernelsu/Kbuild"
grep -n 'KSU_VERSION_FULL :=' "$SRC/drivers/kernelsu/Kbuild"

echo "==> G2 让 KSU 的 selinux_hide 不再运行期改 write_op[]"
# ksu_selinux_hide_enable() 会往 selinuxfs 的 write_op[] 里塞函数指针，
# 而那是个 const 数组（.rodata）。module 模式下 ksu_patch_text 一律 EFAULT(-14)，
# 只能退到 kprobe；built-in 模式下这次写入会落到只读数据上，轻则无效重则写坏
# 相邻字段 —— 打开开关后开机即崩就是这个位置。
# 而 SUSFS 的补丁已经在编译期把 sel_write_context / sel_write_access /
# setprocattr 全部换成了 handle_* 包装，运行期这笔 patch 纯属重复劳动。
python3 - "$SRC/drivers/kernelsu/feature/selinux_hide.c" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
needle = """    if (!backup_sepolicy) {
        pr_err("no backup sepolicy available, please save feature and reboot to retry!\\n");
        return -EAGAIN;
    }
"""
assert s.count(needle) == 1, "selinux_hide.c 里找不到 backup_sepolicy 检查"
patch = needle + """
#ifdef CONFIG_KSU_SUSFS
    /* SUSFS 在编译期已经接管 sel_write_context / sel_write_access / setprocattr，
       这里不能再去改 const 的 write_op[]，否则 built-in 下写坏只读页 → 开机崩溃。
       只保留 backup sepolicy 与 fake status，running 由 feature_set 置位。 */
    ksu_selinux_hide_keep_backup = true;
    pr_info("selinux_hide: CONFIG_KSU_SUSFS=y, skip runtime hooks (compile-time wrappers)\n");
    return 0;
#endif
"""
open(p, "w").write(s.replace(needle, patch, 1))
print("    selinux_hide.c: 已插入 CONFIG_KSU_SUSFS 早退分支")
PYEOF

echo "==> H 集成完成"
echo "    KSU 分支配置文件: $(ls "$SRC/drivers/kernelsu"/Kbuild "$SRC/drivers/kernelsu"/Makefile 2>/dev/null | tr '\n' ' ')"
echo "    SELinux 补丁命中: $(grep -c 'CONFIG_KSU_SUSFS' "$SRC/security/selinux/status.c" 2>/dev/null || echo 0) 处 status.c"
