# 生成赞助收款码占位图（docs/sponsor/wechat.png / alipay.png）
# 用途：README 赞助区先放占位图，拿到真实收款码后直接覆盖同名文件即可。
from PIL import Image, ImageDraw, ImageFont
import os

FONT = r"C:\Windows\Fonts\msyh.ttc"
OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "docs", "sponsor")

SPECS = [
    ("wechat.png", "微信收款码", (7, 190, 100)),
    ("alipay.png", "支付宝收款码", (32, 120, 255)),
]


def dashed_rect(draw, box, dash=12, gap=8, width=3, fill=(180, 180, 180)):
    x0, y0, x1, y1 = box

    def hline(y):
        x = x0
        while x < x1:
            end = min(x + dash, x1)
            draw.line([(x, y), (end, y)], fill=fill, width=width)
            x = end + gap

    def vline(x):
        y = y0
        while y < y1:
            end = min(y + dash, y1)
            draw.line([(x, y), (x, end)], fill=fill, width=width)
            y = end + gap

    hline(y0)
    hline(y1)
    vline(x0)
    vline(x1)


os.makedirs(OUT_DIR, exist_ok=True)
title_font = ImageFont.truetype(FONT, 34)
sub_font = ImageFont.truetype(FONT, 22)

for name, label, color in SPECS:
    img = Image.new("RGB", (400, 470), "white")
    d = ImageDraw.Draw(img)
    dashed_rect(d, (30, 30, 370, 400))
    # 中间画一个二维码角标示意
    d.rectangle([150, 120, 250, 220], outline=color, width=6)
    d.rectangle([170, 140, 230, 200], outline=color, width=3)
    d.text((200, 260), label, font=title_font, fill=color, anchor="mm")
    d.text((200, 310), "（占位图）", font=sub_font, fill=(150, 150, 150), anchor="mm")
    d.text((200, 440), "请替换为真实收款码图片，保持文件名不变",
           font=sub_font, fill=(150, 150, 150), anchor="mm")
    img.save(os.path.join(OUT_DIR, name))
    print("wrote", name)
