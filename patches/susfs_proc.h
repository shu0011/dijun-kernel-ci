/* SPDX-License-Identifier: GPL-2.0 */
/*
 * SUSFS stage-2: /proc/cmdline 与 /proc/version 伪装。
 *
 * 与 spoof_uname 同一套思路：编译期在 proc_show 入口插一行判断，
 * 启用时由本文件直接往 seq_file 写假内容并短路，零运行期代码改写。
 */
#ifndef _LINUX_SUSFS_PROC_H
#define _LINUX_SUSFS_PROC_H

#include <linux/seq_file.h>
#include <linux/types.h>

/* 返回 true 表示已写入假内容，调用方应直接 return 0 */
bool susfs_spoof_cmdline_show(struct seq_file *m);
bool susfs_spoof_version_show(struct seq_file *m);

#endif /* _LINUX_SUSFS_PROC_H */
