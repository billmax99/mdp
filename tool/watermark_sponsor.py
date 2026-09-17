# 处理真实微信赞赏码截图，输出 docs/sponsor/wechat_luckin.png / wechat_other.png
# 用法：
#   1. 把赞赏码原图存为 docs/sponsor/wechat_luckin_raw.png / wechat_other_raw.png
#      （*_raw.png 已 gitignore，只有成品入库）
#   2. python tool/watermark_sponsor.py
# 只做标准化（透明底合白、统一宽度 400px），不加任何横幅水印
# （2026-09-17 按用户要求去掉绿横幅，二维码像素完全不动，不影响扫码）。
# 自定义出路径测试：python tool/watermark_sponsor.py <输入> <输出>
from PIL import Image
import os
import sys

SPONSOR_DIR = os.path.join(os.path.dirname(__file__), "..", "docs", "sponsor")
SLOTS = ["wechat_luckin", "wechat_other"]
TARGET_W = 400


def normalize(src, dst, brand):
    img = Image.open(src)
    # 透明底合成到白底，统一缩放到目标宽度
    if img.mode in ("RGBA", "LA", "P"):
        img = img.convert("RGBA")
        bg = Image.new("RGBA", img.size, "white")
        img = Image.alpha_composite(bg, img)
    img = img.convert("RGB")
    if img.width != TARGET_W:
        img = img.resize(
            (TARGET_W, round(img.height * TARGET_W / img.width)), Image.LANCZOS)
    img.save(dst)
    print(f"{brand}: {src} -> {dst} ({img.width}x{img.height})")


if __name__ == "__main__":
    if len(sys.argv) == 3:
        normalize(sys.argv[1], sys.argv[2], "custom")
    else:
        for name in SLOTS:
            raw = os.path.join(SPONSOR_DIR, f"{name}_raw.png")
            if not os.path.exists(raw):
                sys.exit(f"缺少 {raw}（先把赞赏码原图存为该文件）")
            normalize(raw, os.path.join(SPONSOR_DIR, f"{name}.png"), name)
