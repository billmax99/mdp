# -*- coding: utf-8 -*-
"""盘点 main.dart 中含中文的非注释行（用户可见字符串候选）。"""
import io, re, sys

src = io.open(r"lib/main.dart", encoding="utf-8").read().splitlines()
pat = re.compile(r"[\u4e00-\u9fff]")
hits = []
for i, line in enumerate(src, 1):
    s = line.strip()
    if pat.search(s) and ("'" in s or '"' in s) and not s.startswith("//"):
        hits.append("%5d: %s" % (i, s))
out = io.open(r"tool/zh_lines.txt", "w", encoding="utf-8")
out.write("\n".join(hits))
out.close()
print(len(hits))
