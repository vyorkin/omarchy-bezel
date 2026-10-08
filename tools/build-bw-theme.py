#!/usr/bin/env python3
"""Build the "Simple B/W 8.8" theme for the Turing 8.8" panel (480x1920).

The artwork started as the vendor's "Simple black and white theme", one of the
resources re-published in turing-smart-screen-python under
`res/themes/--Theme examples/8.8inch/Simple black and white theme/`
(`theme_res_157510.png`). Its layout did not survive the move to this panel: the
labels are tiny, three long bands of it are empty, and one of its labels
("Frames FPS") has nothing to show on a machine without a MangoHud log.

What this build keeps is the look — black, white, one monospace face — and the
three little icons the vendor drew (the CPU chip, the graphics card and the
clock). Everything else is laid out here, big enough to read across a desk: a
value per block at 150 px, the small print at 42-56, labels at 34, a bar under
every percentage, and blocks running the whole height with no dead bands.

Usage:

    python3 build-bw-theme.py <vendor template.png> <fonts dir> <output folder>

    python3 build-bw-theme.py \\
      "/tmp/tsx/res/themes/--Theme examples/8.8inch/Simple black and white theme/theme_res_157510.png" \\
      ~/.local/share/bezel/themes/fonts ~/.local/share/bezel/themes/bw-vertical-8.8

The vendor picture is 481x1921 with transparent pixels, and the panel honours a
frame's alpha: a transparent background would show the *previous* theme through
it. Icons are cut out of the template and pasted onto an opaque black canvas, so
the theme is opaque by construction.
"""

import json
import pathlib
import sys

from PIL import Image, ImageDraw, ImageFont

CANVAS = (480, 1920)
MARGIN = 39
WIDTH = CANVAS[0] - MARGIN - MARGIN          # 402: bars and big values
BLACK = (0, 0, 0)
WHITE = "#f3f5faff"
DIM = "#9aa0a6ff"
LABEL = "#8b94a9ff"
MONO = {"family": "JetBrains Mono", "weight": 500, "italic": False}

# Pieces cut out of the vendor template: name, source box, where it goes, height.
ICONS = [
    ("clock", (389, 1531, 428, 1570), (348, 1648), 64),
]

# Labels printed into the background: text, x, y, size.
LABELS = [
    ("CPU", MARGIN, 30, 34),
    ("GPU", MARGIN, 380, 34),
    ("VRAM", MARGIN, 700, 34),
    ("RAM", MARGIN, 806, 34),
    ("DISK", MARGIN, 1126, 34),
    ("NET", MARGIN, 1412, 34),
]

BACKGROUND = {"type": "image", "asset": "assets/background.png", "fit": "fill"}

SOURCE = """# Where this theme comes from

The look is the vendor's "Simple black and white theme" for the 8.8"
Turing/TURZX screen, as re-published with the extracted vendor resources in
[mathoudebine/turing-smart-screen-python](https://github.com/mathoudebine/turing-smart-screen-python)
under `res/themes/--Theme examples/8.8inch/Simple black and white theme/`
(`theme_res_157510.png`). Its black background and its three icons (CPU chip,
graphics card, clock) are used here; the layout, the labels and the values are
this theme's own, drawn by `tools/build-bw-theme.py` in the
[omarchy-bezel](https://github.com/vyorkin/omarchy-bezel) widget repository.
"""


def sensor(key, *, size, paint=WHITE, prefix="", suffix="", decimals=False):
    return {
        "type": "text",
        "content": {
            "type": "sensor",
            "key": key,
            "format": {"showUnit": True, "fahrenheit": False, "decimalBytes": decimals},
            "prefix": prefix,
            "suffix": suffix,
        },
        "style": {"font": MONO, "size": float(size), "paint": paint,
                  "align": "left", "valign": "middle", "letterSpacing": 0.0},
    }


def clock(pattern, *, size, paint=WHITE):
    return {
        "type": "text",
        "content": {"type": "clock", "pattern": pattern},
        "style": {"font": MONO, "size": float(size), "paint": paint,
                  "align": "left", "valign": "middle", "letterSpacing": 0.0},
    }


def bar(key, *, height=26):
    return {
        "type": "bar",
        "binding": {"key": key, "min": 0.0, "max": 100.0},
        "direction": "leftToRight",
        "fill": {"angle": 0.0, "stops": [[0.0, WHITE], [1.0, WHITE]]},
        "track": "#ffffff1f",
        "radius": float(height) / 2,
    }


# name, x, y, width, height, element kind
ROWS = [
    # CPU
    ("CPU usage", MARGIN, 72, WIDTH, 180, sensor("cpu.usage", size=150)),
    ("CPU bar", MARGIN, 250, WIDTH, 26, bar("cpu.usage")),
    ("CPU frequency", MARGIN, 288, 230, 56, sensor("cpu.frequency", size=46)),
    ("CPU temperature", 280, 288, 200, 56, sensor("cpu.temperature", size=46)),
    # GPU
    ("GPU usage", MARGIN, 422, WIDTH, 180, sensor("gpu.usage", size=150)),
    ("GPU bar", MARGIN, 600, WIDTH, 26, bar("gpu.usage")),
    ("GPU frequency", MARGIN, 638, 230, 56, sensor("gpu.frequency", size=46)),
    ("GPU temperature", 280, 638, 200, 56, sensor("gpu.temperature", size=46)),
    # VRAM
    ("GPU memory used", MARGIN, 738, 190, 58,
     sensor("gpu.memory.used", size=42, decimals=True)),
    ("GPU memory percent", 250, 738, 230, 58,
     sensor("gpu.memory.percent", size=42, paint=DIM)),
    # RAM
    ("RAM percent", MARGIN, 812, WIDTH, 180, sensor("memory.percent", size=150)),
    ("RAM bar", MARGIN, 990, WIDTH, 26, bar("memory.percent")),
    ("RAM used", MARGIN, 1028, 190, 56,
     sensor("memory.used", size=40, paint=DIM, decimals=True)),
    ("RAM total", 250, 1028, 230, 56,
     sensor("memory.total", size=40, paint=DIM, decimals=True)),
    # Disk
    ("Disk percent", MARGIN, 1132, WIDTH, 180, sensor("disk.root.percent", size=150)),
    ("Disk bar", MARGIN, 1310, WIDTH, 26, bar("disk.root.percent")),
    ("Disk used", MARGIN, 1348, 190, 56,
     sensor("disk.root.used", size=40, paint=DIM, decimals=True)),
    ("Disk free", 250, 1348, 230, 56,
     sensor("disk.root.free", size=40, paint=DIM, decimals=True)),
    # Network
    ("Network down", MARGIN, 1452, WIDTH, 62, sensor("net.down", size=54, prefix="\u2193 ")),
    ("Network up", MARGIN, 1522, WIDTH, 62, sensor("net.up", size=54, prefix="\u2191 ")),
    # Clock, date, uptime: the vendor's clock icon sits beside the time.
    ("Time", MARGIN, 1626, 300, 120, clock("%H:%M", size=96)),
    ("Date", MARGIN, 1766, 300, 48, clock("%a %e %b", size=38, paint=DIM)),
    ("Uptime", MARGIN, 1814, 300, 44,
     sensor("system.uptime", size=32, paint=DIM, prefix="up ")),
]


def background(template: pathlib.Path, fonts: pathlib.Path) -> Image.Image:
    """Opaque black canvas, the vendor's icons, this theme's labels."""
    source = Image.open(template).convert("RGBA")
    canvas = Image.new("RGB", CANVAS, BLACK)
    for name, box, position, height in ICONS:
        icon = source.crop(box)
        scale = height / icon.height
        icon = icon.resize((max(1, round(icon.width * scale)), height), Image.LANCZOS)
        canvas.paste(icon, position, icon)

    draw = ImageDraw.Draw(canvas)
    face = ImageFont.truetype(str(fonts / "JetBrainsMono-Medium.otf"), 34)
    for text, x, y, size in LABELS:
        face = ImageFont.truetype(str(fonts / "JetBrainsMono-Medium.otf"), size)
        draw.text((x, y), text, fill=(139, 148, 169), font=face)
    return canvas


def main(template: str, fonts: str, output: str) -> int:
    template_path = pathlib.Path(template)
    fonts_path = pathlib.Path(fonts)
    if not template_path.is_file():
        print(f"no template at {template}", file=sys.stderr)
        return 1
    folder = pathlib.Path(output)
    assets = folder / "assets"
    assets.mkdir(parents=True, exist_ok=True)
    background(template_path, fonts_path).save(assets / "background.png")

    elements = []
    for index, (name, x, y, width, height, kind) in enumerate(ROWS, start=1):
        elements.append(
            {
                "id": index,
                "name": name,
                "frame": {"x": float(x), "y": float(y),
                          "width": float(width), "height": float(height)},
                "opacity": 1.0,
                "visible": True,
                "locked": False,
                "kind": kind,
            }
        )
    theme = {
        "schema": 1,
        "name": "Simple B/W 8.8",
        "canvas": {"width": CANVAS[0], "height": CANVAS[1]},
        "orientation": "portrait",
        "refreshSeconds": 1.0,
        "background": BACKGROUND,
        "elements": elements,
    }
    (folder / "theme.json").write_text(json.dumps(theme, indent=2) + "\n")
    (folder / "SOURCE.md").write_text(SOURCE)
    print(f"{folder}: {len(elements)} elements")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 4:
        print(__doc__)
        raise SystemExit(2)
    raise SystemExit(main(sys.argv[1], sys.argv[2], sys.argv[3]))
