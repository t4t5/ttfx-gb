# The ROM is named after the project directory:
rom := "build/" + file_name(justfile_directory()) + ".gb"
ttfx := "references/ttfx/target/release/ttfx"

# Regenerate effects.bin and effects.inc: every ttfx effect playing over
# logo.txt (Omarchy's screensaver logo), recorded with ttfx:
effects: ttfx
    python3 tools/effects.py

# Build ttfx, the reference the effects are recorded with:
ttfx:
    test -x {{ ttfx }} || (cd references/ttfx && cargo build --release)

# Build the ROM (-C marks it Game Boy Color compatible, -m MBC5 gives it
# the ROM banks the effects take):
build:
    mkdir -p build
    rgbasm -o build/main.o main.asm
    rgblink -o {{ rom }} -n build/main.sym build/main.o
    rgbfix -v -C -m MBC5 -p 0xFF -t OMARCHY {{ rom }}

# Start the emulator with the built ROM:
start: build
    mgba-qt {{ rom }}

# Install the ROM on an SD card (using Everdrive):
install: build
    gb install {{ rom }}

# Eject the SD card when no longer needed:
eject:
    sudo eject sda

# Screenshot the ROM to build/screenshot.png after pressing the given buttons
# in turn, e.g. `just screenshot start down`:
screenshot *buttons: build
    gb screenshot {{ rom }} build/screenshot.png {{ buttons }}
