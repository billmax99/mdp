# 生成应用图标：安卓自适应前景、legacy 整图、Windows ico
# 运行：python tool/make_icons.py
from PIL import Image, ImageDraw, ImageFont

BLUE = (0, 122, 255, 255)  # iOS 蓝 #007AFF
FONT = r"C:\Windows\Fonts\arialbd.ttf"
S = 1024


def draw_md(text_color, px):
    """透明画布上画居中的 MD 字样，字高约 px 像素"""
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    f = ImageFont.truetype(FONT, px)
    box = d.textbbox((0, 0), "MD", font=f)
    w, h = box[2] - box[0], box[3] - box[1]
    d.text(((S - w) / 2 - box[0], (S - h) / 2 - box[1]), "MD+", font=f, fill=text_color)
    return img


# 自适应图标前景：字高 300（中心安全区 ~61% 即 ~624px 内）
draw_md((255, 255, 255, 255), 300).save("tool/icons/icon_fg.png")

# legacy 整图：蓝底 + 白 MD
legacy = Image.new("RGBA", (S, S), BLUE)
legacy.alpha_composite(draw_md((255, 255, 255, 255), 370))
legacy.convert("RGB").save("tool/icons/icon_legacy.png")

# Windows ico（多尺寸）
legacy.save("windows/runner/resources/app_icon.ico",
            format="ICO", sizes=[(256, 256), (128, 128), (64, 64), (48, 48), (32, 32), (16, 16)])
print("icons done")
