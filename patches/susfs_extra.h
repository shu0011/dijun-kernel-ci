/* SPDX-License-Identifier: GPL-2.0 */
/*
 * SUSFS extra features for the built-in port:
 *   - ENABLE_LOG              (global log switch)
 *   - SUS_PATH_UID_FILTER     (uid allow-list for sus_path visibility)
 *   - PRIORITY_UID_FILTER     (uid deny-list for priority syscalls)
 *   - OPEN_REDIRECT           (target path -> redirected path on open)
 *
 * These helpers are deliberately lightweight and share the existing
 * built-in SUSFS state (no LKM, no kprobes, no kthreads).  They are driven
 * by the CMD_SUSFS_* sys_reboot ABI in susfs_reboot.c and consumed by the
 * small VFS/syscall hooks injected by ci/integrate.sh.
 */
#ifndef _LINUX_SUSFS_EXTRA_H
#define _LINUX_SUSFS_EXTRA_H

#include <linux/types.h>
#include <linux/fs.h>

/* ---- ENABLE_LOG ---- */
bool susfs_log_enabled(void);

/* ---- SUS_PATH_UID_FILTER ----
 * Returns true when sus_path targets should be hidden from this uid.
 * No filter configured -> every app uid (uid >= 10000) is hidden, matching
 * the pre-filter behaviour.  With a filter, only uids in the allow-list see
 * the real path (uid >= 90000 always allowed). */
bool susfs_uid_hidden_for_sus_path(uid_t uid);

/* ---- PRIORITY_UID_FILTER ----
 * Returns true when the given uid should be hidden from
 * getpriority/setpriority/ioprio_get/ioprio_set. */
bool susfs_uid_priority_filtered(uid_t uid);

/* ---- OPEN_REDIRECT ----
 * Returns the redirected pathname to open instead of the target inode,
 * or NULL when this inode has no redirect for the current process.
 * The returned pointer is a getname_kernel() result; caller must putname(). */
struct filename;
struct filename *susfs_open_redirect_filename(struct inode *inode);
/* True if this inode participates in any redirect (flag check, no uid test). */
bool susfs_inode_has_open_redirect(struct inode *inode);
/* Fill buf with the spoofed target path for readlink on the redirected inode;
 * returns 0 on success, negative errno otherwise. */
int susfs_open_redirect_readlink(struct inode *inode, char *buf, int buflen);

/* ---- ABI setters (root-only, called from susfs_reboot.c) ---- */
int susfs_extra_enable_log(bool enabled);
int susfs_extra_set_sus_path_uid_filter(const char __user *app_strings);
int susfs_extra_set_priority_uid_filter(const char __user *app_strings);
int susfs_extra_add_open_redirect(const void __user *payload);

#endif /* _LINUX_SUSFS_EXTRA_H */
