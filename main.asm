; Omarchy screensaver for the Game Boy: the Omarchy logo, white on black,
; centered on the screen.

; Hardware registers
DEF rLCDC EQU $FF40
DEF rSCY  EQU $FF42
DEF rSCX  EQU $FF43
DEF rLY   EQU $FF44
DEF rBGP  EQU $FF47
DEF rBCPS EQU $FF68 ; Game Boy Color background palette index
DEF rBCPD EQU $FF69 ; Game Boy Color background palette data
DEF rIE   EQU $FFFF

; LCD on, background tiles at $8000 (unsigned indices), map at $9800, BG on
DEF LCDC_ON EQU %10010001

DEF VRAM_TILES EQU $8000
DEF VRAM_MAP   EQU $9800
DEF SCREEN_W   EQU 20 ; in tiles
DEF SCREEN_H   EQU 18
DEF MAP_W      EQU 32

; Game Boy shades for colors 3..0: color 0 (background) black, color 1 (logo) white
DEF DMG_PALETTE EQU %11_11_00_11

SECTION "Header", ROM0[$100]
    jp Start
    ds $150 - @, 0 ; rgbfix fills in the header

SECTION "Main", ROM0

Start:
    di
    call LcdOff

    ; Copy the logo's tiles into VRAM
    ld de, LogoTiles
    ld hl, VRAM_TILES
    ld bc, LogoTilesEnd - LogoTiles
    call Copy

    ; Copy the 20x18 screen map into the top-left of the 32x32 background map
    ld de, LogoMap
    ld hl, VRAM_MAP
    ld b, SCREEN_H
.row
    ld c, SCREEN_W
.col
    ld a, [de]
    ld [hli], a
    inc de
    dec c
    jr nz, .col
    ld a, l ; skip the rest of the 32-wide map row
    add MAP_W - SCREEN_W
    ld l, a
    jr nc, .nextRow
    inc h
.nextRow
    dec b
    jr nz, .row

    ; Palettes: the Game Boy's shades, and colors for a Game Boy Color
    ld a, DMG_PALETTE
    ldh [rBGP], a
    ld a, $80 ; palette 0, color 0, auto-increment
    ldh [rBCPS], a
    ld hl, CgbPalette
    ld b, CgbPaletteEnd - CgbPalette
.palette
    ld a, [hli]
    ldh [rBCPD], a
    dec b
    jr nz, .palette

    xor a
    ldh [rSCX], a
    ldh [rSCY], a
    ldh [rIE], a

    ld a, LCDC_ON
    ldh [rLCDC], a

.forever
    halt ; no interrupts are enabled, so this sleeps for good
    nop
    jr .forever

; Wait for VBlank, then switch the LCD off so VRAM can be written freely.
LcdOff:
    ldh a, [rLY]
    cp 144
    jr c, LcdOff
    xor a
    ldh [rLCDC], a
    ret

; Copy bc bytes from de to hl.
Copy:
    ld a, [de]
    ld [hli], a
    inc de
    dec bc
    ld a, b
    or c
    jr nz, Copy
    ret

; RGB555 colors, little-endian: black, white, and two unused
CgbPalette:
    dw $0000, $7FFF, $7FFF, $7FFF
CgbPaletteEnd:

INCLUDE "logo.inc"
