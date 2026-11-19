/* SPDX-License-Identifier: GPL-2.0 */
/*
 * SUSFS reboot-magic query ABI (built-in port).
 *
 * The susfs4ksu userspace tool (ksu_susfs) and the manager identify a
 * SUSFS kernel by issuing:
 *
 *     syscall(SYS_reboot, 0xDEADBEEF, 0xFAFAFAFA, CMD, &payload)
 *
 * and falling back to prctl() when reboot returns EINVAL.  Our built-in
 * port implements this query channel so the tool reports the real version
 * instead of falling back to the "v1.5.2 (ABI: prctl)" default.
 *
 * Only the read-only query commands are handled here.  Functional changes
 * (add_sus_path etc.) keep using our existing /proc interfaces.
 */
#ifndef _SUSFS_REBOOT_H
#define _SUSFS_REBOOT_H

#define SUSFS_KSU_INSTALL_MAGIC1 0xDEADBEEF
#define SUSFS_MAGIC              0xFAFAFAFA

/* command ids — must match userspace susfs/abi/consts.rs */
#define SUSFS_CMD_SHOW_VERSION          0x000555E1
#define SUSFS_CMD_SHOW_ENABLED_FEATURES 0x000555E2
#define SUSFS_CMD_SHOW_VARIANT          0x000555E3

/* This kernel is a GKI port of the 6.12 / susfs v2.4.0 source. */
#define SUSFS_REPORT_VERSION  "v2.4.0"
#define SUSFS_REPORT_VARIANT  "GKI"

/* payload layouts — must match #[repr(C)] structs in userspace types.rs */
struct susfs_query_version {
	char version[16];
	int err;
};

struct susfs_query_variant {
	char variant[16];
	int err;
};

#define SUSFS_FEATURES_BUFSIZE 8192
struct susfs_query_features {
	char features[SUSFS_FEATURES_BUFSIZE];
	int err;
};

#ifdef CONFIG_KSU_SUSFS
int susfs_reboot_handler(int magic1, int magic2, unsigned int cmd,
			 void __user **arg);
#else
static inline int susfs_reboot_handler(int magic1, int magic2,
				       unsigned int cmd, void __user **arg)
{
	return -EINVAL;
}
#endif

#endif /* _SUSFS_REBOOT_H */