# dijun 内核 CI 构建（GitHub Actions）

> 目标设备：小米 15S Pro（dijun），OS4.0.4.0.XODCNXM
> 原厂内核：`6.18.21-android17-5-g284297031c53-abogki553682993-4k`（KMI android17-6.18）

## 这个仓库干什么

在 Linux runner 上编译 `android17-6.18` 内核，用**从设备原厂 `boot.img` 里抽出来的 config**，
然后把编出来的 `.BTF` 和**同一份原厂 Image 里抠出来的 BTF** 逐类型比对。

**这一步不加 SUSFS。** 它只回答一个问题：这棵树 + 这份 config，能不能长出与设备同 ABI 的内核。
对上了才谈移植；对不上说明源码版本差太多，及时止损。

## 为什么必须在 Linux 上编

macOS 上缺三样**必需**的东西，而且都不能用替身糊过去：

| 缺什么 | 谁要它 | 为什么不能绕 |
|---|---|---|
| `libdwarf`（`dwarf.h`） | `scripts/gendwarfksyms` | 它决定导出符号的 **CRC**；CRC 不一致，厂商那几十个 `.ko` 全部拒绝加载 |
| OpenSSL 头 | `scripts/sign-file` | 模块签名链，`CONFIG_MODULE_SIG_PROTECT` 带白名单 |
| GNU sed | `scripts/headers_install.sh` | BSD sed 不支持嵌套地址块 |

顺带 macOS 还缺 `elf.h`、`endian.h`，且自带 GNU Make 只有 3.81（内核要 ≥4.0）。
这些在 Ubuntu 上 `apt install` 一行就齐。

## 产物

`out/` 里：

| 文件 | 说明 |
|---|---|
| `Image` | 编出来的 arm64 内核（**还不能刷**，见下） |
| `vmlinux.btf` | 从 vmlinux 抽出的 BTF，比对用 |
| `System.map` / `config.built` | 符号表与实际生效的 config |
| `btf-report.json` | 与设备 BTF 的逐类型比对结果 |
| `summary.txt` | 提交号、release 串、Image 大小与 sha256 |
| `build.log` | 完整构建日志 |

## 判读结果

打开 Actions 的 run 摘要，看这一行：

```
比较 11669 个类型，不一致 0，缺失 0，passed=True
```

- **passed=True** → 树和 config 对得上，可以进入下一步（移植 SUSFS 2.4）。
- **不一致 > 0** → 摘要里会列出前 10 个差异（通常是 `task_struct` 这类），说明源码提交差得太多，
  需要换到设备那个 `284297031c53` 的源码。

## 已知限制

1. **这版 Image 不能直接刷。** 它没有 SUSFS，也没有 KernelSU；而且 `boot` 分区还要处理 AVB，
   以及 `vendor_boot` / `dtbo` 的配套。那是下一步。
2. 取不到设备提交 `284297031c53` 时会用分支 HEAD，脚本会打印实际用的提交号——
   BTF 比对正是用来判断"HEAD 是否等价"的。
3. `LOCALVERSION` 被强制成设备那串（`-android17-5-g284297031c53-abogki553682993-4k`），
   否则 vermagic 与厂商模块对不上。这是有意的，不是造假数据——BTF 比对会独立证明结构是否一致。

## 手动跑

```bash
gh workflow run build-kernel.yml
gh run watch
gh run download --name dijun-kernel-<run_number> -D ./artifacts
```
