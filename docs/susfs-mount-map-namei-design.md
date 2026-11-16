# 阶段 M/N/O：sus_mount + sus_map + namei.c 补齐 —— 设计与锚点

> 2026-11-16。基于主线 v6.18 raw 源码逐行核对锚点（本机 AOSP 6.18 源码拉不下来：
> android.googlesource 代理 502 / 直连超时，但 VFS 通用代码主线与 AOSP 一致）。
> 上游参考：gitlab.com/simonpunk/susfs4ksu 的 `50_add_susfs_in_gki-android16-6.12.patch`
> （本地 /private/tmp/susfs-6.12.patch）。

## 0. 总原则：用本项目架构，不照搬上游机制

本项目是 **built-in + inode 指针数组 + proc 0600 接口 + uid>=10000 生效 + 零运行期改写**。
上游是 **LKM + inode bit 标记（AS_FLAGS_*）+ ksu_susfs supercall（sys_reboot）+ fake-qstr 重试**。
两者机制不同，只移植**功能语义**，不引入上游的 supercall / bit 标记 / fake-qstr 基建。

已验证：I/J/K/L 四阶段在 commit 8554be1 上机全部通过，root context `u:r:ksu:s0`，检测软件通过。

---

## 1. 阶段 M：sus_mount（隐藏挂载点）

### 上游做法（不采用，仅记录）
- 按 `mnt_id >= DEFAULT_KSU_MNT_ID(2000000000)` 隐藏，需要改 fs/namespace.c 的
  ida_alloc_min 分配 + mount 树 parent 重映射（patch 780–1030 行，一大片），
  还复制 3 个 150 行的 show 函数 + static key + ksu domain 分流。
- 风险极高：改 mount ID 核心，6.18 上下文与 6.12 差异大，且依赖 KSU 分配高号段 mnt_id
  （我们的 KSU built-in 是否这么分配未确认）。**不照搬。**

### 本项目做法（采用）
复用 sus_path 的 inode 指针匹配：
- 新文件 `fs/susfs_mount.c` + `include/linux/susfs_mount.h`，proc `/proc/susfs_add_sus_mount` 0600。
- 写绝对路径 → `kern_path(path, 0, &p)` → 取 `d_backing_inode(p.dentry)` → `ihold()` 存入数组（最多 64）。
- 写 `clear` → `iput()` 清空。读 → 列路径。
- 判断函数 `bool susfs_is_mnt_sus(struct vfsmount *mnt)`：
  `current_uid().val < 10000` 恒 false；否则取 `d_backing_inode(mnt->mnt_root)` 比对数组。
- 挂点：在 `fs/proc_namespace.c` 的 3 个 show 函数**函数体第一行**加
  `if (susfs_is_mnt_sus(mnt)) return 0;` —— 不复制函数、不改 open 回调、不改 namespace.c。
  - `show_vfsmnt`（第 101 行 `static int show_vfsmnt(struct seq_file *m, struct vfsmount *mnt)`）
  - `show_mountinfo`（第 135 行）
  - `show_vfsstat`（第 193 行，即 /proc/mountstats）
- 这样 `/proc/mounts`、`/proc/self/mountinfo`、`/proc/mountstats` 里该挂载的行整体消失。

### 锚点（6.18 主线已核对，各 1 处）
```
static int show_vfsmnt(struct seq_file *m, struct vfsmount *mnt)   # 101
static int show_mountinfo(struct seq_file *m, struct vfsmount *mnt) # 135
static int show_vfsstat(struct seq_file *m, struct vfsmount *mnt)   # 193
```
插入方式：在匹配行的大括号 `{` 之后插一行判断（用 python 正则定位函数签名 + `{`）。

### 风险
- 低。show 函数是只读展示路径，返回 0 即跳过该行；不碰 mount 核心。
- `mnt->mnt_root` 的 inode 即挂载根 inode，和加入时 `kern_path` 解析到的 inode 一致
  （bind mount / 多挂载点共享同一 inode 会一起隐藏，符合预期）。

---

## 2. 阶段 N：sus_map（隐藏 /proc/<pid>/maps 映射）

### 上游做法
- `kern_path` 解析路径 → `set_bit(AS_FLAGS_SUS_MAP, &inode->i_mapping->flags)`（bit 39）。
- `show_map_vma` 里 `SUSFS_IS_INODE_SUS_MAP(inode)` → `return`。
- 另外 show_smap / show_smaps_rollup / pagemap_read 也各加一处。
- 用 bit 标记是因为 LKM 不能安全改 struct inode；我们 built-in 可用 inode 指针数组。

### 本项目做法（采用）
- 新文件 `fs/susfs_maps.c` + `include/linux/susfs_maps.h`，proc `/proc/susfs_add_sus_map` 0600。
- 写路径 → kern_path → `d_backing_inode` → ihold 存数组；`clear` 清空；读列路径。
- 判断函数 `bool susfs_is_inode_sus_map(const struct inode *inode)`：
  uid>=10000 + 指针比对（去掉 const 比对即可，比较不需要改）。
- 挂点 `fs/proc/task_mmu.c`：
  - `show_map_vma`（第 463 行）：在 `if (vma->vm_file) { const struct inode *inode = file_user_inode(vma->vm_file);` 之后、
    `dev = inode->i_sb->s_dev;` 之前插入 `if (susfs_is_inode_sus_map(inode)) return;`。
    **注意 idmapped**：`file_user_inode` 返回的是 user namespace 视角的 inode；
    而加入时存的是 `d_backing_inode`（底层真实 inode）。需用 `inode_from_user_ns` 或直接
    用 `file_inode(vma->vm_file)`（返回底层 inode）来比对。核对：6.18 有 `file_inode()`。
    实现时**改用 `file_inode(vma->vm_file)`** 传入判断，保证和加入时同一 inode。
  - `show_smap`（第 1355 行）：函数体开头 `if (vma->vm_file && susfs_is_inode_sus_map(file_inode(vma->vm_file))) return 0;`
  - `show_smaps_rollup`（第 1382 行）：循环里加 `goto bypass` 跳过统计（可选，先做前两处，rollup 影响小可后置）。
  - `pagemap_read`：可选，先不做（隐藏 maps 行已够）。

### 锚点（6.18 主线已核对）
```
if (vma->vm_file) {
    const struct inode *inode = file_user_inode(vma->vm_file);
                                        # 在这之后插判断
    dev = inode->i_sb->s_dev;
static int show_smap(struct seq_file *m, void *v)   # 1355
```

### 风险
- 中低。`file_inode` vs `file_user_inode` 的 inode 差异必须用对，否则匹配不上（上机验证会暴露）。
- uid 判断：`show_map_vma` 是读 maps 的进程上下文，app 读自己 maps 时 current_uid 是 app uid，命中。

---

## 3. 阶段 O：补齐 fs/namei.c sus_path 钩子

### 关键前提（已核对 6.18 主线）
- `struct nameidata` 在 6.18 **移到 fs/namei.c 内部**（第 632 行），有 `unsigned int flags, state`。
- state 现有位：`ND_ROOT_PRESET=1`、`ND_ROOT_GRABBED=2`、`ND_JUMPED=4`（bit 0/1/2）。
  bit 5(32)/bit 6(64) **空闲**，可用于 susfs 状态位（与上游 ND_STATE_LOOKUP_LAST=32 /
  ND_STATE_OPEN_LAST=64 一致，不冲突）。
- 但 `ND_FLAGS_LOOKUP_LAST=0x2000000` 是 flags 位，需核对 6.18 flags 是否占用 —— 见下。

### 本项目做法（采用：精简版，不用 fake-qstr 重试）
上游完整机制（7 处调用 + 3 处状态位 + fake qstr name + dcache 重试）极其复杂，目的是让
"最后一步查找"命中 sus_path 时返回 fake dentry 而非 ENOENT，避免检测软件区分。
但本项目已经在 `link_path_walk` 用 -ENOENT 隐藏（K 阶段已上机通过），风格一致即可。
补齐目标：**覆盖最后一步分量**（当前 link_path_walk 只覆盖中间分量遍历），
让直接 `open()` / `exec()` 隐藏路径本身也被拦。

在以下函数插入 `if (dentry && !IS_ERR(dentry) && dentry->d_inode &&
susfs_is_inode_sus_path(dentry->d_inode)) { ...return -ENOENT/NULL; }`：
1. `lookup_fast` RCU 分支：`dentry = __d_lookup_rcu(...)` 之后 → `dentry = NULL`（RCU 不 dput）
2. `lookup_fast` 非 RCU 分支：`dentry = __d_lookup(parent, &nd->last);` 之后 → `dput(dentry); return NULL;`
3. `__lookup_slow`：`return dentry;` 之前 → 命中 `return ERR_PTR(-ENOENT);`
4. `lookup_open`：`dentry = d_lookup(dir, &nd->last);` 之后 → 命中 `dput(dentry); return ERR_PTR(-ENOENT);`

**先不做**（避免状态位/fake-qstr 复杂度与 open(O_CREAT) 的语义纠缠）：
- `lookup_dcache` / `lookup_one_qstr_excl`：这两个主要服务 mkdir/create，隐藏需求低。
- `walk_component` / `lookup_last` / `open_last_lookups` 的状态位置位：仅在需要 fake-qstr 机制时才必须；
  精简版直接 -ENOENT 不需要状态位传递。
- `do_tmpfile` / `path_openat`（上游 OPEN_REDIRECT，不属于本项目范围）。

### 锚点（6.18 主线已核对，各 1 处）
```
dentry = __d_lookup_rcu(parent, &nd->last, &nd->next_seq);
dentry = __d_lookup(parent, &nd->last);
static struct dentry *__lookup_slow(const struct qstr *name,
dentry = d_lookup(dir, &nd->last);     # lookup_open 内
```

### 风险
- 中。`lookup_open` 命中返回 -ENOENT 对 `O_CREAT` 路径意味着"无法创建同名文件"——
  对 sus_path（已存在的隐藏路径）语义正确；不影响其他路径。
- `__lookup_slow` 返回 ENOENT 前要正确 dput/d_lookup_done，避免 dentry 泄漏。
  精简版命中路径：dentry 来自 d_alloc_parallel，需 `d_lookup_done(dentry); dput(dentry);`。

---

## 4. 共用基建
- 三个新 .c 都 `device_initcall` 注册 proc 0600；都 `uid>=10000` 判断；读缓冲 kmalloc（栈 2048 限制）。
- `fs/Makefile` 追加 3 行 `obj-$(CONFIG_KSU_SUSFS) += susfs_*.o`，grep -q 防护。
- 头文件放 `include/linux/susfs_{mount,maps}.h`，判断函数声明。
- namei.c 复用现有 `susfs_is_inode_sus_path`（来自 susfs_path.h，K 阶段已 include）。

## 5. 验证清单（上机）
```
# sus_mount
su -c 'mkdir -p /data/local/tmp/mnttest'
su -c 'mount -t tmpfs tmpfs /data/local/tmp/mnttest'
su -c 'echo /data/local/tmp/mnttest > /proc/susfs_add_sus_mount'
su 10200 -c 'grep mnttest /proc/self/mountinfo'   # 期望无输出
su -c 'grep mnttest /proc/self/mountinfo'          # 期望有
su -c 'umount /data/local/tmp/mnttest; echo clear > /proc/susfs_add_sus_mount'

# sus_map
su -c 'echo /system/lib64/libc.so > /proc/susfs_add_sus_map'
su 10200 -c 'grep libc.so /proc/self/maps'         # 期望无输出
su -c 'echo clear > /proc/susfs_add_sus_map'

# namei 补齐（最后一步 open）
su -c 'echo /data/local/tmp/hidetest > /proc/susfs_add_sus_path'  # 先建一个目录
su 10200 -c 'cat /data/local/tmp/hidetest/file'    # 期望 ENOENT（原 link_path_walk 只拦子路径遍历）
```
