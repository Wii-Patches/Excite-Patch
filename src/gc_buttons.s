# hook: read_kpad_button, the merge point every extension type reaches --
# `lwz r0,0(r3)` (r3 = the channel's KPAD struct, r7 = the previous buttons).
#
# The SI hardware polls the pads and mirrors the answer into SICnINBUFH
# (0xCD006404 + 12*chan): [31] error, [23] always 1 on a real pad response,
# [29:16] the PAD button word (A 0x100 B 0x200 X 0x400 Y 0x800 Start 0x1000
# L 0x40 R 0x20 Z 0x10 Up 8 Down 4 Right 2 Left 1), then the two stick bytes.
#
# This hook runs once per channel per frame, so it also keeps the port's
# auto-polling alive.  The game's PADInit switches polling on at boot, but it
# never calls PADRead, and nothing guarantees the poll stays latched on a real
# Wii; Dolphin refreshes the result registers whether or not the port is
# polled, so it never showed the difference.  For a port the SDK knows holds a
# standard pad (si's cached type), every frame:
#   - write the poll command into SICnOUTBUF,
#   - write SISR with WR (bit 31, latches OUTBUF) plus this port's error
#     nibble (write-1-to-clear), as SIEnablePolling does,
#   - set the port's enable bit in SIPOLL and in si's shadow copy of it (the
#     VI retrace rewrites SIPOLL from that shadow).
#
# Then map the pad's buttons onto the Wii Remote bits the game expects with
# the remote held sideways (the same mapping the Classic Controller patch
# uses) and OR them in before the edge detection runs.
    lwz     0, 0(3)                     # displaced instruction
    lis     4, KBASE@ha
    addi    4, 4, KBASE@l               # KPAD channel 0 struct
    subf    4, 4, 3
    srwi    5, 4, 10                    # channel = offset / 0x400
    cmplwi  5, 3
    bgt     9f
    lis     6, SIBASE@ha
    addi    6, 6, SIBASE@l              # si state: +4 SIPOLL shadow, +0x18 cached types
    slwi    8, 5, 2
    add     8, 8, 6
    lwz     8, 0x18(8)                  # cached device type of this port
    andi.   9, 8, 0x80
    bne     9f                          # probe still pending
    rlwinm  9, 8, 0, 3, 4
    lis     10, 0x0800
    cmpw    9, 10
    bne     9f                          # not a standard GameCube pad
    lis     9, 0xCD00
    mulli   10, 5, 12
    add     10, 9, 10                   # this port's SI register block
    lis     11, 0x0040
    ori     11, 11, 0x0300
    stw     11, 0x6400(10)              # SICnOUTBUF = poll, analog mode 3
    slwi    11, 5, 3
    lis     4, 0x0F00
    srw     4, 4, 11                    # this port's error nibble in SISR
    lwz     8, 0x6438(9)
    and     8, 8, 4
    oris    8, 8, 0x8000                # WR
    stw     8, 0x6438(9)
    li      4, 0x80
    srw     4, 4, 5                     # SIPOLL enable bit of this port
    lwz     8, 0x6430(9)
    and.    11, 8, 4
    bne     1f
    or      8, 8, 4
    andi.   11, 8, 0xFF00
    bne     2f
    ori     8, 8, 0x0100                # Y = 1 poll per frame if unset
2:  stw     8, 0x6430(9)
1:  lwz     8, 4(6)
    or      8, 8, 4
    stw     8, 4(6)                     # keep si's SIPOLL shadow in step
    lwz     8, 0x6404(10)               # INBUFH
    cmpwi   8, 0
    blt     9f                          # error / no answer
    andis.  9, 8, 0x0080
    beq     9f                          # not a pad response
    andi.   9, 8, 0xFCFC
    beq     9f                          # stick bytes zero: not a live pad answer
    srwi    9, 8, 16                    # PAD buttons
    andi.   10, 9, 0x0300               # A -> 2, B -> 1
    rlwinm  11, 9, 1, 20, 20            # X -> A
    or      10, 10, 11
    rlwinm  11, 9, 31, 21, 21           # Y -> B
    or      10, 10, 11
    rlwinm  11, 9, 24, 27, 27           # Start -> +
    or      10, 10, 11
    rlwinm  11, 9, 29, 28, 28           # L -> left   (turbo)
    or      10, 10, 11
    rlwinm  11, 9, 29, 29, 29           # R -> right  (turbo)
    or      10, 10, 11
    rlwinm  11, 9, 30, 30, 30           # D-Up    -> bit 2 (sideways: up)
    or      10, 10, 11
    rlwinm  11, 9, 30, 31, 31           # D-Down  -> bit 1
    or      10, 10, 11
    rlwinm  11, 9, 3, 28, 28            # D-Left  -> bit 8
    or      10, 10, 11
    rlwinm  11, 9, 1, 29, 29            # D-Right -> bit 4
    or      10, 10, 11
    rlwinm  11, 9, 11, 16, 16           # Z -> HOME
    or      10, 10, 11
    or      0, 0, 10
    stw     0, 0(3)
9:
