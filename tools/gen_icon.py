# gen_icon.py · 事务伴侣图标生成（M-029）
# 设计：深绿底圆角方 + 白色时钟表盘 + 绿色对勾（勾=完成事务，表盘=时间管理）
# 输出：安卓五档 mipmap PNG + Windows ico + 原图 512

from PIL import Image, ImageDraw
import os

GREEN_DARK = (46, 84, 60)     # 深绿底
GREEN_MID = (63, 108, 81)     # 主绿（App 主题色 #3F6C51）
GREEN_LIGHT = (166, 205, 178) # 浅绿
WHITE = (255, 255, 255)

def rounded(draw, box, radius, fill):
    draw.rounded_rectangle(box, radius=radius, fill=fill)

def draw_icon(size):
    """画一个 size x size 的图标"""
    s = size
    img = Image.new('RGBA', (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    # 圆角方形背景（安卓自适应图标安全区：内容收在中心 66%）
    m = int(s * 0.02)  # 外边距
    rounded(d, [m, m, s - m, s - m], radius=int(s * 0.22), fill=GREEN_DARK)

    # 内衬渐层感：叠一层稍小的深一点的绿
    m2 = int(s * 0.06)
    rounded(d, [m2, m2, s - m2, s - m2], radius=int(s * 0.20), fill=GREEN_MID)

    # 时钟表盘（白色圆环）
    cx, cy = s * 0.5, s * 0.42
    r = s * 0.20
    ring_w = max(2, int(s * 0.035))
    d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=WHITE, width=ring_w)

    # 指针（10:10 经典钟位）
    hand_w = max(2, int(s * 0.03))
    # 时针（向上偏左）
    d.line([cx, cy, cx - r * 0.45, cy - r * 0.62], fill=WHITE, width=hand_w)
    # 分针（向右上）
    d.line([cx, cy, cx + r * 0.55, cy - r * 0.50], fill=WHITE, width=hand_w)
    # 中心点
    d.ellipse([cx - hand_w, cy - hand_w, cx + hand_w, cy + hand_w], fill=WHITE)

    # 底部对勾（粗壮、活力）
    lw = max(3, int(s * 0.075))
    x1, y1 = s * 0.32, s * 0.78   # 勾的起点（左）
    x2, y2 = s * 0.455, s * 0.885 # 勾的底点
    x3, y3 = s * 0.70, s * 0.68   # 勾的挑起（右）
    d.line([x1, y1, x2, y2], fill=GREEN_LIGHT, width=lw)
    d.line([x2, y2, x3, y3], fill=GREEN_LIGHT, width=lw)
    # 圆头线帽效果：在线端画小圆
    for (px, py) in [(x1, y1), (x3, y3)]:
        d.ellipse([px - lw/2, py - lw/2, px + lw/2, py + lw/2], fill=GREEN_LIGHT)

    return img

base = r'D:/000-me-work/事务伴侣/app'
out_dirs = {
    'mipmap-mdpi': 48,
    'mipmap-hdpi': 72,
    'mipmap-xhdpi': 96,
    'mipmap-xxhdpi': 144,
    'mipmap-xxxhdpi': 192,
}
for dname, px in out_dirs.items():
    icon = draw_icon(px)
    path = os.path.join(base, 'android/app/src/main/res', dname, 'ic_launcher.png')
    icon.save(path)
    print(f'{dname}: {px}px OK')

# 512 原图（未来商店/自适应图标前景用）
draw_icon(512).save(os.path.join(base, 'assets_icon_512.png'))
print('512 原图 OK')

# Windows ico（多尺寸合一）
ico_sizes = [(16,16),(24,24),(32,32),(48,48),(64,64),(128,128),(256,256)]
imgs = [draw_icon(sz).resize((sz,sz), Image.LANCZOS) for sz in set(p for p,_ in ico_sizes)]
imgs[0].save(os.path.join(base, 'windows/runner/resources/app_icon.ico'),
             format='ICO', sizes=[(i.width, i.height) for i in imgs])
print('Windows ico OK')
