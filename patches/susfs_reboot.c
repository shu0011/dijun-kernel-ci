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

/* Feature list reported to userspace.  Order and names match upstream
 * susfs_get_enabled_features() so the WebUI maps 1:1.  Only features this
 * kernel truly implements are reported. */
static const char susfs_feature_list[] =
	"CONFIG_KSU_SUSFS_SUS_PATH\n"
	"CONFIG_KSU_SUSFS_SUS_MOUNT\n"
	"CONFIG_KSU_SUSFS_SUS_KSTAT\n"
	"CONFIG_KSU_SUSFS_SPOOF_UNAME\n"
	"CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS\n"
	"CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG\n"
	"CONFIG_KSU_SUSFS_SUS_MAP\n";

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
	/* our kstat model overrides size; other stat fields are ignored because
	 * we match by inode pointer, not by spoofed numeric attributes. */
	ret = susfs_kstat_abi_add(info->target_pathname,
				  (u64)info->spoofed_size, 0);
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

/* bool-style commands with no-op / state-absorbing handling.  We still read
 * the payload and write err=0 so the official scripts see success. */
static void susfs_abi_bool_ok(void __user **arg)
{
	struct susfs_abi_bool info = {0};

	if (copy_from_user(&info, (struct susfs_abi_bool __user *)*arg,
			   sizeof(info))) {
		info.err = -EFAULT;
		goto out;
	}
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
	case SUSFS_ABI_CMD_ADD_SUS_PATH_LOOP:
		susfs_abi_add_sus_path(arg);
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

	/* enable_log / avc_log_spoofing: no log sink in this build; absorb so
	 * the official scripts don't treat them as unsupported. */
	case SUSFS_ABI_CMD_ENABLE_LOG:
	case SUSFS_ABI_CMD_ENABLE_AVC_SPOOF:
		susfs_abi_bool_ok(arg);
		return 0;

	/* uid-filter / open-redirect commands are not implemented in this
	 * built-in port; leave them unsupported so the tool reports
	 * "operation not supported, please enable it in kernel". */
	default:
		return -EINVAL;
	}
}
