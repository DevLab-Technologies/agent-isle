#!/usr/bin/env python3
"""Render docs/preview.png — a faithful mockup of the expanded island for the README."""
import os
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOCS = os.path.join(ROOT, "docs")
os.makedirs(DOCS, exist_ok=True)


def font(paths, size, index=0):
    for p in paths:
        try:
            return ImageFont.truetype(p, size, index=index)
        except Exception:
            continue
    return ImageFont.load_default()


MONO = ["/System/Library/Fonts/Menlo.ttc", "/System/Library/Fonts/SFNSMono.ttf",
        "/System/Library/Fonts/Courier.ttc"]
SANS = ["/System/Library/Fonts/HelveticaNeue.ttc", "/System/Library/Fonts/Helvetica.ttc"]
def mono(s): return font(MONO, s)
def sans(s): return font(SANS, s)

CLAUDE = (217, 135, 82)
GROK = (150, 150, 162)
COPILOT = (150, 168, 190)
WORKING = (107, 153, 250)
IDLE = (150, 150, 150)
DONE = (92, 212, 140)
WAITING = (250, 184, 77)

PANEL_W = 560
ROW_H = 78
ROW_GAP = 12


def rr(d, box, r, fill=None, outline=None, width=1):
    d.rounded_rectangle(box, radius=r, fill=fill, outline=outline, width=width)


def badge(d, x, y, initials, tint):
    rr(d, [x, y, x + 40, y + 40], 10, fill=tuple(int(c * 0.28) for c in tint), outline=tint)
    d.text((x + 20, y + 21), initials, font=mono(15), fill=tint, anchor="mm")


def session(d, x, y, w, initials, tint, title, sub, msg, status, scolor, tokens, elapsed, highlight=False):
    fill = (36, 30, 20) if highlight else (26, 26, 32)
    rr(d, [x, y, x + w, y + ROW_H], 14, fill=fill,
       outline=scolor if highlight else (52, 52, 60), width=2 if highlight else 1)
    badge(d, x + 14, y + 18, initials, tint)
    tx = x + 68
    d.text((tx, y + 19), title, font=mono(16), fill=(240, 240, 245))
    tlen = d.textlength(title, font=mono(16))
    d.text((tx + tlen + 12, y + 22), sub, font=sans(12), fill=tint)
    d.text((tx, y + 46), msg, font=mono(12), fill=(150, 150, 158))
    # status pill (right)
    label_w = d.textlength(status, font=mono(12))
    pill_w = int(28 + label_w)
    bx = x + w - pill_w - 16
    rr(d, [bx, y + 15, bx + pill_w, y + 39], 12, fill=tuple(int(c * 0.22) for c in scolor))
    d.ellipse([bx + 9, y + 24, bx + 15, y + 30], fill=scolor)
    d.text((bx + 20, y + 27), status, font=mono(12), fill=scolor, anchor="lm")
    d.text((x + w - 16, y + 52), f"{tokens}   {elapsed}", font=mono(11),
           fill=(120, 120, 128), anchor="rm")


def main():
    rows = [
        ("CL", CLAUDE, "fix auth bug", "Claude / VS Code", "Wants to edit middleware.ts",
         "Permission", WAITING, "48.2k", "14s", True),
        ("CL", CLAUDE, "backend server", "Claude / iTerm", "Running: npm test",
         "Working", WORKING, "1.3M", "1h", False),
        ("GR", GROK, "optimize-queries", "Grok / Grok CLI", "Analyzing the slow queries",
         "Working", WORKING, "212k", "5h", False),
        ("CO", COPILOT, "refactor-ui", "Copilot / Copilot CLI", "Reviewing result",
         "Idle", IDLE, "45.6k", "3m", False),
    ]

    header_h = 60
    footer_h = 34
    panel_h = header_h + 14 + len(rows) * (ROW_H + ROW_GAP) + footer_h + 18
    margin = 40
    W = PANEL_W + margin * 2
    H = panel_h + margin * 2

    img = Image.new("RGBA", (W, H), (13, 11, 19, 255))
    d = ImageDraw.Draw(img, "RGBA")
    for yy in range(H):
        t = yy / H
        d.line([(0, yy), (W, yy)], fill=(int(22 - 10 * t), int(17 - 7 * t), int(30 - 12 * t), 255))

    px, py = margin, margin
    rr(d, [px, py, px + PANEL_W, py + panel_h], 26, fill=(0, 0, 0, 255), outline=(255, 255, 255, 26), width=1)

    # header
    d.text((px + 20, py + 20), ">", font=mono(20), fill=(99, 240, 232))
    d.text((px + 38, py + 20), "_", font=mono(20), fill=(255, 95, 162))
    d.text((px + 60, py + 22), "AGENT ISLE", font=mono(15), fill=(228, 228, 234))
    d.text((px + PANEL_W - 20, py + 24), "5 agents", font=mono(13), fill=(140, 140, 150), anchor="rm")
    d.line([(px + 16, py + header_h), (px + PANEL_W - 16, py + header_h)], fill=(255, 255, 255, 26))

    x = px + 16
    w = PANEL_W - 32
    y = py + header_h + 14
    for r in rows:
        session(d, x, y, w, *r)
        y += ROW_H + ROW_GAP

    tabs = [("Monitor", True), ("Approve", False), ("Ask", False)]
    tw = (w - 16) // 3
    for i, (label, active) in enumerate(tabs):
        bx = x + i * (tw + 8)
        rr(d, [bx, y, bx + tw, y + footer_h], 8,
           fill=tuple(int(c * 0.18) for c in DONE) if active else (18, 18, 22),
           outline=DONE if active else (52, 52, 60), width=1)
        d.text((bx + tw // 2, y + footer_h // 2), label, font=mono(13),
               fill=DONE if active else (150, 150, 158), anchor="mm")

    img.save(os.path.join(DOCS, "preview.png"))
    print("Wrote", os.path.join(DOCS, "preview.png"), f"({W}x{H})")


if __name__ == "__main__":
    main()
