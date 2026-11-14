#!/usr/bin/env python3
"""比较两棵内核的 BTF：结构体/联合体的 sizeof 与成员偏移是否一致。

用途：CI 里编出来的 Image 自带 .BTF，和从设备原厂 boot.img 里抠出来的 BTF 对比。
如果 862 个类型全部一致，说明"这棵树 + 这份 config"确实能长出与设备同 ABI 的内核；
只要有一个类型 sizeof 或成员偏移不同，就说明源码版本或 config 差得太多，不能刷。

容忍 split BTF 的 name_off 越界（模块 BTF 才会出现；vmlinux BTF 不会）。
"""
from __future__ import annotations

import argparse
import json
import struct
import sys
from pathlib import Path


def load_btf(path: Path) -> dict:
    data = path.read_bytes()
    magic, version, _flags, hdr, off, length, soff, slen = struct.unpack_from("<HBBIIIII", data)
    if magic != 0xEB9F or version != 1:
        raise SystemExit(f"{path}: 不是 little-endian BTF v1")

    start = hdr + soff
    strings = data[start:start + slen]

    def name(n: int) -> str:
        if n >= len(strings):
            return ""
        end = strings.find(b"\0", n)
        return strings[n:end if end >= 0 else len(strings)].decode(errors="replace")

    types, named = {}, {}
    pos, end, ident = hdr + off, hdr + off + length, 1
    while pos < end:
        n, info, size = struct.unpack_from("<III", data, pos)
        pos += 12
        kind, vlen, kflag = (info >> 24) & 31, info & 65535, info >> 31
        rec = {"kind": kind, "name": name(n), "size": size, "members": []}
        if kind in (4, 5):
            for i in range(vlen):
                mn, _mt, mo = struct.unpack_from("<III", data, pos + 12 * i)
                rec["members"].append({
                    "name": name(mn),
                    "offset": (mo & 0xFFFFFF) if kflag else mo,
                    "bits": (mo >> 24) if kflag else 0,
                })
            extra = 12 * vlen
        elif kind == 1:
            extra = 4
        elif kind == 3:
            extra = 12
        elif kind in (6, 13):
            extra = 8 * vlen
        elif kind in (14, 17):
            extra = 4
        elif kind in (15, 19):
            extra = 12 * vlen
        else:
            extra = 0
        types[ident] = rec
        if rec["name"]:
            named.setdefault(rec["name"], []).append(ident)
        pos += extra
        ident += 1
    return {"types": types, "named": named}


def signature(rec: dict) -> str:
    return json.dumps([rec["size"],
                       [(m["name"], m["offset"], m["bits"]) for m in rec["members"]]],
                      sort_keys=True)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--kernel", required=True, help="编出来的 vmlinux BTF")
    ap.add_argument("--device", required=True, help="从原厂 boot.img 抠出的 BTF")
    ap.add_argument("--json", required=True)
    ap.add_argument("--allow-missing", action="store_true",
                    help="设备有但我们的内核没有的类型只记录、不判失败")
    a = ap.parse_args()

    k = load_btf(Path(a.kernel))
    d = load_btf(Path(a.device))

    compared, mismatches, missing = 0, [], []
    for name, ids in d["named"].items():
        drecs = [d["types"][i] for i in ids if d["types"][i]["kind"] in (4, 5)]
        if not drecs:
            continue
        if name not in k["named"]:
            missing.append(name)
            continue
        krecs = [k["types"][i] for i in k["named"][name] if k["types"][i]["kind"] in (4, 5)]
        if not krecs:
            missing.append(name)
            continue
        dset = {signature(r) for r in drecs}
        kset = {signature(r) for r in krecs}
        compared += 1
        if not (dset & kset):
            dm = drecs[0]
            km = krecs[0]
            diff = []
            if dm["size"] != km["size"]:
                diff.append({"field": "sizeof", "device": dm["size"], "kernel": km["size"]})
            if dm["name"] == km["name"]:
                kmap = {m["name"]: m for m in km["members"]}
                for m in dm["members"]:
                    other = kmap.get(m["name"])
                    if other is None:
                        diff.append({"field": m["name"], "device": [m["offset"], m["bits"]],
                                     "kernel": None})
                    elif (other["offset"], other["bits"]) != (m["offset"], m["bits"]):
                        diff.append({"field": m["name"],
                                     "device": [m["offset"], m["bits"]],
                                     "kernel": [other["offset"], other["bits"]]})
            mismatches.append({"type": name, "problems": diff[:12]})

    report = {
        "passed": not mismatches and (a.allow_missing or not missing),
        "kernel_btf": str(a.kernel),
        "device_btf": str(a.device),
        "device_types": len({n for n, ids in d["named"].items()
                             if any(d["types"][i]["kind"] in (4, 5) for i in ids)}),
        "kernel_types": len({n for n, ids in k["named"].items()
                             if any(k["types"][i]["kind"] in (4, 5) for i in ids)}),
        "compared": compared,
        "mismatching": len(mismatches),
        "missing_in_kernel": len(missing),
        "mismatches": mismatches,
        "missing": sorted(missing)[:50],
    }
    Path(a.json).parent.mkdir(parents=True, exist_ok=True)
    Path(a.json).write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")

    print(f"比较 {compared} 个类型：不一致 {len(mismatches)}，缺失 {len(missing)}")
    for m in mismatches[:8]:
        print(f"  [x] {m['type']}: {m['problems'][:2]}")
    print("passed =", report["passed"])
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
