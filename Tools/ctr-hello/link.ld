/* Code at 0x00100000 like every .3dsx; rodata and data on their own pages. */
ENTRY(_start)
SECTIONS {
    . = 0x00100000;
    .text : { *(.text.start) *(.text .text.*) }
    . = ALIGN(0x1000);
    .rodata : { *(.rodata .rodata.*) }
    . = ALIGN(0x1000);
    .data : { *(.data .data.*) }
    .bss : { *(.bss .bss.* COMMON) }
    /DISCARD/ : { *(.ARM.exidx*) *(.comment) }
}
