#!/usr/bin/env python3
"""Build a Bezel theme out of the vendor's "Simple black and white" template.

The template is one of the vendor resources re-published with the extracted
Turing/TURZX themes in turing-smart-screen-python, under
`res/themes/--Theme examples/8.8inch/Simple black and white theme/`: a black
480x1920 layout whose labels carry no values, because the vendor app drew them
(`theme_res_157510.png`).

This script keeps that artwork as the background and puts live Bezel sensors to
the right of each label. The label boxes were measured on the template, so the
frames here are not guesses:

    CPU USAGE        y  295-306  x 47-126      RAM USAGE    y 1375-1383  x 39-99
    GPU USAGE        y  900-911  x 47-127      ROM USAGE    y 1519-1527  x 39-99
    NETWORK SPEED    y 1304-1324  x 216-434    TIME (big)   y 1531-1569  x 214-290
    DATE             y 1611-1621  x 220-252    TIME         y 1658-1669  x 220-242
    Frames FPS       y 1658-1669  x 39-97      CPU/GPU icons y 1846-1874 x 47/217

Usage:

    python3 build-bw-theme.py <template.png> ~/.local/share/bezel/themes/bw-vertical-8.8

The vendor artwork stays the vendor's; the theme.json and this script are ours.
"""

import json
import pathlib
import shutil
import sys

LABEL_COLOUR = "#f3f5faff"
DIM_COLOUR = "#9aa0a6ff"
MONO = {"family": "JetBrains Mono", "weight": 500, "italic": False}

BACKGROUND = {"type": "image", "asset": "assets/background.png", "fit": "fill"}

SOURCE = """# Where this theme comes from

The artwork is the vendor's own "Simple black and white theme" for the 8.8"
Turing/TURZX screen, as re-published with the extracted vendor resources in
[mathoudebine/turing-smart-screen-python](https://github.com/mathoudebine/turing-smart-screen-python)
under `res/themes/--Theme examples/8.8inch/Simple black and white theme/`
(the file `theme_res_157510.png`: an empty 480x1920 black layout, the vendor app
drew the values).

`theme.json` was written for Bezel by `tools/build-bw-theme.py` in the
[omarchy-bezel](https://github.com/vyorkin/omarchy-bezel) widget repository: the
same labels, with live sensor text to their right.
"""


def sensor(key, *, size, paint=LABEL_COLOUR, prefix="", suffix="", decimals=False):
    return {
        "type": "text",
        "content": {
            "type": "sensor",
            "key": key,
            "format": {"showUnit": True, "fahrenheit": False, "decimalBytes": decimals},
            "prefix": prefix,
            "suffix": suffix,
        },
        "style": {
            "font": MONO,
            "size": float(size),
            "paint": paint,
            "align": "left",
            "valign": "middle",
            "letterSpacing": 0.0,
        },
    }


def clock(pattern, *, size, paint=LABEL_COLOUR):
    return {
        "type": "text",
        "content": {"type": "clock", "pattern": pattern},
        "style": {
            "font": MONO,
            "size": float(size),
            "paint": paint,
            "align": "left",
            "valign": "middle",
            "letterSpacing": 0.0,
        },
    }


# name, x, y, width, height, element kind
#
# Every value sits directly under the label it belongs to, in the label's own
# column: the template reserves that space (the vendor app printed the value
# there), and one rule keeps the sparse screen looking deliberate. Three places
# cannot follow it — the date, the second time and the frame rate share the
# bottom right, and the big time has the clock icon beside it — so there the
# value goes to the right of its label instead.
ROWS = [
    ("CPU usage", 47, 318, 300, 46, sensor("cpu.usage", size=36)),
    ("GPU usage", 47, 923, 300, 46, sensor("gpu.usage", size=36)),
    ("Network down", 216, 1332, 240, 24, sensor("net.down", size=18, prefix="\u2193 ")),
    ("Network up", 216, 1358, 240, 24, sensor("net.up", size=18, prefix="\u2191 ")),
    ("RAM percent", 39, 1398, 110, 32, sensor("memory.percent", size=26)),
    ("RAM used", 39, 1432, 200, 22,
     sensor("memory.used", size=18, paint=DIM_COLOUR, decimals=True)),
    ("ROM percent", 39, 1542, 110, 32, sensor("disk.root.percent", size=26)),
    ("ROM used", 39, 1576, 200, 22,
     sensor("disk.root.used", size=18, paint=DIM_COLOUR, decimals=True)),
    ("Time", 300, 1526, 90, 48, clock("%H:%M", size=26)),
    ("Date", 264, 1598, 200, 34, clock("%a %e %b", size=22)),
    ("Time with seconds", 264, 1646, 200, 30, clock("%H:%M:%S", size=20)),
    ("FPS", 115, 1647, 100, 30, sensor("gpu.fps", size=22)),
    ("CPU temperature", 95, 1835, 110, 34, sensor("cpu.temperature", size=26)),
    ("GPU temperature", 268, 1835, 110, 34, sensor("gpu.temperature", size=26)),
]


def main(template: str, output: str) -> int:
    template_path = pathlib.Path(template)
    if not template_path.is_file():
        print(f"no template at {template}", file=sys.stderr)
        return 1
    folder = pathlib.Path(output)
    assets = folder / "assets"
    assets.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(template_path, assets / "background.png")

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
        "canvas": {"width": 480, "height": 1920},
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
    if len(sys.argv) != 3:
        print(__doc__)
        raise SystemExit(2)
    raise SystemExit(main(sys.argv[1], sys.argv[2]))
