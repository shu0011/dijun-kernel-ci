# 官方 SUSFS 原样移植（upstream-align 分支）

本目录存放**官方源码原样副本**，本分支的目标是：SUSFS 的所有功能与机制都由官方代码提供，
我们只做 6.18 / SukiSU 的 API 适配，不再自己重写任何功能。

## 来源

| 项 | 值 |
|---|---|
| 仓库 | `midori01/susfs4ksu`（simonpunk/susfs4ksu 的镜像），分支 `gki-android16-6.12` |
| 版本 | `SUSFS_VERSION "v2.4.0"`（见 `include/linux/susfs.h`） |
| 取用时分支 HEAD | 2026-11-17 |

> 注意：`work/susfs-618/` 里那份旧 patch 与本目录的 `susfs.c` **不是同一版本**
> （旧 patch 的 `susfs_is_inode_sus_path()` 带 `struct mnt_idmap *` 参数，v2.4.0 不带）。
> 两者混用会编译不过，**以本目录为准**。

## 组成

```
fs/susfs.c                                    官方 SUSFS 实现（原样）
include/linux/susfs.h                         官方头（原样）
include/linux/susfs_def.h                     官方宏/flag 定义（原样）
kernel_patches/50_add_susfs_in_gki-android16-6.12.patch   内核侧钩子（官方）
kernel_patches/10_enable_susfs_for_ksu.patch              KSU 侧胶水（官方）
```

## 试打结论（在本机 6.18 源码树上实测）

### 内核侧 `50_add_susfs_*`（27 文件）

- **19 个文件原样命中**（允许行偏移）
- **8 个文件需要适配**（只改 API 调用，不改逻辑）：
  `fs/Makefile`、`fs/namei.c`、`fs/namespace.c`、`fs/open.c`、
  `fs/readdir.c`、`fs/stat.c`、`mm/memory.c`、`security/selinux/hooks.c`

### KSU 侧 `10_enable_susfs_for_ksu`（37 文件，SukiSU-Nova main）

- **29 个文件原样命中**
- **8 个文件需要适配**：
  `kernel/Kbuild`、`kernel/core/init.c`、`kernel/hook/setuid_hook.c`、
  `kernel/policy/allowlist.c`、`kernel/policy/app_profile.h`、
  `kernel/runtime/boot_event.c`、`kernel/runtime/ksud_integration.c`、
  `kernel/supercall/dispatch.c`

## 排除清单（SukiSU-Nova 没有对应符号，且与 SUSFS 功能无关）

官方 patch 里这些 hunk 是 KernelSU 的 su-compat / preinit / input / init-rc 钩子，
SukiSU-Nova 未导出所需符号（`ksu_setup_preinit_file`、`ksu_handle_vfs_fstat`、
`ksu_is_input_hook_enabled` 等），且**不属于 SUSFS 功能**，一律不打：

- `fs/exec.c`（preinit/sucompat）
- `fs/open.c`（faccessat su-compat）
- `fs/read_write.c`（init rc hook）
- `drivers/input/input.c`（input hook）
- `fs/stat.c` 里的 `ksu_handle_vfs_fstat` / `ksu_handle_stat` 部分（保留 SUS_KSTAT 部分）

## 自研模块的去向

`patches/susfs_*.c`（path/kstat/maps/mount/proc/uname/extra/reboot/bridge）**不再参与编译**，
但文件保留、注入阶段用开关关掉（`SUSFS_UPSTREAM=1`），便于对比和回退。
