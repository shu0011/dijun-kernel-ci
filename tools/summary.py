#!/usr/bin/env python3
"""把构建摘要写进 $GITHUB_STEP_SUMMARY。"""
import json
import os
from pathlib import Path

out = Path(os.environ.get("GITHUB_STEP_SUMMARY", "/dev/stdout"))
lines = ["## 构建摘要", "```"]
summary = Path("out/summary.txt")
lines += summary.read_text().splitlines() if summary.exists() else ["（没有 summary）"]
lines += ["```", "## BTF 对比", "```"]
report = Path("out/btf-report.json")
if report.exists():
    d = json.loads(report.read_text())
    lines.append(f"比较 {d['compared']} 个类型，不一致 {d['mismatching']}，"
                 f"缺失 {d['missing_in_kernel']}，passed={d['passed']}")
    for m in d["mismatches"][:10]:
        lines.append(f"  [x] {m['type']} {m['problems'][:2]}")
else:
    lines.append("（没有报告）")
lines.append("```")
with out.open("a") as fh:
    fh.write("\n".join(lines) + "\n")
print("\n".join(lines))
