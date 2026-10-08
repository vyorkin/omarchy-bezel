#!/usr/bin/env python3
"""Build a Bezel theme out of the vendor's "Simple black and white" template.

The template is one of the vendor resources re-published with the extracted
Turing/TURZX themes in turing-smart-screen-python, under
`res/themes/--Theme examples/8.8inch/Simple black and white theme/`: a black
480x1920 layout whose labels carry no values, because the vendor app drew them
(`theme_res_157510.png`).

That layout leaves three long bands empty — above the CPU label, between the CPU
and GPU blocks, and under the ROM block — so this build fills them with values
and gauges of its own and prints a few extra labels into the background. The
labels the vendor drew, and the boxes they leave, were measured on the template:

    CPU USAGE      y  295-306  x  47-126     RAM USAGE   y 1375-1383  x 39-99
    GPU USAGE      y  900-911  x  47-127     ROM USAGE   y 1519-1527  x 39-99
    NETWORK SPEED  y 1304-1324  x 216-434    DATE        y 1611-1621  x 220-252
    TIME (big)     y 1531-1569  x 214-290    TIME        y 1658-1669  x 220-242
    clock icon     y 1531-1569  x 389-427    Frames FPS  y 1658-1669  x  39-97
    CPU icon       y 1846-1874  x  47-75     GPU icon    y 1846-1874  x 217-254

Usage:

    python3 build-bw-theme.py <template.png> <fonts dir> ~/.local/share/bezel/themes/bw-vertical-8.8

Two things about the picture itself: the vendor file is 481x1921 and has
transparent pixels, and on the panel a frame is an image whose alpha is honoured
— a transparent background would show the *previous* theme through it. The
background is therefore cropped to the canvas and composited onto the colour the
template already uses (its own black). "Frames FPS" is a label this machine has
nothing to put under (no MangoHud log), so it is painted over and the room is
used for the disk rates.
"""

import json
import pathlib
import sys

from PIL import Image, ImageDraw, ImageFont

WHITE = "#f3f5faff"
DIM = "#9aa0a6ff"
MONO = {"family": "JetBrains Mono", "weight": 500, "italic": False}
CANVAS = (480, 1920)

# Labels this build prints into the background, in the vendor's own white and in
# the panel's monospace: name, x, y, size.
LABELS = [
    ("LOAD 1", 39, 34, 22),
    ("LOAD 5", 39, 106, 22),
    ("LOAD 15", 39, 178, 22),
    ("CLOCK", 39, 498, 22),
    ("CLOCK", 39, 1103, 22),
    ("VRAM", 39, 1168, 22),
    ("DISK R", 39, 1706, 22),
    ("DISK W", 39, 1746, 22),
]

# A rectangle of the background's own colour, to take the one label this machine
# cannot fill off the picture: name, x, y, width, height.
COVER = ("no-frames-label", 24, 1650, 190, 34)

BACKGROUND = {"type": "image", "asset": "assets/background.png", "fit": "fill"}

SOURCE = """# Where this theme comes from

The artwork is the vendor's own "Simple black and white theme" for the 8.8"
Turing/TURZX screen, as re-published with the extracted vendor resources in
[mathoudebine/turing-smart-screen-python](https://github.com/mathoudebine/turing-smart-screen-python)
under `res/themes/--Theme examples/8.8inch/Simple black and white theme/`
(`theme_res_157510.png`: an empty 480x1920 black layout; the vendor app drew the
values).

`theme.json`, the extra labels and the values are written by
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


def bar(key, low, high, *, fill="#f3f5faff", track="#ffffff1a"):
    return {
        "type": "bar",
        "binding": {"key": key, "min": low, "max": high},
        "direction": "leftToRight",
        "fill": {"angle": 0.0, "stops": [[0.0, fill], [1.0, fill]]},
        "track": track,
        "radius": 9.0,
    }


def graph(key, low, high, *, history=90, colour="#f3f5faff", fill="#ffffff22"):
    return {
        "type": "graph",
        "binding": {"key": key, "min": low, "max": high},
        "history": history,
        "style": "area",
        "color": colour,
        "fill": {"angle": 90.0, "stops": [[0.0, fill], [1.0, "#ffffff00"]]},
        "lineWidth": 2.0,
        "autoscale": False,
    }


def rect(colour):
    return {
        "type": "shape",
        "shape": "rect",
        "radius": 0.0,
        "fill": {"angle": 0.0, "stops": [[0.0, colour], [1.0, colour]]},
        "strokeWidth": 0.0,
    }


# name, x, y, width, height, element kind. Values are set in the panel's own
# size: a percentage is 110 px tall, a temperature 44, the rest 26..40.
ROWS = [
    # Above the CPU label: the load average, in the otherwise empty top band.
    ("Load 1", 160, 30, 300, 46, sensor("cpu.load.1", size=34)),
    ("Load 5", 160, 102, 300, 46, sensor("cpu.load.5", size=34)),
    ("Load 15", 160, 174, 300, 46, sensor("cpu.load.15", size=34)),
    # CPU: the number, its bar, its clock.
    ("CPU usage", 39, 320, 400, 140, sensor("cpu.usage", size=110)),
    ("CPU bar", 39, 466, 400, 24, bar("cpu.usage", 0, 100)),
    ("CPU frequency", 130, 498, 320, 48, sensor("cpu.frequency", size=40)),
    # GPU: the same, and now the band between CPU and GPU is the CPU bar.
    ("GPU usage", 39, 925, 400, 140, sensor("gpu.usage", size=110)),
    ("GPU bar", 39, 1071, 400, 24, bar("gpu.usage", 0, 100)),
    ("GPU frequency", 130, 1103, 320, 48, sensor("gpu.frequency", size=40)),
    ("GPU memory used", 130, 1168, 220, 46,
     sensor("gpu.memory.used", size=36, decimals=True)),
    ("GPU memory percent", 130, 1222, 220, 34,
     sensor("gpu.memory.percent", size=24, paint=DIM)),
    # Network, RAM, ROM: the vendor's own blocks.
    ("Network down", 216, 1332, 240, 30, sensor("net.down", size=24, prefix="\u2193 ")),
    ("Network up", 216, 1362, 240, 30, sensor("net.up", size=24, prefix="\u2191 ")),
    ("RAM percent", 39, 1398, 300, 84, sensor("memory.percent", size=72)),
    ("RAM used", 39, 1488, 300, 30,
     sensor("memory.used", size=26, paint=DIM, decimals=True)),
    ("ROM percent", 39, 1542, 300, 84, sensor("disk.root.percent", size=72)),
    ("ROM used", 39, 1626, 300, 30,
     sensor("disk.root.used", size=26, paint=DIM, decimals=True)),
    # Time, date, seconds: the vendor's labels, plus the icon beside the big one.
    ("Time", 300, 1532, 88, 44, clock("%H:%M", size=26)),
    ("Date", 264, 1596, 216, 40, clock("%a %e %b", size=30)),
    ("Time with seconds", 264, 1644, 216, 34, clock("%H:%M:%S", size=24)),
    # Disk rates, in the room the covered "Frames FPS" label leaves.
    ("Disk read", 142, 1700, 320, 38, sensor("disk.read", size=28)),
    ("Disk write", 142, 1740, 320, 38, sensor("disk.write", size=28)),
    # Temperatures, beside the vendor's two icons.
    ("CPU temperature", 95, 1824, 110, 56, sensor("cpu.temperature", size=44)),
    ("GPU temperature", 268, 1824, 110, 56, sensor("gpu.temperature", size=44)),
]


def paint_background(template: pathlib.Path, fonts: pathlib.Path) -> Image.Image:
    picture = Image.open(template).convert("RGBA").crop((0, 0, *CANVAS))
    backdrop = picture.getpixel((int(CANVAS[0] * 0.6), int(CANVAS[1] * 0.88)))[:3]
    flat = Image.new("RGB", CANVAS, backdrop)
    flat.paste(picture, (0, 0), picture)
    draw = ImageDraw.Draw(flat)

    # The vendor's own labels are a compact uppercase face; the theme's font is
    # monospace, so the added ones use it too.
    font = ImageFont.truetype(str(fonts / "JetBrainsMono-Medium.otf"), 22)
    for text, x, y, size in LABELS:
        font = ImageFont.truetype(str(fonts / "JetBrainsMono-Medium.otf"), size)
        draw.text((x, y), text, fill=(243, 245, 250), font=font)
    _, x, y, width, height = COVER
    draw.rectangle((x, y, x + width, y + height), fill=backdrop)
    return flat


def main(template: str, fonts: str, output: str) -> int:
    template_path = pathlib.Path(template)
    fonts_path = pathlib.Path(fonts)
    if not template_path.is_file():
        print(f"no template at {template}", file=sys.stderr)
        return 1
    folder = pathlib.Path(output)
    assets = folder / "assets"
    assets.mkdir(parents=True, exist_ok=True)
    paint_background(template_path, fonts_path).save(assets / "background.png")

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
