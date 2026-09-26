#!/usr/bin/env python3
"""Precompute ttfx's randomsequence, wipe and highlight effects on the logo, in
../effects.inc.

ttfx (a port of TerminalTextEffects) animates each character through a scene:
a list of colors, each shown for some ticks. In these three effects every
character plays the same kind of scene, only starting at a different tick and
ending on its own final color. So an effect boils down to:

- a start tick per character, worked out here the way ttfx picks them;
- a ramp: the color index to show for each tick since the start, with the
  index before the start (pre) and after the ramp (post);
- palettes that turn those indices into colors. The Game Boy Color gets one
  palette per tile row of the logo, which approximates ttfx's vertical
  gradients in three bands; the Game Boy gets shades of gray.

Colors, gradients, groupings and easing follow ttfx (src/effects and
src/engine), which reproduces TerminalTextEffects frame for frame. The one
difference is the random order of randomsequence, drawn from Python's random
with a fixed seed.

Usage: tools/effects.py
"""

import math
import random
import sys

sys.dont_write_bytecode = True  # no __pycache__ from importing logo.py
from logo import ROOT, Layout, read_cells  # noqa: E402

BLACK = (0, 0, 0)
SEED = 1


def hex_color(s):
    return tuple(int(s[i : i + 2], 16) for i in (0, 2, 4))


def gradient(stops, steps):
    """graphics.Gradient: steps colors per pair of stops, by integer deltas."""
    stops = [hex_color(s) if isinstance(s, str) else s for s in stops]
    steps = (steps + [steps[-1]] * len(stops))[: len(stops) - 1]
    spectrum = []
    for (start, end), n in zip(zip(stops, stops[1:]), steps):
        delta = [(e - s) // n for s, e in zip(start, end)]
        for i in range(1 if spectrum else 0, n):
            spectrum.append(tuple(max(0, min(255, s + d * i)) for s, d in zip(start, delta)))
        spectrum.append(end)
    return spectrum


def color_at_fraction(spectrum, fraction):
    n = len(spectrum)
    return next(c for i, c in enumerate(spectrum) if fraction <= (i + 1) / n)


def vertical_colors(spectrum, rows):
    """A vertical gradient's color for each cell row, top first."""
    return [color_at_fraction(spectrum, (rows - r) / rows) for r in range(rows)]


def adjust_brightness(color, brightness):
    """Animation.adjust_color_brightness: scale the color's HLS lightness."""
    r, g, b = (c / 255 for c in color)
    hi, lo = max(r, g, b), min(r, g, b)
    lightness = (hi + lo) / 2
    if hi == lo:
        hue = saturation = 0.0
    else:
        diff = hi - lo
        saturation = diff / (2 - hi - lo) if lightness > 0.5 else diff / (hi + lo)
        if hi == r:
            hue = (g - b) / diff + (6 if g < b else 0)
        elif hi == g:
            hue = (b - r) / diff + 2
        else:
            hue = (r - g) / diff + 4
        hue /= 6
    lightness = max(0.0, min(1.0, lightness * brightness))
    if saturation == 0:
        rgb = (lightness,) * 3
    else:
        q = lightness * (1 + saturation) if lightness < 0.5 else lightness + saturation - lightness * saturation
        p = 2 * lightness - q

        def channel(h):
            h = h + 1 if h < 0 else h - 1 if h > 1 else h
            if h < 1 / 6:
                return p + (q - p) * 6 * h
            if h < 1 / 2:
                return q
            if h < 2 / 3:
                return p + (q - p) * (2 / 3 - h) * 6
            return p

        rgb = (channel(hue + 1 / 3), channel(hue), channel(hue - 1 / 3))
    return tuple(round(c * 255) for c in rgb)


def in_out_circ(p):
    if p < 0.5:
        return (1 - math.sqrt(1 - (2 * p) ** 2)) / 2
    return (math.sqrt(1 - (-2 * p + 2) ** 2) + 1) / 2


def eased_start_ticks(groups, steps=100):
    """SequenceEaser: the tick at which each group is added."""
    starts, previous = [], 0
    for tick in range(steps):
        length = int(min(1.0, max(0.0, in_out_circ((tick + 1) / steps))) * len(groups))
        assert length >= previous, "the easing went backwards"
        starts += [tick] * (length - previous)
        previous = length
    return starts


class Logo:
    def __init__(self):
        self.layout = Layout(*read_cells())
        cells = self.layout.cells
        self.rows, self.cols = self.layout.rows, self.layout.cols
        # Visible characters as (cell row, column); ttfx drops the spaces
        self.chars = [(r, c) for r in range(self.rows) for c in range(self.cols) if any(cells[r][c])]

    def tte_coord(self, r, c):
        """ttfx's (column, row): 1-based, rows counted from the bottom."""
        return c + 1, self.rows - r

    def grouped(self, key):
        """Terminal.get_characters_grouped: characters bucketed by key, ascending."""
        buckets = {}
        for r, c in self.chars:
            buckets.setdefault(key(*self.tte_coord(r, c)), []).append((r, c))
        return [buckets[k] for k in sorted(buckets)]

    def bands(self):
        """The cell rows in each tile row of the logo."""
        return [range(k * 4, min(self.rows, k * 4 + 4)) for k in range(self.layout.th)]


class Effect:
    """What main.asm needs to play one effect. scene(r) gives cell row r's
    scene: its colors in order, each shown for `duration` ticks. index maps
    the position in a scene to a color index."""

    def __init__(self, name, logo, starts, scene, duration, index, pre, post, final, shades):
        self.name, self.logo, self.starts = name, logo, starts
        self.ramp = [i for i in index for _ in range(duration)]
        self.pre, self.post, self.shades = pre, post, shades
        assert len(self.ramp) <= 128 and self.ramp[-1] == post
        assert max(starts.values()) < 256, "start ticks must fit in a byte"

        # Each band's color for index j: the average of the scene colors
        # shown with it, except for the final color, which is exact
        self.palettes = []
        for band in logo.bands():
            palette = [BLACK]
            for j in range(1, 4):
                if j == post:
                    colors = [final(r) for r in band]
                else:
                    colors = [c for r in band for c, i in zip(scene(r), index) if i == j]
                palette.append(tuple(round(sum(ch) / len(colors)) for ch in zip(*colors)) if colors else BLACK)
            self.palettes.append(palette)

    def asm(self):
        label = "Effect" + self.name.title().replace(" ", "")
        duration = max(self.starts.values()) + len(self.ramp)
        bgp = sum(shade << (2 * j) for j, shade in enumerate(self.shades))
        rgb555 = lambda c: (c[0] >> 3) | (c[1] >> 3) << 5 | (c[2] >> 3) << 10
        layout = self.logo.layout
        lines = [
            f'SECTION "{self.name} effect", ROM0',
            "",
            f"{label}::",
            f"    dw {label}.starts",
            f"    db HIGH({label}.ramp), {len(self.ramp)} ; ramp and its length",
            f"    db {self.pre}, {self.post} ; color index before and after the ramp",
            f"    dw {duration} ; ticks until every character has finished",
            f"    db %{bgp:08b} ; Game Boy shades",
            f"    dw {label}.palettes",
            "",
            "; Game Boy Color palettes, one per tile row",
            f"{label}.palettes:",
        ]
        lines += ["    dw " + ", ".join(f"${rgb555(c):04X}" for c in p) for p in self.palettes]
        lines += ["", f'SECTION "{self.name} ramp", ROM0, ALIGN[8]', "", f"{label}.ramp:"]
        lines += [f"    db {', '.join(map(str, self.ramp[i : i + 16]))}" for i in range(0, len(self.ramp), 16)]
        lines += ["", f'SECTION "{self.name} starts", ROM0, ALIGN[3]', "", "; Start tick of each cell, per group", f"{label}.starts:"]
        for r, g in layout.groups:
            ticks = [self.starts.get((r, c), 0) for c in range(g * 8, g * 8 + 8)]
            lines.append(f"    db {', '.join(f'{t:3}' for t in ticks)}")
        return lines + [""]


def random_sequence(logo):
    """Characters appear in a random order, a few per tick, each fading in
    from the background to its color."""
    final = vertical_colors(gradient(["8A008A", "00D1FF", "FFFFFF"], [12]), logo.rows)
    per_tick = max(int(0.007 * len(logo.chars)), 1)
    pending = list(logo.chars)
    random.Random(SEED).shuffle(pending)
    starts = {ch: i // per_tick for i, ch in enumerate(reversed(pending))}
    return Effect(
        "random sequence", logo, starts,
        scene=lambda r: gradient([BLACK, final[r]], [7]),
        duration=8,
        index=[0, 0, 1, 1, 2, 2, 3, 3],
        pre=0, post=3, final=lambda r: final[r],
        shades=[3, 2, 1, 0],
    )  # fmt: skip


def wipe(logo):
    """Diagonals of characters, top left first, appear on an eased schedule and
    shift from the gradient's first color to their own."""
    spectrum = gradient(["833ab4", "fd1d1d", "fcb045"], [12])
    final = vertical_colors(spectrum, logo.rows)
    groups = logo.grouped(lambda col, row: col - row)
    starts = {ch: t for group, t in zip(groups, eased_start_ticks(groups)) for ch in group}
    return Effect(
        "wipe", logo, starts,
        scene=lambda r: gradient([spectrum[0], final[r]], [12]),
        duration=3,
        index=[1, 1, 1, 2, 2, 2, 2, 2, 2, 3, 3, 3, 3],
        pre=0, post=3, final=lambda r: final[r],
        shades=[3, 2, 1, 0],
    )  # fmt: skip


def highlight(logo):
    """A brighter band sweeps diagonally from the bottom left over the
    characters, which are already showing their colors."""
    base = vertical_colors(gradient(["8A008A", "00D1FF", "FFFFFF"], [12]), logo.rows)
    width = 8
    groups = logo.grouped(lambda col, row: col + row)
    starts = {ch: t for group, t in zip(groups, eased_start_ticks(groups)) for ch in group}

    def scene(r):
        bright = adjust_brightness(base[r], 1.75)
        return gradient([base[r], bright, bright, base[r]], [3, width, 3])

    # Index 2 is the base color, 3 the highlight and 1 between the two
    return Effect(
        "highlight", logo, starts, scene,
        duration=2,
        index=[2, 1, 1] + [3] * (width + 1) + [1, 1, 2],
        pre=2, post=2, final=lambda r: base[r],
        shades=[3, 1, 1, 0],
    )  # fmt: skip


def main():
    logo = Logo()
    effects = [random_sequence(logo), wipe(logo), highlight(logo)]
    lines = [
        "; Generated by tools/effects.py from logo.txt - do not edit.",
        ";",
        "; Each effect starts with its descriptor, in the order of hEffect in main.asm.",
        "",
    ]
    for effect in effects:
        lines += effect.asm()
    out = ROOT / "effects.inc"
    out.write_text("\n".join(lines))
    print(f"Wrote {out.relative_to(ROOT)}: {', '.join(e.name for e in effects)}")


if __name__ == "__main__":
    main()
