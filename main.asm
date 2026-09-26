; Omarchy screensaver for the Game Boy: the Omarchy logo, centered on a black
; screen, animated in a loop with effects ported from ttfx (a port of
; TerminalTextEffects, which Omarchy's screensaver runs).
;
; The logo is a grid of cells, one per character of logo.txt, and an effect
; gives each cell a color index. tools/effects.py works out when each cell's
; animation starts and which color index it shows at each tick after that
; (its ramp). For each frame, BuildColorTable turns the current tick into a
; table from start tick to color index, and Render looks up every cell in it,
; drawing the logo's tiles into a framebuffer in WRAM. The VBlank handler then
; copies that framebuffer to VRAM, half a frame per VBlank, as copying it all
; takes longer than a Game Boy's VBlank. So the effects play at 30 frames per
; second.

INCLUDE "logo.inc"

; Hardware registers
DEF rP1   EQU $FF00
DEF rIF   EQU $FF0F
DEF rLCDC EQU $FF40
DEF rSCY  EQU $FF42
DEF rSCX  EQU $FF43
DEF rLY   EQU $FF44
DEF rBGP  EQU $FF47
DEF rKEY1 EQU $FF4D ; Game Boy Color speed switch
DEF rVBK  EQU $FF4F ; Game Boy Color VRAM bank
DEF rBCPS EQU $FF68 ; Game Boy Color background palette index
DEF rBCPD EQU $FF69 ; Game Boy Color background palette data
DEF rIE   EQU $FFFF

; LCD on, background tiles at $8000 (unsigned indices), map at $9800, BG on
DEF LCDC_ON   EQU %10010001
DEF IE_VBLANK EQU %00000001

DEF VRAM_TILES EQU $8000
DEF VRAM_MAP   EQU $9800
DEF MAP_W      EQU 32

; The logo's tiles sit at the top left of the map, scrolled to the center
DEF LOGO_X EQU (160 - LOGO_W) / 2
DEF LOGO_Y EQU (144 - LOGO_H) / 2

; ttfx ticks per frame: Omarchy's screensaver runs ttfx at 120 frames per
; second, and a Game Boy shows 60
DEF TICKS_PER_FRAME EQU 2
; How long each effect's last frame stays up before the next effect starts
DEF HOLD_FRAMES EQU 90

ASSERT LOGO_HALF_A < 256

SECTION "VBlank interrupt", ROM0[$40]
    jp VBlank

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

    ; A Game Boy Color runs at double speed, which leaves time in VBlank to
    ; load its palettes as well as copy the framebuffer
    ldh a, [hIsCgb]
    and a
    jr z, .speedSet
    ld a, 1
    ldh [rKEY1], a
    ld a, $30
    ldh [rP1], a
    stop
.speedSet

    ; Blank tiles, an empty map and blank framebuffers
    ld hl, VRAM_TILES
    ld bc, $2000
    xor a
    call Fill
    ld hl, wFrameA
    ld bc, LOGO_FRAME_SIZE
    call Fill
    ld hl, wFrameB
    ld bc, LOGO_FRAME_SIZE
    call Fill

    ; The map's top left shows the logo's tiles: tile row k's start at tile
    ; $10 * (k + 1), 256 bytes after tile row k - 1's
    ld hl, VRAM_MAP
    ld b, $10
    ld d, LOGO_TH
.mapRow
    ld a, b
    ld c, LOGO_TW
.mapTile
    ld [hli], a
    inc a
    dec c
    jr nz, .mapTile
    call NextMapRow
    ld a, b
    add $10
    ld b, a
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

    ; Game Boy Color: each tile row of the logo gets the palette of its number
    ld a, 1
    ldh [rVBK], a
    ld hl, VRAM_MAP
    ld bc, MAP_W * 32
    xor a
    call Fill
    ld hl, VRAM_MAP
    ld d, 0
.attributeRow
    ld a, d
    ld c, LOGO_TW
.attributeTile
    ld [hli], a
    dec c
    jr nz, .attributeTile
    call NextMapRow
    inc d
    ld a, d
    cp LOGO_TH
    jr nz, .attributeRow
    xor a
    ldh [rVBK], a
.palettesSet

    ld a, LOW(-LOGO_X)
    ldh [rSCX], a
    ld a, LOW(-LOGO_Y)
    ldh [rSCY], a

    ; Nothing to copy yet
    xor a
    ldh [hFrame], a
    ldh [hFrame + 1], a
    ldh [hHalf], a
    ldh [hPalettePending], a
    inc a
    ldh [hFrontDone], a
    ld a, HIGH(wFrameA)
    ldh [hFront], a
    ld a, HIGH(wFrameB)
    ldh [hBack], a

    ld a, LCDC_ON
    ldh [rLCDC], a
    xor a
    ldh [rIF], a
    ld a, IE_VBLANK
    ldh [rIE], a
    ei

.effects
    ld hl, Effects
.nextEffect
    ld a, [hli]
    ld e, a
    ld a, [hli]
    ld d, a
    or e
    jr z, .effects
    push hl
    ld h, d
    ld l, e
    call PlayEffect
    pop hl
    jr .nextEffect

; The effects to loop through, in order
Effects:
    dw EffectRandomSequence
    dw EffectWipe
    dw EffectHighlight
    dw 0

; Play the effect whose descriptor is at hl, then hold its last frame.
PlayEffect:
    ld c, LOW(hEffect)
    ld b, hEffectEnd - hEffect
.load
    ld a, [hli]
    ldh [c], a
    inc c
    dec b
    jr nz, .load

    ; Black out the screen until the effect's first frame is all on it, then
    ; switch to the effect's palettes
    ld a, $FF
    ldh [rBGP], a
    ld hl, BlackPalettes
    call SetCgbPalettes
    xor a
    ldh [hTick], a
    ldh [hTick + 1], a
    call BuildColorTable
    call Render
    call Present
    call WaitFrontDone
    ldh a, [hBgp]
    ldh [rBGP], a
    ldh a, [hEffectPalettes]
    ld l, a
    ldh a, [hEffectPalettes + 1]
    ld h, a
    call SetCgbPalettes

    di
    ldh a, [hFrame]
    ldh [hStartFrame], a
    ldh a, [hFrame + 1]
    ldh [hStartFrame + 1], a
    ei

.frame
    ; The tick to show: TICKS_PER_FRAME per frame since the start, up to the
    ; effect's duration
    di
    ldh a, [hFrame]
    ld l, a
    ldh a, [hFrame + 1]
    ld h, a
    ei
    ldh a, [hStartFrame]
    ld c, a
    ldh a, [hStartFrame + 1]
    ld b, a
    ld a, l
    sub c
    ld l, a
    ld a, h
    sbc b
    ld h, a
    ld d, h
    ld e, l
    REPT TICKS_PER_FRAME - 1
        add hl, de
    ENDR
    ldh a, [hDuration]
    ld e, a
    ldh a, [hDuration + 1]
    ld d, a
    ld a, l
    sub e
    ld a, h
    sbc d
    jr c, .running
    ld h, d
    ld l, e
.running
    ld a, l
    ldh [hTick], a
    ld a, h
    ldh [hTick + 1], a

    call BuildColorTable
    call Render
    call Present

    ; Until the frame of the effect's duration
    ldh a, [hDuration]
    ld b, a
    ldh a, [hTick]
    cp b
    jr nz, .frame
    ldh a, [hDuration + 1]
    ld b, a
    ldh a, [hTick + 1]
    cp b
    jr nz, .frame

    ld b, HOLD_FRAMES
.hold
    halt
    dec b
    jr nz, .hold
    ret

; Fill wColorTable with the color index each start tick shows at hTick:
; the effect's pre color for start ticks still to come, its ramp for the
; ticks that have started less than a ramp's length ago, and its post color
; for the rest.
BuildColorTable:
    ld hl, wColorTable
    ; bc = tick - (ramp length - 1): the start ticks past their ramp
    ldh a, [hRampLen]
    dec a
    ld c, a
    ldh a, [hTick]
    sub c
    ld c, a
    ldh a, [hTick + 1]
    sbc 0
    jr c, .noneFinished
    ldh a, [hPost]
    jr nz, .fillRest ; all 256 finished
    inc c
    jr .finishedTest
.finished
    ld [hl], a
    inc l
.finishedTest
    dec c
    jr nz, .finished
    ldh a, [hRampLen]
    dec a
    jr .ramp
.noneFinished
    ldh a, [hTick]
.ramp
    ; de = the ramp at the age of start tick l, counting down to age 0
    ld e, a
    ldh a, [hRampHi]
    ld d, a
.rampStep
    ld a, [de]
    ld [hl], a
    inc l
    ret z
    dec e
    bit 7, e ; ramps are at most 128 long
    jr z, .rampStep
    ldh a, [hPre]
.fillRest
    ld [hl], a
    inc l
    jr nz, .fillRest
    ret

; Render the logo into the back framebuffer: for each group of 8 cells, look
; up their color indices, split them into the two bit planes, and keep the
; pixels of its upper and lower pixel rows that are the logo's.
Render:
    ldh a, [hStarts]
    ld e, a
    ldh a, [hStarts + 1]
    ld d, a
    ld a, LOW(LogoMasks)
    ldh [hMasks], a
    ld a, HIGH(LogoMasks)
    ldh [hMasks + 1], a
    xor a
    ldh [hDest], a
    ldh a, [hBack]
    ldh [hDest + 1], a
    ld a, LOGO_GROUPS
    ldh [hGroupsLeft], a
.group
    ld h, HIGH(wColorTable)
    FOR I, 8
        ld a, [de] ; start tick
        IF I < 7
            inc e ; start ticks are 8-aligned per group
        ELSE
            inc de
        ENDC
        ld l, a
        ld a, [hl] ; color index
        rra
        rl c ; low bit plane
        rra
        rl b ; high bit plane
    ENDR
    push de
    ldh a, [hDest]
    ld e, a
    ldh a, [hDest + 1]
    ld d, a
    ldh a, [hMasks]
    ld l, a
    ldh a, [hMasks + 1]
    ld h, a
    ld a, c ; upper pixel row
    and [hl]
    ld [de], a
    inc e
    ld a, b
    and [hl]
    ld [de], a
    inc e
    inc hl
    ld a, c ; lower pixel row
    and [hl]
    ld [de], a
    inc e
    ld a, b
    and [hl]
    ld [de], a
    inc de
    inc hl
    ld a, l
    ldh [hMasks], a
    ld a, h
    ldh [hMasks + 1], a
    ld a, e
    ldh [hDest], a
    ld a, d
    ldh [hDest + 1], a
    pop de
    ldh a, [hGroupsLeft]
    dec a
    ldh [hGroupsLeft], a
    jp nz, .group
    ret

; Hand the back framebuffer to the VBlank handler to copy, once it is done
; with the front one.
Present:
    call WaitFrontDone
    di
    ldh a, [hFront]
    ld b, a
    ldh a, [hBack]
    ldh [hFront], a
    ld a, b
    ldh [hBack], a
    xor a
    ldh [hFrontDone], a
    ei
    ret

; On a Game Boy Color, load the palettes at hl in the next VBlank.
SetCgbPalettes:
    ldh a, [hIsCgb]
    and a
    ret z
    ld a, l
    ldh [hPalettes], a
    ld a, h
    ldh [hPalettes + 1], a
    ld a, 1
    ldh [hPalettePending], a
.wait
    halt
    ldh a, [hPalettePending]
    and a
    jr nz, .wait
    ret

BlackPalettes:
    ds LOGO_TH * 8, 0

; Wait until the front framebuffer is all on screen.
WaitFrontDone:
    ldh a, [hFrontDone]
    and a
    ret nz
    halt
    jr WaitFrontDone

; Move hl from the end of the logo's tiles on a map row to the next row.
NextMapRow:
    ld a, l
    add MAP_W - LOGO_TW
    ld l, a
    ret nc
    inc h
    ret

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

; Copy \1 bytes from sp to hl, 2 at a time, within hl's 256-byte page.
MACRO POPSLIDE
    REPT (\1) / 2
        pop de
        ld [hl], e
        inc l
        ld [hl], d
        inc l
    ENDR
ENDM

; Count the frame, load the Game Boy Color palettes if asked to, and copy the
; next half of the front framebuffer to VRAM.
VBlank:
    push af
    push bc
    push de
    push hl
    ldh a, [hFrame]
    inc a
    ldh [hFrame], a
    jr nz, .counted
    ldh a, [hFrame + 1]
    inc a
    ldh [hFrame + 1], a
.counted
    ldh a, [hPalettePending]
    and a
    call nz, LoadCgbPalettes
    ldh a, [hFrontDone]
    and a
    jp nz, .done

    ld [wSavedSP], sp
    ldh a, [hHalf]
    and a
    jp nz, .halfB
    inc a
    ldh [hHalf], a
    ldh a, [hFront]
    ld h, a
    ld l, 0
    ld sp, hl
    COPY_HALF_A
    jp .restoreSP
.halfB
    xor a
    ldh [hHalf], a
    inc a
    ldh [hFrontDone], a
    ldh a, [hFront]
    ld h, a
    ld l, LOGO_HALF_A
    ld sp, hl
    COPY_HALF_B
.restoreSP
    ld hl, wSavedSP
    ld a, [hli]
    ld h, [hl]
    ld l, a
    ld sp, hl
.done
    pop hl
    pop de
    pop bc
    pop af
    reti

; Load the Game Boy Color palettes at hPalettes, one per tile row.
LoadCgbPalettes:
    xor a
    ldh [hPalettePending], a
    ld a, $80 ; palette 0, color 0, auto-increment
    ldh [rBCPS], a
    ldh a, [hPalettes]
    ld l, a
    ldh a, [hPalettes + 1]
    ld h, a
    ld b, LOGO_TH * 8
.loop
    ld a, [hli]
    ldh [rBCPD], a
    dec b
    jr nz, .loop
    ret

SECTION "Color table", WRAM0, ALIGN[8]
wColorTable: ds 256

; Two framebuffers: the front one being copied to VRAM, and the back one
; being rendered
SECTION "Framebuffer A", WRAM0, ALIGN[8]
wFrameA: ds LOGO_FRAME_SIZE

SECTION "Framebuffer B", WRAM0, ALIGN[8]
wFrameB: ds LOGO_FRAME_SIZE

SECTION "Variables", WRAM0
wSavedSP: ds 2

SECTION "HRAM", HRAM
hIsCgb:          ds 1
hFrame:          ds 2 ; counted by the VBlank handler
hFront:          ds 1 ; high byte of the framebuffer being copied to VRAM
hBack:           ds 1 ; high byte of the framebuffer being rendered
hHalf:           ds 1 ; which half of the front framebuffer to copy next
hFrontDone:      ds 1 ; nonzero once the front framebuffer is all copied
hPalettePending: ds 1 ; nonzero to load hPalettes in the next VBlank
hPalettes:       ds 2 ; Game Boy Color palettes to load
hStartFrame:     ds 2 ; hFrame when the effect started
hTick:           ds 2 ; the effect's tick being rendered
hDest:           ds 2 ; Render's position in the framebuffer
hMasks:          ds 2 ; Render's position in LogoMasks
hGroupsLeft:     ds 1

; The current effect's descriptor, as tools/effects.py writes it
hEffect:
hStarts:         ds 2 ; start tick of each cell, per group, 8-aligned
hRampHi:         ds 1 ; the ramp's page (it is 256-aligned)
hRampLen:        ds 1
hPre:            ds 1 ; color index before a cell's start tick
hPost:           ds 1 ; color index after its ramp
hDuration:       ds 2 ; ticks until every cell has finished its ramp
hBgp:            ds 1 ; Game Boy palette
hEffectPalettes: ds 2 ; Game Boy Color palettes
hEffectEnd:

INCLUDE "effects.inc"
