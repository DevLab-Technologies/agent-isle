#!/usr/bin/env python3
"""Generate AppIcon.icns for Claude Island — a dark squircle with the dynamic-island
pill and three agent dots (Claude orange, Codex green, Gemini blue)."""
import os, math, subprocess
from PIL import Image, ImageDraw

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


def glow_dot(base, cx, cy, radius, color):
    """A crisp dot with a tight, subtle halo."""
    d = ImageDraw.Draw(base, "RGBA")
    for i in range(4, 0, -1):
        rr = radius * (1 + i * 0.16)
        a = int(30 * (i / 4.0))
        d.ellipse([cx - rr, cy - rr, cx + rr, cy + rr],
                  fill=(color[0], color[1], color[2], a))
    d.ellipse([cx - radius, cy - radius, cx + radius, cy + radius], fill=color)
    # tiny top highlight
    hr = radius * 0.34
    d.ellipse([cx - hr - radius * 0.25, cy - hr - radius * 0.28,
               cx + hr - radius * 0.25, cy + hr - radius * 0.28],
              fill=(255, 255, 255, 90))


def build():
    margin = 40
    inner = S - margin * 2
    radius = int(inner * 0.225)

    # Background squircle with a subtle vertical gradient.
    bg = vgradient(inner, (46, 46, 53), (16, 16, 20)).convert("RGBA")
    mask = rounded_mask(inner, radius)

    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    canvas.paste(bg, (margin, margin), mask)

    draw = ImageDraw.Draw(canvas, "RGBA")
    # Hairline top highlight for depth.
    draw.rounded_rectangle([margin, margin, S - margin, S - margin],
                           radius=radius, outline=(255, 255, 255, 28), width=3)

    # Dynamic-island pill — the hero of the icon.
    pw, ph = int(S * 0.60), int(S * 0.235)
    cx = S // 2
    cy = int(S * 0.50)
    x0, y0 = cx - pw // 2, cy - ph // 2
    # soft drop shadow under the pill
    draw.rounded_rectangle([x0, y0 + 14, x0 + pw, y0 + ph + 14], radius=ph // 2,
                           fill=(0, 0, 0, 90))
    draw.rounded_rectangle([x0, y0, x0 + pw, y0 + ph], radius=ph // 2,
                           fill=(7, 7, 9, 255), outline=(255, 255, 255, 30), width=3)

    # Three agent dots inside the pill (Claude / Codex / Gemini).
    dot_r = int(ph * 0.20)
    colors = [(224, 138, 78), (92, 212, 140), (107, 153, 250)]
    gap = pw * 0.24
    start = cx - gap
    for i, col in enumerate(colors):
        glow_dot(canvas, int(start + i * gap), cy, dot_r, col)

    return canvas


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
