"""StudioSync's toolbar button image, in REAPER's toolbar style (as Helgobox's Playtime button): three states side by side (normal,
hover, on), a flat filled circle with the symbol cut out, grey, lighter grey, then StudioSync's accent. 100%, 150% and 200% sizes.
python tools/make_toolbar_icon.py  ->  lib/toolbar_icons/{,150/,200/}toolbar_studiosync.png
"""
import math, os
from PIL import Image, ImageDraw

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib", "toolbar_icons")
STATES = [(129, 137, 137), (147, 154, 154), (76, 141, 246)]  # (the greys of REAPER's own and Helgobox's buttons; StudioSync's accent)
SS = 8  # drawn this many times larger, then scaled down: smooth edges


def arrow_arc(d, cx, cy, r, a0, a1, w):
    """A thick arc from a0 to a1 (degrees, clockwise from 3 o'clock in PIL terms) with an arrowhead at a1."""
    d.arc([cx - r, cy - r, cx + r, cy + r], a0, a1, fill=255, width=w)
    t = math.radians(a1)
    tip_r = r
    hx, hy = cx + tip_r * math.cos(t), cy + tip_r * math.sin(t)
    # head: a triangle pointing along the arc's direction (clockwise)
    dirx, diry = -math.sin(t), math.cos(t)
    nx, ny = math.cos(t), math.sin(t)
    L = w * 1.7
    pts = [(hx + dirx * L, hy + diry * L), (hx + nx * L, hy + ny * L), (hx - nx * L, hy - ny * L)]
    d.polygon(pts, fill=255)


def glyph(size):
    """The cut-out symbol: two arrows chasing each other round a circle (sync), as a mask."""
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    c, r, w = size / 2, size * 0.24, max(2, int(size * 0.075))
    arrow_arc(d, c, c, r, 200, 320, w)
    arrow_arc(d, c, c, r, 20, 140, w)
    return m


def state(size, rgb):
    big = size * SS
    img = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    pad = big * 0.1
    d.ellipse([pad, pad, big - pad, big - pad], fill=rgb + (255,))
    cut = glyph(big)
    alpha = img.getchannel("A")
    alpha.paste(0, mask=cut)  # (cut out: the toolbar's own colour shows through, whatever the theme)
    img.putalpha(alpha)
    return img.resize((size, size), Image.LANCZOS)


def strip(size):
    out = Image.new("RGBA", (size * 3, size), (0, 0, 0, 0))
    for i, rgb in enumerate(STATES):
        out.alpha_composite(state(size, rgb), (i * size, 0))
    return out


for sub, size in (("", 30), ("150", 45), ("200", 60)):
    d = os.path.join(OUT, sub)
    os.makedirs(d, exist_ok=True)
    strip(size).save(os.path.join(d, "toolbar_studiosync.png"))
    print(os.path.join(d, "toolbar_studiosync.png"))
