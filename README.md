# Omarchy screensaver for the Game Boy

<img width="1348" height="752" alt="image" src="https://github.com/user-attachments/assets/54a6e8f0-4302-4521-a511-26656ae24420" />


ttfx, the engine behind [Omarchy](https://omarchy.org)'s screensaver, was just
ported from Rust to x86-64 assembly. This keeps drilling: the same screensaver
in Game Boy assembly, on a 4 MHz CPU with 8 KB of video RAM. It plays in gray
on the original Game Boy and in color on a Game Boy Color.

## How it works

A Game Boy is too slow to run the effects live, so they're recorded ahead of
time. `tools/effects.py` renders every [ttfx](https://github.com/omacom/ttfx)
effect over the logo at the Game Boy's resolution, and keeps only the 8-byte
half tiles that change from frame to frame.

`main.asm`, about 430 lines of assembly, plays them back. It reads the stream
through the stack pointer, and copies each update into video RAM during
HBlank or VBlank, the only times the LCD lets it in. Partway down each frame it
switches tile sets, which is how it draws a full-screen bitmap of 360 tiles
with a tile map that can only address 256.

## Usage

Requires [RGBDS](https://rgbds.gbdev.io), [just](https://just.systems) and
[mGBA](https://mgba.io). Re-recording the effects also needs Python 3, Rust and
ttfx cloned into `reference/ttfx`.

```sh
just start      # build the ROM and run it in mGBA
just effects    # re-record the effects, e.g. after reordering EFFECTS in tools/effects.py
```
