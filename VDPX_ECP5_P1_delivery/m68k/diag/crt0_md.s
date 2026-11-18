| MD-VDPX diag M4.2: vetores, header de cartucho, TMSS, .data/.bss, main
    .section .vectors, "a"
    .long   0x00FFFE00          | SSP
    .long   _start              | PC inicial
    .rept   62
    .long   _halt
    .endr
| ---- header ($100-$1FF)
    .ascii  "SEGA MEGA DRIVE "
    .ascii  "(C)VDPX 2026.NOV"
    .ascii  "MD-VDPX DIAG M4.2 (SOMENTE ESCRITA NA CN2)      "
    .ascii  "MD-VDPX DIAG M4.2 (WRITE-ONLY CN2 TEST)         "
    .ascii  "GM 00000000-00"
    .word   0x0000              | checksum (preenchido por fixsum.py)
    .ascii  "J               "
    .long   0x00000000
    .long   _rom_end - 1
    .long   0x00FF0000
    .long   0x00FFFFFF
    .ascii  "            "
    .ascii  "            "
    .ascii  "                                        "
    .ascii  "JUE             "

    .text
    .globl  _start
_start:
    move.w  #0x2700, %sr
    | TMSS: consoles com versão != 0 exigem "SEGA" em $A14000 antes de usar o VDP
    move.b  0xA10001, %d0
    andi.b  #0x0F, %d0
    beq.s   1f
    move.l  #0x53454741, 0xA14000
1:  lea     _data_load, %a0
    lea     _data_start, %a1
    lea     _data_end, %a2
2:  cmp.l   %a2, %a1
    bcc.s   3f
    move.w  (%a0)+, (%a1)+
    bra.s   2b
3:  lea     _bss_start, %a1
    lea     _bss_end, %a2
4:  cmp.l   %a2, %a1
    bcc.s   5f
    clr.w   (%a1)+
    bra.s   4b
5:  jsr     main
_halt:
    bra.s   _halt
