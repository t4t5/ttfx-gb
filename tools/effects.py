#!/usr/bin/env python3
"""Record every ttfx effect playing over the logo, and write it out as the
stream of screen updates main.asm plays: ../effects.bin, with ../effects.inc
placing it in ROM banks.

ttfx (a port of TerminalTextEffects, which Omarchy's screensaver runs) renders
each effect on a canvas of 160x72 character cells, the Game Boy's screen at
one pixel per column and two per row, which keeps the square-pixel look the
half-block logo has in a terminal. A cell whose character is a half block
lights that half, and text is drawn as a checkerboard (HALVES).

The screen is a bitmap of 360 tiles, so a frame is 720 half tiles of 8 bytes,
and the stream holds, for every recorded frame, the half tiles that changed
since the frame before it. main.asm copies them into VRAM during HBlanks and
VBlanks, which on a Game Boy comes to about BUDGET half tiles per 60th of a
second, so frames are recorded as often as that budget allows: FPS times a
second (ttfx runs at 120 ticks per second) when little changes, less often
when a lot does.

Colors: the Game Boy Color shows 4 colors per palette, 8 palettes, each fixed
to a band of tile rows (PALETTE_ROWS). For each band, the 3 colors seen most
over the effect are picked (k-means), sorted from dark to light, so that the
Game Boy's fixed gray ramp (BGP) shows the same indices as shades.

Stream format, read with the stack pointer, 16 bits at a time:

    n (n < $FFF0), due, then n packets of a VRAM address and 8 bytes: copy
        the packets, starting no earlier than frame `due` since the palettes
        were last set. Frames start being counted from the palette command.
    $FFFF: the stream continues at the start of the next ROM bank
    $FFFE, bgp, 8 Game Boy Color palettes (64 bytes): set the palettes,
        once all packets so far are copied, and restart the frame count
    $FFFD: the stream ends, play it again from the start

Between effects the palettes go black while the last effect's frame is cleared
and the next effect's first frame is drawn.

Requires ttfx built in references/ttfx (cargo build --release).

Usage: tools/effects.py [effect...]
"""

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TTFX = ROOT / "references" / "ttfx" / "target" / "release" / "ttfx"
DUMPS = ROOT / "build" / "dumps"
LOGO = ROOT / "logo.txt"

COLS, ROWS = 160, 72  # canvas cells
TILE_COLS, TILE_ROWS = 20, 18
TICKS_PER_SECOND = 120  # Omarchy's screensaver runs ttfx at this frame rate
TICKS_PER_FRAME = 2  # ttfx ticks per Game Boy frame (60 per second)
FPS = 30  # how often frames are recorded, at most
# Long effects that move a lot are recorded less often, to fit a 4 MB ROM
SLOW_FPS = dict.fromkeys(
    "beams binarypath blackhole bouncyballs fireworks laseretch matrix rings swarm thunderstorm".split(), 20
)
SEED = 1
HOLD_SECONDS = 1.5  # how long an effect's last frame stays up
BUDGET = 160  # half tiles main.asm copies per frame on a Game Boy
BANK_SIZE = 0x4000
MAX_BANKS = 256  # a 4 MB ROM (MBC5 allows 8)
BGP = 0b00011011  # Game Boy shades: index 0 black, then darker to lighter

# The palette of each tile row on a Game Boy Color: the logo's rows (7-10) get
# one each, the rest share
PALETTE_ROWS = [0, 0, 0, 0, 5, 5, 5, 1, 2, 3, 4, 6, 6, 6, 7, 7, 7, 7]

# Which halves of a cell a block character lights: (upper, lower). Any other
# character lights one half, alternating like a checkerboard, so that text
# (decrypt, matrix, the symbols of burn or rain) reads as a texture rather
# than a solid block.
HALVES = {
    " ": (0, 0),
    "▀": (1, 0), "▝": (1, 0), "▘": (1, 0), "▔": (1, 0), "^": (1, 0), "'": (1, 0), "`": (1, 0),
    "▄": (0, 1), "▖": (0, 1), "▗": (0, 1), "▁": (0, 1), "▂": (0, 1), "▃": (0, 1), "_": (0, 1),
    ",": (0, 1), ".": (0, 1),
    "█": (1, 1), "▓": (1, 1), "▅": (1, 1), "▆": (1, 1), "▇": (1, 1), "▙": (1, 1), "▛": (1, 1),
    "▜": (1, 1), "▟": (1, 1), "▌": (1, 1), "▍": (1, 1), "▎": (1, 1), "▏": (1, 1), "▐": (1, 1),
    "─": (1, 1), "│": (1, 1),
}  # fmt: skip
CHECKER = [(1, 0), (0, 1)]

# Options that shorten effects' timed phases, as ttfx's own demos do
OPTIONS = {
    "matrix": ["--rain-time", "3"],
    "thunderstorm": ["--storm-time", "3"],
    "vhstape": ["--total-glitch-time", "250"],
    "spotlights": ["--search-duration", "80"],
    "errorcorrect": ["--error-pairs", "0.5"],
}

# ttfx's effects, in the order they play
EFFECTS = """beams binarypath blackhole bouncyballs bubbles burn colorshift crumble
decrypt errorcorrect expand fireworks highlight laseretch matrix middleout
orbittingvolley overflow pour print rain randomsequence rings scattered slice
slide smoke spotlights spray swarm sweep synthgrid thunderstorm unstable
vhstape waves wipe""".split()

CELL = re.compile(r"(?:\x1b\[38;2;(\d+);(\d+);(\d+)m)?(.)(?:\x1b\[0m)?")
BLACK = (0, 0, 0)


def dump(name):
    """ttfx's frames of the effect, as lists of rows of (glyph, color) or None."""
    command = [
        str(TTFX), "--parity-dump", f"--seed={SEED}", f"--frame-rate={TICKS_PER_SECOND}",
        f"--canvas-width={COLS}", f"--canvas-height={ROWS}", "--anchor-canvas=c", "--anchor-text=c",
        "--ignore-terminal-dimensions", name, *OPTIONS.get(name, []),
    ]  # fmt: skip
    path = DUMPS / f"{name}.dump"
    stamp = " ".join(command) + "\n" + LOGO.read_text()
    if not path.exists() or path.with_suffix(".cmd").read_text() != stamp:
        DUMPS.mkdir(parents=True, exist_ok=True)
        with LOGO.open("rb") as stdin, path.open("wb") as stdout:
            subprocess.run(command, stdin=stdin, stdout=stdout, stderr=subprocess.DEVNULL, check=True)
        path.with_suffix(".cmd").write_text(stamp)
    data = path.read_bytes()
    frames, i = [], 0
    while i < len(data):
        j = data.index(b"\n", i)
        n = int(data[i:j])
        frames.append(parse_frame(data[j + 1 : j + 1 + n].decode()))
        i = j + 1 + n + 1
    return frames


def parse_frame(text):
    rows = []
    for line in text.split("\n"):
        row = []
        for m in CELL.finditer(line):
            glyph = m.group(4)
            if glyph == " ":
                row.append(None)
            else:
                color = tuple(map(int, m.group(1, 2, 3))) if m.group(1) else (255, 255, 255)
                row.append((glyph, color))
        assert len(row) == COLS, f"a row of {len(row)} cells"
        rows.append(row)
    assert len(rows) == ROWS, f"a frame of {len(rows)} rows"
    return rows


def luminance(color):
    r, g, b = color
    return 0.299 * r + 0.587 * g + 0.114 * b


def quantize(histogram):
    """The 3 colors to show the given (color: count)s with, dark to light."""
    colors = sorted(histogram, key=luminance)
    if not colors:
        return [BLACK] * 3
    if len(colors) <= 3:
        return colors + [colors[-1]] * (3 - len(colors))
    # k-means from the luminance terciles
    total = sum(histogram.values())
    centers, seen, k = [], 0, 0
    for c in colors:
        seen += histogram[c]
        if seen * 3 > total * (2 * k + 1) and k < 3:
            centers.append(c)
            k += 1
    while len(centers) < 3:
        centers.append(colors[-1])
    for _ in range(20):
        sums = [[0, 0, 0, 0] for _ in centers]
        for c, n in histogram.items():
            s = sums[nearest(centers, c)]
            s[3] += n
            for ch in range(3):
                s[ch] += c[ch] * n
        new = [tuple(round(s[ch] / s[3]) for ch in range(3)) if s[3] else centers[i] for i, s in enumerate(sums)]
        if new == centers:
            break
        centers = new
    return sorted(centers, key=luminance)


def nearest(centers, color):
    return min(range(len(centers)), key=lambda i: sum((a - b) ** 2 for a, b in zip(centers[i], color)))


def rgb555(color):
    return (color[0] >> 3) | (color[1] >> 3) << 5 | (color[2] >> 3) << 10


def half_tile_address(index):
    """The VRAM address of half tile `index` (tile row major, upper half first).
    Tile rows 0-11 are tiles 0-239 at $8000 (LCDC's unsigned addressing),
    rows 12-17 tiles 0-119 at $9000 (signed addressing, switched to at line 96)."""
    tile, half = divmod(index, 2)
    row, col = divmod(tile, TILE_COLS)
    if row < 12:
        return 0x8000 + tile * 16 + half * 8
    return 0x9000 + ((row - 12) * TILE_COLS + col) * 16 + half * 8


class Effect:
    def __init__(self, name):
        self.name = name
        frames = dump(name)
        self.ticks = len(frames)
        ticks = range(0, self.ticks, TICKS_PER_FRAME)

        # Palettes: the colors each band shows, weighted by how long
        bands = {}
        for t in ticks:
            for r, row in enumerate(frames[t]):
                histogram = bands.setdefault(PALETTE_ROWS[r // 4], {})
                for cell in row:
                    if cell:
                        histogram[cell[1]] = histogram.get(cell[1], 0) + 1
        self.palettes = [[BLACK] + quantize(bands.get(p, {})) for p in range(8)]
        self.indices = [{c: nearest(palette, c) for c in bands.get(p, {})} for p, palette in enumerate(self.palettes)]

        # The screen at each tick: the 8 bytes of each half tile that is not blank
        self.screens = {t: self.screen(frames[t]) for t in ticks}

    def screen(self, frame):
        screen = {}
        for row in range(TILE_ROWS):
            indices = self.indices[PALETTE_ROWS[row]]
            for half in range(2):
                for col in range(TILE_COLS):
                    data = bytearray()
                    for y in range(row * 4 + half * 2, row * 4 + half * 2 + 2):
                        cells = frame[y][col * 8 : col * 8 + 8]
                        if not any(cells):
                            data += bytes(4)
                            continue
                        planes = [[0, 0], [0, 0]]  # upper and lower pixel rows' bit planes
                        for x, cell in enumerate(cells, y):
                            for pixel in planes:
                                pixel[0] <<= 1
                                pixel[1] <<= 1
                            if cell:
                                index = indices[cell[1]]
                                for pixel, on in zip(planes, HALVES.get(cell[0]) or CHECKER[x & 1]):
                                    if on:
                                        pixel[0] |= index & 1
                                        pixel[1] |= index >> 1
                        for pixel in planes:
                            data += bytes(pixel)
                    if any(data):
                        screen[(row * TILE_COLS + col) * 2 + half] = bytes(data)
        return screen

    def record(self, previous):
        """The stream's frames of the effect, from the screen `previous`: as
        (due, packets), with the packets as (half tile index, bytes)."""
        # The first frame redraws every half tile lit before or after it, so
        # that it also comes out right on the blank screen at power-on
        shown = self.screens[0]
        recorded = [(0, sorted((i, shown.get(i, bytes(8))) for i in previous.keys() | shown.keys()))]
        shown_tick = 0
        step = TICKS_PER_FRAME * (60 // SLOW_FPS.get(self.name, FPS))
        last = max(self.screens)
        for tick in sorted(set(range(step, self.ticks, step)) | {last}):
            screen = self.screens[tick]
            packets = delta(shown, screen)
            if not packets:
                continue
            copy_frames = -(-len(packets) // BUDGET)
            # A frame is recorded if it can be copied since the one before it,
            # and the last one regardless, as late as it has to be
            if copy_frames <= (tick - shown_tick) // TICKS_PER_FRAME or tick == last:
                due = max(shown_tick // TICKS_PER_FRAME, tick // TICKS_PER_FRAME - copy_frames)
                recorded.append((due, packets))
                shown, shown_tick = screen, tick
        return recorded, shown


def delta(before, after):
    return sorted((i, after.get(i, bytes(8))) for i in before.keys() | after.keys() if before.get(i) != after.get(i))


class Stream:
    """The stream, split into ROM banks."""

    def __init__(self):
        self.banks = [bytearray()]

    def emit(self, data):
        if len(self.banks[-1]) + len(data) + 2 > BANK_SIZE:
            self.banks[-1] += b"\xff\xff"
            self.banks.append(bytearray())
            assert len(self.banks) < MAX_BANKS, "the effects do not fit in a 4 MB ROM"
        self.banks[-1] += data

    def frame(self, due, packets):
        data = bytearray(len(packets).to_bytes(2, "little") + due.to_bytes(2, "little"))
        for index, tile in packets:
            data += half_tile_address(index).to_bytes(2, "little") + tile
        self.emit(data)

    def palettes(self, palettes):
        data = b"\xfe\xff" + bytes([BGP])
        for palette in palettes:
            data += b"".join(rgb555(c).to_bytes(2, "little") for c in palette)
        self.emit(data + b"\x00")  # padded to an even length, as main.asm reads words

    def end(self):
        self.emit(b"\xfd\xff")


def main():
    names = sys.argv[1:] or EFFECTS
    if not TTFX.exists():
        sys.exit(f"effects.py: build ttfx first: cd {TTFX.parents[2]} && cargo build --release")
    effects = [Effect(name) for name in names]

    stream = Stream()
    black = [[BLACK] * 4] * 8
    hold = round(HOLD_SECONDS * 60)
    previous = effects[-1].screens[max(effects[-1].screens)]
    sizes = []
    for effect in effects:
        recorded, previous = effect.record(previous)
        # Black out the screen for the change of frame, then play the effect
        # and hold its last frame
        stream.palettes(black)
        stream.frame(*recorded[0])
        stream.palettes(effect.palettes)
        for due, packets in recorded[1:]:
            stream.frame(due, packets)
        stream.frame(effect.ticks // TICKS_PER_FRAME + hold, [])
        sizes.append(sum(4 + 10 * len(p) for _, p in recorded))
        print(f"{effect.name:16} {effect.ticks / TICKS_PER_SECOND:5.1f} s {len(recorded):5} frames {sizes[-1] / 1024:7.1f} KB")
    stream.end()

    (ROOT / "effects.bin").write_bytes(b"".join(bank.ljust(BANK_SIZE, b"\xff") for bank in stream.banks))
    lines = [
        "; Generated by tools/effects.py from logo.txt - do not edit.",
        "",
        'SECTION "Palette rows", ROM0',
        "",
        "; The palette of each tile row on a Game Boy Color",
        "PaletteRows::",
        "    db " + ", ".join(map(str, PALETTE_ROWS)),
        "",
        "; The stream of screen updates, one ROM bank at a time",
    ]
    for n, bank in enumerate(stream.banks, 1):
        lines += [f'SECTION "Stream bank {n}", ROMX, BANK[{n}]', f'    INCBIN "effects.bin", {(n - 1) * BANK_SIZE}, {len(bank)}']
    (ROOT / "effects.inc").write_text("\n".join(lines) + "\n")
    print(f"Wrote effects.bin and effects.inc: {len(effects)} effects in {len(stream.banks)} banks ({sum(sizes) / 1024 / 1024:.2f} MB)")


if __name__ == "__main__":
    main()
