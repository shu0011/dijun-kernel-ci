// SPDX-License-Identifier: GPL-2.0
/*
 * SUSFS reboot-magic ABI — built-in implementation.
 *
 * Implements the full CMD_SUSFS_* syscall ABI used by the upstream ksu_susfs
 * tool (gitlab.com/simonpunk/susfs4ksu, gki-android16-6.12), so that the
 * official susfs4ksu-module can actually manage this kernel: add_sus_path,
 * spoof_uname, set_cmdline, add_sus_kstat, add_sus_map, ... plus the three
 * read-only query commands (version / features / variant).
 *
 * Payload structs and command ids live in <linux/susfs_abi.h> and are copied
 * verbatim from upstream.  Functional commands are routed to the same
 * built-in feature state that the /proc/susfs_* nodes drive (both interfaces
 * share one source of truth), so there is no duplicate implementation.
 *
 * Unhandled commands return -EINVAL so kernel/reboot.c falls through to the
 * normal reboot flow, exactly like upstream's default: branch.
 */
#include <linux/susfs_reboot.h>
#include <linux/susfs_abi.h>

#include <linux/errno.h>
#include <linux/cred.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/uaccess.h>

/* built-in feature setters (share state with the /proc interfaces) */
#include <linux/susfs_path.h>
#include <linux/susfs_maps.h>
#include <linux/susfs_mount.h>
#include <linux/susfs_kstat.h>
#include <linux/susfs_uname.h>
#include <linux/susfs_proc.h>
#include <linux/susfs_extra.h>

/* Feature list reported to userspace.  Order and names match upstream
 * susfs_get_enabled_features() so the WebUI maps 1:1.  Only features this
 * kernel truly implements are reported. */
static const char susfs_feature_list[] =
	"CONFIG_KSU_SUSFS_SUS_PATH\n"
	"CONFIG_KSU_SUSFS_SUS_MOUNT\n"
	"CONFIG_KSU_SUSFS_SUS_KSTAT\n"
	"CONFIG_KSU_SUSFS_SPOOF_UNAME\n"
	"CONFIG_KSU_SUSFS_ENABLE_LOG\n"
	"CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG\n"
	"CONFIG_KSU_SUSFS_OPEN_REDIRECT\n"
	"CONFIG_KSU_SUSFS_SUS_MAP\n";
/* finasu-v23-compat: v2.4 新增的 HIDE_KSU_SUSFS_SYMBOLS / PRIORITY_UID_FILTER
 * 已关闭并从本表移除，只上报 FinaSU v2.3 识别的 8 项，避免其按 v2.3 协议
 * 操作 v2.4 功能导致的重启 bug。SUS_PATH_UID_FILTER 仍是 SUS_PATH 子功能，
 * 沿用 upstream 做法不单独上报。 */

/* ---------- read-only query commands ---------- */
static void susfs_query_show_version(void __user **arg)
{
	struct susfs_abi_str16 info = {0};

	if (copy_from_user(&info, (struct susfs_abi_str16 __user *)*arg,
			   sizeof(info))) {
		info.err = -EFAULT;
		goto out;
	}
	strscpy(info.buf, SUSFS_REPORT_VERSION, sizeof(info.buf) - 1);
	info.err = 0;
out:
	if (copy_to_user((struct susfs_abi_str16 __user *)*arg, &info,
			 sizeof(info)))
		info.err = -EFAULT;
}

static void susfs_query_show_variant(void __user **arg)
{
	struct susfs_abi_str16 info = {0};

	if (copy_from_user(&info, (struct susfs_abi_str16 __user *)*arg,
			   sizeof(info))) {
		info.err = -EFAULT;
		goto out;
	}
	strscpy(info.buf, SUSFS_REPORT_VARIANT, sizeof(info.buf) - 1);
	info.err = 0;
out:
	if (copy_to_user((struct susfs_abi_str16 __user *)*arg, &info,
			 sizeof(info)))
		info.err = -EFAULT;
}

static void susfs_query_show_features(void __user **arg)
{
	struct susfs_abi_features *info;

	info = kzalloc(sizeof(*info), GFP_KERNEL);
	if (!info)
		return;	/* leave payload untouched; err stays 126 */

	strscpy(info->enabled_features, susfs_feature_list,
		sizeof(info->enabled_features) - 1);
	info->err = 0;
	if (copy_to_user((struct susfs_abi_features __user *)*arg, info,
			 sizeof(*info)))
		info->err = -EFAULT;
	kfree(info);
}

/* ---------- functional commands ---------- */
static void susfs_abi_add_sus_path(void __user **arg)
{
	struct susfs_abi_sus_path info = {0};
	int ret;

	if (copy_from_user(&info, (struct susfs_abi_sus_path __user *)*arg,
			   sizeof(info))) {
		info.err = -EFAULT;
		goto out;
	}
	info.target_pathname[sizeof(info.target_pathname) - 1] = '\0';
	ret = susfs_path_abi_add(info.target_pathname);
	info.err = ret ? ret : 0;
out:
	if (copy_to_user((struct susfs_abi_sus_path __user *)*arg, &info,
			 sizeof(info)))
		info.err = -EFAULT;
}

static void susfs_abi_add_sus_path_loop(void __user **arg)
{
	struct susfs_abi_sus_path info = {0};
	int ret;

	if (copy_from_user(&info, (struct susfs_abi_sus_path __user *)*arg,
			   sizeof(info))) {
		info.err = -EFAULT;
		goto out;
	}
	info.target_pathname[sizeof(info.target_pathname) - 1] = '\0';
	ret = susfs_path_abi_add_loop(info.target_pathname);
	info.err = ret ? ret : 0;
out:
	if (copy_to_user((struct susfs_abi_sus_path __user *)*arg, &info,
			 sizeof(info)))
		info.err = -EFAULT;
}

static void susfs_abi_add_sus_map(void __user **arg)
{
	struct susfs_abi_sus_map info = {0};
	int ret;

	if (copy_from_user(&info, (struct susfs_abi_sus_map __user *)*arg,
			   sizeof(info))) {
		info.err = -EFAULT;
		goto out;
	}
	info.target_pathname[sizeof(info.target_pathname) - 1] = '\0';
	ret = susfs_map_abi_add(info.target_pathname);
	info.err = ret ? ret : 0;
out:
	if (copy_to_user((struct susfs_abi_sus_map __user *)*arg, &info,
			 sizeof(info)))
		info.err = -EFAULT;
}

static void susfs_abi_add_sus_kstat(void __user **arg)
{
	struct susfs_abi_kstat *info;
	int ret;

	/* 8KB-ish payload: kzalloc, never stack (kernel stack limit 2048) */
	info = kzalloc(sizeof(*info), GFP_KERNEL);
	if (!info)
		return;
	if (copy_from_user(info, (struct susfs_abi_kstat __user *)*arg,
			   sizeof(*info))) {
		info->err = -EFAULT;
		goto out;
	}
	info->target_pathname[sizeof(info->target_pathname) - 1] = '\0';
	/* 官方语义：
	 *   ADD_SUS_KSTAT / UPDATE_SUS_KSTAT -> 以当前真实 stat 为快照
	 *   ADD_SUS_KSTAT_STATICALLY         -> 采用载荷里的 ino/dev/nlink/size/
	 *                                       atime/mtime/ctime/blocks/blksize
	 * 两种情况都由 susfs_kstat_abi_add() 处理，override 时全字段生效。 */
	ret = susfs_kstat_abi_add(info->target_pathname, info);
	info->err = ret ? ret : 0;
out:
	if (copy_to_user((struct susfs_abi_kstat __user *)*arg, info,
			 sizeof(*info)))
		info->err = -EFAULT;
	kfree(info);
}

static void susfs_abi_set_uname(void __user **arg)
{
	struct susfs_abi_uname info = {0};

	if (copy_from_user(&info, (struct susfs_abi_uname __user *)*arg,
			   sizeof(info))) {
		info.err = -EFAULT;
		goto out;
	}
	info.release[sizeof(info.release) - 1] = '\0';
	info.version[sizeof(info.version) - 1] = '\0';
	/* upstream rejects an empty release or version with -EFAULT */
	if (!info.release[0] || !info.version[0]) {
		info.err = -EFAULT;
		goto out;
	}
	susfs_uname_abi_set(info.release, info.version);
	info.err = 0;
out:
	if (copy_to_user((struct susfs_abi_uname __user *)*arg, &info,
			 sizeof(info)))
		info.err = -EFAULT;
}

static void susfs_abi_set_cmdline(void __user **arg)
{
	struct susfs_abi_cmdline *info;

	/* 8KB payload: heap only */
	info = kzalloc(sizeof(*info), GFP_KERNEL);
	if (!info)
		return;
	if (copy_from_user(info, (struct susfs_abi_cmdline __user *)*arg,
			   sizeof(*info))) {
		info->err = -EFAULT;
		goto out;
	}
	info->fake_cmdline_or_bootconfig[sizeof(info->fake_cmdline_or_bootconfig) - 1] = '\0';
	susfs_cmdline_abi_set(info->fake_cmdline_or_bootconfig);
	info->err = 0;
out:
	if (copy_to_user((struct susfs_abi_cmdline __user *)*arg, info,
			 sizeof(*info)))
		info->err = -EFAULT;
	kfree(info);
}

/* bool-style command that actually drives state: AVC 日志伪装。
 * 之前这里用 susfs_abi_bool_ok() 只回 err=0，static key 永远不打开，
 * 于是 SELinux 补丁里那段过滤代码成了死代码。 */
static void susfs_abi_set_avc_spoof(void __user **arg)
{
	struct susfs_abi_bool info = {0};

	if (copy_from_user(&info, (struct susfs_abi_bool __user *)*arg,
			   sizeof(info))) {
		info.err = -EFAULT;
		goto out;
	}
	susfs_set_avc_log_spoofing(info.enabled);
	info.err = 0;
out:
	if (copy_to_user((struct susfs_abi_bool __user *)*arg, &info,
			 sizeof(info)))
		info.err = -EFAULT;
}

static void susfs_abi_set_mount_toggle(void __user **arg)
{
	struct susfs_abi_bool info = {0};

	if (copy_from_user(&info, (struct susfs_abi_bool __user *)*arg,
			   sizeof(info))) {
		info.err = -EFAULT;
		goto out;
	}
	susfs_mount_abi_set_enabled(info.enabled);
	info.err = 0;
out:
	if (copy_to_user((struct susfs_abi_bool __user *)*arg, &info,
			 sizeof(info)))
		info.err = -EFAULT;
}

int susfs_reboot_handler(int magic1, int magic2, unsigned int cmd,
			 void __user **arg)
{
	/* SUSFS tool always calls with magic1 = KSU_INSTALL_MAGIC1. */
	if (magic1 != (int)SUSFS_ABI_MAGIC1)
		return -EINVAL;

	/* SUSFS magic, root only — matches upstream's uid==0 gate. */
	if (magic2 != (int)SUSFS_ABI_MAGIC2 || current_uid().val != 0)
		return -EINVAL;

	switch (cmd) {
	/* read-only queries */
	case SUSFS_ABI_CMD_SHOW_VERSION:
		susfs_query_show_version(arg);
		return 0;
	case SUSFS_ABI_CMD_SHOW_VARIANT:
		susfs_query_show_variant(arg);
		return 0;
	case SUSFS_ABI_CMD_SHOW_FEATURES:
		susfs_query_show_features(arg);
		return 0;

	/* sus_path */
	case SUSFS_ABI_CMD_ADD_SUS_PATH:
		susfs_abi_add_sus_path(arg);
		return 0;
	/* ADD_SUS_PATH_LOOP：路径可能稍后才出现 / 被重建，登记到 loop 表由定时
	 * 任务持续重试解析，解析成功后并入普通 sus_path 表（上游 LOOP 语义）。 */
	case SUSFS_ABI_CMD_ADD_SUS_PATH_LOOP:
		susfs_abi_add_sus_path_loop(arg);
		return 0;

	/* sus_map */
	case SUSFS_ABI_CMD_ADD_SUS_MAP:
		susfs_abi_add_sus_map(arg);
		return 0;

	/* sus_kstat */
	case SUSFS_ABI_CMD_ADD_SUS_KSTAT:
	case SUSFS_ABI_CMD_UPDATE_SUS_KSTAT:
	case SUSFS_ABI_CMD_ADD_SUS_KSTAT_ST:
		susfs_abi_add_sus_kstat(arg);
		return 0;

	/* spoof_uname */
	case SUSFS_ABI_CMD_SET_UNAME:
		susfs_abi_set_uname(arg);
		return 0;

	/* spoof_cmdline / bootconfig */
	case SUSFS_ABI_CMD_SET_CMDLINE:
		susfs_abi_set_cmdline(arg);
		return 0;

	/* sus_mount toggle (path-list based impl: absorb, no id-range switch) */
	case SUSFS_ABI_CMD_HIDE_MNTS_NON_SU:
		susfs_abi_set_mount_toggle(arg);
		return 0;

	/* enable_log: real static-key log switch. */
	case SUSFS_ABI_CMD_ENABLE_LOG: {
		struct susfs_abi_bool info = {0};

		if (copy_from_user(&info, (struct susfs_abi_bool __user *)*arg,
				   sizeof(info)))
			return -EFAULT;
		susfs_extra_enable_log(info.enabled);
		info.err = 0;
		if (copy_to_user((struct susfs_abi_bool __user *)*arg, &info,
				 sizeof(info)))
			return -EFAULT;
		return 0;
	}

	/* avc_log_spoofing: 打开/关闭 security/selinux/avc.c 里的过滤分支
	 * （tsid == ksu_sid 时把 tcontext 改写成 priv_app）。 */
	case SUSFS_ABI_CMD_ENABLE_AVC_SPOOF:
		susfs_abi_set_avc_spoof(arg);
		return 0;

	/* uid filters (SUS_PATH allow-list + PRIORITY deny-list).
	 * err lives at offset 65536 in struct susfs_abi_uid_filter. */
	case SUSFS_ABI_CMD_SET_SUS_PATH_UID:
	case SUSFS_ABI_CMD_SET_PRIORITY_UID: {
		struct susfs_abi_uid_filter __user *p =
			(struct susfs_abi_uid_filter __user *)*arg;
		int err = (cmd == SUSFS_ABI_CMD_SET_SUS_PATH_UID) ?
			susfs_extra_set_sus_path_uid_filter(*arg) :
			susfs_extra_set_priority_uid_filter(*arg);

		if (copy_to_user(&p->err, &err, sizeof(err)))
			return -EFAULT;
		return 0;
	}

	/* open_redirect: target path -> redirected path. err at offset 516. */
	case SUSFS_ABI_CMD_ADD_OPEN_REDIRECT: {
		struct susfs_abi_open_redirect __user *p =
			(struct susfs_abi_open_redirect __user *)*arg;
		int err = susfs_extra_add_open_redirect(*arg);

		if (copy_to_user(&p->err, &err, sizeof(err)))
			return -EFAULT;
		return 0;
	}

	default:
		return -EINVAL;
	}
}
