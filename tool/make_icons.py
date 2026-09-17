# 生成应用图标：安卓自适应前景、legacy 整图、Windows ico
# 运行：python tool/make_icons.py
from PIL import Image, ImageDraw, ImageFont

BLUE = (0, 122, 255, 255)  # iOS 蓝 #007AFF
FONT = r"C:\Windows\Fonts\arialbd.ttf"
S = 1024


def draw_md(text_color, px):
    """透明 1024 画布上画精确居中的 MD+ 字样（两步墨迹法，免疫字体测量偏差）"""
    tmp = Image.new("RGBA", (S * 2, S * 2), (0, 0, 0, 0))
    ImageDraw.Draw(tmp).text((S // 2, S // 2), "MD+", font=ImageFont.truetype(FONT, px), fill=text_color)
    bbox = tmp.getbbox()  # 实际墨迹范围
    glyph = tmp.crop(bbox)
    out = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    out.alpha_composite(glyph, ((S - glyph.width) // 2, (S - glyph.height) // 2))
    return out


# 自适应图标前景：字号 270（墨迹宽约 547px，中心安全区 ~624px 内）
draw_md((255, 255, 255, 255), 270).save("tool/icons/icon_fg.png")

# legacy 整图：蓝底 + 白 MD+
legacy = Image.new("RGBA", (S, S), BLUE)
legacy.alpha_composite(draw_md((255, 255, 255, 255), 340))
legacy.convert("RGB").save("tool/icons/icon_legacy.png")

# 无字版备用变体：纯蓝底（官网曾试用后改回完整图标，文件保留备用）
Image.new("RGBA", (S, S), BLUE).convert("RGB").save("tool/icons/icon_plain.png")

# Windows ico（多尺寸）
legacy.save("windows/runner/resources/app_icon.ico",
            format="ICO", sizes=[(256, 256), (128, 128), (64, 64), (48, 48), (32, 32), (16, 16)])
print("icons done")
