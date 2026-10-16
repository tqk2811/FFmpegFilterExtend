#!/usr/bin/env python3
"""Builds the 2x2 leaf atlases of the falling-maple and falling-ginkgo example effects
from the SVGs in assets/leaves (see assets/leaves/README.md for their licenses).

Each atlas holds four colour variants of one leaf, straight alpha, 128 px per cell.
Needs Pillow and cairosvg:  python3 scripts/make-leaf-atlas.py
"""
import colorsys
import io
import math
from pathlib import Path

import cairosvg
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "assets" / "leaves"
CELL = 128
SS = 4  # render larger, then downscale premultiplied for clean edges


def render(svg: Path, size: int) -> Image.Image:
    png = cairosvg.svg2png(url=str(svg), output_width=size, output_height=size)
    return Image.open(io.BytesIO(png)).convert("RGBA")


def downscale(img: Image.Image) -> Image.Image:
    # Premultiplied, so transparent black does not darken the edges.
    return img.convert("RGBa").resize((CELL, CELL), Image.LANCZOS).convert("RGBA")


def recolor(img: Image.Image, hue: float, sat: float, val: float) -> Image.Image:
    """Moves every pixel to `hue` (0..1) and scales saturation and value, keeping the shading."""
    out = img.copy()
    px = out.load()
    for y in range(out.height):
        for x in range(out.width):
            r, g, b, a = px[x, y]
            if a:
                _, s, v = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
                nr, ng, nb = colorsys.hsv_to_rgb(hue, min(1.0, s * sat), min(1.0, v * val))
                px[x, y] = (round(nr * 255), round(ng * 255), round(nb * 255), a)
    return out


def maple_cells():
    # Noto's maple leaf is orange to red; pull it to reds of different depth.
    base = render(ASSETS / "maple-leaf.svg", CELL * SS)
    variants = [(0.995, 1.15, 0.95), (0.02, 1.1, 1.0), (0.975, 1.2, 0.75), (0.035, 1.05, 0.9)]
    return [downscale(recolor(base, *v)) for v in variants]


def ginkgo_cells():
    # The game-icons ginkgo is a flat silhouette: paint it with a gradient and fan veins.
    size = CELL * SS
    shape = render(ASSETS / "ginkgo-leaf.svg", size).getchannel("A")
    stem = (0.36 * size, 0.33 * size)  # where the stem meets the blade
    cells = []
    for light, dark, vein in [
        ((255, 222, 70), (226, 160, 20), (190, 130, 20)),
        ((250, 235, 110), (235, 190, 40), (200, 160, 40)),
        ((245, 200, 40), (205, 125, 15), (170, 100, 15)),
        ((240, 225, 90), (190, 175, 40), (150, 140, 30)),
    ]:
        img = Image.new("RGB", (size, size))
        px = img.load()
        for y in range(size):
            for x in range(size):
                # Darker near the stem, lighter towards the outer edge.
                d = min(1.0, math.hypot(x - stem[0], y - stem[1]) / (0.75 * size))
                px[x, y] = tuple(round(dark[c] + (light[c] - dark[c]) * d) for c in range(3))
        draw = ImageDraw.Draw(img)
        for k in range(28):
            a = math.radians(-20 + 125 * k / 27)  # fan from the right round to the lower left
            draw.line([stem, (stem[0] + math.cos(a) * size, stem[1] + math.sin(a) * size)], fill=vein, width=max(1, SS // 2))
        img = img.convert("RGBA")
        img.putalpha(shape)
        cells.append(downscale(img))
    return cells


def atlas(cells, out: Path):
    img = Image.new("RGBA", (CELL * 2, CELL * 2), (0, 0, 0, 0))
    for i, cell in enumerate(cells):
        img.paste(cell, ((i % 2) * CELL, (i // 2) * CELL))
    out.parent.mkdir(parents=True, exist_ok=True)
    img.save(out, optimize=True)
    print(out.relative_to(ROOT))


if __name__ == "__main__":
    atlas(maple_cells(), ROOT / "examples/effects/standalone/falling-maple/textures/leaves.png")
    atlas(ginkgo_cells(), ROOT / "examples/effects/standalone/falling-ginkgo/textures/leaves.png")
