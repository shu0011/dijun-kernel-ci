/* SPDX-License-Identifier: GPL-2.0 */
/*
 * SUSFS stage-3: sus_path（inode 级匹配，与上游 susfs4ksu 一致）。
 */
#ifndef _LINUX_SUSFS_PATH_H
#define _LINUX_SUSFS_PATH_H

#include <linux/fs.h>
#include <linux/types.h>

/* true 表示该 inode 属于被隐藏的路径；uid < 10000 恒为 false */
bool susfs_is_inode_sus_path(struct inode *inode);

#endif /* _LINUX_SUSFS_PATH_H */
