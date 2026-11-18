# dijun 内核（小米 15S Pro / 玄戒 O1 / android17-6.18）

> 设备：小米 15S Pro（`dijun`），HyperOS OS4.0.5.0，玄戒 O1
> 内核基线：`6.18.21-android17-5-g284297031c53-abogki553682993-4k`（GKI / KMI `android17-6.18`）
> 当前版本：**#147**（分支 `main`，commit `ee96ad70`，CI run `44278522101` 构建成功，已上机多次重启验证稳定）
> 上游：2026-11-15 起 SukiSU-Ultra 更名为 **SukiSU-Nova**，本项目跟踪其 `main` 分支

本仓库用 GitHub Actions 复现整套构建：AOSP `android17-6.18` 源码 + 设备原厂 `boot.img` 抽出的 config，
编译出可直接刷入 `boot` 分区、内置 SukiSU（built-in）与 **官方 SUSFS v2.4.0** 完整移植的内核。
root 与 SUSFS 随 `boot` 分区的 `Image` 内置；标准 AK3 只刷写 `boot`，**不触碰 `init_boot`**。
不依赖 LKM、不写运行期只读内存、零 kprobe；AK3 成品包见 Releases。

---

## 项目目标与总体做法

**目标**：在小米 15S Pro（玄戒 O1，android17-6.18）上做一套可复现、可直接刷入的内核——内置 root 与完整
SUSFS 隐藏能力，不依赖 LKM、不写运行期只读内存、零 kprobe；在通过 root 检测的同时保持开机稳定、
相机等硬件正常，并让管理器和 susfs-for-kernelsu 模块能正确识别与管理。

**主要工作**（均已上机验证）：

1. **可复现的构建底座**：用 AOSP android17-6.18 源码加设备原厂 config 复现 GKI 构建；开启稳定的导出符号
   CRC 生成，让符号版本与厂商 `.ko` 对齐、避免模块版本不匹配；补齐 clang/rustc/bindgen 工具链并保证
   相机 HAL 正常。
2. **内置 root**：按官方集成指南把 SukiSU 编进内核，版本号由上游构建过程自动计算；root 随 `boot` 分区
   内置，刷入不涉及 `init_boot`。
3. **SELinux 隐藏**：built-in 模式下上游的隐藏实现会在运行期写只读内存导致崩溃，因此改为在编译期接通
   官方已有的隐藏逻辑；几处上游修复（setprocattr、inode_setxattr 侧信道）也一并接回，让检测软件查不出
   改动。全程不写只读内存、零 kprobe。
4. **完整 SUSFS 功能**：把 SUSFS v2.4.0 的隐藏能力完整移植进来——uname/cmdline/version 伪装、路径与
   stat 隐藏、挂载隐藏、maps/smaps 隐藏等。功能主体沿用官方实现，仅对因内核版本差异而不适用的钩子
   做等价适配；并新增属主豁免，避免误伤 QQ/TIM 读取自身图片。
5. **管理器与工具识别**：补齐 reboot 命令字分发，让管理器能读到 SUSFS 版本、变体与已启用功能，不再
   回退到默认的旧版本；同时把官方的全部命令字接进分发器，使 susfs-for-kernelsu 模块的配置下发真正生效。
6. **符号隐藏**：按官方补丁在编译期过滤内核符号表中的 KSU/SUSFS 符号名，实测符号表里查不到相关符号，
   零 kprobe。
7. **打包与分发**：CI 自动构建加标准 AnyKernel3 打包，产物在 Releases 发布，管理器可直接刷入。

各部分的细节与官方对齐情况见下文。

---

## 1. 功能与官方 SUSFS v2.4.0 的关系（重点）

本项目的 SUSFS **功能主体是官方 v2.4.0 原样移植**（核心 `fs/susfs.c` 与官方基线逐行对比，
除"属主豁免"一处新增外完全一致）。因内核从 6.12 漂移到 6.18、root 方案从 KernelSU 模块变为
SukiSU-Nova built-in，钩子层需要等价适配。下表把全部能力分成三类，便于准确理解"哪些是官方、哪些是我们做的"。

编译开关 `SUSFS_UPSTREAM=1`（见 `.github/workflows/build-kernel.yml`）：官方实现线启用，
仓库里早期自研的 `patches/susfs_*.c`（uname/cmdline/path/kstat/mount/map/extra/符号隐藏）已**不参与编译**，
文件保留仅供对比与回退。

### 1.1 与官方一致（功能 + 实现都来自官方 v2.4.0）

| 能力 | 说明 |
|---|---|
| SUSFS 核心实现 | `fs/susfs.c`、`include/linux/susfs.h`、`susfs_def.h` 官方原样；版本上报 `v2.4.0`、variant `GKI`、feature 列表顺序与官方一致（实测 **10/10**：SUS_PATH / SUS_MOUNT / SUS_KSTAT / SPOOF_UNAME / ENABLE_LOG / HIDE_SYMBOLS / SPOOF_CMDLINE / OPEN_REDIRECT / SUS_MAP / PRIORITY_UID_FILTER） |
| `sus_path` 路径隐藏 | 官方 inode 匹配实现，隐藏返回 `ENOENT`；含官方全局 uid filter（`packages.list` 解析、throne 变更重建线程） |
| `sus_kstat` / `sus_mount` / `sus_map` | 官方 stat 字段伪造、挂载隐藏（号段 mnt_id）、`/proc/<pid>/maps|smaps` 隐藏，均为官方函数 |
| uname / cmdline / version 伪装 | 官方 `susfs_set_uname` / `susfs_set_cmdline_or_bootconfig` 实现 |
| `open_redirect` / AVC 日志伪装 / 优先级 uid filter | 官方实现 |
| 官方两套补丁 | `50_add_susfs_in_gki-android16-6.12.patch` 命中文件原样应用（15 个）；`10_enable_susfs_for_ksu.patch` KSU 侧胶水 |
| 符号隐藏（kallsyms） | 官方 `kernel/kallsyms.c` hunk 原样应用：编译期按 18 个前缀过滤 `ksu_` / `__ksu_` / `susfs_` / `ksud` / `is_ksu_` / `setup_selinux` / `track_throne` / `try_umount` / `kernelsu` / `getenforce` 等；`/proc/kallsyms` 实测 0 个 KSU/SUSFS 符号，**零 kprobe** |
| SELinux 隐藏 | 官方同款编译期补丁；检测软件 MapleUltra 全量 261 项通过 |
|  userspace ABI | 命令字 magic `0xDEADBEEF`/`0xFAFAFAFA`、载荷 struct 逐字段对齐官方 `gki-android16-6.12`，`ksu_susfs` 工具二进制兼容；管理器显示 "SuFS 版本 v2.4.0"，模块识别成功（不再回退默认 v1.5.2） |

### 1.2 单独实现（功能对齐官方，但代码为 6.18 / SukiSU 适配而改写）

> 这些能力**语义与官方一致**，但因 6.18 API 漂移或 SukiSU built-in 平台差异，钩子/胶水由本项目改写或注入。
> 官方后续升级不能无脑同步这些位置。

| 位置 | 适配内容 |
|---|---|
| `fs/susfs.c`（构建期） | 自动提取 39 个全局函数签名生成前置原型，过 6.18 `-Werror,-Wmissing-prototypes`；`statfs.c` 两个 wrapper 同样补原型 |
| `fs/namespace.c` | 号段 mnt_id 用**独立原子计数器**（官方用 IDA；6.18 xarray 在持 `namespace_sem` 时做 GFP_KERNEL 分配会死锁——这是早期版本"应用全打不开"的根因）；`clone_mnt` 的 KSU 域 unshare 复用旧 id；补齐 4 个 sus_mount 隐藏门（`__lookup_mnt` / `mnt_find_id_at` / `lookup_mnt_in_ns` / `do_listmount`）；3 个 non-sus 辅助函数 |
| `fs/namei.c` | `open_redirect` 钩子（`path_openat` + `vfs_readlink`）——6.18 无官方依赖的 `ND_STATE_LOOKUP_LAST/OPEN_LAST`，用等价注入 |
| `fs/stat.c` / `mm/memory.c` / `fs/proc/task_mmu.c` | SUS_KSTAT 按 6.18 `mnt_idmap` 改写；sus_map 阻断 `process_vm_readv`；maps/smaps/smaps_rollup/pagemap 隐藏按 6.18 结构定位注入（官方 hunk 上下文是 6.12 的，会插错位置） |
| `susfs_def.h` 三个 TIF 闸门 | SukiSU-Nova 没有 KernelSU-Next 的 `TIF_PROC_UMOUNTED/NO_SU` 线程标志，改为直接问 KSU：`ksu_uid_should_umount()` + isolated uid（90000–99999）无条件打标，语义一致 |
| `kernel/hook/setuid_hook.c` | 接官方 LOOP 调度：`setresuid` 时 `schedule_work(&susfs_extra_works)`，让 `ADD_SUS_PATH_LOOP` 在 app spawn 时落地（官方在 KernelSU setuid 钩子里做，SukiSU 无现成接线） |
| `patches/susfs_upstream.c` | reboot-magic → `CMD_SUSFS_*` 分发器（15 个命令字）、`susfs_is_current_ksu_domain()`、`susfs_ksu_proc_umounted()`、`susfs_init()` 调用点——官方由 KernelSU `supercall/dispatch.c` 提供，SukiSU built-in 下本地补胶水 |
| `patches/susfs_bridge.c`（瘦身版） | 保留编译（SELinux 补丁依赖其导出 SID），删掉与官方 susfs.c 重名的符号；AVC spoof 开关改走官方 `(void __user **)` 版本 |
| `integrate.sh` 的 SELinux 编译期钩子 | built-in 下官方 `selinux_hide` 运行期写 `write_op[]`（只读段）会崩溃，故让这段早退；再把误伤的 5 类官方动作用编译期钩子逐一接通（fake status、context/access 走 `backup_sepolicy`、setprocattr #3981、inode_setxattr #3996）。详见 §2 |

### 1.3 新增功能（官方 v2.4.0 完全没有）

#### sus_path 属主豁免（owner exemption）— #147 的核心新增

- **是什么**：路径属于 `/Android/data/<pkg>` 或 `/Android/media/<pkg>` 时，**属主 app 自己仍能看到该目录**，其他 app 仍然隐藏。
- **为什么需要**：官方只有"全局 uid 白名单"（`susfs_set_sus_path_uid_filter`），只能表达"这个 uid 能看到所有 sus_path"，
  无法表达"每个 app 只看自己的目录"。一旦用 LOOP 给每个 app 加 `/sdcard/Android/data/<pkg>`，
  就会把 QQ/TIM **自身**的图片数据也隐藏掉（早期版本 QQ/TIM 读不到自身图片的根因）。
  本功能补上官方缺失的 per-inode 属主放行能力。
- **实现**：`susfs.c` 里约 200 行，源码注释明确标注 `LOCAL EXTENSION, NOT PART OF UPSTREAM SUSFS`。
  `struct susfs_sus_path_owner` + 10bit RCU 哈希表；属主 uid 在 sus_path 加入时从 `packages.list` 解析；
  `susfs_is_inode_sus_path()` 判定隐藏前先查属主放行。热路径无锁、只在 app 数据目录做 creds 切换。
- **与官方功能隔离**：不改全局 uid filter 语义，独立开关于 `CONFIG_KSU_SUSFS_SUS_PATH` 内。
- **验证**：内核判定层 `/data/media` 视图 A/B——QQ 读自己 ✅ / 读 TIM `ENOENT` ✅，反之亦然，readdir 一致；
  真实 app 层 logcat 显示 QQ（libAPNG）、TIM（FastDynamicDrawable）正常读写自身外部数据图片；
  MapleUltra 261 项全过、无 FATAL/ANR、dmesg 无 oops。

其余构建底座能力（GKI ABI 对齐、AOSP 工具链、SukiSU built-in、AK3 打包）见 §2 / §3，它们是平台工程，非 SUSFS 功能。

---

## 2. 构建底座与 SELinux 隐藏原理

### 2.1 可复现构建底座

| 能力 | 说明 |
|---|---|
| GKI 构建 | AOSP 源码 `284297031c53`；`KBUILD_GENDWARFKSYMS_STABLE=1` 让导出符号 CRC 与厂商 `.ko` 对齐（`module_layout = 0x60801db3`，18187 个导出符号，vermagic 与原厂一致） |
| AOSP 工具链 | 预编译 clang / rustc / bindgen 0.72.1；开启 `CONFIG_RUST=y` + `CONFIG_ASHMEM=y`，否则 camera HAL 初始化会崩 |
| SukiSU built-in | 按官方 `kernel/setup.sh` 集成到 `drivers/kernelsu`，分支 `main`；版本串 `v3.0.0-<sha>@shushu` 由上游 Kbuild 自动计算；管理器与 `ksud` 可用 |
| boot 打包 | 官方 4096 B header（改 `kernel_size`）+ 自编 `Image` + 官方 vbmeta(2368 B) + 零填充 + 原 64 B AVB footer；总长不变，多次上机验证 |
| CI / Release | Actions 自动构建产出 `Image`、`System.map`、`config.built`、`vmlinux.symvers`、`summary.txt`、完整日志；AK3 成品包在 Releases 发布 |

### 2.2 SELinux 隐藏是怎么打通的

上游 `ksu_selinux_hide_enable()` 在 built-in 模式下会用 `ksu_patch_text` 往
`static ssize_t (*const write_op[])`（位于 `.rodata`，只读）塞函数指针：
module 模式下这两次写入返回 `-EFAULT` 还能退到 kprobe，built-in 没有退路，
结果是 system_server 调 `sel_write_context` 时跳到坏指针 → 连续重启。

本项目解法全部在 `ci/integrate.sh`，分五步：

1. **让运行期 hook 安装早退**：`CONFIG_KSU_SUSFS=y` 时让 `enable()` 早退，跳过三处运行期 hook 安装。
   SUSFS 补丁在编译期已把 `selinuxfs.c` / `hooks.c` 函数换成 `handle_*` 包装，运行期再塞一遍是重复且是崩溃源。
2. **status 按需初始化**：`sel_open_handle_status` 的 fake status 改为打开 status 时按需初始化，
   去掉 static key 门控（防时序静默失效）。
3. **修正 context / access**：编译期包装原本查实时策略（已含 `ksu_file`），
   而官方 `my_write_context`/`my_write_access` 查的是 **`backup_sepolicy`**（原厂策略）并强制 `avd.seqno = 1`——
   这才是检测软件查不出改动的原因。现把 `security_*_with_policy(backup_sepolicy, ...)` 包装成
   `ksu_backup_context_to_sid` / `ksu_backup_sid_to_context` / `ksu_backup_compute_av` 接回编译期包装，
   `access` 补 `avd.seqno = 1`；`write_op[]` 与 `handle_*` 不动。
4. **修 setprocattr 侧信道**：Maple 报的"策略属性写入特征"来自 app 写 `/proc/self/attr/current` 的侧信道。
   上游 `c836ea2c`（#3981）已修，但早退跳过了 `ksu_lsm_hook(&selinux_setprocattr_hook)`，
   修复只是编进内核、从未挂上。这里导出 `ksu_backup_setprocattr` 指向官方 `my_setprocattr`，
   把 `handle_selinux_setprocattr` 的 app-uid 分支改调它。
5. **修 inode_setxattr 文件 label 侧信道**：盘点 `enable()` 后发现还漏了
   `ksu_lsm_hook(&selinux_inode_setxattr_hook)`——官方 `my_inode_setxattr`（`5b6262e8` / #3996）同样没挂上。
   这里导出 `ksu_backup_inode_setxattr` 指向官方实现，首次进入时 lazy 补跑官方解析好函数指针，
   hooks.c 编译期新增 `handle_selinux_inode_setxattr` 替换挂载点。

**后三步全程零 kprobe、不改 `write_op[]`、不写只读数据、不新增功能**，只是让官方已有实现真正生效。

**版本号完全交给上游 Kbuild 自动计算**（不写死）：`KSU_VERSION = VERSION_BASE + LOCAL_COUNT − VERSION_OFFSET`。
Nova 改名后为 `30000 + COUNT − 4001`。补齐 KernelSU 完整历史与 `drivers/` 下的 `.git` 指针，
让版本码由上游公式自动算出，不依赖网络 API。

---

## 3. 当前进度与已知问题

### 3.1 状态

- ✅ **#147 已发布**：GKI ABI 对齐、Rust/ASHMEM 工具链、SukiSU built-in、SELinux 隐藏（检测软件通过）、
  官方 SUSFS v2.4.0 完整功能、管理器识别、属主豁免新增、符号隐藏、标准 AK3 刷入不动 `init_boot`、
  CI 可复现构建。分支：`main` = #147，`stable-143` 保留上一稳定点。
- 上机证据（#147）：开机/SELinux Enforcing/root（`u:r:ksu:s0`）/ksud 3.0.0 正常；
  enabled_features 10/10；kallsyms 0 符号；sus_path app uid 读隐藏文件 `ENOENT`；
  QQ/TIM 正常启动、读自身图片正常、无 tombstone；MapleUltra 261 项全过；dmesg 无 panic/oops/BUG/WARNING。

### 3.2 已知问题 / 边界

- **属主 uid 只在加入 sus_path 时解析一次**：app 卸载重装、uid 变化后属主豁免失效（该 app 看不到自己的目录），
  需重新 add_sus_path 或重启恢复。彻底修需在 `track_throne` 重建处加 owner 表重建钩子（要改官方 10 patch + `susfs.h`）。
- **FUSE inode `i_ino = 0`**：FUSE 视图下 readdir 的 `ilookup(sb, ino)` 可能失效；namei 路径不受影响。
  内核判定层验证改用 `/data/media`（f2fs 直接视图）绕开，彻底修需按 FUSE nodeid 建索引，属独立课题。
- **FUSE 视图无法用合成进程验证**：本 ROM 上任何 app uid 经 FUSE 访问 `/sdcard/Android/data` 都返回 `EACCES`
  （无 avc，是 FUSE/MediaProvider 权限门，与 susfs 无关）。故该视图只能靠真实 app 行为验证。
- **`bridge.c` 的 `sus_av` 表 / `sus_type` 判断是空壳**：仓库源文件里这两个函数返回 false / 空操作；
  upstream 模式下由官方 `susfs.c` 的同名符号接管（已瘦身去重），实际运行走官方实现，源码阅读时易混淆。
- **BTF 类型比对**：`build.log` 尾部 `passed=False`，不一致 8 / 缺失 21，均为 `pkvm_*` / `f2fs_*` /
  `mt_device` / `fsverity_info` 等 vendor-only 类型；符号 CRC 与厂商 `.ko` 一致，实机正常开机。
- **AVB**：沿用官方 vbmeta、未重算 kernel hash 描述符（设备侧校验不阻塞）。
- **刷机前提**：需要已解锁 bootloader；刷机有风险，请先备份原厂 `boot.img`（标准 AK3 只刷 `boot`，无需备份 `init_boot`）。

---

## 4. 构建与刷写

```bash
# CI 手动触发
gh workflow run build-kernel.yml
gh run download --name dijun-kernel-<run_number> -D ./artifacts

# 刷写（标准 AK3 只刷 boot，不触碰 init_boot）
fastboot flash boot <AK3 内 boot.img 或管理器刷入>
fastboot reboot
```

AK3 成品包请从 **Releases** 下载，在 Recovery / KernelSU 管理器里刷入；
包内 `README-AK3.txt` 写明适用机型、槽位处理与回滚方式。
回滚：刷回原厂 `boot.img`（`fastboot flash boot <原厂 boot.img>`）即可，`init_boot` 全程不需要动。

分支说明：`main` = 当前发布版 #147；`stable-143` = 上一稳定点；`upstream-align` = 官方移植基线；
`main-selfdev` = 早期自研实现（保留对比）。

---

## 5. 致谢

- **[simonpunk / susfs4ksu](https://gitlab.com/simonpunk/susfs4ksu)（SUSFS 原作者）**：SUSFS 完整实现与
  `gki-android16-6.12` 分支的 v2.4.0 源码、官方两套内核/KSU 补丁、ABI 定义——本项目 SUSFS 功能主体
  直接来自其原样实现，属主豁免也是在其 `susfs.c` 基础上做的本地扩展。
- **[SukiSU-Ultra](https://github.com/SukiSU-Ultra/SukiSU-Ultra) / SukiSU-Nova 团队**：KernelSU 分支、管理器、
  `selinux_hide` 官方实现，以及 `kernel/setup.sh` 的 built-in 集成指南。特别感谢上游 `c836ea2c`（#3981，
  setprocattr 侧信道）与 `5b6262e8`（#3996，inode_setxattr 文件 label 侧信道）两个修复，
  本项目只是把它们官方已有实现在 built-in 下接通。
- **[KernelSU](https://github.com/tiann/KernelSU) 原项目及其贡献者**：整套内核侧 root 架构的基础。
- **LingLuo17 / [AnyKernel3](https://github.com/osm0sis/AnyKernel3)**：`dijun` 上实测可开机的 AK3 基线与打包方案。
- **[AOSP / Google](https://source.android.com/)**：`android17-6.18` GKI 源码、clang/rustc 工具链与
  `gendwarfksyms` 稳定 CRC 机制。
- **小米 / 玄戒**：原厂固件与开源内核，以及设备侧的 `logfs` / `oops` / `pstore` 日志能力——
  没有这些日志，`.rodata` 写入导致 panic 的根因无从定位。
- **finasu 的 LKM 版 `kernelsu.ko`**：作为对照基线，验证"官方隐藏功能本来就够用"，
  从而把问题收敛到 built-in 的失效点。
- **所有参与实机刷机、抓日志、跑检测软件并反馈结果的朋友**：本项目每一步结论都来自上机证据，而非推测。

---

## 6. 免责声明

本项目仅用于个人设备研究与学习。刷写内核有变砖风险，请确保已解锁、已备份、了解回滚方式；
因使用本项目产物造成的设备或数据损失，作者与贡献者不承担责任。
