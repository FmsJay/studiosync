"""StudioSync's toolbar button image: the StudioSync logo (docs/logo/studiosync-small.svg: two faders, the blue and orange halves of the
portal, the gradient caps and the curve between them) inside a button frame like the toolbar's own (James, 0.58.83: the flat sync circle
"made things look a little offset" beside REAPER's framed buttons, and should "still match the regular studio sync icon"). Three states
side by side, as REAPER wants: normal, hover (a lighter frame), on (the panel is open: a darker, pressed frame).
The frame's greys and margins are the Reapertips and default dark themes' (their toolbar_blank.png); outside it the image is transparent, so
any toolbar's own colour shows round it. 100%, 150% and 200% sizes.
python tools/make_toolbar_icon.py  ->  lib/toolbar_icons/{,150/,200/}toolbar_studiosync.png
"""
import math, os
from PIL import Image, ImageDraw

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib", "toolbar_icons")
SS = 8  # drawn this many times larger, then scaled down: smooth edges
BLUE, VIOLET, ORANGE = (0x1E, 0x9B, 0xFF), (0xC2, 0x6B, 0xD6), (0xFF, 0x8A, 0x1E)
LINE = (194, 198, 206)  # (the theme's own symbol grey)
# per state: frame fill, its top/left edge, its bottom/right edge, the faders' grey
FRAMES = [((61, 61, 61), (72, 72, 72), (52, 52, 52), LINE),
          ((83, 83, 83), (95, 95, 95), (60, 60, 60), (232, 234, 238)),
          ((45, 45, 45), (36, 36, 36), (53, 53, 53), LINE)]


def ramp(t):
    """The logo's gradient, blue to violet to orange (t 0..1)."""
    t = max(0.0, min(1.0, t))
    a, b, u = (BLUE, VIOLET, t * 2) if t < 0.5 else (VIOLET, ORANGE, t * 2 - 1)
    return tuple(int(round(a[i] + (b[i] - a[i]) * u)) for i in range(3))


def logo(px):
    """The logo's parts, `px` square: the portal halves (RGBA), the faders' lines (a mask), the gradient and its mask. SVG units 0..64."""
    k = px / 64.0

    def P(u, v): return (u * k, v * k)

    portal = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    # a half ellipse from each fader's line, filled faintly and edged (blue left, bulging right; orange right, bulging left)
    for x0, side, rgb in ((18, 1, BLUE), (46, -1, ORANGE)):
        pts = [P(x0 + side * 9 * math.cos(math.radians(a)), 32 + 25 * math.sin(math.radians(a))) for a in range(-90, 91, 3)]
        lay = Image.new("RGBA", (px, px), (0, 0, 0, 0))
        d = ImageDraw.Draw(lay)
        d.polygon(pts, fill=rgb + (120,))
        d.line(pts + [pts[0]], fill=rgb + (255,), width=max(1, int(3.5 * k)), joint="curve")
        portal.alpha_composite(lay)
    lines = Image.new("L", (px, px), 0)
    d = ImageDraw.Draw(lines)
    w = int(5 * k)
    for x0 in (18, 46):
        d.line([P(x0, 6), P(x0, 58)], fill=255, width=w)
        for y in (6, 58):
            cx, cy = P(x0, y)
            d.ellipse([cx - w / 2, cy - w / 2, cx + w / 2, cy + w / 2], fill=255)
    gmask = Image.new("L", (px, px), 0)
    d = ImageDraw.Draw(gmask)
    curve = []
    for i in range(41):
        t = i / 40
        x = (1 - t) ** 3 * 18 + 3 * (1 - t) ** 2 * t * 32 + 3 * (1 - t) * t ** 2 * 32 + t ** 3 * 46
        y = (1 - t) ** 3 * 20 + 3 * (1 - t) ** 2 * t * 20 + 3 * (1 - t) * t ** 2 * 44 + t ** 3 * 44
        curve.append(P(x, y))
    d.line(curve, fill=255, width=int(5.5 * k), joint="curve")
    for x0, y0 in ((6, 13), (34, 37)):
        d.rounded_rectangle([P(x0, y0), P(x0 + 24, y0 + 14)], radius=4 * k, fill=255)
    grad = Image.new("RGBA", (px, px))
    gd = ImageDraw.Draw(grad)
    for x in range(px):
        gd.line([(x, 0), (x, px)], fill=ramp((x / k - 12) / 40) + (255,))
    grad.putalpha(gmask)
    return portal, lines, grad


def state(size, frame):
    fill, lit, shade, line = frame
    big = size * SS
    img = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    u = SS * size / 30  # one pixel at this size
    r, m = 3 * u, 0.5 * u
    d.rounded_rectangle([m, m, big - m, big - m], radius=r, fill=shade + (255,))
    d.rounded_rectangle([m, m, big - m - u, big - m - u], radius=r, fill=lit + (255,))
    d.rounded_rectangle([m + u, m + u, big - m - u, big - m - u], radius=max(1, r - u), fill=fill + (255,))
    # the logo in the middle 18 of 30 px: about as big as the theme's own symbols look (14-16 px), its thin lines needing a little more
    lp = int(big * 18 / 30)
    portal, lines, grad = logo(lp)
    off = ((big - lp) // 2, (big - lp) // 2)
    img.alpha_composite(portal, off)
    grey = Image.new("RGBA", (lp, lp), line + (255,))
    grey.putalpha(lines)
    img.alpha_composite(grey, off)
    img.alpha_composite(grad, off)
    return img.resize((size, size), Image.LANCZOS)


def strip(size):
    out = Image.new("RGBA", (size * 3, size), (0, 0, 0, 0))
    for i, f in enumerate(FRAMES):
        out.alpha_composite(state(size, f), (i * size, 0))
    return out


for sub, size in (("", 30), ("150", 45), ("200", 60)):
    d = os.path.join(OUT, sub)
    os.makedirs(d, exist_ok=True)
    strip(size).save(os.path.join(d, "toolbar_studiosync.png"))
