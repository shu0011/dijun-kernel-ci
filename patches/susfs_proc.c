// SPDX-License-Identifier: GPL-2.0
/*
 * SUSFS stage-2: /proc/cmdline 与 /proc/version 伪装（built-in）
 *
 * 控制接口：
 *   /proc/susfs_spoof_cmdline   0600
 *     写 "0" / "off"  -> 关闭
 *     写任意一行       -> 读 /proc/cmdline 时返回这一行
 *   /proc/susfs_spoof_version   0600
 *     写 "0" / "off"  -> 关闭
 *     写整行（含 Linux version ...）-> 读 /proc/version 时返回这一行
 *
 * 参考 LKM 版（susfs）的 spoof_cmdline 语义：整体替换，不做逐项过滤，
 * 因为检测软件对比的是"是否存在可疑参数"，逐项删更容易露出破绽。
 *
 * 注意：/proc/version 伪装是本项目的扩展，上游 susfs 没有这一项。
 * 上游只处理 /proc/cmdline（通过 fs/proc/bootconfig.c），这里两处都覆盖。
 */
#include <linux/err.h>
#include <linux/fs.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/mutex.h>
#include <linux/proc_fs.h>
#include <linux/sched.h>
#include <linux/seq_file.h>
#include <linux/string.h>
#include <linux/susfs_proc.h>
#include <linux/uaccess.h>
#include <linux/version.h>

#define SUSFS_CMDLINE_MAX 2048
#define SUSFS_VERSION_MAX 512

static struct {
	char buf[SUSFS_CMDLINE_MAX];
	bool enabled;
} susfs_cmdline;

static struct {
	char buf[SUSFS_VERSION_MAX];
	bool enabled;
} susfs_version;

static DEFINE_MUTEX(susfs_proc_mutex);

bool susfs_spoof_cmdline_show(struct seq_file *m)
{
	if (!READ_ONCE(susfs_cmdline.enabled))
		return false;

	seq_puts(m, susfs_cmdline.buf);
	seq_putc(m, '\n');

	return true;
}

bool susfs_spoof_version_show(struct seq_file *m)
{
	if (!READ_ONCE(susfs_version.enabled))
		return false;

	seq_puts(m, susfs_version.buf);
	seq_putc(m, '\n');

	return true;
}

/* 去掉行尾的 \n / \r / 空白；返回处理后的长度 */
static size_t susfs_chomp(char *s, size_t len)
{
	while (len && (s[len - 1] == '\n' || s[len - 1] == '\r' ||
		       s[len - 1] == ' ' || s[len - 1] == '\t'))
		s[--len] = '\0';
	return len;
}

static bool susfs_is_off(const char *s)
{
	return !strcmp(s, "0") || !strcmp(s, "off");
}

static ssize_t susfs_buf_read(char *buf, bool enabled, char __user *ubuf,
			      size_t count, loff_t *ppos)
{
	char *out;
	int len;
	size_t n;

	if (*ppos)
		return 0;

	/* 不能放栈上：内核栈帧上限 2048，这里需要 2KB+ */
	out = kmalloc(SUSFS_CMDLINE_MAX + 8, GFP_KERNEL);
	if (!out)
		return -ENOMEM;

	mutex_lock(&susfs_proc_mutex);
	len = enabled ? scnprintf(out, SUSFS_CMDLINE_MAX + 8, "1\n%s\n", buf)
		      : scnprintf(out, SUSFS_CMDLINE_MAX + 8, "0\n");
	mutex_unlock(&susfs_proc_mutex);

	n = min((size_t)len, count);
	if (copy_to_user(ubuf, out, n)) {
		kfree(out);
		return -EFAULT;
	}

	kfree(out);
	*ppos += n;
	return n;
}

static ssize_t susfs_buf_write(char *buf, size_t bufsz, bool *enabled,
			       const char __user *ubuf, size_t count)
{
	char *kbuf;
	size_t len;

	if (!count || count > bufsz)
		return -EINVAL;

	kbuf = memdup_user_nul(ubuf, count);
	if (IS_ERR(kbuf))
		return PTR_ERR(kbuf);

	len = susfs_chomp(kbuf, strnlen(kbuf, count));

	mutex_lock(&susfs_proc_mutex);
	if (!len || susfs_is_off(kbuf)) {
		memset(buf, 0, bufsz);
		*enabled = false;
	} else {
		strscpy(buf, kbuf, bufsz);
		*enabled = true;
	}
	mutex_unlock(&susfs_proc_mutex);

	kfree(kbuf);
	return count;
}

static ssize_t susfs_cmdline_read(struct file *file, char __user *ubuf,
				  size_t count, loff_t *ppos)
{
	return susfs_buf_read(susfs_cmdline.buf, susfs_cmdline.enabled,
			      ubuf, count, ppos);
}

void susfs_cmdline_abi_set(const char *cmdline)
{
	mutex_lock(&susfs_proc_mutex);
	memset(susfs_cmdline.buf, 0, sizeof(susfs_cmdline.buf));
	if (cmdline && cmdline[0] && strcmp(cmdline, "0") && strcmp(cmdline, "off")) {
		strscpy(susfs_cmdline.buf, cmdline, sizeof(susfs_cmdline.buf));
		susfs_cmdline.enabled = true;
	} else {
		susfs_cmdline.enabled = false;
	}
	mutex_unlock(&susfs_proc_mutex);
}

static ssize_t susfs_cmdline_write(struct file *file, const char __user *ubuf,
				   size_t count, loff_t *ppos)
{
	return susfs_buf_write(susfs_cmdline.buf, sizeof(susfs_cmdline.buf),
			       &susfs_cmdline.enabled, ubuf, count);
}

static ssize_t susfs_version_read(struct file *file, char __user *ubuf,
				  size_t count, loff_t *ppos)
{
	return susfs_buf_read(susfs_version.buf, susfs_version.enabled,
			      ubuf, count, ppos);
}

static ssize_t susfs_version_write(struct file *file, const char __user *ubuf,
				   size_t count, loff_t *ppos)
{
	return susfs_buf_write(susfs_version.buf, sizeof(susfs_version.buf),
			       &susfs_version.enabled, ubuf, count);
}

#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 6, 0)
static const struct proc_ops susfs_cmdline_fops = {
	.proc_read  = susfs_cmdline_read,
	.proc_write = susfs_cmdline_write,
	.proc_lseek = noop_llseek,
};

static const struct proc_ops susfs_version_fops = {
	.proc_read  = susfs_version_read,
	.proc_write = susfs_version_write,
	.proc_lseek = noop_llseek,
};
#else
static const struct file_operations susfs_cmdline_fops = {
	.read  = susfs_cmdline_read,
	.write = susfs_cmdline_write,
	.llseek = noop_llseek,
};

static const struct file_operations susfs_version_fops = {
	.read  = susfs_version_read,
	.write = susfs_version_write,
	.llseek = noop_llseek,
};
#endif

static int __init susfs_proc_init(void)
{
	if (!proc_create("susfs_spoof_cmdline", 0600, NULL, &susfs_cmdline_fops))
		return -ENOMEM;
	if (!proc_create("susfs_spoof_version", 0600, NULL, &susfs_version_fops))
		return -ENOMEM;

	pr_info("susfs: spoof_cmdline / spoof_version ready\n");
	return 0;
}
device_initcall(susfs_proc_init);
