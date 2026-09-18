# -*- coding: utf-8 -*-
"""扫描 main.dart：s() 取词行上方 4 行内存在未闭合的 const 构造（编译隐患）。"""
import io, re

main = io.open("lib/main.dart", encoding="utf-8").read().splitlines()
risk = []
for i, line in enumerate(main):
    if re.search(r"\bs\('[a-z_0-9]+'\)", line):
        ctx = main[max(0, i - 4):i]
        for j, cl in enumerate(ctx):
            if re.search(r"\bconst\s+[A-Z]", cl) and cl.count("(") > cl.count(")"):
                risk.append("line %d 的 s() 处于 line %d 未闭合 const 构造内: %s" % (i + 1, i - len(ctx) + j + 1, cl.strip()))
print("const 包裹 s() 风险点:", len(risk))
for r in risk:
    print(" ", r)
