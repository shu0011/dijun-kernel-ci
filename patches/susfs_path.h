/* SPDX-License-Identifier: GPL-2.0 */
/*
 * SUSFS stage-3: sus_path（按路径隐藏）。
 * 编译期在 vfs_getattr 入口插一行判断，app uid 命中路径时返回 -ENOENT。
 */
#ifndef _LINUX_SUSFS_PATH_H
#define _LINUX_SUSFS_PATH_H

#include <linux/path.h>
#include <linux/types.h>

/* true 表示该路径对当前 app 进程应当"不存在" */
bool susfs_is_hidden_path(const struct path *path);

#endif /* _LINUX_SUSFS_PATH_H */
