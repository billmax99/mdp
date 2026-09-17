# 生成赞助赞赏码占位图（docs/sponsor/wechat_luckin.png / wechat_other.png）
# 两栏均为微信赞赏码：咖啡杯=赞助一杯瑞幸，猫头=赞助一杯其它。
# 用途：README 赞助区先放占位图。拿到真实赞赏码后：原图存为同目录 *_raw.png，
# 再跑 tool/watermark_sponsor.py 生成带项目名水印的成品（覆盖同名文件）。
from PIL import Image, ImageDraw, ImageFont
import math
import os

FONT = r"C:\Windows\Fonts\msyh.ttc"
OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "docs", "sponsor")

W, H = 400, 470
GRAY = (150, 150, 150)
DASH, GAP, WIDTH = 12, 8, 3


def dash_poly(draw, pts, fill, dash=DASH, gap=GAP, width=WIDTH):
    """沿折线按弧长画虚线。"""
    on = True
    left = dash
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        length = math.hypot(x1 - x0, y1 - y0)
        if length == 0:
            continue
        t = 0.0
        while t < length:
            step = min(left, length - t)
            a = (x0 + (x1 - x0) * t / length, y0 + (y1 - y0) * t / length)
            b = (x0 + (x1 - x0) * (t + step) / length,
                 y0 + (y1 - y0) * (t + step) / length)
            if on:
                draw.line([a, b], fill=fill, width=width)
            t += step
            left -= step
            if left <= 0.01:
                on = not on
                left = dash if on else gap


def arc_pts(cx, cy, rx, ry, a0, a1, n=72):
    """参数化椭圆弧（角度按 PIL 习惯：0°=右，顺时针增大）。"""
    return [(cx + rx * math.cos(math.radians(a0 + (a1 - a0) * i / n)),
             cy + ry * math.sin(math.radians(a0 + (a1 - a0) * i / n)))
            for i in range(n + 1)]


def qr_mark(draw, cx, cy, size, color):
    """二维码角标示意：嵌套空心方块。"""
    half = size // 2
    draw.rectangle([cx - half, cy - half, cx + half, cy + half],
                   outline=color, width=6)
    inner = size * 0.4
    draw.rectangle([cx - inner, cy - inner, cx + inner, cy + inner],
                   outline=color, width=3)


def draw_coffee(draw, title_font, sub_font, hint_font):
    """咖啡杯外框（咖啡棕）——赞助一杯瑞幸。"""
    coffee = (101, 67, 33)
    light = (160, 110, 70)
    # 杯口
    dash_poly(draw, [(70, 70), (330, 70)], coffee)
    # 杯身（左、圆角底、右）一条连贯轮廓
    contour = [(330, 70), (330, 290)]
    contour += arc_pts(290, 290, 40, 40, 0, 90)      # 右下圆角
    contour += [(290, 330), (110, 330)]
    contour += arc_pts(110, 290, 40, 40, 90, 180)    # 左下圆角
    contour += [(70, 290), (70, 70)]
    dash_poly(draw, contour, coffee)
    # 杯柄（右侧外凸半椭圆）
    dash_poly(draw, arc_pts(332, 175, 40, 60, -70, 70), coffee)
    # 热气（两条波浪短线）
    for x0 in (165, 235):
        steam = [(x0 + 10 * math.sin(math.radians(i * 40)), 30 + i * 5)
                 for i in range(6)]
        dash_poly(draw, steam, light, dash=8, gap=6, width=2)
    # 碟子
    dash_poly(draw, arc_pts(200, 355, 140, 20, 0, 360), light)
    # 内容
    qr_mark(draw, 200, 175, 100, coffee)
    draw.text((200, 262), "微信赞赏码", font=title_font, fill=coffee, anchor="mm")
    draw.text((200, 300), "（占位图 · 赞助一杯瑞幸）", font=sub_font, fill=GRAY, anchor="mm")
    draw.text((200, 440), "请替换为真实赞赏码（流程见 docs/sponsor/README.md）",
              font=hint_font, fill=GRAY, anchor="mm")


def draw_cat(draw, title_font, sub_font, hint_font):
    """猫头外框（微信绿）——赞助一杯其它。"""
    green = (7, 193, 96)
    cx, cy, r = 200, 255, 140
    # 左耳：圆上 190°~230° 两点向外拉出三角
    p190 = (cx + r * math.cos(math.radians(190)), cy + r * math.sin(math.radians(190)))
    p230 = (cx + r * math.cos(math.radians(230)), cy + r * math.sin(math.radians(230)))
    apex_l = (66, 112)
    # 右耳（镜像）
    p310 = (cx + r * math.cos(math.radians(310)), cy + r * math.sin(math.radians(310)))
    p350 = (cx + r * math.cos(math.radians(350)), cy + r * math.sin(math.radians(350)))
    apex_r = (334, 112)
    # 头顶弧（两耳之间：230°→310° 经过 270°）
    dash_poly(draw, arc_pts(cx, cy, r, r, 230, 310), green)
    # 下半圆弧（350°→190° 经过 0/90/180°）
    dash_poly(draw, arc_pts(cx, cy, r, r, 350, 550), green)
    # 两只耳朵
    dash_poly(draw, [p190, apex_l, p230], green)
    dash_poly(draw, [p310, apex_r, p350], green)
    # 内容（猫脸位置放二维码示意）
    qr_mark(draw, 200, 200, 100, green)
    draw.text((200, 295), "微信赞赏码", font=title_font, fill=green, anchor="mm")
    draw.text((200, 332), "（占位图 · 赞助一杯其它）", font=sub_font, fill=GRAY, anchor="mm")
    draw.text((200, 440), "请替换为真实赞赏码（流程见 docs/sponsor/README.md）",
              font=hint_font, fill=GRAY, anchor="mm")


os.makedirs(OUT_DIR, exist_ok=True)
title_font = ImageFont.truetype(FONT, 34)
sub_font = ImageFont.truetype(FONT, 22)
hint_font = ImageFont.truetype(FONT, 18)  # 20 字提示在 400px 画布内需 ≤18px 才不裁切

for name, painter in [("wechat_luckin.png", draw_coffee), ("wechat_other.png", draw_cat)]:
    img = Image.new("RGB", (W, H), "white")
    painter(ImageDraw.Draw(img), title_font, sub_font, hint_font)
    img.save(os.path.join(OUT_DIR, name))
    print("wrote", name)
