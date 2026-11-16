// SPDX-License-Identifier: GPL-2.0
/*
 * SUSFS reboot-magic query ABI — built-in implementation.
 *
 * Mirrors the query-only portion of upstream susfs4ksu's
 * ksu_handle_sys_reboot (kernel/supercall/dispatch.c).  We intentionally
 * implement ONLY the three read-only query commands that the userspace tool
 * and the manager need for detection:
 *
 *   CMD_SUSFS_SHOW_VERSION  (0x555E1) -> "v2.4.0"
 *   CMD_SUSFS_SHOW_ENABLED_FEATURES (0x555E2) -> feature name list
 *   CMD_SUSFS_SHOW_VARIANT  (0x555E3) -> "GKI"
 *
 * Functional commands (add_sus_path, etc.) are NOT handled here: this kernel
 * exposes those through /proc/susfs_* nodes instead.  Any unhandled command
 * returns -EINVAL so kernel/reboot.c falls through to the normal reboot flow.
 */
#include "susfs_reboot.h"

#include <linux/errno.h>
#include <linux/cred.h>
#include <linux/sched.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/uaccess.h>

/* Feature list reported to userspace.  Only the features this kernel actually
 * implements are listed, so the WebUI does not expose toggles that do nothing.
 * Names must match what susfs4ksu-module scripts/webui grep for. */
static const char susfs_feature_list[] =
	"CONFIG_KSU_SUSFS_SPOOF_UNAME\n"
	"CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG\n"
	"CONFIG_KSU_SUSFS_SUS_PATH\n"
	"CONFIG_KSU_SUSFS_SUS_KSTAT\n"
	"CONFIG_KSU_SUSFS_SUS_MOUNT\n"
	"CONFIG_KSU_SUSFS_SUS_MAP\n"
	"CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS\n";

static void susfs_query_show_version(void __user **arg)
{
	struct susfs_query_version info = {0};

	if (copy_from_user(&info, (struct susfs_query_version __user *)*arg,
			   sizeof(info))) {
		info.err = -EFAULT;
		goto out;
	}
	strscpy(info.version, SUSFS_REPORT_VERSION, sizeof(info.version) - 1);
	info.err = 0;
out:
	if (copy_to_user((struct susfs_query_version __user *)*arg, &info,
			 sizeof(info)))
		info.err = -EFAULT;
}

static void susfs_query_show_variant(void __user **arg)
{
	struct susfs_query_variant info = {0};

	if (copy_from_user(&info, (struct susfs_query_variant __user *)*arg,
			   sizeof(info))) {
		info.err = -EFAULT;
		goto out;
	}
	strscpy(info.variant, SUSFS_REPORT_VARIANT, sizeof(info.variant) - 1);
	info.err = 0;
out:
	if (copy_to_user((struct susfs_query_variant __user *)*arg, &info,
			 sizeof(info)))
		info.err = -EFAULT;
}

static void susfs_query_show_features(void __user **arg)
{
	struct susfs_query_features *info;

	info = kzalloc(sizeof(*info), GFP_KERNEL);
	if (!info)
		return;	/* leave payload untouched; err stays whatever userspace set */

	strscpy(info->features, susfs_feature_list, sizeof(info->features) - 1);
	info->err = 0;
	if (copy_to_user((struct susfs_query_features __user *)*arg, info,
			 sizeof(*info)))
		info->err = -EFAULT;
	kfree(info);
}

int susfs_reboot_handler(int magic1, int magic2, unsigned int cmd,
			 void __user **arg)
{
	/* SUSFS tool always calls with magic1 = KSU_INSTALL_MAGIC1. */
	if (magic1 != (int)SUSFS_KSU_INSTALL_MAGIC1)
		return -EINVAL;

	/* SUSFS magic, root only — matches upstream's uid==0 gate. */
	if (magic2 != (int)SUSFS_MAGIC || current_uid().val != 0)
		return -EINVAL;

	switch (cmd) {
	case SUSFS_CMD_SHOW_VERSION:
		susfs_query_show_version(arg);
		return 0;
	case SUSFS_CMD_SHOW_VARIANT:
		susfs_query_show_variant(arg);
		return 0;
	case SUSFS_CMD_SHOW_ENABLED_FEATURES:
		susfs_query_show_features(arg);
		return 0;
	default:
		/* Not one of our query commands: let reboot.c fall through. */
		return -EINVAL;
	}
}