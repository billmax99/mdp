# 把真实微信赞赏码合成咖啡杯外框，输出 docs/sponsor/wechat_luckin.png
# （wechat_other.png 为同一张码的副本，文件名保留备用）
# 用法：
#   1. 赞赏码原图（截图裁好后）存为 docs/sponsor/wechat_luckin_raw.png
#      （*_raw.png 已 gitignore，只有成品入库）
#   2. python tool/watermark_sponsor.py
# 布局：二维码放大放进杯身，引导语（原图底部文字）拆出来放在碟子下方。
# 无横幅水印（2026-09-17 用户要求去掉）；二维码像素等比缩放，不影响扫码。
# 杯子画法沿用 tool/make_sponsor_placeholders.py 的虚线外框。
from PIL import Image, ImageDraw
import math
import os

SPONSOR_DIR = os.path.join(os.path.dirname(__file__), "..", "docs", "sponsor")
SLOTS = ["wechat_luckin", "wechat_other"]

W, H = 400, 440
DASH, GAP, WIDTH = 12, 8, 3
COFFEE = (101, 67, 33)
LIGHT = (160, 110, 70)
QR_MAX_W, QR_MAX_H = 236, 240   # 杯身内码的尺寸上限
QUOTE_MAX_W = 280               # 碟下引导语的宽度上限


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


def draw_cup_frame(draw):
    """咖啡杯虚线外框：杯口、杯身、杯柄、热气、碟子。"""
    dash_poly(draw, [(70, 70), (330, 70)], COFFEE)                 # 杯口
    contour = [(330, 70), (330, 290)]
    contour += arc_pts(290, 290, 40, 40, 0, 90)                    # 右下圆角
    contour += [(290, 330), (110, 330)]
    contour += arc_pts(110, 290, 40, 40, 90, 180)                  # 左下圆角
    contour += [(70, 290), (70, 70)]
    dash_poly(draw, contour, COFFEE)                               # 杯身
    dash_poly(draw, arc_pts(332, 200, 42, 62, -70, 70), COFFEE)    # 杯柄
    for x0 in (165, 235):                                          # 热气
        steam = [(x0 + 10 * math.sin(math.radians(i * 40)), 30 + i * 7)
                 for i in range(6)]
        dash_poly(draw, steam, LIGHT, dash=8, gap=6, width=2)
    dash_poly(draw, arc_pts(200, 355, 140, 20, 0, 360), LIGHT)     # 碟子


def trim_and_split(raw):
    """去白边；再把底部的引导语文字与上方的码拆成两块。"""
    g = raw.convert("L")
    px = g.load()
    w, h = g.size

    def row_dark(y):
        return sum(1 for x in range(w) if px[x, y] < 200)

    dark_rows = [y for y in range(h) if row_dark(y) > 0]
    top, bot = min(dark_rows), max(dark_rows)
    xs = [x for y in range(top, bot + 1) for x in range(w) if px[x, y] < 200]
    left, right = min(xs), max(xs)
    # 找最靠下的连续全白行带（≥15 行），作为码与引导语的分界
    gap_end = bot
    run = 0
    for y in range(bot, top, -1):
        if row_dark(y) == 0:
            run += 1
            if run >= 15:
                gap_end = y + run - 1  # 白带最后一行
                break
        else:
            run = 0
    qr = raw.crop((left, top, right + 1, gap_end + 1))
    quote = raw.crop((left, gap_end + 1, right + 1, bot + 1))
    return qr, quote


def fit(img, max_w, max_h):
    scale = min(max_w / img.width, max_h / img.height)
    return img.resize((round(img.width * scale), round(img.height * scale)),
                      Image.LANCZOS)


def compose(raw_path, dst, brand):
    raw = Image.open(raw_path).convert("RGB")
    qr, quote = trim_and_split(raw)
    qr = fit(qr, QR_MAX_W, QR_MAX_H)
    quote = fit(quote, QUOTE_MAX_W, quote.height * QUOTE_MAX_W / quote.width)

    canvas = Image.new("RGB", (W, H), "white")
    draw_cup_frame(ImageDraw.Draw(canvas))
    # 码在杯身内垂直水平居中（杯身内域 y74..328）
    canvas.paste(qr, ((W - qr.width) // 2, (74 + 328 - qr.height) // 2))
    # 引导语在碟子下方居中
    canvas.paste(quote, ((W - quote.width) // 2, 396))
    canvas.save(dst)
    print(f"{brand}: {raw_path} -> {dst} ({W}x{H}, qr {qr.width}x{qr.height}, "
          f"quote {quote.width}x{quote.height})")


if __name__ == "__main__":
    for name in SLOTS:
        raw = os.path.join(SPONSOR_DIR, f"{name}_raw.png")
        if not os.path.exists(raw):
            raise SystemExit(f"缺少 {raw}（先把赞赏码原图存为该文件）")
        compose(raw, os.path.join(SPONSOR_DIR, f"{name}.png"), name)
