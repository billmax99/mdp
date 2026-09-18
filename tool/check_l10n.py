# -*- coding: utf-8 -*-
"""l10n 静态自检（本机无 Flutter SDK 的替代验证）：
1) main.dart 非注释行不再含中文字符串字面量
2) s('key') 用到的每个键在 zh/en 两表都存在；两表键集合一致
3) 带占位符（{n}/{name}）的键，zh/en 占位符一致
4) 无占位符的 zh 值必须逐字节出现在旧版（HEAD~0 改动前 = git show HEAD:lib/main.dart）源码中，
   保证 test/ 按中文文案断言不受影响
"""
import io, re, subprocess, sys

main = io.open("lib/main.dart", encoding="utf-8").read()
strings = io.open("lib/strings.dart", encoding="utf-8").read()

zh_pat = re.compile(r"[\u4e00-\u9fff]")
bad = []
for i, line in enumerate(main.splitlines(), 1):
    t = line.strip()
    code = t.split("//")[0]  # 行尾注释里的中文不算字符串字面量
    if zh_pat.search(code) and ("'" in code or '"' in code) and not t.startswith("//"):
        bad.append("%d: %s" % (i, t))
print("[1] main.dart 非注释中文串残留：%d" % len(bad))
for b in bad:
    print("   ", b)

# 解析 strings.dart 两个 map
def block(lang):
    m = re.search(r"'" + lang + r"':\s*\{(.*?)\n  \},", strings, re.S)
    body = m.group(1)
    out = {}
    for km in re.finditer(r"'([a-z_0-9]+)':\s*((?:'(?:[^'\\]|\\.)*'|\"(?:[^\"\\]|\\.)*\"))", body):
        key, raw = km.group(1), km.group(2)
        val = raw[1:-1]
        val = val.replace("\\'", "'").replace('\\"', '"').replace("\\n", "\n")
        out[key] = val
    return out

langs = ["zh", "en", "ja", "ko", "de", "fr"]
tables = {lg: block(lg) for lg in langs}
used = set(re.findall(r"s\('([a-z_0-9]+)'\)", main))
dynamic_themes = {"theme_light", "theme_dark", "theme_paper", "theme_warm", "theme_green", "theme_blue"}
used |= dynamic_themes

miss = {lg: sorted(k for k in used if k not in tables[lg]) for lg in langs}
zh_keys = set(tables["zh"])
only = {lg: sorted(set(tables[lg]) ^ zh_keys) for lg in langs}
print("[2] 缺键:", {k: v for k, v in miss.items() if v})
print("    表间键差异:", {k: v for k, v in only.items() if v})

ph = re.compile(r"\{(n|name)\}")
ph_bad = []
for lg in langs:
    for k, v in tables[lg].items():
        if k in zh_keys and sorted(ph.findall(v)) != sorted(ph.findall(tables["zh"][k])):
            ph_bad.append("%s:%s" % (lg, k))
print("[3] 占位符与 zh 不一致：%s" % ph_bad)

old = subprocess.run(["git", "show", "HEAD:lib/main.dart"], capture_output=True).stdout.decode("utf-8")
not_found = []
for k, v in tables["zh"].items():
    if ph.search(v) or k.startswith("theme_"):
        continue  # 带占位符的与主题名无法直接子串匹配，人工核对
    if v.replace("\n", "\\n") not in old:
        not_found.append("%s: %r" % (k, v))
print("[4] zh 值在旧源码中找不到：%d" % len(not_found))
for x in not_found:
    print("   ", x)

ok = not (bad or any(miss.values()) or any(only.values()) or ph_bad or not_found)
print("RESULT:", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
