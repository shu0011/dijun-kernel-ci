/* SPDX-License-Identifier: GPL-2.0 */
/*
 * SUSFS userspace ABI (built-in port).
 *
 * Command ids and payload layouts are copied verbatim from upstream
 * gitlab.com/simonpunk/susfs4ksu, branch gki-android16-6.12:
 *   ksu_susfs/jni/includes/susfs_defs.h
 *   ksu_susfs/jni/features/  (all .c files)
 *   kernel_patches/include/linux/susfs.h + susfs_def.h
 *
 * The ksu_susfs tool issues:
 *   syscall(SYS_reboot, 0xDEADBEEF, 0xFAFAFAFA, CMD, &payload)
 * and pre-sets payload.err = 126 (ERR_CMD_NOT_SUPPORTED).  A handled command
 * must overwrite err with 0.  Struct layouts MUST match the userspace side
 * exactly, otherwise copy_from_user reads garbage.
 */
#ifndef _SUSFS_ABI_H
#define _SUSFS_ABI_H

#include <linux/types.h>

/* magic (from susfs_defs.h) */
#define SUSFS_ABI_MAGIC1 0xDEADBEEF
#define SUSFS_ABI_MAGIC2 0xFAFAFAFA
#define SUSFS_ERR_NOT_SUPPORTED 126

/* sizes (from susfs_def.h / susfs.h) */
#define SUSFS_ABI_MAX_LEN_PATHNAME 256
#define SUSFS_ABI_NEW_UTS_LEN      64
#define SUSFS_ABI_FAKE_CMDLINE_SIZE 8192
#define SUSFS_ABI_ENABLED_FEATS_SIZE 8192

/* command ids (from kernel susfs_def.h — authoritative) */
#define SUSFS_ABI_CMD_ADD_SUS_PATH        0x55550
#define SUSFS_ABI_CMD_ADD_SUS_PATH_LOOP   0x55553
#define SUSFS_ABI_CMD_SET_SUS_PATH_UID    0x55554
#define SUSFS_ABI_CMD_HIDE_MNTS_NON_SU    0x55561
#define SUSFS_ABI_CMD_ADD_SUS_KSTAT       0x55570
#define SUSFS_ABI_CMD_UPDATE_SUS_KSTAT    0x55571
#define SUSFS_ABI_CMD_ADD_SUS_KSTAT_ST    0x55572
#define SUSFS_ABI_CMD_SET_UNAME           0x55590
#define SUSFS_ABI_CMD_ENABLE_LOG          0x555a0
#define SUSFS_ABI_CMD_SET_CMDLINE         0x555b0
#define SUSFS_ABI_CMD_ADD_OPEN_REDIRECT   0x555c0
#define SUSFS_ABI_CMD_SHOW_VERSION        0x555e1
#define SUSFS_ABI_CMD_SHOW_FEATURES       0x555e2
#define SUSFS_ABI_CMD_SHOW_VARIANT        0x555e3
#define SUSFS_ABI_CMD_ENABLE_AVC_SPOOF    0x60010
#define SUSFS_ABI_CMD_ADD_SUS_MAP         0x60020
#define SUSFS_ABI_CMD_SET_PRIORITY_UID    0x60030

/* payload layouts — field order/types identical to userspace features/ .c files */
struct susfs_abi_sus_path {
	char target_pathname[SUSFS_ABI_MAX_LEN_PATHNAME];
	int err;
};

struct susfs_abi_uname {
	char release[SUSFS_ABI_NEW_UTS_LEN + 1];
	char version[SUSFS_ABI_NEW_UTS_LEN + 1];
	int err;
};

struct susfs_abi_cmdline {
	char fake_cmdline_or_bootconfig[SUSFS_ABI_FAKE_CMDLINE_SIZE];
	int err;
};

struct susfs_abi_kstat {
	bool is_statically;
	unsigned long target_ino;
	char target_pathname[SUSFS_ABI_MAX_LEN_PATHNAME];
	unsigned long spoofed_ino;
	unsigned long spoofed_dev;
	unsigned int spoofed_nlink;
	long long spoofed_size;
	long spoofed_atime_tv_sec;
	unsigned long spoofed_atime_tv_nsec;
	long spoofed_mtime_tv_sec;
	unsigned long spoofed_mtime_tv_nsec;
	long spoofed_ctime_tv_sec;
	unsigned long spoofed_ctime_tv_nsec;
	long long spoofed_blocks;
	long spoofed_blksize;
	int flags;
	int err;
};

struct susfs_abi_bool {
	bool enabled;
	int err;
};

struct susfs_abi_sus_map {
	char target_pathname[SUSFS_ABI_MAX_LEN_PATHNAME];
	int err;
};

struct susfs_abi_features {
	char enabled_features[SUSFS_ABI_ENABLED_FEATS_SIZE];
	int err;
};

struct susfs_abi_str16 {
	char buf[16];
	int err;
};

#endif /* _SUSFS_ABI_H */