# The ROM is named after the project directory:
rom := "build/" + file_name(justfile_directory()) + ".gb"

# Regenerate logo.inc and effects.inc from logo.txt (Omarchy's screensaver logo):
logo:
    python3 tools/logo.py
    python3 tools/effects.py

# Build the ROM (-C marks it Game Boy Color compatible):
build:
    mkdir -p build
    rgbasm -o build/main.o main.asm
    rgblink -o {{ rom }} -n build/main.sym build/main.o
    rgbfix -v -C -p 0xFF -t OMARCHY {{ rom }}

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
