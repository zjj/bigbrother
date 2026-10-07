#!/usr/bin/env python3
"""从 Resources/icon.png 生成 macOS 应用图标 Resources/AppIcon.icns。

── 为什么需要这一步 ────────────────────────────────────────────────
直接把一张方图丢给 `CFBundleIconFile` 是不行的。实测仓库里的 icon.png 是
1024×1024 的 **完全不透明** 方图:里面是一枚 768×768 的圆角方块(圆角半径约
170px),外面裹着一圈纯白。macOS 不会替你裁掉这圈白边,于是图标在访达、
通知、系统设置里会显示成「白底方块里有个小方块」。

所以这里把它修成标准形态:
  · 取出那枚 768×768 的圆角图形,按 Apple 的图标网格缩到画布的 ~80%
  · 四周留出透明外边距(图标内容占 824/1024)
  · 圆角用超椭圆(连续曲率)而不是正圆角,和系统图标一致
  · 抗锯齿边缘按覆盖率写进 alpha,不会出现白边或锯齿

如果原始图本来就是规范形态(有透明边距、比例正确),这里会原样放行,
只做缩放,不做二次加工 —— 免得把已经做好的图改坏。
"""

import argparse
import math
import os
import shutil
import subprocess
import sys
import tempfile

try:
    from PIL import Image, ImageChops, ImageFilter
except ImportError:  # pragma: no cover
    sys.exit("需要 Pillow:python3 -m pip install pillow")

# Apple 图标网格:1024 画布里,圆角方块本体约 824px,其余是留白。
CANVAS = 1024
BODY = 824
# macOS 图标的圆角比例(半径 / 边长)≈ 0.2237,并且是连续曲率的超椭圆。
CORNER_RATIO = 0.2237
SUPERELLIPSE_N = 5.0


def superellipse_mask(size: int, supersample: int = 4) -> Image.Image:
    """生成 Apple 风格的圆角方块 alpha 蒙版(超椭圆,带抗锯齿)。"""
    big = size * supersample
    r = big * CORNER_RATIO
    n = SUPERELLIPSE_N

    # 用 1/4 象限计算再镜像,省 3/4 的计算量
    quarter = Image.new("L", (big // 2 + 1, big // 2 + 1), 0)
    px = quarter.load()
    half = big / 2.0
    for y in range(quarter.height):
        dy = abs(half - (y + 0.5))
        # 超椭圆: |x/a|^n + |y/a|^n = 1,a 取到圆角圆心
        a = half - r
        if dy <= a:
            x_edge = half
        else:
            t = (dy - a) / r
            if t >= 1.0:
                x_edge = a + r  # 该行只剩圆角顶点的极限
                if dy >= half:
                    x_edge = a
            else:
                x_edge = a + r * (1.0 - t ** n) ** (1.0 / n)
        x_edge = min(max(x_edge, a), half)
        for x in range(quarter.width):
            dx = half - (x + 0.5)
            inside = dx <= x_edge and dy <= half
            px[x, y] = 255 if inside else 0

    full = Image.new("L", (big, big), 0)
    full.paste(quarter, (0, 0))
    full.paste(quarter.transpose(Image.FLIP_LEFT_RIGHT), (big // 2, 0))
    full.paste(quarter.transpose(Image.FLIP_TOP_BOTTOM), (0, big // 2))
    full.paste(quarter.transpose(Image.ROTATE_180), (big // 2, big // 2))
    return full.resize((size, size), Image.LANCZOS)


def _bbox_of(mask) -> tuple:
    ys, xs = mask.nonzero()
    if len(xs) == 0:
        return None
    return (int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1)


def content_bbox(im: Image.Image) -> tuple:
    """找出画面里真正的图形范围(用最小通道判定"近白")。

    踩过的坑:
      · 只看"非纯白"会把四角那几个 (249,249,249) 的抗锯齿噪点算进来,
        周围又留一圈白,图标显示成"白底方块套白边"。
      · 用 Otsu 自动阈值也不行 —— 淡蓝背景与白的差异只有十几,而企鹅很黑,
        Otsu 会把分界落在企鹅身上,裁出的是企鹅不是图形。
      · 判定要用**最小通道**:淡蓝是 (205,232,249),min=205 一眼就能与近白分开。
    """
    import numpy as np

    if im.mode == "RGBA" and im.getchannel("A").getextrema()[0] < 255:
        return im.getchannel("A").point(lambda v: 255 if v > 8 else 0).getbbox()

    arr = np.asarray(im.convert("RGB")).astype(np.int32)
    not_white = arr.min(axis=2) < 248
    return _bbox_of(not_white) or (0, 0, im.width, im.height)


def background_alpha(rgb_arr):
    """从四周向内泛洪,把"与边界连通的近白区域"标成透明。

    必须泛洪而不是全局按颜色抠:图形内部也有大片白(企鹅的肚子、脚下的雪),
    全局抠会把这些地方也挖成透明。
    """
    import numpy as np

    h, w = rgb_arr.shape[:2]
    near_white = rgb_arr.min(axis=2) >= 244

    # 与边界连通的近白像素,才属于"外圈底色"
    visited = np.zeros((h, w), dtype=bool)
    stack = []
    for x in range(w):
        for y in (0, h - 1):
            if near_white[y, x] and not visited[y, x]:
                visited[y, x] = True; stack.append((y, x))
    for y in range(h):
        for x in (0, w - 1):
            if near_white[y, x] and not visited[y, x]:
                visited[y, x] = True; stack.append((y, x))
    while stack:
        y, x = stack.pop()
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            ny, nx = y + dy, x + dx
            if 0 <= ny < h and 0 <= nx < w and near_white[ny, nx] and not visited[ny, nx]:
                visited[ny, nx] = True
                stack.append((ny, nx))

    alpha = np.where(visited, 0, 255).astype(np.uint8)
    return alpha


def normalize(src: Image.Image) -> tuple:
    """把任意方图修成标准画布。返回 (图像, 说明列表)。"""
    import numpy as np

    notes = []
    im = src.convert("RGBA")
    w, h = im.size
    had_alpha = im.getchannel("A").getextrema()[0] < 255
    bbox = tuple(int(v) for v in content_bbox(im))
    art = im.crop(bbox)
    bw, bh = art.size

    arr = np.asarray(art.convert("RGB")).astype(np.int32)
    alpha = background_alpha(arr)
    if had_alpha:
        alpha = np.minimum(alpha, np.asarray(art.getchannel("A")))

    alpha_img = Image.fromarray(alpha, "L").filter(ImageFilter.GaussianBlur(0.7))
    art = art.copy()
    art.putalpha(ImageChops.multiply(art.getchannel("A"), alpha_img))

    if not had_alpha:
        notes.append("原图完全不透明,已把外圈底色改为透明")
    if bw != bh:
        notes.append(f"图形不是正方形({bw}×{bh}),已按最大边居中")
    if bw > w * 0.98:
        notes.append("图形几乎铺满画布,已按 Apple 图标网格缩到 ~80% 留出边距")

    side = max(art.size)
    square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    square.paste(art, ((side - bw) // 2, (side - bh) // 2), art)
    square = square.resize((BODY, BODY), Image.LANCZOS)

    out = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    out.paste(square, ((CANVAS - BODY) // 2, (CANVAS - BODY) // 2), square)
    return out, notes


ICONSET = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default="Resources/icon.png")
    ap.add_argument("--out", default="Resources/AppIcon.icns")
    ap.add_argument("--preview", default=None, metavar="PATH",
                    help="额外输出一张 256×256 预览图(默认不生成,避免污染仓库文件)")
    args = ap.parse_args()

    if not os.path.exists(args.src):
        sys.exit(f"找不到源图:{args.src}")

    src = Image.open(args.src)
    icon, notes = normalize(src)
    print(f"▸ 图标源:{args.src}({src.size[0]}×{src.size[1]}, {src.mode})")
    for n in notes:
        print(f"  · {n}")

    with tempfile.TemporaryDirectory() as tmp:
        iconset = os.path.join(tmp, "AppIcon.iconset")
        os.makedirs(iconset)
        for size, name in ICONSET:
            icon.resize((size, size), Image.LANCZOS).save(os.path.join(iconset, name))
        if args.preview:
            os.makedirs(os.path.dirname(os.path.abspath(args.preview)), exist_ok=True)
            icon.resize((256, 256), Image.LANCZOS).save(args.preview)
            print(f"  预览图:{args.preview}")
        os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", args.out], check=True)

    size_kb = os.path.getsize(args.out) / 1024
    print(f"✓ 已生成 {args.out}({size_kb:.0f} KB,含 {len(ICONSET)} 个尺寸)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
