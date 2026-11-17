// SPDX-License-Identifier: GPL-2.0
/*
 * SUSFS stage-3: sus_path（built-in，inode 匹配）
 *
 * 与上游 susfs4ksu 一致：加入路径时解析成 inode 并 igrab()，之后所有判断都是
 * 指针比较（susfs_is_inode_sus_path），因此硬链接 / bind mount / 相对路径
 * 这些绕过路径字符串的手段都无效。
 *
 * 控制接口：/proc/susfs_add_sus_path  0600
 *   写绝对路径 -> 解析并加入（重复写幂等）
 *   写 "clear" -> 清空并 iput
 *   读         -> 每行一个已加入路径（仅用于查看，不参与匹配）
 *
 * 只对 app uid（>= 10000）生效：系统进程若被隐藏，开机阶段会找不到 /data/adb 而崩。
 */
#include <linux/atomic.h>
#include <linux/cred.h>
#include <linux/dcache.h>
#include <linux/err.h>
#include <linux/fs.h>
#include <linux/init.h>
#include <linux/jiffies.h>
#include <linux/kernel.h>
#include <linux/limits.h>
#include <linux/magic.h>
#include <linux/mnt_idmapping.h>
#include <linux/mutex.h>
#include <linux/namei.h>
#include <linux/path.h>
#include <linux/proc_fs.h>
#include <linux/sched.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/susfs_path.h>
#include <linux/susfs_extra.h>
#include <linux/uaccess.h>
#include <linux/version.h>
#include <linux/workqueue.h>
/* 官方 susfs.c 就是直接包含 fuse_i.h 来拿 struct fuse_inode / get_fuse_inode */
#include "fuse/fuse_i.h"

/*
 * The entry list grows on demand.  A fixed 64-entry array is far too small in
 * practice: the susfs4ksu module with emulate_vold_app_data adds one path per
 * installed app (/sdcard/Android/data/<pkg>), easily 150+ entries, and every
 * add beyond the cap used to fail silently.
 */
#define SUSFS_PATH_MIN_CAP 64
#define SUSFS_PATH_MAX_CAP 4096
#define SUSFS_PATH_MAX_LEN 256	/* upstream SUSFS_MAX_LEN_PATHNAME */
#define SUSFS_PATH_PROC "susfs_add_sus_path"

/* susfs_log() 是 susfs_extra.c 内部的宏，跨文件用不了；这里基于导出的
 * susfs_log_enabled() 做同样的事（enable_log 关闭时零输出）。 */
#define susfs_path_log(fmt, ...)					\
	do {								\
		if (susfs_log_enabled())				\
			pr_info("susfs: " fmt, ##__VA_ARGS__);		\
	} while (0)

#ifndef AS_FLAGS_SUS_PATH
#define AS_FLAGS_SUS_PATH 33	/* 官方 susfs_def.h */
#endif

struct susfs_path_entry {
	struct inode *inode;
	char path[SUSFS_PATH_MAX_LEN];	/* 仅用于回读展示 / clear */
};

static struct susfs_path_entry *susfs_paths;
static int susfs_path_count;
static int susfs_path_cap;
static DEFINE_MUTEX(susfs_path_mutex);

/*
 * 属主放行（owner bypass）
 * ----------------------
 * susfs4ksu 模块的 emulate_vold_app_data 会给每个第三方应用加一条
 * /sdcard/Android/data/<pkg>。如果连属主一起隐藏，应用读不到自己的外部数据
 * 目录：QQ/TIM 聊天图片全挂、很多应用启动即崩（实测 #93/#107）。
 *
 * 上游 v1.x 的 susfs_is_inode_sus_path() 就是带属主判定的：
 *     is_i_uid_not_allowed(i_uid) = 是 app 进程 && current_uid() != i_uid
 * 即"自己拥有的文件永远看得见，别人的才隐藏"。v2.x 把 sus_path 抽成纯
 * inode flag 后这条判定丢了，这里按 v1.x 语义补回来（可用
 * `echo owner_bypass=0 > /proc/susfs_add_sus_path` 关掉做 A/B 对比）。
 *
 * 实现约束：susfs_is_inode_sus_path() 会在 lookup_fast() 的 RCU 分支里被调用
 * （见 ci/integrate.sh 的 namei 注入），所以查属主**不能加锁、不能睡眠**。
 * 因此这里用固定大小的环状槽位 + 尾部追加 + smp_store_release 发布，
 * 永远不 realloc，读者只做 READ_ONCE 线性扫描。
 */
#define SUSFS_OWNER_SLOTS 2048

struct susfs_owner_slot {
	struct inode *inode;	/* 发布标志：非空表示该槽有效 */
	uid_t raw;		/* inode->i_uid（未按 idmap 映射的原始值） */
	uid_t mapped;		/* 按加入时挂载 idmap 映射后的 uid */
};

static struct susfs_owner_slot susfs_owner_slots[SUSFS_OWNER_SLOTS];
static int susfs_owner_slot_count;
static bool susfs_owner_bypass = true;
/* 只保护写侧（proc 写入与 LOOP 定时任务可能并发）；读侧无锁。 */
static DEFINE_MUTEX(susfs_owner_mutex);

static void susfs_owner_forget(struct inode *inode)
{
	int i, n;

	mutex_lock(&susfs_owner_mutex);
	n = smp_load_acquire(&susfs_owner_slot_count);
	for (i = 0; i < n; i++) {
		if (READ_ONCE(susfs_owner_slots[i].inode) == inode) {
			/* 先摘发布标志，避免 inode 释放后被复用造成误判 */
			WRITE_ONCE(susfs_owner_slots[i].inode, NULL);
			break;
		}
	}
	mutex_unlock(&susfs_owner_mutex);
}

static void susfs_owner_record(struct inode *inode, uid_t raw, uid_t mapped)
{
	int i, n;

	mutex_lock(&susfs_owner_mutex);
	n = smp_load_acquire(&susfs_owner_slot_count);

	for (i = 0; i < n; i++) {
		if (READ_ONCE(susfs_owner_slots[i].inode) == inode) {
			WRITE_ONCE(susfs_owner_slots[i].raw, raw);
			WRITE_ONCE(susfs_owner_slots[i].mapped, mapped);
			goto out;
		}
	}
	if (n >= SUSFS_OWNER_SLOTS) {
		susfs_path_log("sus_path: owner table full (%d)\n",
			       SUSFS_OWNER_SLOTS);
		goto out;
	}
	WRITE_ONCE(susfs_owner_slots[n].raw, raw);
	WRITE_ONCE(susfs_owner_slots[n].mapped, mapped);
	/* inode 是"已发布"标志，必须最后写；计数再 release 递增 */
	smp_store_release(&susfs_owner_slots[n].inode, inode);
	smp_store_release(&susfs_owner_slot_count, n + 1);
out:
	mutex_unlock(&susfs_owner_mutex);
}

/*
 * 调用者是该 inode 的属主吗？比较两个口径：
 *  - raw   ：inode->i_uid，/sdcard 这类 FUSE 挂载上就是应用 uid
 *  - mapped：按加入时那个挂载的 idmap 映射后的 uid（idmapped mount 场景）
 * 任一相等即放行。两者都做 %100000（工作资料/多用户）。
 * 注意 raw 为 0 时不会误判：调用方已经排除了 uid < 10000。
 */
static bool susfs_owner_is_caller(struct inode *inode, uid_t uid)
{
	int i, n;

	if (!READ_ONCE(susfs_owner_bypass))
		return false;

	n = smp_load_acquire(&susfs_owner_slot_count);
	for (i = 0; i < n; i++) {
		uid_t raw, mapped;

		if (READ_ONCE(susfs_owner_slots[i].inode) != inode)
			continue;
		raw = READ_ONCE(susfs_owner_slots[i].raw);
		mapped = READ_ONCE(susfs_owner_slots[i].mapped);
		return (raw && raw == uid) || (mapped && mapped == uid);
	}
	return false;
}

/*
 * ADD_SUS_PATH_LOOP：路径可能稍后才创建、或被删除后重建。
 *
 * 两个 6.18 上必须处理的问题：
 *  1) delayed work 跑在 workqueue 里，cred 是 kernel 域（u:r:kernel:s0），
 *     直接 kern_path 读 /data、/sdcard 会被 SELinux 拒绝 → 必须临时
 *     override_creds() 成加入者（ksu 域/root）的 cred。
 *  2) kworker 的 mount namespace 是 init ns，/sdcard（/storage/self/...）
 *     这类按进程解析的路径在 init ns 里不可用 → 加入时先记下「最深的已存在
 *     父目录」的 struct path，重试时用 vfs_path_lookup() 从该 base 往下解析，
 *     不再依赖 kworker 的 namespace。
 */
#define SUSFS_PATH_LOOP_MAX 256
#define SUSFS_PATH_LOOP_INTERVAL_MS 30000

struct susfs_loop_entry {
	char *path;		/* 原始绝对路径（回显用） */
	char *remainder;	/* 相对 base 的剩余路径 */
	struct path base;	/* 最深已存在父目录；base.mnt 为空表示直接用 kern_path */
};

static struct susfs_loop_entry susfs_loop_entries[SUSFS_PATH_LOOP_MAX];
static int susfs_loop_count;
static DEFINE_MUTEX(susfs_loop_mutex);
static struct delayed_work susfs_path_loop_work;
static const struct cred *susfs_loop_cred;

/* Doubling growth; caller must hold susfs_path_mutex. */
static int susfs_path_grow_locked(void)
{
	struct susfs_path_entry *grown;
	int newcap = susfs_path_cap ? susfs_path_cap * 2 : SUSFS_PATH_MIN_CAP;

	if (newcap > SUSFS_PATH_MAX_CAP)
		newcap = SUSFS_PATH_MAX_CAP;
	if (newcap <= susfs_path_cap)
		return -ENOSPC;

	grown = kvmalloc_array(newcap, sizeof(*grown), GFP_KERNEL);
	if (!grown)
		return -ENOMEM;
	if (susfs_path_count)
		memcpy(grown, susfs_paths,
		       susfs_path_count * sizeof(*grown));
	kvfree(susfs_paths);
	susfs_paths = grown;
	susfs_path_cap = newcap;
	return 0;
}

/*
 * 完全对齐官方：隐藏状态不靠指针表，而是打在 inode 的 i_mapping->flags 上。
 * FUSE 下同时标记 fuse_inode 的 backing inode（官方 susfs_add_sus_path 同款）。
 */
static void susfs_path_flag_inode(struct inode *inode, bool set)
{
	struct fuse_inode *fi;

	if (!inode || !inode->i_mapping)
		return;

	if (inode->i_sb->s_magic == FUSE_SUPER_MAGIC) {
		fi = get_fuse_inode(inode);
		if (!fi || !fi->inode.i_mapping)
			return;
		if (set) {
			set_bit(AS_FLAGS_SUS_PATH, &fi->inode.i_mapping->flags);
			set_bit(AS_FLAGS_SUS_PATH, &inode->i_mapping->flags);
		} else {
			clear_bit(AS_FLAGS_SUS_PATH, &fi->inode.i_mapping->flags);
			clear_bit(AS_FLAGS_SUS_PATH, &inode->i_mapping->flags);
		}
		return;
	}

	if (set)
		set_bit(AS_FLAGS_SUS_PATH, &inode->i_mapping->flags);
	else
		clear_bit(AS_FLAGS_SUS_PATH, &inode->i_mapping->flags);
}

/*
 * 官方 susfs_is_inode_sus_path() 的 6.18 版本：
 *  - uid 先 % 100000（工作资料/多用户）
 *  - FUSE 分支只看 backing inode（fi->inode.i_mapping），命中即返回
 *  - 非 FUSE 看 inode->i_mapping
 *  - uid 规则交给 susfs_uid_hidden_for_sus_path()（<10000 / >=90000 / 位图）
 *  - 额外：属主放行（见上面 owner bypass 的说明）
 */
bool susfs_is_inode_sus_path(struct inode *inode)
{
	uid_t uid = current_uid().val % 100000;
	struct fuse_inode *fi = NULL;
	unsigned long *flags;

	if (!inode || !inode->i_mapping)
		return false;

	if (uid < 10000)
		return false;

	if (inode->i_sb->s_magic == FUSE_SUPER_MAGIC) {
		fi = get_fuse_inode(inode);
		if (!fi || !fi->inode.i_mapping)
			return false;
		flags = &fi->inode.i_mapping->flags;
	} else {
		flags = &inode->i_mapping->flags;
	}

	if (!test_bit(AS_FLAGS_SUS_PATH, flags))
		return false;

	if (!susfs_uid_hidden_for_sus_path(uid))
		return false;

	/* 属主永远看得见自己拥有的文件（emulate_vold_app_data 靠这条才可用） */
	if (susfs_owner_is_caller(inode, uid))
		return false;

	return true;
}

static void susfs_path_clear(void)
{
	struct inode *inode;

	/*
	 * iput() 可能触发 inode evict；在 FUSE 上会发出 forget 请求并等待
	 * MediaProvider 处理，此时若持有 susfs_path_mutex，MediaProvider 的
	 * namei/stat 钩子会来抢同一把锁，形成环。所以每次只取一个、放锁后再
	 * iput。
	 */
	for (;;) {
		mutex_lock(&susfs_path_mutex);
		if (susfs_path_count == 0) {
			mutex_unlock(&susfs_path_mutex);
			break;
		}
		susfs_path_count--;
		inode = susfs_paths[susfs_path_count].inode;
		susfs_paths[susfs_path_count].inode = NULL;
		susfs_paths[susfs_path_count].path[0] = '\0';
		mutex_unlock(&susfs_path_mutex);
		if (inode) {
			susfs_owner_forget(inode);
			susfs_path_flag_inode(inode, false);
			iput(inode);
		}
	}

	mutex_lock(&susfs_owner_mutex);
	memset(susfs_owner_slots, 0, sizeof(susfs_owner_slots));
	smp_store_release(&susfs_owner_slot_count, 0);
	mutex_unlock(&susfs_owner_mutex);
}

/*
 * 取应用视角的属主 uid。两个口径都记：
 *   raw    = inode->i_uid.val        —— 普通文件系统、FUSE 上就是应用 uid
 *   mapped = i_uid_into_vfsuid(idmap) —— idmapped mount 下的应用视角
 */
static void susfs_path_owner_uid(struct path *p, uid_t *raw, uid_t *mapped)
{
	struct inode *inode = d_backing_inode(p->dentry);
	vfsuid_t vfsuid;

	if (!inode) {
		*raw = 0;
		*mapped = 0;
		return;
	}

	*raw = inode->i_uid.val % 100000;
	vfsuid = i_uid_into_vfsuid(mnt_idmap(p->mnt), inode);
	*mapped = vfsuid_into_kuid(vfsuid).val % 100000;
}

/* 已拿到 inode 时直接加入；调用方负责 path_put 与偏移/权限检查 */
static int susfs_path_add_inode(struct inode *inode, uid_t owner_raw,
				uid_t owner_mapped, const char *path)
{
	int i, ret;

	if (!inode)
		return -ENOENT;

	/* 官方做法：标记在 inode 的 i_mapping->flags 上，幂等 */
	susfs_path_flag_inode(inode, true);
	/* 属主表是热路径查询用的，先登记，再入展示表 */
	susfs_owner_record(inode, owner_raw, owner_mapped);

	mutex_lock(&susfs_path_mutex);
	for (i = 0; i < susfs_path_count; i++) {
		if (susfs_paths[i].inode == inode) {
			mutex_unlock(&susfs_path_mutex);
			return 0;	/* 已存在 */
		}
		/* 同一路径被删除后重建：inode 变了，替换旧 inode 并释放引用，
		 * 否则 LOOP 重试会把同一路径越积越多、且旧 inode 永远泄漏。 */
		if (!strcmp(susfs_paths[i].path, path)) {
			struct inode *old = susfs_paths[i].inode;

			ihold(inode);
			susfs_paths[i].inode = inode;
			mutex_unlock(&susfs_path_mutex);
			if (old) {
				susfs_owner_forget(old);
				iput(old);
			}
			return 0;
		}
	}
	if (susfs_path_count >= susfs_path_cap) {
		ret = susfs_path_grow_locked();
		if (ret) {
			mutex_unlock(&susfs_path_mutex);
			return ret;
		}
	}

	ihold(inode);
	susfs_paths[susfs_path_count].inode = inode;
	strscpy(susfs_paths[susfs_path_count].path, path, SUSFS_PATH_MAX_LEN);
	susfs_path_count++;
	mutex_unlock(&susfs_path_mutex);

	return 0;
}

static int susfs_path_add(const char *path)
{
	struct path p;
	uid_t raw = 0, mapped = 0;
	int ret;

	if (path[0] != '/')
		return -EINVAL;

	ret = kern_path(path, LOOKUP_FOLLOW, &p);
	if (ret)
		return ret;

	susfs_path_owner_uid(&p, &raw, &mapped);
	ret = susfs_path_add_inode(d_backing_inode(p.dentry), raw, mapped,
				   path);
	path_put(&p);
	return ret;
}

int susfs_path_abi_add(const char *path)
{
	return susfs_path_add(path);
}

/* 记录「最深的已存在父目录」，用于绕过 kworker 的 mount namespace */
static void susfs_loop_capture_base(struct susfs_loop_entry *e, const char *path)
{
	char buf[SUSFS_PATH_MAX_LEN];
	char *slash;
	struct path p;

	if (strlen(path) >= sizeof(buf))
		return;

	strscpy(buf, path, sizeof(buf));
	while ((slash = strrchr(buf, '/')) != NULL) {
		if (slash == buf)	/* 根目录本来就是存在的，不需要 base */
			break;
		*slash = '\0';
		if (!kern_path(buf, 0, &p)) {
			e->base = p;
			e->remainder = kstrdup(path + strlen(buf) + 1,
					       GFP_KERNEL);
			return;
		}
	}
}

static int susfs_loop_try_entry(struct susfs_loop_entry *e)
{
	struct path p;
	uid_t raw = 0, mapped = 0;
	int ret;

	if (e->base.mnt && e->remainder && e->remainder[0]) {
		/* 从捕获的父目录往下解析，不依赖当前进程的 namespace */
		ret = vfs_path_lookup(e->base.dentry, e->base.mnt,
				      e->remainder, 0, &p);
	} else {
		ret = kern_path(e->path, 0, &p);
	}
	if (ret)
		return ret;

	susfs_path_owner_uid(&p, &raw, &mapped);
	ret = susfs_path_add_inode(d_backing_inode(p.dentry), raw, mapped,
				   e->path);
	path_put(&p);
	return ret;
}

/* 调用方持 susfs_loop_mutex：把所有待定路径重新解析并入普通表 */
static int susfs_path_loop_resolve_locked(void)
{
	int i, resolved = 0;

	for (i = 0; i < susfs_loop_count; i++) {
		if (!susfs_loop_entries[i].path)
			continue;
		if (!susfs_loop_try_entry(&susfs_loop_entries[i]))
			resolved++;
	}
	return resolved;
}

static void susfs_path_loop_work_fn(struct work_struct *work)
{
	int resolved;
	bool pending;
	const struct cred *old = NULL;

	/* susfs_path_add() 只取 susfs_path_mutex，这里持 loop 锁在外层，
	 * 不存在反向加锁路径。 */
	mutex_lock(&susfs_loop_mutex);
	/* workqueue 的 cred 是 kernel 域，读 /data、/sdcard 会被 SELinux 拒绝；
	 * 临时切到加入者（ksu 域/root）的 cred 才能解析。 */
	if (susfs_loop_cred)
		old = override_creds(susfs_loop_cred);
	resolved = susfs_path_loop_resolve_locked();
	if (old)
		revert_creds(old);
	pending = susfs_loop_count > 0;
	mutex_unlock(&susfs_loop_mutex);

	susfs_path_log("sus_path loop: tick, %d pending, %d resolved\n",
		       susfs_loop_count, resolved);

	if (pending)
		schedule_delayed_work(&susfs_path_loop_work,
				      msecs_to_jiffies(SUSFS_PATH_LOOP_INTERVAL_MS));
}

int susfs_path_abi_add_loop(const char *path)
{
	struct susfs_loop_entry *e;
	int i, ret;

	if (!path || path[0] != '/')
		return -EINVAL;
	if (strlen(path) >= SUSFS_PATH_MAX_LEN)
		return -ENAMETOOLONG;

	mutex_lock(&susfs_loop_mutex);
	for (i = 0; i < susfs_loop_count; i++) {
		if (susfs_loop_entries[i].path &&
		    !strcmp(susfs_loop_entries[i].path, path)) {
			mutex_unlock(&susfs_loop_mutex);
			return 0;	/* 已登记 */
		}
	}
	if (susfs_loop_count >= SUSFS_PATH_LOOP_MAX) {
		mutex_unlock(&susfs_loop_mutex);
		return -ENOSPC;
	}
	e = &susfs_loop_entries[susfs_loop_count];
	e->path = kstrdup(path, GFP_KERNEL);
	if (!e->path) {
		mutex_unlock(&susfs_loop_mutex);
		return -ENOMEM;
	}
	/* 深父目录 + 剩余部分：kworker 里 /sdcard 解析不了，靠这个绕开 */
	susfs_loop_capture_base(e, path);
	if (!susfs_loop_cred)
		susfs_loop_cred = get_current_cred();
	susfs_loop_count++;
	mutex_unlock(&susfs_loop_mutex);

	susfs_path_log("sus_path loop: queued %s\n", path);

	/* 立刻试一次；路径还不存在属于正常情况，LOOP 语义下仍返回成功。 */
	ret = susfs_path_add(path);
	if (ret && ret != -ENOENT)
		return ret;

	schedule_delayed_work(&susfs_path_loop_work,
			      msecs_to_jiffies(SUSFS_PATH_LOOP_INTERVAL_MS));
	return 0;
}

static ssize_t susfs_path_write(struct file *file, const char __user *ubuf,
				size_t count, loff_t *ppos)
{
	char *kbuf;
	size_t len;
	int ret;

	if (!count || count > PATH_MAX)
		return -EINVAL;

	kbuf = memdup_user_nul(ubuf, count);
	if (IS_ERR(kbuf))
		return PTR_ERR(kbuf);

	len = strnlen(kbuf, count);
	while (len && (kbuf[len - 1] == '\n' || kbuf[len - 1] == '\r' ||
		       kbuf[len - 1] == ' ' || kbuf[len - 1] == '\t'))
		kbuf[--len] = '\0';

	if (!len) {
		kfree(kbuf);
		return -EINVAL;
	}

	if (!strcmp(kbuf, "clear")) {
		susfs_path_clear();
		kfree(kbuf);
		return count;
	}

	/* 调试开关：echo owner_bypass=0 > /proc/susfs_add_sus_path
	 * 关掉属主放行即可复现"连属主一起隐藏"的上游 v2.x 行为，用于 A/B 对比。 */
	if (!strncmp(kbuf, "owner_bypass=", 13)) {
		WRITE_ONCE(susfs_owner_bypass, kbuf[13] != '0');
		susfs_path_log("sus_path: owner_bypass=%d\n",
			       READ_ONCE(susfs_owner_bypass));
		kfree(kbuf);
		return count;
	}

	ret = susfs_path_add(kbuf);
	kfree(kbuf);

	return ret ? ret : count;
}

static ssize_t susfs_path_read(struct file *file, char __user *ubuf,
			       size_t count, loff_t *ppos)
{
	char *out;
	size_t used = 0, total, chunk;
	int i, n;

	/*
	 * 一次把所有条目渲染到内存，再按 *ppos 拷对应片段。
	 * 之前用固定 PAGE_SIZE 缓冲 + "if (*ppos) return 0"，列表超过 4KB
	 * 时后续读取直接返回 0，回显被截断（199 条只能看到 99 条）。
	 */
	mutex_lock(&susfs_path_mutex);
	total = (size_t)susfs_path_count * (SUSFS_PATH_MAX_LEN + 16) + 1;
	mutex_unlock(&susfs_path_mutex);

	out = kvzalloc(total, GFP_KERNEL);
	if (!out)
		return -ENOMEM;

	mutex_lock(&susfs_path_mutex);
	for (i = 0; i < susfs_path_count; i++) {
		n = scnprintf(out + used, total - used, "%s\n",
			      susfs_paths[i].path);
		if (n <= 0 || used + n >= total)
			break;
		used += n;
	}
	mutex_unlock(&susfs_path_mutex);

	if (*ppos >= used) {
		kvfree(out);
		return 0;
	}
	chunk = used - *ppos;
	if (chunk > count)
		chunk = count;

	if (copy_to_user(ubuf, out + *ppos, chunk)) {
		kvfree(out);
		return -EFAULT;
	}

	kvfree(out);
	*ppos += chunk;
	return chunk;
}

#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 6, 0)
static const struct proc_ops susfs_path_fops = {
	.proc_read  = susfs_path_read,
	.proc_write = susfs_path_write,
	.proc_lseek = noop_llseek,
};
#else
static const struct file_operations susfs_path_fops = {
	.read  = susfs_path_read,
	.write = susfs_path_write,
	.llseek = noop_llseek,
};
#endif

#define SUSFS_PATH_LOOP_PROC "susfs_sus_path_loop"

/*
 * LOOP 表的观察/兜底入口：
 *   读        -> "count=N" + 每条待定路径
 *   写任意内容 -> 立即重试解析一次（不依赖定时器）
 */
static ssize_t susfs_path_loop_proc_read(struct file *file, char __user *ubuf,
					 size_t count, loff_t *ppos)
{
	char *out;
	size_t used;
	int i, n;

	if (*ppos)
		return 0;

	out = kmalloc(PAGE_SIZE, GFP_KERNEL);
	if (!out)
		return -ENOMEM;

	mutex_lock(&susfs_loop_mutex);
	n = scnprintf(out, PAGE_SIZE, "count=%d\n", susfs_loop_count);
	used = n > 0 ? n : 0;
	for (i = 0; i < susfs_loop_count; i++) {
		if (used >= PAGE_SIZE - 1)
			break;
		n = scnprintf(out + used, PAGE_SIZE - used, "%s\n",
			      susfs_loop_entries[i].path ?
				      susfs_loop_entries[i].path : "-");
		if (n <= 0)
			break;
		used += n;
	}
	mutex_unlock(&susfs_loop_mutex);

	if (used > count)
		used = count;
	if (copy_to_user(ubuf, out, used)) {
		kfree(out);
		return -EFAULT;
	}
	kfree(out);
	*ppos += used;
	return used;
}

static ssize_t susfs_path_loop_proc_write(struct file *file,
					  const char __user *ubuf,
					  size_t count, loff_t *ppos)
{
	int resolved;

	mutex_lock(&susfs_loop_mutex);
	resolved = susfs_path_loop_resolve_locked();
	mutex_unlock(&susfs_loop_mutex);

	susfs_path_log("sus_path loop: manual retry, %d resolved\n", resolved);
	return count;
}

#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 6, 0)
static const struct proc_ops susfs_path_loop_fops = {
	.proc_read  = susfs_path_loop_proc_read,
	.proc_write = susfs_path_loop_proc_write,
	.proc_lseek = noop_llseek,
};
#else
static const struct file_operations susfs_path_loop_fops = {
	.read   = susfs_path_loop_proc_read,
	.write  = susfs_path_loop_proc_write,
	.llseek = noop_llseek,
};
#endif

static int __init susfs_path_init(void)
{
	INIT_DELAYED_WORK(&susfs_path_loop_work, susfs_path_loop_work_fn);

	if (!proc_create(SUSFS_PATH_PROC, 0600, NULL, &susfs_path_fops))
		return -ENOMEM;
	if (!proc_create(SUSFS_PATH_LOOP_PROC, 0600, NULL,
			 &susfs_path_loop_fops))
		return -ENOMEM;

	pr_info("susfs: sus_path ready (/proc/%s)\n", SUSFS_PATH_PROC);
	return 0;
}
device_initcall(susfs_path_init);
