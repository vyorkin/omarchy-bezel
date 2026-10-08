#!/usr/bin/env python3
"""Build the "Simple B/W 8.8" theme for the Turing 8.8" panel (480x1920).

The look is the vendor's "Simple black and white theme", one of the resources
re-published in turing-smart-screen-python under
`res/themes/--Theme examples/8.8inch/Simple black and white theme/`
(`theme_res_157510.png`). Its own layout is unusable here — 22 px labels, three
empty bands, and a "Frames FPS" label with nothing to show on a machine without
a MangoHud log — so only the look (black, white, monospace) and its clock icon
are kept.

Everything else is laid out by this script as a list of blocks that it stacks
down the canvas with the same gaps everywhere: a label, then the value, then a
bar or a line under it. No y is typed in by hand, so the spacing cannot drift
per block — which is how the earlier hand-placed version ended up with labels
touching their numbers.

Usage:

    python3 build-bw-theme.py <vendor template.png> <fonts dir> <output folder>

    python3 build-bw-theme.py \\
      "/tmp/tsx/res/themes/--Theme examples/8.8inch/Simple black and white theme/theme_res_157510.png" \\
      ~/.local/share/bezel/themes/fonts ~/.local/share/bezel/themes/bw-vertical-8.8

The vendor picture is 481x1921 with transparent pixels, and the panel honours a
frame's alpha: a transparent background would show the *previous* theme through
it. The icon is cut out of the template and pasted onto an opaque black canvas,
so this theme is opaque by construction.
"""

import json
import pathlib
import shutil
import sys

from PIL import Image, ImageDraw, ImageFont

CANVAS = (480, 1920)
MARGIN = 36
WIDTH = CANVAS[0] - MARGIN
BLACK = (0, 0, 0)
WHITE = "#f3f5faff"
DIM = "#9aa0a6ff"
LABEL_COLOUR = (139, 148, 169)
MONO = {"family": "JetBrains Mono", "weight": 500, "italic": False}

# The panel's sizes: the main reading is huge, the small print is still readable
# across a desk, and the labels sit between the two.
BIG = 150          # CPU and GPU, the two the panel is read for
MID = 104          # RAM and DISK, side by side
VRAM = 56
SMALL = 44
TOTAL = 26
NET = 46
CLOCK = 88
DATE = 30
LABEL_SIZE = 32

# A block's parts, in pixels. `LABEL_GAP` is the air between the label and the
# ink of the value under it; `BLOCK_GAP` is the air between two blocks.
LABEL_BOX = 40
LABEL_GAP = 34
BLOCK_GAP = 80
BAR_GAP = 20            # value -> bar
LINE_GAP = 16           # bar -> the line under it

ICON_BOX = (389, 1531, 428, 1570)     # the clock icon in the vendor template
ICON_HEIGHT = 64

BACKGROUND = {"type": "image", "asset": "assets/background.png", "fit": "fill"}

SOURCE = """# Where this theme comes from

The look is the vendor's "Simple black and white theme" for the 8.8"
Turing/TURZX screen, as re-published with the extracted vendor resources in
[mathoudebine/turing-smart-screen-python](https://github.com/mathoudebine/turing-smart-screen-python)
under `res/themes/--Theme examples/8.8inch/Simple black and white theme/`
(`theme_res_157510.png`). Its black background and its clock icon are used here;
the layout, the labels and the values are this theme's own, drawn by
`tools/build-bw-theme.py` in the
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


def bar(key, *, height=24):
    return {
        "type": "bar",
        "binding": {"key": key, "min": 0.0, "max": 100.0},
        "direction": "leftToRight",
        "fill": {"angle": 0.0, "stops": [[0.0, WHITE], [1.0, WHITE]]},
        "track": "#ffffff1f",
        "radius": float(height) / 2,
    }


def ink(size):
    """How tall a value of this size stands, with a little air around it.

    Smaller than the font's own box (a monospace face reserves room for
    descenders), so a value can never reach into the row above it.
    """
    return round(size * 0.85) + 12


# Each block: its label, and its rows. A row is a list of columns, and a column
# is (x, width, name, size, kind). The script works out every y from this.
BLOCKS = [
    ("CPU", [
        [(MARGIN, 300, "CPU usage", BIG, sensor("cpu.usage", size=BIG))],
        [(MARGIN, WIDTH, "CPU bar", 26, bar("cpu.usage"))],
        [(MARGIN, 230, "CPU frequency", SMALL, sensor("cpu.frequency", size=SMALL)),
         (280, 200, "CPU temperature", SMALL, sensor("cpu.temperature", size=SMALL))],
    ]),
    ("GPU", [
        [(MARGIN, 300, "GPU usage", BIG, sensor("gpu.usage", size=BIG))],
        [(MARGIN, WIDTH, "GPU bar", 26, bar("gpu.usage"))],
        [(MARGIN, 230, "GPU frequency", SMALL, sensor("gpu.frequency", size=SMALL)),
         (280, 200, "GPU temperature", SMALL, sensor("gpu.temperature", size=SMALL))],
        # VRAM belongs to the graphics card, so it lives in that block, and it
        # says its own name: as small print under a wall of percentages nobody
        # could tell what the number was.
        [(MARGIN, WIDTH, "GPU memory used", VRAM,
          sensor("gpu.memory.used", size=VRAM, prefix="VRAM ", decimals=True))],
        [(MARGIN, WIDTH, "GPU memory percent", SMALL,
          sensor("gpu.memory.percent", size=SMALL, paint=DIM, suffix=" used"))],
    ]),
    # RAM and DISK share a block, side by side: neither needs the full width.
    ("RAM / DISK", [
        [(MARGIN, 200, "RAM percent", MID, sensor("memory.percent", size=MID)),
         (252, 220, "Disk percent", MID, sensor("disk.root.percent", size=MID))],
        [(MARGIN, 200, "RAM bar", 22, bar("memory.percent")),
         (252, 220, "Disk bar", 22, bar("disk.root.percent"))],
        [(MARGIN, 200, "RAM used", SMALL,
          sensor("memory.used", size=SMALL, paint=DIM, decimals=True)),
         (252, 220, "Disk used", SMALL,
          sensor("disk.root.used", size=SMALL, paint=DIM, decimals=True))],
        [(MARGIN, 200, "RAM total", TOTAL,
          sensor("memory.total", size=TOTAL, paint=DIM, decimals=True)),
         (252, 220, "Disk free", TOTAL,
          sensor("disk.root.free", size=TOTAL, paint=DIM, decimals=True))],
    ]),
    ("NET", [
        [(MARGIN, WIDTH, "Network down", NET,
          sensor("net.down", size=NET, prefix="\u2193 "))],
        [(MARGIN, WIDTH, "Network up", NET,
          sensor("net.up", size=NET, prefix="\u2191 "))],
    ]),
    ("", [                    # the clock, with the vendor's icon beside it
        [(MARGIN, 300, "Time", CLOCK, clock("%H:%M", size=CLOCK))],
        [(MARGIN, 240, "Date", DATE, clock("%a %e %b", size=DATE, paint=DIM)),
         (290, 190, "Uptime", TOTAL,
          sensor("system.uptime", size=TOTAL, paint=DIM, prefix="up "))],
    ]),
]


def layout():
    """Every element with its frame, and the labels to print into the picture."""
    elements = []
    labels = []
    y = MARGIN
    for label, rows in BLOCKS:
        if label:
            labels.append((label, MARGIN, y))
            y += LABEL_BOX + LABEL_GAP
        for index, columns in enumerate(rows):
            height = max(ink(size) if kind["type"] == "text" else size
                         for _, _, _, size, kind in columns)
            for x, width, name, _, kind in columns:
                elements.append({
                    "id": len(elements) + 1,
                    "name": name,
                    "frame": {"x": float(x), "y": float(y),
                              "width": float(width), "height": float(height)},
                    "opacity": 1.0,
                    "visible": True,
                    "locked": False,
                    "kind": kind,
                })
            if index == 0 and len(rows) > 1:
                y += height + BAR_GAP
            elif len(rows) > 1:
                y += height + LINE_GAP
        y += BLOCK_GAP
    return elements, labels


def background(template: pathlib.Path, fonts: pathlib.Path, labels, elements) -> Image.Image:
    """Opaque black canvas, the vendor's clock icon, this build's labels."""
    source = Image.open(template).convert("RGBA")
    canvas = Image.new("RGB", CANVAS, BLACK)
    icon = source.crop(ICON_BOX)
    scale = ICON_HEIGHT / icon.height
    icon = icon.resize((round(icon.width * scale), ICON_HEIGHT), Image.LANCZOS)
    clock = next(element for element in elements if element["name"] == "Time")
    icon_y = int(clock["frame"]["y"] + (clock["frame"]["height"] - ICON_HEIGHT) / 2)
    canvas.paste(icon, (330, icon_y), icon)

    draw = ImageDraw.Draw(canvas)
    face = ImageFont.truetype(str(fonts / "JetBrainsMono-Medium.otf"), LABEL_SIZE)
    for text, x, y in labels:
        draw.text((x, y), text, fill=LABEL_COLOUR, font=face)
    return canvas


def main(template: str, fonts: str, output: str) -> int:
    template_path = pathlib.Path(template)
    fonts_path = pathlib.Path(fonts)
    if not template_path.is_file():
        print(f"no template at {template}", file=sys.stderr)
        return 1
    elements, labels = layout()
    folder = pathlib.Path(output)
    assets = folder / "assets"
    assets.mkdir(parents=True, exist_ok=True)
    background(template_path, fonts_path, labels, elements).save(assets / "background.png")
    # A copy of the source art travels with the theme: rebuilding it later does
    # not need the vendor repository again.
    shutil.copyfile(template_path, folder / "vendor-template.png")

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
    last = elements[-1]["frame"]
    end = int(last["y"] + last["height"])
    print(f"{folder}: {len(elements)} elements, last row ends at {end} of {CANVAS[1]}")
    if end > CANVAS[1]:
        print("  warning: the blocks run past the panel", file=sys.stderr)
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 4:
        print(__doc__)
        raise SystemExit(2)
    raise SystemExit(main(sys.argv[1], sys.argv[2], sys.argv[3]))
