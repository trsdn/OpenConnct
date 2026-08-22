#!/usr/bin/env python3
"""Generate the OpenConnct app icon.

The icon is drawn programmatically rather than checked in as a binary blob so
it stays diffable: change a colour or a fader position here and re-run
`make icon` to regenerate App/OpenConnctApp/Resources/AppIcon.icns.

Motif: three channel-strip faders on a macOS-style squircle. Faders read as
"software mixer" at 1024px and still hold up as three distinct marks at 32px.
"""

import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

REPO = Path(__file__).resolve().parent.parent
OUT_ICNS = REPO / "App" / "OpenConnctApp" / "Resources" / "AppIcon.icns"

# Everything is drawn on a 1024 grid at 4x and downsampled, which gives clean
# edges without hand-rolled antialiasing.
GRID = 1024
SS = 4

# Apple's macOS app icon geometry: an 824pt body centred on a 1024pt canvas.
BODY = 824
RADIUS = 185

GRAD_TOP = (58, 196, 214)      # teal
GRAD_BOTTOM = (36, 82, 232)    # blue

TRACK_COUNT = 3
TRACK_W = 60
TRACK_H = 470
TRACK_GAP = 230
# Normalised fader positions, 0 = bottom, 1 = top.
TRACK_LEVELS = (0.66, 0.34, 0.78)

CAP_W = 116
CAP_H = 48


def s(v: float) -> int:
    """Scale a 1024-grid coordinate into supersampled pixels."""
    return int(round(v * SS))


def rounded_mask(size: tuple[int, int], radius: int) -> Image.Image:
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size[0] - 1, size[1] - 1], radius=radius, fill=255)
    return mask


def vertical_gradient(size: tuple[int, int], top: tuple, bottom: tuple) -> Image.Image:
    w, h = size
    grad = Image.new("RGB", (1, h))
    px = grad.load()
    for y in range(h):
        t = y / max(h - 1, 1)
        px[0, y] = tuple(int(round(top[i] + (bottom[i] - top[i]) * t)) for i in range(3))
    return grad.resize((w, h), Image.BILINEAR)


def draw_icon() -> Image.Image:
    canvas = Image.new("RGBA", (s(GRID), s(GRID)), (0, 0, 0, 0))

    x0 = (GRID - BODY) / 2
    y0 = (GRID - BODY) / 2 - 8  # optical centring: leave room for the drop shadow
    body_box = (s(x0), s(y0), s(x0 + BODY), s(y0 + BODY))
    body_size = (body_box[2] - body_box[0], body_box[3] - body_box[1])
    body_mask = rounded_mask(body_size, s(RADIUS))

    # Drop shadow.
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 90), (body_box[0], body_box[1] + s(18)), body_mask)
    canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(s(14))))

    body = vertical_gradient(body_size, GRAD_TOP, GRAD_BOTTOM).convert("RGBA")

    # Soft top-edge sheen so the plate does not read as flat colour.
    sheen = Image.new("RGBA", body_size, (255, 255, 255, 0))
    sd = ImageDraw.Draw(sheen)
    for i in range(s(260)):
        alpha = int(46 * (1 - i / s(260)))
        sd.line([(0, i), (body_size[0], i)], fill=(255, 255, 255, alpha))
    body = Image.alpha_composite(body, sheen)

    draw_faders(body, x0, y0)

    body.putalpha(body_mask)
    canvas.alpha_composite(body, (body_box[0], body_box[1]))
    return canvas.resize((GRID, GRID), Image.LANCZOS)


def draw_faders(body: Image.Image, x0: float, y0: float) -> None:
    """Draw the channel strips in body-local coordinates."""
    layer = Image.new("RGBA", body.size, (255, 255, 255, 0))
    d = ImageDraw.Draw(layer)

    cx = GRID / 2 - x0
    cy = GRID / 2 - y0
    top = cy - TRACK_H / 2
    bottom = cy + TRACK_H / 2

    for i in range(TRACK_COUNT):
        tx = cx + (i - (TRACK_COUNT - 1) / 2) * TRACK_GAP
        level_y = bottom - TRACK_LEVELS[i] * TRACK_H

        # Track groove.
        d.rounded_rectangle(
            [s(tx - TRACK_W / 2), s(top), s(tx + TRACK_W / 2), s(bottom)],
            radius=s(TRACK_W / 2),
            fill=(6, 22, 60, 110),
        )
        # Level fill from the bottom up to the cap.
        d.rounded_rectangle(
            [s(tx - TRACK_W / 2), s(level_y), s(tx + TRACK_W / 2), s(bottom)],
            radius=s(TRACK_W / 2),
            fill=(255, 255, 255, 150),
        )
        # Fader cap.
        d.rounded_rectangle(
            [s(tx - CAP_W / 2), s(level_y - CAP_H / 2), s(tx + CAP_W / 2), s(level_y + CAP_H / 2)],
            radius=s(CAP_H / 2),
            fill=(255, 255, 255, 255),
        )

    # Cast a soft shadow from the strips onto the plate before drawing them.
    silhouette = layer.getchannel("A").point(lambda a: int(a * 0.30))
    shadow = Image.new("RGBA", body.size, (0, 0, 0, 0))
    shadow.paste((4, 16, 48, 255), (0, s(10)), silhouette)
    body.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(s(8))))
    body.alpha_composite(layer)


def main() -> int:
    icon = draw_icon()
    OUT_ICNS.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "AppIcon.iconset"
        iconset.mkdir()
        for pt in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                px = pt * scale
                suffix = "" if scale == 1 else "@2x"
                icon.resize((px, px), Image.LANCZOS).save(iconset / f"icon_{pt}x{pt}{suffix}.png")

        result = subprocess.run(
            ["iconutil", "-c", "icns", str(iconset), "-o", str(OUT_ICNS)],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            sys.stderr.write(result.stderr)
            return result.returncode

    # A 1024px PNG for the README and release pages.
    icon.save(OUT_ICNS.with_suffix(".png"))
    print(f"Wrote {OUT_ICNS.relative_to(REPO)} and {OUT_ICNS.with_suffix('.png').relative_to(REPO)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
