/* SPDX-License-Identifier: GPL-2.0 */
/*
 * SUSFS stage-1: spoof_uname.
 *
 * 参考实现是 LKM 版（inforcqb/susfs4ksu-lkm，分支 main@f95ae4c）的
 * spoof_uname 一层；这里是 built-in 版本，零运行期代码改写：
 * 只在 kernel/sys.c 的 newuname/uname 出口处调用一次。
 */
#ifndef _LINUX_SUSFS_UNAME_H
#define _LINUX_SUSFS_UNAME_H

#include <linux/types.h>
#include <linux/utsname.h>

/* 若未启用伪装则原样返回，调用方可无条件调用 */
void susfs_spoof_uname(struct new_utsname *u);
bool susfs_is_uname_spoofed(void);

#endif /* _LINUX_SUSFS_UNAME_H */
