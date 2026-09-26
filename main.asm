; Omarchy screensaver for the Game Boy: the Omarchy logo, centered on a black
; screen, animated in a loop with the effects of ttfx (a port of
; TerminalTextEffects, which Omarchy's screensaver runs).
;
; tools/effects.py records every effect with ttfx and writes the stream of
; screen updates in effects.bin: for each frame, the half tiles (8 bytes) that
; changed, with the frame at which to start copying them, and between effects
; the palettes to switch to. The screen is a bitmap of 360 tiles, and the
; stream is played by copying its packets into VRAM whenever the LCD allows
; it: one half tile in each HBlank (two on a Game Boy Color, which runs at
; double speed) and a run of them in VBlank, with the stack pointer reading
; the stream and interrupts kept off. The stream's frames are paced for the
; Game Boy's copying speed; a Game Boy Color just finishes them sooner.
;
; 360 tiles are more than the 256 the tile map can address, so the top 12
; tile rows use tiles 0-239 at $8000 and the bottom 6 tiles 0-119 at $9000,
; which the LCD is switched to in the HBlank of line 95 (LCDC bit 4) and back
; in VBlank.

; Hardware registers
DEF rP1   EQU $FF00
DEF rLCDC EQU $FF40
DEF rSTAT EQU $FF41
DEF rSCY  EQU $FF42
DEF rSCX  EQU $FF43
DEF rLY   EQU $FF44
DEF rBGP  EQU $FF47
DEF rKEY1 EQU $FF4D ; Game Boy Color speed switch
DEF rVBK  EQU $FF4F ; Game Boy Color VRAM bank
DEF rBCPS EQU $FF68 ; Game Boy Color background palette index
DEF rBCPD EQU $FF69 ; Game Boy Color background palette data
DEF rIE   EQU $FFFF

DEF rROMB0 EQU $2000 ; MBC5 ROM bank, low 8 bits
DEF rROMB1 EQU $3000 ; MBC5 ROM bank, bit 8

; LCD on, map at $9800, background on; tiles at $8000 (unsigned indices)
; for the top 12 tile rows and at $8800 (signed) for the bottom 6
DEF LCDC_TOP    EQU %10010001
DEF LCDC_BOTTOM EQU %10000001
DEF SWITCH_LINE EQU 95 ; the line in whose HBlank the LCD switches tiles

DEF VRAM_TILES EQU $8000
DEF OAM_START  EQU $FE00
DEF OAM_SIZE   EQU $A0
DEF VRAM_MAP   EQU $9800
DEF MAP_W      EQU 32
DEF TILE_COLS  EQU 20
DEF TILE_ROWS  EQU 18
DEF TOP_ROWS   EQU 12 ; tile rows drawn from $8000

; Stream commands, in place of a frame's packet count
DEF CMD_NEXT_BANK EQU $FFFF
DEF CMD_PALETTES  EQU $FFFE
DEF CMD_RESTART   EQU $FFFD
DEF PALETTES_SIZE EQU 66 ; BGP, 8 Game Boy Color palettes and a pad byte

DEF STREAM_BANK  EQU 1
DEF STREAM_START EQU $4000

; Copy a packet from sp: a VRAM address, then 8 bytes. 39 cycles.
MACRO POP_PACKET
    pop hl
    REPT 4
        pop de
        ld a, e
        ld [hli], a
        ld a, d
        ld [hli], a
    ENDR
ENDM

; Point sp at the start of the stream.
MACRO RESTART_STREAM
    ld a, STREAM_BANK
    ldh [hBank], a
    ld [rROMB0], a
    xor a
    ldh [hBank + 1], a
    ld [rROMB1], a
    ld sp, STREAM_START
ENDM

SECTION "Header", ROM0[$100]
    jp Start
    ds $150 - @, 0 ; rgbfix fills in the header

SECTION "Main", ROM0

Start:
    di
    ld sp, $E000
    cp $11 ; the boot ROM leaves $11 in a on a Game Boy Color
    ld a, 0
    jr nz, .notCgb
    inc a
.notCgb
    ldh [hIsCgb], a

    xor a
    ldh [rIE], a
    call LcdOff

    ; A Game Boy Color runs at double speed, which fits two packets in an
    ; HBlank instead of one
    ldh a, [hIsCgb]
    and a
    jr z, .speedSet
    ld a, 1
    ldh [rKEY1], a
    ld a, $30
    ldh [rP1], a
    stop
.speedSet

    ; Blank tiles, and no sprites: an OAM entry left over from the boot ROM
    ; would make an emulator lengthen its lines' drawing
    ld hl, VRAM_TILES
    ld bc, $2000
    xor a
    call Fill
    ld hl, OAM_START
    ld bc, OAM_SIZE
    xor a
    call Fill

    ; The map: tile rows 0-11 count tiles 0-239, rows 12-17 tiles 0-119
    ld hl, VRAM_MAP
    xor a
    ld d, TILE_ROWS
.mapRow
    ld c, TILE_COLS
.mapTile
    ld [hli], a
    inc a
    dec c
    jr nz, .mapTile
    cp TOP_ROWS * TILE_COLS
    jr nz, .mapRowDone
    xor a
.mapRowDone
    ld e, a
    ld a, l
    add MAP_W - TILE_COLS
    ld l, a
    jr nc, .noCarry
    inc h
.noCarry
    ld a, e
    dec d
    jr nz, .mapRow

    ; Palettes start out black
    ld a, $FF
    ldh [rBGP], a
    ldh a, [hIsCgb]
    and a
    jr z, .palettesSet
    ld a, $80 ; palette 0, color 0, auto-increment
    ldh [rBCPS], a
    xor a
    ld b, 8 * 8
.blackPalettes
    ldh [rBCPD], a
    dec b
    jr nz, .blackPalettes

    ; Game Boy Color: each tile row gets the palette PaletteRows gives it
    ld a, 1
    ldh [rVBK], a
    ld hl, VRAM_MAP
    ld de, PaletteRows
    ld b, TILE_ROWS
.attributeRow
    ld a, [de]
    inc de
    ld c, TILE_COLS
.attributeTile
    ld [hli], a
    dec c
    jr nz, .attributeTile
    ld a, l
    add MAP_W - TILE_COLS
    ld l, a
    jr nc, .attributeRowDone
    inc h
.attributeRowDone
    dec b
    jr nz, .attributeRow
    xor a
    ldh [rVBK], a
.palettesSet

    xor a
    ldh [rSCX], a
    ldh [rSCY], a
    ld a, LCDC_TOP
    ldh [rLCDC], a

; Play the stream, forever. The stack pointer reads the stream in the ROM
; bank at hBank, bc counts the packets of the frame being copied, and hFrame
; the frames since the palettes were last set. A frame's header is read as
; soon as the frame before it is copied, and its packets start once hFrame
; reaches hDue.
;
; With sp in ROM there is no calling anything, and registers are precious in
; the copying loops, so this is all one routine.
Play:
    xor a
    ldh [hHaveHeader], a
    ldh [hFrame], a
    ldh [hFrame + 1], a
    RESTART_STREAM
    ld bc, 0

    ; Wait for an HBlank. From its start, VRAM can be written for the 51
    ; cycles of the HBlank and the 20 of the next line's OAM scan (twice as
    ; many on a Game Boy Color), and the loop sees it within 10. The first
    ; write waits a few cycles more: mGBA drops writes made right at the start
    ; of an HBlank, and the margin at its end is plenty.
.line
    ldh a, [rSTAT]
    and 3
    jr nz, .line
    REPT 4
        nop
    ENDR
    ld a, b
    or c
    jr z, .lineCopied
    POP_PACKET ; done by cycle 57
    dec bc
    ; A Game Boy Color has time for a second one
    ldh a, [hIsCgb]
    and a
    jr z, .lineCopied
    ld a, b
    or c
    jr z, .lineCopied
    POP_PACKET ; done by cycle 108 of 142
    dec bc
.lineCopied
    ldh a, [rLY]
    cp SWITCH_LINE - 1
    jr z, .switchLine
    cp 143
    jr nc, .vblank
    ; Wait out the next line's drawing before looking for its HBlank
.drawing
    ldh a, [rSTAT]
    and 3
    cp 3
    jr nz, .drawing
    jr .line

    ; The next HBlank, line 95's (or 94's, when the copying ran into line 95:
    ; tile row 11 draws the same either way) switches the tiles instead of
    ; copying
.switchLine
    ldh a, [rSTAT]
    and 3
    cp 3
    jr nz, .switchLine
.switchWait
    ldh a, [rSTAT]
    and 3
    jr nz, .switchWait
    REPT 4
        nop
    ENDR
    ld a, LCDC_BOTTOM
    ldh [rLCDC], a
    jr .drawing

    ; VBlank, entered after line 143's HBlank (or, when the copying ran into
    ; the next line, line 142's): once it has begun, count the frame, start
    ; the next one if it is due, and copy packets until line 152
.vblank
    ldh a, [rSTAT]
    and 3
    cp 1
    jr nz, .vblank
    ld a, LCDC_TOP
    ldh [rLCDC], a
    ldh a, [hFrame]
    inc a
    ldh [hFrame], a
    jr nz, .counted
    ldh a, [hFrame + 1]
    inc a
    ldh [hFrame + 1], a
.counted

    ld a, b
    or c
    jp nz, .vblankCopy
.nextHeader
    ldh a, [hHaveHeader]
    and a
    jr nz, .haveHeader
    pop bc ; the packet count, or a command
    ld a, c
    cp LOW(CMD_RESTART)
    jr c, .frameHeader
    ld a, b
    inc a
    jr nz, .frameHeader
    ld a, c
    cp LOW(CMD_NEXT_BANK)
    jr z, .nextBank
    cp LOW(CMD_PALETTES)
    jr z, .setPalettes
    RESTART_STREAM
    jr .nextHeader
.nextBank
    ldh a, [hBank]
    inc a
    ldh [hBank], a
    ld [rROMB0], a
    jr nz, .bankSet
    ldh a, [hBank + 1]
    inc a
    ldh [hBank + 1], a
    ld [rROMB1], a
.bankSet
    ld sp, STREAM_START
    jr .nextHeader
.setPalettes
    pop hl ; BGP and the first Game Boy Color palette byte
    ld a, l
    ldh [rBGP], a
    ldh a, [hIsCgb]
    and a
    jr z, .skipCgbPalettes
    ld a, $80 ; palette 0, color 0, auto-increment
    ldh [rBCPS], a
    ld a, h
    ldh [rBCPD], a
    ld d, (PALETTES_SIZE - 4) / 2
.paletteWord
    pop hl
    ld a, l
    ldh [rBCPD], a
    ld a, h
    ldh [rBCPD], a
    dec d
    jr nz, .paletteWord
    pop hl ; the last byte and the pad
    ld a, l
    ldh [rBCPD], a
    jr .palettesLoaded
.skipCgbPalettes
    add sp, PALETTES_SIZE - 2
.palettesLoaded
    xor a
    ldh [hFrame], a
    ldh [hFrame + 1], a
    jr .nextHeader
.frameHeader
    ld a, c
    ldh [hPackets], a
    ld a, b
    ldh [hPackets + 1], a
    pop hl ; the frame it is due
    ld a, l
    ldh [hDue], a
    ld a, h
    ldh [hDue + 1], a
    ld a, 1
    ldh [hHaveHeader], a
.haveHeader
    ; Due when hFrame >= hDue
    ldh a, [hDue]
    ld l, a
    ldh a, [hDue + 1]
    ld h, a
    ldh a, [hFrame]
    sub l
    ldh a, [hFrame + 1]
    sbc h
    ld bc, 0
    jr c, .vblankCopy
    xor a
    ldh [hHaveHeader], a
    ldh a, [hPackets]
    ld c, a
    ldh a, [hPackets + 1]
    ld b, a

.vblankCopy
    ld a, b
    or c
    jr z, .vblankDone
    ldh a, [rLY]
    and a ; line 153 reads as 0 for most of its length
    jr z, .vblankDone
    cp 152
    jr nc, .vblankDone
    POP_PACKET
    dec bc
    jr .vblankCopy
.vblankDone
    jp .drawing

; Wait for VBlank, then switch the LCD off so VRAM can be written freely.
LcdOff:
    ldh a, [rLY]
    cp 144
    jr c, LcdOff
    xor a
    ldh [rLCDC], a
    ret

; Fill bc bytes at hl with a.
Fill:
    ld e, a
.loop
    ld a, e
    ld [hli], a
    dec bc
    ld a, b
    or c
    jr nz, .loop
    ret

SECTION "HRAM", HRAM
hIsCgb:       ds 1
hBank:        ds 2 ; the ROM bank the stream is being read from
hFrame:       ds 2 ; frames since the palettes were last set
hHaveHeader:  ds 1 ; nonzero once the next frame's header is read
hPackets:     ds 2 ; that frame's packet count
hDue:         ds 2 ; and the frame it is due

INCLUDE "effects.inc"
