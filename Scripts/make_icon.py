#!/usr/bin/env python3
"""Generate AppIcon.icns for Claude Island — a dark squircle with a neon terminal
prompt (`>_`), a vibecoding/synthwave glow aesthetic."""
import os, math, subprocess
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Sources", "ClaudeIsland", "Resources")
os.makedirs(OUT, exist_ok=True)

S = 1024


def rounded_mask(size, radius):
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return m


def vgradient(size, top, bottom):
    img = Image.new("RGB", (size, size), top)
    px = img.load()
    for y in range(size):
        t = y / (size - 1)
        r = int(top[0] + (bottom[0] - top[0]) * t)
        g = int(top[1] + (bottom[1] - top[1]) * t)
        b = int(top[2] + (bottom[2] - top[2]) * t)
        for x in range(size):
            px[x, y] = (r, g, b)
    return img


def draw_prompt(size, chevron_col, cursor_col, width_scale=1.0):
    """Draw the `>` chevron and block cursor onto a transparent layer."""
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    cx, cy = size // 2, size // 2

    stroke = int(size * 0.052 * width_scale)
    # Chevron ">" — two thick rounded strokes meeting at a tip.
    left_x = int(size * 0.34)
    tip_x = int(size * 0.50)
    top_y = int(size * 0.365)
    bot_y = int(size * 0.635)
    d.line([(left_x, top_y), (tip_x, cy)], fill=chevron_col, width=stroke, joint="curve")
    d.line([(tip_x, cy), (left_x, bot_y)], fill=chevron_col, width=stroke, joint="curve")
    for (px, py) in [(left_x, top_y), (tip_x, cy), (left_x, bot_y)]:
        r = stroke // 2
        d.ellipse([px - r, py - r, px + r, py + r], fill=chevron_col)

    # Block cursor to the right (classic terminal caret).
    bx0 = int(size * 0.57)
    bx1 = int(size * 0.685)
    by0 = int(size * 0.40)
    by1 = int(size * 0.635)
    d.rounded_rectangle([bx0, by0, bx1, by1], radius=int(size * 0.02), fill=cursor_col)
    return layer


def build():
    margin = 40
    inner = S - margin * 2
    radius = int(inner * 0.225)

    # Deep synthwave-dark background squircle.
    bg = vgradient(inner, (30, 22, 54), (9, 8, 16)).convert("RGBA")
    mask = rounded_mask(inner, radius)

    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    canvas.paste(bg, (margin, margin), mask)

    # Neon horizon glow low in the tile for the "vibe" aesthetic.
    horizon = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    hd = ImageDraw.Draw(horizon)
    hd.ellipse([int(S * 0.12), int(S * 0.62), int(S * 0.88), int(S * 1.02)],
               fill=(255, 60, 150, 70))
    horizon = horizon.filter(ImageFilter.GaussianBlur(70))
    canvas = Image.alpha_composite(canvas, put_in_mask(horizon, mask, margin, inner))

    chevron_col = (99, 240, 232)   # cyan
    cursor_col = (255, 95, 162)    # magenta

    # Glow pass: blurred, oversized prompt behind the crisp one.
    glow = draw_prompt(S, chevron_col, cursor_col, width_scale=1.5)
    glow = glow.filter(ImageFilter.GaussianBlur(26))
    canvas = Image.alpha_composite(canvas, glow)
    canvas = Image.alpha_composite(canvas, glow)  # double for intensity

    # Crisp prompt on top.
    sharp = draw_prompt(S, chevron_col, cursor_col)
    canvas = Image.alpha_composite(canvas, sharp)

    # Hairline border for depth.
    draw = ImageDraw.Draw(canvas, "RGBA")
    draw.rounded_rectangle([margin, margin, S - margin, S - margin],
                           radius=radius, outline=(255, 255, 255, 26), width=3)
    return canvas


def put_in_mask(layer, mask, margin, inner):
    """Clip an RGBA layer to the squircle so glows don't bleed past the tile."""
    out = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    full_mask = Image.new("L", (S, S), 0)
    full_mask.paste(mask, (margin, margin))
    out.paste(layer, (0, 0), Image.composite(layer.split()[3], Image.new("L", (S, S), 0), full_mask))
    return out


def main():
    master = build()
    iconset = os.path.join(ROOT, "build", "AppIcon.iconset")
    os.makedirs(iconset, exist_ok=True)
    specs = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
             (256, 1), (256, 2), (512, 1), (512, 2)]
    for size, scale in specs:
        px = size * scale
        img = master.resize((px, px), Image.LANCZOS)
        name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
        img.save(os.path.join(iconset, name))
    master.save(os.path.join(OUT, "icon_preview.png"))

    icns = os.path.join(OUT, "AppIcon.icns")
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", icns], check=True)
    print("Wrote", icns)


if __name__ == "__main__":
    main()
