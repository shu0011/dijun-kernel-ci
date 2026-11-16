// SPDX-License-Identifier: GPL-2.0
/*
 * SUSFS stage-1: spoof_uname (built-in)
 *
 * 控制接口：/proc/susfs_spoof_uname  0600（仅 root）
 *   写 "0" 或 "off"        -> 关闭伪装
 *   写 "<release>"          -> 只伪装 release（uname -r）
 *   写 "<release>\n<version>" -> 同时伪装 release 与 version（uname -v）
 *   读                    -> "0\n" 或 "1\n<release>\n<version>\n"
 *
 * 与 LKM 版的语义保持一致：只改 release/version 两个字段，
 * sysname/nodename/machine 不动（那三项在 GKI 上本来就是通用值）。
 */
#include <linux/err.h>
#include <linux/fs.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/mutex.h>
#include <linux/proc_fs.h>
#include <linux/sched.h>
#include <linux/string.h>
#include <linux/susfs_uname.h>
#include <linux/uaccess.h>
#include <linux/utsname.h>
#include <linux/version.h>

#define SUSFS_UNAME_PROC "susfs_spoof_uname"
#define SUSFS_UNAME_LEN  65

static struct {
	bool enabled;
	char release[SUSFS_UNAME_LEN];
	char version[SUSFS_UNAME_LEN];
} susfs_uts;

static DEFINE_MUTEX(susfs_uts_mutex);

bool susfs_is_uname_spoofed(void)
{
	return READ_ONCE(susfs_uts.enabled);
}

void susfs_spoof_uname(struct new_utsname *u)
{
	if (!u || !READ_ONCE(susfs_uts.enabled))
		return;

	if (susfs_uts.release[0])
		strscpy(u->release, susfs_uts.release, sizeof(u->release));
	if (susfs_uts.version[0])
		strscpy(u->version, susfs_uts.version, sizeof(u->version));
}

static ssize_t susfs_uname_read(struct file *file, char __user *buf,
				size_t count, loff_t *ppos)
{
	char out[2 * SUSFS_UNAME_LEN + 8];
	int len;

	if (*ppos)
		return 0;

	mutex_lock(&susfs_uts_mutex);
	if (susfs_uts.enabled)
		len = scnprintf(out, sizeof(out), "1\n%s\n%s\n",
				susfs_uts.release, susfs_uts.version);
	else
		len = scnprintf(out, sizeof(out), "0\n");
	mutex_unlock(&susfs_uts_mutex);

	if ((size_t)len > count)
		len = count;
	if (copy_to_user(buf, out, len))
		return -EFAULT;

	*ppos += len;
	return len;
}

static void susfs_rtrim(char *s)
{
	size_t n = strlen(s);

	while (n && (s[n - 1] == ' ' || s[n - 1] == '\t'))
		s[--n] = '\0';
}

static char *susfs_ltrim(char *s)
{
	while (*s == ' ' || *s == '\t')
		s++;
	return s;
}

/*
 * 写入解析：按第一个换行切成 release / version 两段；
 * 两段都会去掉首尾空白，空串表示"该字段不伪装"。
 */
void susfs_uname_abi_set(const char *release, const char *version)
{
	mutex_lock(&susfs_uts_mutex);
	memset(susfs_uts.release, 0, sizeof(susfs_uts.release));
	memset(susfs_uts.version, 0, sizeof(susfs_uts.version));
	if (release && release[0])
		strscpy(susfs_uts.release, release, sizeof(susfs_uts.release));
	if (version && version[0])
		strscpy(susfs_uts.version, version, sizeof(susfs_uts.version));
	susfs_uts.enabled = (susfs_uts.release[0] || susfs_uts.version[0]);
	mutex_unlock(&susfs_uts_mutex);
}

static ssize_t susfs_uname_write(struct file *file, const char __user *buf,
				 size_t count, loff_t *ppos)
{
	char *kbuf, *nl;
	char rel[SUSFS_UNAME_LEN] = { 0 };
	char ver[SUSFS_UNAME_LEN] = { 0 };
	size_t len;

	if (!count || count > (SUSFS_UNAME_LEN * 2))
		return -EINVAL;

	kbuf = memdup_user_nul(buf, count);
	if (IS_ERR(kbuf))
		return PTR_ERR(kbuf);

	len = strnlen(kbuf, count);
	while (len && (kbuf[len - 1] == '\n' || kbuf[len - 1] == '\r'))
		kbuf[--len] = '\0';

	if (!len) {
		kfree(kbuf);
		return -EINVAL;
	}

	if (!strcmp(kbuf, "0") || !strcmp(kbuf, "off")) {
		mutex_lock(&susfs_uts_mutex);
		susfs_uts.enabled = false;
		memset(susfs_uts.release, 0, sizeof(susfs_uts.release));
		memset(susfs_uts.version, 0, sizeof(susfs_uts.version));
		mutex_unlock(&susfs_uts_mutex);
		kfree(kbuf);
		return count;
	}

	nl = strchr(kbuf, '\n');
	if (nl) {
		*nl = '\0';
		strscpy(ver, susfs_ltrim(nl + 1), sizeof(ver));
		susfs_rtrim(ver);
	}
	strscpy(rel, susfs_ltrim(kbuf), sizeof(rel));
	susfs_rtrim(rel);

	mutex_lock(&susfs_uts_mutex);
	strscpy(susfs_uts.release, rel, sizeof(susfs_uts.release));
	strscpy(susfs_uts.version, ver, sizeof(susfs_uts.version));
	susfs_uts.enabled = (rel[0] || ver[0]);
	mutex_unlock(&susfs_uts_mutex);

	kfree(kbuf);
	return count;
}

#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 6, 0)
static const struct proc_ops susfs_uname_fops = {
	.proc_read  = susfs_uname_read,
	.proc_write = susfs_uname_write,
	.proc_lseek = noop_llseek,
};
#else
static const struct file_operations susfs_uname_fops = {
	.read  = susfs_uname_read,
	.write = susfs_uname_write,
	.llseek = noop_llseek,
};
#endif

static int __init susfs_uname_init(void)
{
	if (!proc_create(SUSFS_UNAME_PROC, 0600, NULL, &susfs_uname_fops))
		return -ENOMEM;

	pr_info("susfs: spoof_uname ready (/proc/%s)\n", SUSFS_UNAME_PROC);
	return 0;
}
device_initcall(susfs_uname_init);
