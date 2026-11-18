| Inicialização mínima de 68000 (vetores, .data, .bss, main)
    .section .vectors, "a"
    .long   0x01000000          | SSP (topo da RAM em $FFFFFF+1)
    .long   _start              | PC inicial
    .rept   62
    .long   _halt               | demais exceções: para
    .endr

    .text
    .globl  _start
_start:
    move.w  #0x2700, %sr
    lea     _data_load, %a0
    lea     _data_start, %a1
    lea     _data_end, %a2
1:  cmp.l   %a2, %a1
    bcc.s   2f
    move.w  (%a0)+, (%a1)+
    bra.s   1b
2:  lea     _bss_start, %a1
    lea     _bss_end, %a2
3:  cmp.l   %a2, %a1
    bcc.s   4f
    clr.w   (%a1)+
    bra.s   3b
4:  jsr     main
_halt:
    move.w  #0xDEAD, 0x600000   | sinaliza ao testbench
5:  bra.s   5b
