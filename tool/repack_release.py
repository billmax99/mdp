# 重新打包发布包 zip：MD+_v2.4.1_发布包.zip
# 内容与目录 MD+_v2.4.1_发布包/ 一致，UTF-8 文件名（与原 python 打包一致）。
import os
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "MD+_v2.4.1_发布包")
OUT = os.path.join(ROOT, "MD+_v2.4.1_发布包.zip")

if os.path.exists(OUT):
    os.remove(OUT)

count = 0
with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for dirpath, dirnames, filenames in os.walk(SRC):
        for name in sorted(filenames):
            full = os.path.join(dirpath, name)
            arc = os.path.relpath(full, ROOT)
            z.write(full, arc)
            count += 1

print(f"packed {count} files -> {OUT} ({os.path.getsize(OUT)} bytes)")
