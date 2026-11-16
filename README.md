# dijun 内核（小米 15S Pro / 玄戒 O1 / android17-6.18）

> 设备：小米 15S Pro（`dijun`），HyperOS OS4.0.5.0，玄戒 O1
> 内核基线：`6.18.21-android17-5-g284297031c53-abogki553682993-4k`（GKI / KMI `android17-6.18`）
> 当前状态：**built-in SukiSU + 完整 SUSFS 移植 + SELinux 隐藏已上机验证通过**。
> SUSFS 从"仅 SELinux 隐藏"扩展到完整能力（路径/ stat / 挂载 / maps 隐藏、uname/cmdline/version 伪装），
> 并补齐 reboot-magic 查询 ABI，使管理器与 susfs-for-kernelsu 模块正确识别 **SUSFS v2.4.0 (GKI)**。
> 检测软件通过、开机稳定、零 kprobe。AK3 成品包见 Releases。
> 上游：2026-11-15 起 SukiSU-Ultra 更名为 **SukiSU-Nova**，本项目同步跟踪其 `main` 分支

本仓库用 GitHub Actions 复现整套构建：AOSP `android17-6.18` 源码 + 设备原厂 `boot.img` 抽出的 config，
编译出可直接刷入 `boot` 分区、内置 SukiSU Ultra 与 SELinux 隐藏的内核。
root 随 `boot` 分区的 `Image` 内置；标准 AK3 只刷写 `boot`，**不触碰 `init_boot`**，因此不存在与 init_boot 的冲突。

## 当前实现的功能

| 能力 | 说明 |
|---|---|
| 可复现 GKI 构建 | AOSP 源码 `284297031c53`；`KBUILD_GENDWARFKSYMS_STABLE=1` 让导出符号 CRC 与厂商 `.ko` 对齐（`module_layout = 0x60801db3`，18187 个导出符号，vermagic 与原厂一致） |
| AOSP 工具链 | 预编译 clang / rustc / bindgen 0.72.1；开启 `CONFIG_RUST=y` + `CONFIG_ASHMEM=y`，否则 camera HAL 初始化会崩 |
| SukiSU built-in | 按官方 `kernel/setup.sh` 集成到 `drivers/kernelsu`，分支 `main`；版本号**由上游 Kbuild 自动计算**（不再写死），版本串 `v3.0.0-<sha>@shushu`；管理器与 `ksud` 可用 |
| SELinux 隐藏（完整生效） | 见下节；**检测软件已通过**，Maple「策略属性写入特征」侧信道已修，`ksud feature get 4` = enabled，开机无重启 |
| SUSFS 完整移植 | 在仅隐藏的基础上补齐全部功能：`spoof_uname`/`cmdline`/`version`、`sus_path`（路径/stat 隐藏）、`sus_kstat`、`sus_mount`（挂载隐藏）、`sus_map`（maps/smaps 隐藏）、`namei.c` 多级挂点。功能经 `/proc/susfs_*` 接口控制（0600、root 写、uid≥10000 生效），已逐项上机验证 |
| 管理器识别 SUSFS v2.4.0 | 内核实现 reboot-magic 查询 ABI（magic1=`0xDEADBEEF`/magic2=`0xFAFAFAFA`，cmd `0x555E1/2/3`），返回版本 `v2.4.0`、variant `GKI`、7 项功能名。**SukiSU Nova 管理器显示 "SuFS 版本 v2.4.0"，susfs-for-kernelsu 模块识别成功**（不再回退默认 v1.5.2） |
| 零运行期 patch / 零 kprobe | 不写只读的 `write_op[]`，不挂 `selinux_hide` 相关 kprobe，隐藏全部走编译期钩子 |
| boot 打包 | 官方 4096 B header（改 `kernel_size`）+ 自编 `Image` + 官方 vbmeta(2368 B) + 零填充 + 原 64 B AVB footer；总长不变，已多次上机验证 |
| CI / Release | Actions 自动构建并产出 `Image`、`System.map`、`config.built`、`vmlinux.symvers`、`summary.txt`、完整日志；AK3 成品包在 Releases 发布 |

### SELinux 隐藏是怎么打通的

上游 `ksu_selinux_hide_enable()` 在 built-in 模式下会用 `ksu_patch_text` 往
`static ssize_t (*const write_op[])`（位于 `.rodata`，只读）塞函数指针：
module 模式下这两次写入返回 `-EFAULT` 还能退到 kprobe，built-in 没有退路，
结果是 system_server 调 `sel_write_context` 时跳到坏指针 → 连续重启。

本项目的解法分三步，全部在 `ci/integrate.sh`：

1. **G2**：`CONFIG_KSU_SUSFS=y` 时让 `enable()` 早退，跳过三处运行期 hook 安装。
   SUSFS 的补丁在编译期已经把 `selinuxfs.c` / `hooks.c` 的对应函数换成了 `handle_*` 包装，
   运行期再塞一遍纯属重复且是崩溃源。
2. **G3**：`sel_open_handle_status` 的 fake status 改为打开 status 时按需初始化，
   去掉 `fake_status_initialize_key` 的 static key 门控（防时序导致的静默失效）。
3. **G4（context/access 修复）**：SUSFS 编译期包装原本查**实时策略**（已含 `ksu_file`），
   而官方 `my_write_context` / `my_write_access` 查的是 **`backup_sepolicy`**（原厂策略）
   并强制 `avd.seqno = 1`，这才是检测软件查不出改动的原因。
   现在把 `security_*_with_policy(backup_sepolicy, ...)` 包装成
   `ksu_backup_context_to_sid` / `ksu_backup_sid_to_context` / `ksu_backup_compute_av`，
   接回编译期包装，`access` 补 `avd.seqno = 1`；`write_op[]` 与 `handle_*` 不动。
4. **G5（setprocattr / Maple 侧信道修复）**：Maple 报的「重要: 策略属性写入特征」
   （`kernelsu_traits_count:1`）来自 app 写 `/proc/self/attr/current`（setprocattr）的侧信道：
   检测软件写一个含 KSU type 的 context，比较内核返回行为判断 live policy 是否被改过。
   上游 `c836ea2c`（#3981，2026-11-09）已修此问题：`my_setprocattr` 先用
   `security_context_to_sid_live()` 校验，只有遇到 ksu 新增 type（`-EAGAIN`，stale type mark）
   才 dual parse 查 `backup_sepolicy`，因此写原厂 context 的行为与未 root 真机一致。
   但 G2 早退跳过了 `ksu_lsm_hook(&selinux_setprocattr_hook)`，这个修复在 built-in 下
   只是**编进内核、从未挂上**；app 的写入落到 SUSFS 的 `susfs_selinux_setprocattr`（无 live-parse）
   → 侧信道暴露。LKM ko 能过检测，是因为它完整跑了 `enable()`、`my_setprocattr` 真挂上了。
   G5 用与 G4 相同的编译期手法：导出 `ksu_backup_setprocattr` 指向官方 `my_setprocattr`，
   把 `handle_selinux_setprocattr` 的 app-uid 分支改调它。**不挂 kprobe、不改 `write_op[]`、
   不写只读数据、不新增功能**，只是让官方已有实现真正生效。
5. **G6（inode_setxattr / 文件 label 侧信道修复）**：完整盘点 `enable()` 的 6 类动作后，
   发现 G2 早退还漏了第 6 类 `ksu_lsm_hook(&selinux_inode_setxattr_hook)` —— 官方
   `my_inode_setxattr`（上游 `5b6262e8` / #3996，2026-11-14，与 #3981 同批 live-parse 修复）
   同样只是编进内核、从未挂上。它管的是 app 写文件 `security.selinux` xattr 时的侧信道：
   先用 `security_context_to_sid_live()` 校验、ksu 新 type 才查 backup，写原厂 label 的行为
   与真机一致；缺了它，检测软件写文件 label 即可探知 live policy 被改。
   难点是该函数依赖两个 kallsyms 解析的原函数指针，G2 早退跳过了初始化故为 NULL；
   G6 导出 `ksu_backup_inode_setxattr` 指向官方实现、首次进入时 lazy 补跑官方
   `selinux_hide_init_setxattr()` 解析好指针（built-in 下 `superblock_init` 是 no-op stub），
   hooks.c 编译期新增 `handle_selinux_inode_setxattr` 替换挂载点，app-uid + SELinux xattr
   走 wrapper、失败或非目标回落原生。同样**零 kprobe、不改 `write_op[]`、不写只读数据、
   不新增功能**。至此 G2 早退误伤的官方隐藏动作全部接通。

**版本号完全交给上游 Kbuild 自动计算**（不写死）：公式为
`KSU_VERSION = VERSION_BASE + LOCAL_COUNT − VERSION_OFFSET`。早期 Ultra 是 `40000 + COUNT − 2815`，
2026-11-15 改名 Nova 后改为 `30000 + COUNT − 4001`。之前曾短暂写死 `41185`，这违背上游"自动计算"
的设计且改名后过时，已撤销。CI 上偶发的 `40000`/`30000` 回退并非 API 限流，而是 G-fix 修复前
`setup.sh` 浅克隆 + `drivers/kernelsu` 换成实目录后 `.git` 丢失，`git rev-list --count main` 数不到
完整历史所致。G-fix 现在会补齐 KernelSU 的完整历史并在 `drivers/` 下补 `.git` 指针，
让版本码由上游公式自动算出，不依赖网络 API。

## 本项目做了什么、目的是什么

**目的**：在小米 15S Pro（玄戒 O1 / android17-6.18）上，做出一套**可复现、可直接刷入**的内核——
内置 root（SukiSU / KernelSU）、完整 SUSFS 隐藏能力，且**不依赖 LKM、不写运行期只读内存、零 kprobe**，
在通过 root 检测的同时保持开机稳定、相机等硬件正常。所有功能最终要能被管理器和 susfs-for-kernelsu 模块
**正确识别和管理**。

**做了哪些动作**（按阶段，全部已上机验证）：

1. **构建底座**：用 AOSP `android17-6.18` 源码 + 设备原厂 config 复现 GKI 构建；开启
   `KBUILD_GENDWARFKSYMS_STABLE=1` 让导出符号 CRC 与厂商 `.ko` 对齐，避免模块版本不匹配；
   补齐 AOSP clang / rustc / bindgen 工具链（`CONFIG_RUST` + `CONFIG_ASHMEM`，否则相机 HAL 崩）。
2. **built-in SukiSU**：按官方 `setup.sh` 集成到 `drivers/kernelsu`，版本号由上游 Kbuild 自动计算
   （`30000 + COUNT − 4001`，不写死）；root 随 `boot` 内置，AK3 刷入不涉及 `init_boot`。
3. **SELinux 隐藏（G2–G6）**：built-in 模式下官方 `selinux_hide` 的运行期 `write_op[]` 补丁会写只读段导致崩溃，
   故 G2 让它早退；但这误伤了官方其余 5 类动作，逐一盘点并用编译期钩子接通：
   G3 fake status、G4 context/access 走 `backup_sepolicy`、G5 setprocattr（#3981 侧信道）、
   G6 inode_setxattr（#3996 文件 label 侧信道）。目的是让官方已有实现真正生效，而不是另造隐藏。
4. **SUSFS 完整移植（I–O）**：从"仅 SELinux 隐藏"补齐为完整能力——uname/cmdline/version 伪装、
   `sus_path` 路径与 stat 隐藏、`sus_kstat`、`sus_mount` 挂载隐藏、`sus_map` maps/smaps 隐藏、
   `namei.c` 多级挂点。功能统一经 `/proc/susfs_*` 接口控制。目的是把 SUSFS 的隐藏能力真正用起来。
5. **管理器识别 ABI（P）**：在 `kernel/reboot.c` 注入 reboot-magic 查询分发，实现只读查询
   version/variant/features，让管理器不再回退默认 `v1.5.2`。目的是让上层工具能识别并管理这些功能。
6. **打包与分发**：CI 自动构建 + 标准 AnyKernel3 打包，产物在 Releases 发布，管理器可直接刷入。

## 当前进度

- ✅ **全部完成并上机验证**：GKI ABI 对齐、Rust/ASHMEM 工具链、SukiSU built-in、SELinux 隐藏（检测软件通过）、
  SUSFS 完整功能（路径/挂载/maps 隐藏、伪装）、管理器识别 SUSFS v2.4.0、标准 AK3 刷入不动 `init_boot`、
  boot/AVB 打包、CI 可复现构建、AK3 打包。已合并到 `main`。
- ⚠️ **已知限制**
  - `build.log` 尾部 BTF 类型比对 `passed=False`：不一致 8 / 缺失 21，均为 `pkvm_*`、`f2fs_*`、
    `mt_device`、`fsverity_info` 等 vendor-only 类型；符号 CRC 与厂商 `.ko` 一致，实机正常开机。
  - AVB 沿用官方 vbmeta、未重算 kernel hash 描述符（设备侧校验不阻塞）。
  - 需要已解锁 bootloader；刷机有风险，请先备份原厂 `boot.img`（标准 AK3 只刷 `boot`，无需备份 `init_boot`）。

## 构建与刷写

```bash
# CI 手动触发
gh workflow run build-kernel.yml
gh run download --name dijun-kernel-<run_number> -D ./artifacts

# 或本地打包（需 CI 产物 out/Image 与原厂 boot.img）
# 布局见 ci/integrate.sh 与 Releases 里的交付说明

# 刷写（标准 AK3 只刷 boot，不触碰 init_boot）
fastboot flash boot boot_g4_official_selinuxhide.img
fastboot reboot
```

AK3 成品包请从 **Releases** 下载，在 Recovery / KernelSU 管理器里刷入；
包内 `README-AK3.txt` 会写明适用机型、槽位处理与回滚方式。

回滚：刷回原厂 `boot.img`（`fastboot flash boot <原厂 boot.img>`）即可，
`init_boot` 全程不需要动。

## 致谢

- **SukiSU-Ultra / SukiSU-Nova 团队**：KernelSU 分支、管理器、`selinux_hide` 官方实现，
  以及 `kernel/setup.sh` 的 built-in 集成指南 —— 本项目的隐藏逻辑完全建立在官方实现之上。
  特别感谢上游 `c836ea2c`（#3981，setprocattr 侧信道）与 `5b6262e8`（#3996，inode_setxattr 文件 label 侧信道）
  两个修复，G5/G6 只是把它们官方已有的实现在 built-in 下接通。
- **KernelSU 原项目及其贡献者**：整套内核侧 root 架构的基础。
- **SUSFS 项目（susfs4ksu 系列）**：SELinux 编译期包装与隐藏思路，本项目当前接入的补丁来源。
- **LingLuo17 / AnyKernel3**：`dijun` 上实测可开机的 AK3 基线与打包方案，
  是本项目判断"哪些改动会开机失败"的重要参照。
- **AOSP / Google**：`android17-6.18` GKI 源码、clang/rustc 工具链与 `gendwarfksyms` 稳定 CRC 机制。
- **小米 / 玄戒**：原厂固件与开源内核，以及设备侧的 `logfs`/`oops`/`pstore` 日志能力 ——
  没有这些日志，`.rodata` 写入导致 panic 的根因无从定位。
- **finasu 的 LKM 版 `kernelsu.ko`**：作为对照基线，用它验证了"官方隐藏功能本来就够用"，
  从而把问题收敛到 built-in 的失效点，而不是去另造一套隐藏。
- **所有参与实机刷机、抓日志、跑检测软件并反馈结果的朋友**：这个项目几乎每一步结论都来自上机证据，
  而不是推测。

## 免责声明

本项目仅用于个人设备研究与学习。刷写内核有变砖风险，请确保已解锁、已备份、了解回滚方式；
因使用本项目产物造成的设备或数据损失，作者与贡献者不承担责任。

