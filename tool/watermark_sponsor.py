# 给真实收款码加项目名水印，输出 docs/sponsor/{wechat,alipay}.png
# 用法：
#   1. 把微信/支付宝收款码原图存为 docs/sponsor/wechat_raw.png / alipay_raw.png
#      （*_raw.png 已 gitignore，只有加水印的成品入库）
#   2. python tool/watermark_sponsor.py
# 水印为顶部品牌色横幅（微信绿/支付宝蓝），二维码像素完全不动，不影响扫码。
# 自定义出路径测试：python tool/watermark_sponsor.py <输入> <输出> <wechat|alipay>
from PIL import Image, ImageDraw, ImageFont
import os
import sys

FONT = r"C:\Windows\Fonts\msyh.ttc"
SPONSOR_DIR = os.path.join(os.path.dirname(__file__), "..", "docs", "sponsor")
TEXT = "MD+ 官方收款码 · billmax99"
BANNER_H = 60
BRAND = {"wechat": (7, 193, 96), "alipay": (22, 119, 255)}  # 微信绿 / 支付宝蓝
TARGET_W = 400


def watermark(src, dst, brand):
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

    out = Image.new("RGB", (TARGET_W, img.height + BANNER_H), "white")
    out.paste(img, (0, BANNER_H))
    draw = ImageDraw.Draw(out)
    draw.rectangle([0, 0, TARGET_W, BANNER_H - 1], fill=BRAND[brand])
    # 字号自适应：从 22px 起缩到文字放得下为止
    size = 22
    while size > 12:
        font = ImageFont.truetype(FONT, size)
        if draw.textlength(TEXT, font=font) <= TARGET_W - 32:
            break
        size -= 1
    draw.text((TARGET_W // 2, BANNER_H // 2), TEXT, font=font,
              fill="white", anchor="mm")
    out.save(dst)
    print(f"{brand}: {src} -> {dst} ({out.width}x{out.height}, font {size}px)")


if __name__ == "__main__":
    if len(sys.argv) == 4:
        watermark(sys.argv[1], sys.argv[2], sys.argv[3])
    else:
        for name in ("wechat", "alipay"):
            raw = os.path.join(SPONSOR_DIR, f"{name}_raw.png")
            if not os.path.exists(raw):
                sys.exit(f"缺少 {raw}（先把真实收款码原图存为该文件）")
            watermark(raw, os.path.join(SPONSOR_DIR, f"{name}.png"), name)
