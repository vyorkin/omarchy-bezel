# Case Panel for the Omarchy bar

The 8.8" screen inside the case, from the bar: which theme it shows, how bright
it is, and the parameters worth changing without opening Bezel Studio. The bar
shows a small screen outline whose lower part fills with the backlight level;
when the panel is off, the outline is left hollow.

## What it does

| Target | How |
|---|---|
| The theme on the screen | `bezel-run@<theme>` — the same systemd user unit `bezel` documents for starting a theme at login |
| The backlight | `bezel brightness <percent>` |
| Refresh rate, orientation | `refreshSeconds` and `orientation` in the theme's `theme.json` |
| Element visibility, opacity, text size | `visible`, `opacity` and `kind.style.size` of one element |
| Every colour in a theme | any `#rrggbbaa` in the theme, gradient stops included, painted from the current Omarchy palette |

The widget itself knows nothing about themes. `bin/omarchy-bezel` reads the same
theme folders `bezel` reads, edits a theme in place and restarts the unit on it;
one `theme.json.bak` is kept next to the original the first time a theme is
edited. Because every read goes to disk, the popup, Bezel Studio and a terminal
can never disagree for long — press the glyph again after editing in the studio
and the values are current.

Deliberately out of scope: **creating themes** (that is Bezel Studio's job, with
a canvas, widgets and undo), and **themes stored as `.bezeltheme` archives**,
which are read-only here.

## Actions

| Input | Result |
|---|---|
| Left click on the bar glyph | open the popup |
| Middle click | take the panel off the screen, or put it back |
| Click a theme | that theme is enabled and started on the panel |
| Drag a slider | applies while dragging, one restart of the theme when the value settles |
| Arrow keys | move the cursor: right enters the elements, left comes back |
| Enter | pick a theme, open an element, toggle a switch, paint a colour |
| Escape | one step back, then close |

Previews are rendered once per theme with demo values and cached in
`~/.cache/omarchy-bezel/thumbs/`, so the popup opens instantly after the first
time and a theme shows its new look seconds after it is edited.

## Requirements

- [bezel](https://github.com/slipalison/bezel) 0.16 or newer, with its
  `bezel-run@.service` user unit (the deb, the rpm, or
  `scripts/install-local.sh` from a source build);
- `python3` (any 3.9+);
- ImageMagick or `ffmpeg` for smaller previews — without either, the full-size
  render still shows.

## Install

```bash
omarchy plugin install https://github.com/vyorkin/omarchy-bezel
```

Or by hand:

```bash
git clone https://github.com/vyorkin/omarchy-bezel ~/.config/omarchy/plugins/io.github.vyorkin.omarchy-bezel
omarchy restart shell
```

Then add it to the bar if the shell does not offer to:

```bash
omarchy plugin enable io.github.vyorkin.omarchy-bezel right
omarchy restart shell
```

The bar layout is read when the shell starts, so enabling a widget needs the
restart — a change to the plugin's own code does not.

## Use from a terminal

The same helper drives everything, and prints JSON:

```bash
bin/omarchy-bezel status                 # the chosen theme, the screen, every theme
bin/omarchy-bezel themes                 # names, paths, thumbnails, unit state
bin/omarchy-bezel params turing-8.8-vertical
bin/omarchy-bezel use turing-8.8-vertical
bin/omarchy-bezel set turing-8.8-vertical refresh=2 elements.2.visible=false
bin/omarchy-bezel set turing-8.8-vertical elements.2.kind.style.paint=#ff3535ff
bin/omarchy-bezel brightness 40
bin/omarchy-bezel stop
```

A path in `set` is the dotted path inside `theme.json`, which is exactly what
`params` prints for every element and colour, so nothing has to be guessed:

```json
{"index": 2, "name": "Time", "type": "text", "size": 150.0,
 "paths": {"visible": "elements.2.visible", "size": "elements.2.kind.style.size"},
 "colors": [{"path": "kind.style.paint", "value": "#f3f5faff"}]}
```

Only one program may drive the screen at a time. If Bezel Studio has **Live** on,
turn it off before picking a theme here; otherwise the second process is refused.
The RGB Control widget, which also talks to the panel, only sets its backlight.

## Layout of this repository

```
manifest.json        the plugin manifest the shell reads
Panel.qml            the bar widget and its popup
bin/omarchy-bezel    themes, parameters, systemd unit, preview cache
```

## License

MIT.
