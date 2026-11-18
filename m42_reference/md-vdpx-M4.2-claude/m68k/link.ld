/* Mapa de memória da co-simulação M2 (igual ao de um cartucho de Mega Drive) */
MEMORY {
    ROM (rx)  : ORIGIN = 0x000000, LENGTH = 64K
    RAM (rwx) : ORIGIN = 0xFF0000, LENGTH = 64K
}
ENTRY(_start)
SECTIONS {
    .text : {
        KEEP(*(.vectors))
        *(.text .text.*)
        *(.rodata .rodata.*)
        . = ALIGN(2);
    } > ROM
    .data : {
        _data_start = .;
        *(.data .data.*)
        . = ALIGN(2);
        _data_end = .;
    } > RAM AT > ROM
    _data_load = LOADADDR(.data);
    .bss (NOLOAD) : {
        _bss_start = .;
        *(.bss .bss.* COMMON)
        . = ALIGN(2);
        _bss_end = .;
    } > RAM
    /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
