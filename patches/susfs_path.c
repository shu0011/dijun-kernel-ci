// SPDX-License-Identifier: GPL-2.0
/*
 * SUSFS stage-3: sus_path（built-in）
 *
 * 控制接口：/proc/susfs_add_sus_path  0600
 *   写绝对路径      -> 加入隐藏列表（重复写入幂等）
 *   写 "clear"      -> 清空列表
 *   读              -> 每行一个路径
 *
 * 匹配方式：d_path() 取真实路径后与列表逐项 strcmp。
 * 只对 app uid（>= 10000）生效，系统进程/root 不受影响——这点和 LKM 版一致，
 * 否则 init 在开机阶段会因为找不到 /data/adb 相关路径而崩。
 */
#include <linux/cred.h>
#include <linux/dcache.h>
#include <linux/err.h>
#include <linux/fs.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/limits.h>
#include <linux/list.h>
#include <linux/mutex.h>
#include <linux/path.h>
#include <linux/proc_fs.h>
#include <linux/sched.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/susfs_path.h>
#include <linux/uaccess.h>
#include <linux/version.h>

#define SUSFS_MAX_PATHS 64
#define SUSFS_PATH_PROC "susfs_add_sus_path"

struct susfs_path_entry {
	struct list_head node;
	char path[PATH_MAX];
};

static LIST_HEAD(susfs_paths);
static int susfs_path_count;
static DEFINE_MUTEX(susfs_path_mutex);

/*
 * 按"输入路径字符串"匹配，用于 namei 层（open / lookup）的早期拦截。
 * 只处理绝对路径：相对路径（"../x"）在解析前无法确定真实位置，交给 vfs_getattr 那层。
 */
bool susfs_is_hidden_name(const struct filename *name)
{
	struct susfs_path_entry *e;
	const char *s;
	size_t len;
	bool found = false;

	if (!name || !name->name)
		return false;

	if (!READ_ONCE(susfs_path_count))
		return false;

	if (likely(current_uid().val < 10000))
		return false;

	s = name->name;
	if (s[0] != '/')
		return false;

	mutex_lock(&susfs_path_mutex);
	list_for_each_entry(e, &susfs_paths, node) {
		len = strlen(e->path);
		if (!strncmp(s, e->path, len) &&
		    (s[len] == '\0' || s[len] == '/')) {
			found = true;
			break;
		}
	}
	mutex_unlock(&susfs_path_mutex);

	return found;
}

static bool susfs_path_matches(const char *real, const struct susfs_path_entry *e)
{
	size_t len = strlen(e->path);

	/* 精确命中 */
	if (!strcmp(real, e->path))
		return true;

	/*
	 * 前缀命中必须落在路径分隔符上：隐藏 /a/b 时 /a/b/c 也算隐藏，
	 * 但 /a/b_backup 不算，避免误伤同前缀的兄弟目录。
	 */
	if (len && real[len] == '/' && !strncmp(real, e->path, len))
		return true;

	return false;
}

bool susfs_is_hidden_path(const struct path *path)
{
	struct susfs_path_entry *e;
	char *buf, *p;
	bool found = false;

	if (!READ_ONCE(susfs_path_count))
		return false;

	/* 系统进程一律放行 */
	if (likely(current_uid().val < 10000))
		return false;

	buf = kmalloc(PATH_MAX, GFP_KERNEL);
	if (!buf)
		return false;

	p = d_path(path, buf, PATH_MAX);
	if (IS_ERR(p)) {
		kfree(buf);
		return false;
	}

	mutex_lock(&susfs_path_mutex);
	list_for_each_entry(e, &susfs_paths, node) {
		if (susfs_path_matches(p, e)) {
			found = true;
			break;
		}
	}
	mutex_unlock(&susfs_path_mutex);

	kfree(buf);
	return found;
}

static void susfs_path_clear(void)
{
	struct susfs_path_entry *e, *tmp;

	mutex_lock(&susfs_path_mutex);
	list_for_each_entry_safe(e, tmp, &susfs_paths, node) {
		list_del(&e->node);
		kfree(e);
	}
	susfs_path_count = 0;
	mutex_unlock(&susfs_path_mutex);
}

static int susfs_path_add(const char *path)
{
	struct susfs_path_entry *e;
	int ret = 0;

	if (path[0] != '/')
		return -EINVAL;

	mutex_lock(&susfs_path_mutex);
	list_for_each_entry(e, &susfs_paths, node) {
		if (!strcmp(e->path, path))
			goto out;	/* 已存在，幂等 */
	}
	if (susfs_path_count >= SUSFS_MAX_PATHS) {
		ret = -ENOSPC;
		goto out;
	}
	e = kzalloc(sizeof(*e), GFP_KERNEL);
	if (!e) {
		ret = -ENOMEM;
		goto out;
	}
	strscpy(e->path, path, sizeof(e->path));
	list_add_tail(&e->node, &susfs_paths);
	susfs_path_count++;
out:
	mutex_unlock(&susfs_path_mutex);
	return ret;
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

	ret = susfs_path_add(kbuf);
	kfree(kbuf);

	return ret ? ret : count;
}

static ssize_t susfs_path_read(struct file *file, char __user *ubuf,
			       size_t count, loff_t *ppos)
{
	struct susfs_path_entry *e;
	char *out;
	size_t used = 0;
	int n;

	if (*ppos)
		return 0;

	out = kmalloc(PAGE_SIZE, GFP_KERNEL);
	if (!out)
		return -ENOMEM;

	mutex_lock(&susfs_path_mutex);
	list_for_each_entry(e, &susfs_paths, node) {
		n = scnprintf(out + used, PAGE_SIZE - used, "%s\n", e->path);
		if (n <= 0)
			break;
		used += n;
		if (PAGE_SIZE - used < PATH_MAX)
			break;
	}
	mutex_unlock(&susfs_path_mutex);

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

static int __init susfs_path_init(void)
{
	if (!proc_create(SUSFS_PATH_PROC, 0600, NULL, &susfs_path_fops))
		return -ENOMEM;

	pr_info("susfs: sus_path ready (/proc/%s)\n", SUSFS_PATH_PROC);
	return 0;
}
device_initcall(susfs_path_init);
