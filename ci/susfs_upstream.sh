#!/usr/bin/env bash
# upstream-align：官方 SUSFS v2.4.0 原样移植
#
# 原则：能用官方实现的都用官方（susfs.c + 内核补丁的干净文件）；
#       6.18 上打不上的（namei/readdir/stat/namespace/memory）用我们已验证的等价实现。
#
# 本脚本在 integrate.sh 的 A~E 阶段（KSU 集成 + CONFIG + SELinux + bridge）之后运行，
# 负责：vendor 源码 → 官方补丁 → 6.18 适配 → 分发器/胶水 → 关闭自研模块。
set -euo pipefail

SRC="$1"
HERE="$2"
UP="$HERE/patches/upstream"

echo "==> [upstream] 关掉自研 SUSFS 模块（文件保留，仅不编译）"
# fs/Makefile 里自研模块的 obj 行全部注释掉
python3 - "$SRC" <<'PY'
import os, sys, re
p = os.path.join(sys.argv[1], "fs/Makefile")
s = open(p).read()
# 注意：susfs_bridge 必须继续编译 —— 阶段 D 的 SELinux 补丁 extern 了
# susfs_ksu_sid / susfs_priv_app_sid，且 SID 解析在它的 late_initcall 里。
for m in ("susfs_path", "susfs_kstat", "susfs_maps", "susfs_mount",
          "susfs_proc", "susfs_uname", "susfs_extra", "susfs_reboot"):
    s = re.sub(r"^(obj-\$\(CONFIG_KSU_SUSFS\) \+= %s\.o)$" % m,
               r"# [upstream-align] \1", s, flags=re.M)
open(p, "w").write(s)
print("    自研模块 obj 行已注释")
PY

echo "==> [upstream] 放入官方源码"
cp "$UP/fs/susfs.c" "$SRC/fs/susfs.c"
cp "$UP/include/linux/susfs.h" "$SRC/include/linux/susfs.h"
cp "$UP/include/linux/susfs_def.h" "$SRC/include/linux/susfs_def.h"
cp "$HERE/patches/susfs_upstream.c" "$SRC/fs/susfs_upstream.c"
cp "$HERE/patches/susfs_abi.h" "$SRC/include/linux/susfs_abi.h"
if ! grep -q 'susfs\.o' "$SRC/fs/Makefile"; then
    printf 'obj-$(CONFIG_KSU_SUSFS) += susfs.o susfs_upstream.o\n' >> "$SRC/fs/Makefile"
fi

echo "==> [upstream] 补齐官方 CONFIG 开关"
python3 - "$SRC/drivers/Kconfig" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
add = ""
for name, desc in [
    ("KSU_SUSFS_SUS_PATH", "sus_path hiding"),
    ("KSU_SUSFS_SUS_MOUNT", "sus_mount hiding"),
    ("KSU_SUSFS_SUS_KSTAT", "sus_kstat spoofing"),
    ("KSU_SUSFS_SUS_MAP", "sus_map hiding"),
    ("KSU_SUSFS_SPOOF_UNAME", "uname spoofing"),
    ("KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG", "cmdline/bootconfig spoofing"),
]:
    if "config %s\n" % name in s:
        continue
    add += ('\nconfig %s\n\tbool "SUSFS: %s"\n\tdepends on KSU_SUSFS\n\tdefault y\n'
            '\thelp\n\t  Upstream SUSFS %s.\n' % (name, desc, desc))
if add:
    i = s.rfind("endmenu")
    s = s[:i] + add + s[i:]
    open(p, "w").write(s)
    print("    已补齐 6 个 CONFIG")
else:
    print("    CONFIG 已齐")
PY


echo "==> [upstream] 瘦身 bridge（官方 susfs.c 已提供同名符号，避免重复定义）"
python3 - "$SRC" <<'PYB'
import os, sys
p = os.path.join(sys.argv[1], "fs/susfs_bridge.c")
s = open(p).read()
if "SUSFS_BRIDGE_TRIMMED" in s:
    raise SystemExit(0)
for old in [
"""bool susfs_is_current_ksu_domain(void)
{
	return is_ksu_domain();
}""",
"""bool susfs_is_sus_type_rcu(u32 sid)
{
	(void)sid;
	return false;
}""",
"""void susfs_spoof_avd_allowed_rcu(u32 s_type, u32 t_type, u32 c_type,
				 u32 *avd_allowed)
{
	(void)s_type;
	(void)t_type;
	(void)c_type;
	(void)avd_allowed;
}""",
"""DEFINE_STATIC_KEY_FALSE(susfs_is_avc_log_spoofing_enabled);""",
# 官方版本签名是 (void __user **)，与 bridge 的 (bool) 不同名不同参，共存必报重定义
"""void susfs_set_avc_log_spoofing(bool enabled)
{
	if (enabled)
		static_branch_enable(&susfs_is_avc_log_spoofing_enabled);
	else
		static_branch_disable(&susfs_is_avc_log_spoofing_enabled);

	pr_info("susfs: avc_log_spoofing %s\\n", enabled ? "enabled" : "disabled");
}""",
]:
    assert old in s, "bridge: 待删符号没找到:\n" + old[:40]
    s = s.replace(old, "/* [upstream-align] 由官方 fs/susfs.c 提供: " + old.split("(")[0].split()[-1] + " */", 1)
s = s.replace("bool susfs_is_current_ksu_domain(void);", "/* [upstream-align] 由 susfs_upstream.c 提供 */", 1)
s = s.replace("bool susfs_is_sus_type_rcu(u32 sid);", "/* [upstream-align] 由官方 susfs.c 提供 */", 1)
s = s.replace("""void susfs_spoof_avd_allowed_rcu(u32 s_type, u32 t_type, u32 c_type,
				 u32 *avd_allowed);""", "/* [upstream-align] 由官方 susfs.c 提供 */", 1)
s += "\n/* SUSFS_BRIDGE_TRIMMED */\n"
open(p, "w").write(s)
print("    bridge 已瘦身")
PYB

echo "==> [upstream] 应用官方内核补丁（排除 6.18 需适配与 KSU 专属 hunk）"
python3 - "$UP/kernel_patches/50_add_susfs_in_gki-android16-6.12.patch" "$SRC" <<'PYA'
import os, re, subprocess, sys, tempfile

patch_file, src = sys.argv[1], sys.argv[2]
# 不打：KSU 专属 hunk（exec/open/read_write/input）+ 6.18 需手工适配的文件
# + 我们保留自研实现的文件（namei/readdir/stat/namespace/memory/Makefile/reboot）
skip = {
    "fs/exec.c", "fs/open.c", "fs/read_write.c", "drivers/input/input.c",
    "fs/namei.c", "fs/readdir.c", "fs/stat.c", "fs/namespace.c",
    "mm/memory.c", "fs/Makefile", "kernel/reboot.c",
    # 阶段 D 的 SELinux 补丁已经改过这 5 个文件（同一份官方补丁的旧版本），
    # 再打官方新版必然冲突；功能由 D 提供。
    "security/selinux/avc.c", "security/selinux/hooks.c",
    "security/selinux/selinuxfs.c", "security/selinux/ss/services.c",
    "security/selinux/status.c",
    # task_mmu.c：官方 hunk 的上下文在 6.18 命中了别的函数（__VM_NO_COMPAT 是 6.12 的），
    # 模糊匹配插错位置 → 先跳过，sus_map 的展示钩子下一轮单独补。
    "fs/proc/task_mmu.c",
}
chunks, cur, name = [], [], None
for ln in open(patch_file).read().split("\n"):
    m = re.match(r"^diff --git a/(\S+) b/", ln)
    if m:
        if cur:
            chunks.append((name, "\n".join(cur) + "\n"))
        name, cur = m.group(1), []
    if name:
        cur.append(ln)
if cur:
    chunks.append((name, "\n".join(cur) + "\n"))

applied = 0
for name, body in chunks:
    if name in skip:
        continue
    with tempfile.NamedTemporaryFile("w", suffix=".patch", delete=False) as fh:
        fh.write(body)
        tmp = fh.name
    r = subprocess.run(["patch", "-p1", "-f", "-s", "-N", "-d", src],
                       stdin=open(tmp), capture_output=True, text=True)
    os.unlink(tmp)
    if r.returncode != 0:
        print("!! patch 失败: %s\n%s%s" % (name, r.stdout, r.stderr))
        sys.exit(1)
    applied += 1
print("    官方补丁已应用 %d 个文件（按 cwd 解析，避开仓库根）" % applied)
PYA

echo "    官方补丁已应用（15 个文件）"

echo "==> [upstream] 6.18 适配：statfs.c 两个 wrapper 补前置原型（-Wmissing-prototypes）"
python3 - "$SRC/fs/statfs.c" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
proto = (
    "#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT\n"
    "/* 6.18 -Werror,-Wmissing-prototypes：官方 6.12 只在 susfs.c(使用方)声明这两个\n"
    " * wrapper，定义方 statfs.c 自身无原型。补定义侧原型，签名与官方 extern 一致。 */\n"
    "extern int statfs_by_dentry_wrapper(struct dentry *dentry, struct kstatfs *buf);\n"
    "extern int calculate_f_flags_wrapper(struct vfsmount *mnt);\n"
    "#endif\n"
)
anchor = "int statfs_by_dentry_wrapper(struct dentry *dentry, struct kstatfs *buf)"
if "extern int statfs_by_dentry_wrapper" in s:
    print("    statfs.c 原型已存在，跳过")
elif anchor in s:
    s = s.replace(anchor, proto + anchor, 1)
    open(p, "w").write(s)
    print("    statfs.c 已补 2 个 wrapper 原型")
else:
    print("    !! statfs.c 没找到 wrapper 定义，跳过")
PY

echo "==> [upstream] 6.18 适配：susfs_def.h 的三个 TIF 闸门"
python3 - "$SRC/include/linux/susfs_def.h" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = """static inline bool susfs_is_current_proc_umounted(void) {
	return (likely(test_thread_flag(TIF_PROC_UMOUNTED)));
}"""
new = """/* [upstream-align] SukiSU-Nova 没有 TIF_PROC_UMOUNTED / TIF_PROC_NO_SU 线程标志，
 * 改成问 KSU：ksu_uid_should_umount() 的语义与官方闸门一致（只对会被 umount 模块的
 * app 进程隐藏，已排除管理器与已授权 su 的应用）。 */
extern bool susfs_ksu_proc_umounted(void);
static inline bool susfs_is_current_proc_umounted(void) {
	return susfs_ksu_proc_umounted();
}"""
assert old in s, "susfs_def.h: umounted 闸门锚点没找到"
s = s.replace(old, new, 1)

old2 = """static inline bool susfs_is_current_proc_no_su(void) {
	return (likely(test_thread_flag(TIF_PROC_NO_SU)));
}"""
new2 = """extern bool susfs_is_current_ksu_domain(void);
static inline bool susfs_is_current_proc_no_su(void) {
	return !susfs_is_current_ksu_domain();
}"""
assert old2 in s, "susfs_def.h: no_su 闸门锚点没找到"
s = s.replace(old2, new2, 1)

# 第三个闸门：SUSFS_IS_INODE_OPEN_REDIRECT / SUSFS_IS_INODE_SUS_MAP 都依赖它，
# 同样要看 TIF_PROC_UMOUNTED，不换掉这两个宏就永远为 false（功能静默失效）。
old3 = """static inline bool susfs_is_current_proc_umounted_app(void) {
	return (likely(test_thread_flag(TIF_PROC_UMOUNTED)) &&
			current_uid().val >= 10000);
}"""
new3 = """static inline bool susfs_is_current_proc_umounted_app(void) {
	return susfs_ksu_proc_umounted() && current_uid().val >= 10000;
}"""
assert old3 in s, "susfs_def.h: umounted_app 闸门锚点没找到"
s = s.replace(old3, new3, 1)
open(p, "w").write(s)
print("    闸门已替换为 KSU 判定（含 umounted_app）")
PY

echo "==> [upstream] 6.18 适配：fs/stat.c（SUS_KSTAT 官方钩子）"
python3 - "$SRC" <<'PY'
import os, sys
SRC = sys.argv[1]
p = os.path.join(SRC, "fs/stat.c")
s = open(p).read()
if "susfs_sus_kstat_spoof_generic_fillattr" in s:
    print("    已注入过")
    raise SystemExit(0)

inc = '#include "mount.h"\n'
assert inc in s, "stat.c: 找不到 #include \"mount.h\""
decl = inc + """
#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
#include <linux/susfs_def.h>	/* STATX_SUS_KSTAT / susfs_is_current_app_uid */
extern bool susfs_is_inode_sus_kstat(struct inode *inode, bool *out_is_fuse);
extern void susfs_sus_kstat_spoof_generic_fillattr(struct inode *inode, struct kstat *stat, u32 result_mask);
extern u64 susfs_get_non_sus_mnt_id_unique_from_mnt(struct mount *orig_mnt);
#endif
"""
s = s.replace(inc, decl, 1)

anchor = "\tidmap = mnt_idmap(path->mnt);\n"
assert anchor in s, "stat.c: idmap 锚点没找到"
gate = anchor + """#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
	if (susfs_is_current_app_uid()) {
		bool is_fuse = false;

		if (susfs_is_inode_sus_kstat(inode, &is_fuse)) {
			if (!is_fuse) {
				stat->mnt_id = real_mount(path->mnt)->mnt_id;
				stat->result_mask |= STATX_SUS_KSTAT;
			}
			stat->mnt_id = real_mount(path->mnt)->mnt_id;
			stat->result_mask |= STATX_SUS_KSTAT_FUSE;
		}
	}
#endif
"""
s = s.replace(anchor, gate, 1)

# getattr / generic_fillattr 之后覆盖并提前返回（官方语义，跳过 bdev_statx）
anchor2 = """	if (S_ISBLK(stat->mode))
		bdev_statx(path, stat, request_mask);
"""
assert anchor2 in s, "stat.c: bdev_statx 锚点没找到"
spoof = """#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
	if (stat->result_mask & STATX_SUS_KSTAT) {
		susfs_sus_kstat_spoof_generic_fillattr(inode, stat, STATX_SUS_KSTAT);
		return 0;
	}
	if (stat->result_mask & STATX_SUS_KSTAT_FUSE) {
		susfs_sus_kstat_spoof_generic_fillattr(inode, stat, STATX_SUS_KSTAT_FUSE);
		return 0;
	}
#endif
"""
s = s.replace(anchor2, spoof + anchor2, 1)
open(p, "w").write(s)
print("    vfs_getattr_nosec 已注入")
PY

echo "==> [upstream] 6.18 适配：fs/namespace.c（号段分配 + 官方 non-sus 辅助函数）"
python3 - "$SRC" <<'PY'
import os, sys
SRC = sys.argv[1]
p = os.path.join(SRC, "fs/namespace.c")
s = open(p).read()
if "susfs_get_non_sus_mnt_id_from_mnt" in s:
    print("    已注入过")
    raise SystemExit(0)

# 1) 头文件 + 号段常量（M 阶段在上游模式被跳过，这里自己补齐）
preamble = (
    "#include <linux/susfs_def.h>\n"
    "#include <linux/atomic.h>\n"
    "extern bool susfs_is_current_ksu_domain(void);\n"
    "#ifndef VFSMOUNT_MNT_FLAGS_KSU_UNSHARED_MNT\n"
    "#define VFSMOUNT_MNT_FLAGS_KSU_UNSHARED_MNT 0x80000000u\n"
    "#endif\n"
    "#ifndef CL_COPY_MNT_NS\n"
    "#define CL_COPY_MNT_NS BIT(25)\n"
    "#endif\n")
# 必须插在内核其它 include 之后：susfs_def.h 里用到 current_uid()/set_thread_flag()，
# 放在文件最前面会因为 cred.h / sched 头还没进来而报 undeclared。
lines = s.split("\n")
last = max(i for i, ln in enumerate(lines[:80]) if ln.startswith("#include <linux/"))
assert last > 0, "namespace.c: include 锚点没找到"
lines.insert(last + 1, preamble.rstrip("\n"))
s = "\n".join(lines)

# 2) 号段计数器（官方用独立 IDA；6.18 的 xarray 不能在里面做 GFP_KERNEL 分配）
alloc_anchor = ("static int mnt_alloc_id(struct mount *mnt)\n"
                "{\n"
                "\tint res;\n"
                "\n"
                "\txa_lock(&mnt_id_xa);\n")
assert alloc_anchor in s, "namespace.c: mnt_alloc_id 锚点没找到"
alloc_block = (
    "#ifdef CONFIG_KSU_SUSFS\n"
    "/* 号段挂载的 id 用独立计数器（对齐上游独立 IDA 的做法），不进 mnt_id_xa。\n"
    " * 绝不能在 xa_lock 内做 GFP_KERNEL 分配：copy_mnt_ns 持有 namespace_sem 时\n"
    " * 会走到这里，高 index 首次分配要建 xarray 节点 → 回收 → 与 unshare 互锁。 */\n"
    "static atomic_t susfs_mnt_id_ctr = ATOMIC_INIT(1);\n"
    "static int susfs_mnt_alloc_id_range(struct mount *mnt)\n"
    "{\n"
    "\tint id = atomic_inc_return(&susfs_mnt_id_ctr) + DEFAULT_KSU_MNT_ID;\n"
    "\n"
    "\tif (id <= 0 || id > INT_MAX)\n"
    "\t\treturn -ENOSPC;\n"
    "\tmnt->mnt_id = id;\n"
    "\tmnt->mnt_id_unique = ++mnt_id_ctr;\n"
    "\tmnt->mnt.mnt_flags |= VFSMOUNT_MNT_FLAGS_KSU_UNSHARED_MNT;\n"
    "\treturn 0;\n"
    "}\n"
    "#endif\n"
    "\n"
    "static int mnt_alloc_id(struct mount *mnt)\n"
    "{\n"
    "\tint res;\n"
    "\n"
    "#ifdef CONFIG_KSU_SUSFS\n"
    "\tif (susfs_is_current_ksu_domain())\n"
    "\t\treturn susfs_mnt_alloc_id_range(mnt);\n"
    "#endif\n"
    "\txa_lock(&mnt_id_xa);\n")
s = s.replace(alloc_anchor, alloc_block, 1)

# 3) mnt_free_id：号段 id 不在 xa 里，靠标记跳过回收
free_anchor = ("static void mnt_free_id(struct mount *mnt)\n"
               "{\n"
               "\txa_erase(&mnt_id_xa, mnt->mnt_id);\n"
               "}\n")
assert free_anchor in s, "namespace.c: mnt_free_id 锚点没找到"
free_block = ("static void mnt_free_id(struct mount *mnt)\n"
              "{\n"
              "#ifdef CONFIG_KSU_SUSFS\n"
              "\tif (unlikely(mnt->mnt.mnt_flags & VFSMOUNT_MNT_FLAGS_KSU_UNSHARED_MNT))\n"
              "\t\treturn;\n"
              "#endif\n"
              "\txa_erase(&mnt_id_xa, mnt->mnt_id);\n"
              "}\n")
s = s.replace(free_anchor, free_block, 1)

# 4) clone_mnt：只 erase 不分配
clone_anchor = ("\tmnt = alloc_vfsmnt(old->mnt_devname);\n"
                "\tif (!mnt)\n"
                "\t\treturn ERR_PTR(-ENOMEM);\n")
assert clone_anchor in s, "namespace.c: clone_mnt 锚点没找到"
clone_block = clone_anchor + (
    "#ifdef CONFIG_KSU_SUSFS\n"
    "\tif (mnt->mnt_id < DEFAULT_KSU_MNT_ID &&\n"
    "\t    old->mnt_id >= DEFAULT_KSU_MNT_ID) {\n"
    "\t\txa_lock(&mnt_id_xa);\n"
    "\t\t__xa_erase(&mnt_id_xa, mnt->mnt_id);\n"
    "\t\txa_unlock(&mnt_id_xa);\n"
    "\t\tif (flag & CL_COPY_MNT_NS) {\n"
    "\t\t\tmnt->mnt_id = old->mnt_id;\n"
    "\t\t} else {\n"
    "\t\t\tint sus_id = atomic_inc_return(&susfs_mnt_id_ctr) + DEFAULT_KSU_MNT_ID;\n"
    "\n"
    "\t\t\tmnt->mnt_id = (sus_id > 0 && sus_id < INT_MAX) ? sus_id : old->mnt_id;\n"
    "\t\t}\n"
    "\t\tmnt->mnt.mnt_flags |= VFSMOUNT_MNT_FLAGS_KSU_UNSHARED_MNT;\n"
    "\t}\n"
    "#endif\n")
s = s.replace(clone_anchor, clone_block, 1)

# 5) 追加官方三个 non-sus 辅助函数（proc_namespace / proc/fd / statfs 都要用）
assert "fs_initcall(init_fs_namespace_sysctls);" in s, "namespace.c: 尾部锚点没找到"
tail = """
#ifdef CONFIG_KSU_SUSFS
/* 官方实现（6.12 patch 尾部），原样保留 */
/* 6.18 构建开了 -Werror,-Wmissing-prototypes：非 static 的全局函数定义前必须有原型。
 * 官方 6.12 在使用方(fd.c/stat.c/statfs.c)声明，但定义方 namespace.c 无前置声明；
 * 这里补上定义侧原型，签名与官方 extern 完全一致。 */
extern int susfs_get_non_sus_mnt_id_from_mnt(struct mount *orig_mnt);
extern u64 susfs_get_non_sus_mnt_id_unique_from_mnt(struct mount *orig_mnt);
extern struct vfsmount *susfs_get_non_sus_vfsmnt_from_vfsmnt(struct vfsmount *vfsmnt);
int susfs_get_non_sus_mnt_id_from_mnt(struct mount *orig_mnt)
{
	struct mount *mnt = orig_mnt;
	int mnt_id;

	if (mnt->mnt_id < DEFAULT_KSU_MNT_ID)
		return mnt->mnt_id;

	lock_mount_hash();
	for (; mnt && mnt->mnt_parent && mnt != mnt->mnt_parent &&
	       mnt->mnt_id >= DEFAULT_KSU_MNT_ID; mnt = mnt->mnt_parent) { }
	mnt_id = mnt->mnt_id;
	unlock_mount_hash();
	return mnt_id;
}

struct vfsmount *susfs_get_non_sus_vfsmnt_from_vfsmnt(struct vfsmount *vfsmnt)
{
	struct mount *mnt = real_mount(vfsmnt);

	if (mnt->mnt_id < DEFAULT_KSU_MNT_ID) {
		mntget(&mnt->mnt);
		dget(mnt->mnt.mnt_root);
		return &mnt->mnt;
	}

	lock_mount_hash();
	for (; mnt && mnt->mnt_parent && mnt != mnt->mnt_parent &&
	       mnt->mnt_id >= DEFAULT_KSU_MNT_ID; mnt = mnt->mnt_parent) { }
	mntget(&mnt->mnt);
	if (!mnt->mnt.mnt_root || IS_ERR(mnt->mnt.mnt_root)) {
		mntput(&mnt->mnt);
		unlock_mount_hash();
		return vfsmnt;
	}
	dget(mnt->mnt.mnt_root);
	unlock_mount_hash();
	return &mnt->mnt;
}

u64 susfs_get_non_sus_mnt_id_unique_from_mnt(struct mount *orig_mnt)
{
	struct mount *mnt = orig_mnt;
	u64 mnt_id_unique;

	if (mnt->mnt_id < DEFAULT_KSU_MNT_ID)
		return mnt->mnt_id_unique;

	lock_mount_hash();
	for (; mnt && mnt->mnt_parent && mnt != mnt->mnt_parent &&
	       mnt->mnt_id >= DEFAULT_KSU_MNT_ID; mnt = mnt->mnt_parent) { }
	mnt_id_unique = mnt->mnt_id_unique;
	unlock_mount_hash();
	return mnt_id_unique;
}
#endif
"""
s = s.replace("fs_initcall(init_fs_namespace_sysctls);",
              "fs_initcall(init_fs_namespace_sysctls);\n" + tail, 1)
open(p, "w").write(s)
print("    namespace.c 已适配（号段分配 + 3 个辅助函数）")
PY

echo "==> [upstream] 6.18 适配：mm/memory.c（sus_map 阻断 process_vm_readv）"
python3 - "$SRC" <<'PY'
import os, sys
SRC = sys.argv[1]
p = os.path.join(SRC, "mm/memory.c")
s = open(p).read()
if "SUSFS_IS_INODE_SUS_MAP" in s:
    print("    已注入过")
    raise SystemExit(0)
i = s.find("#include <linux/sched/sysctl.h>")
assert i > 0, "memory.c: include 锚点没找到"
s = s[:i] + "#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n#include <linux/susfs_def.h>\n#endif\n" + s[i:]

anchor = """		struct folio *folio;
		struct vm_area_struct *vma = NULL;
"""
assert anchor in s, "memory.c: 循环变量锚点没找到"
hook = anchor + """#ifdef CONFIG_KSU_SUSFS_SUS_MAP
		if (vma_lookup(mm, addr) &&
		    vma_lookup(mm, addr)->vm_file &&
		    SUSFS_IS_INODE_SUS_MAP(file_inode(vma_lookup(mm, addr)->vm_file)))
			break;
#endif
"""
s = s.replace(anchor, hook, 1)
open(p, "w").write(s)
print("    __access_remote_vm 已注入")
PY


echo "==> [upstream] 6.18 适配：fs/namei.c 的 open_redirect（path_openat + vfs_readlink）"
python3 - "$SRC" <<'PY'
import os, sys

SRC = sys.argv[1]
p = os.path.join(SRC, "fs/namei.c")
s = open(p).read()
if "susfs_open_redirect_spoof_do_sys_openat" in s:
    print("    已注入过")
    raise SystemExit(0)

# 需要 def.h 里的 SUSFS_IS_INODE_OPEN_REDIRECT* 和官方两个函数的声明。
# 插在 include 块末尾：def.h 里用到 current_uid()/set_thread_flag()，放最前面会报隐式声明。
lines = s.split("\n")
last = max(i for i, ln in enumerate(lines[:120]) if ln.startswith("#include <linux/"))
decl = (
    "#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT\n"
    "#include <linux/susfs_def.h>\n"
    "extern struct filename *susfs_open_redirect_spoof_do_sys_openat(struct inode *inode);\n"
    "extern int susfs_open_redirect_spoof_vfs_readlink(struct inode *inode,\n"
    "\t\t\t\t\t\t  char __user *buffer, int buflen);\n"
    "#endif")
lines.insert(last + 1, decl)
s = "\n".join(lines)

# (1) path_openat 局部变量
anchor = ("static struct file *path_openat(struct nameidata *nd,\n"
          "\t\t\tconst struct open_flags *op, unsigned flags)\n"
          "{\n")
assert anchor in s, "namei.c: path_openat 签名锚点没找到"
s = s.replace(anchor, anchor +
              "#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT\n"
              "\tint sus_old_dfd = nd->dfd;\n"
              "\tbool sus_root_preset = (nd->state & ND_ROOT_PRESET);\n"
              "\tstruct inode *sus_redir_inode = NULL;\n"
              "\tstruct filename *sus_fake_name = NULL;\n"
              "\tstruct filename *sus_old_name = nd->name;\n"
              "#endif\n", 1)

# (2) open 前重定向
loop_anchor = ("\t\tconst char *s = path_init(nd, flags);\n"
               "\t\twhile (!(error = link_path_walk(s, nd)) &&\n"
               "\t\t       (s = open_last_lookups(nd, file, op)) != NULL)\n"
               "\t\t\t;\n"
               "\t\tif (!error)\n"
               "\t\t\terror = do_open(nd, file, op);\n")
assert loop_anchor in s, "namei.c: path_openat 循环锚点没找到"
s = s.replace(loop_anchor,
              "\t\tconst char *s = path_init(nd, flags);\n"
              "\t\twhile (!(error = link_path_walk(s, nd)) &&\n"
              "\t\t       (s = open_last_lookups(nd, file, op)) != NULL)\n"
              "\t\t\t;\n"
              "#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT\n"
              "\t\t/* 官方语义：命中 open_redirect 规则就换成 redirected 路径重走一遍 */\n"
              "\t\tsus_redir_inode = nd->path.dentry ? d_inode(nd->path.dentry) : NULL;\n"
              "\t\t/* 官方宏没有给参数加括号，必须传简单标识符而不是表达式 */\n"
              "\t\tif (!error && !sus_root_preset &&\n"
              "\t\t    SUSFS_IS_INODE_OPEN_REDIRECT_WITHOUT_UID_CHECK(sus_redir_inode)) {\n"
              "\t\t\tsus_fake_name = susfs_open_redirect_spoof_do_sys_openat(\n"
              "\t\t\t\tsus_redir_inode);\n"
              "\t\t\tif (sus_fake_name && !IS_ERR(sus_fake_name)) {\n"
              "\t\t\t\tconst char *new_s = NULL;\n"
              "\n"
              "\t\t\t\tterminate_walk(nd);\n"
              "\t\t\t\trestore_nameidata();\n"
              "\t\t\t\tset_nameidata(nd, sus_old_dfd, sus_fake_name, NULL);\n"
              "\t\t\t\tnew_s = path_init(nd, flags);\n"
              "\t\t\t\twhile (!(error = link_path_walk(new_s, nd)) &&\n"
              "\t\t\t\t       (new_s = open_last_lookups(nd, file, op)) != NULL)\n"
              "\t\t\t\t\t;\n"
              "\t\t\t}\n"
              "\t\t}\n"
              "#endif\n"
              "\t\tif (!error)\n"
              "\t\t\terror = do_open(nd, file, op);\n", 1)

# (3) 收尾：还原 nd->name
cleanup_anchor = ("\t\tterminate_walk(nd);\n"
                  "\t}\n"
                  "\tif (likely(!error)) {\n")
assert cleanup_anchor in s, "namei.c: path_openat 收尾锚点没找到"
s = s.replace(cleanup_anchor,
              "\t\tterminate_walk(nd);\n"
              "\t}\n"
              "#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT\n"
              "\tif (sus_fake_name && !IS_ERR(sus_fake_name)) {\n"
              "\t\tnd->name = sus_old_name;\n"
              "\t\tputname(sus_fake_name);\n"
              "\t}\n"
              "#endif\n"
              "\tif (likely(!error)) {\n", 1)

# (4) vfs_readlink：命中规则时用 redirected 路径回填，防止反查出真实位置
rl_anchor = ("\tstruct inode *inode = d_inode(dentry);\n"
             "\tDEFINE_DELAYED_CALL(done);\n"
             "\tconst char *link;\n"
             "\tint res;\n")
assert rl_anchor in s, "namei.c: vfs_readlink 声明锚点没找到"
s = s.replace(rl_anchor, rl_anchor +
              "#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT\n"
              "\tif (SUSFS_IS_INODE_OPEN_REDIRECT(inode)) {\n"
              "\t\tint sus_rl = susfs_open_redirect_spoof_vfs_readlink(inode, buffer, buflen);\n"
              "\n"
              "\t\t/* 官方成功时返回 0（已直接写入用户缓冲），失败返回负值 */\n"
              "\t\tif (!sus_rl)\n"
              "\t\t\treturn 0;\n"
              "\t}\n"
              "#endif\n", 1)

open(p, "w").write(s)
print("    namei.c: open_redirect 已注入（path_openat + vfs_readlink）")
PY

