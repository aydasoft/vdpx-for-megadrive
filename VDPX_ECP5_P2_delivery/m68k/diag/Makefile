# ROM de diagnóstico M4.2 (somente escrita na CN2).
#   make        -> diag_md.bin  (Mega Drive real: texto no VDP do console, TMSS, checksum)
#   make sim    -> diag_sim.hex (co-simulação fx68k: sem VDP, porta de depuração $600000)
MARSDEV ?= $(HOME)/marsdev
ifneq ($(wildcard $(MARSDEV)/m68k-elf/bin/m68k-elf-gcc),)
  CROSS ?= $(MARSDEV)/m68k-elf/bin/m68k-elf-
else ifneq ($(shell which m68k-elf-gcc 2>/dev/null),)
  CROSS ?= m68k-elf-
else
  CROSS ?= m68k-linux-gnu-
endif
CC      := $(CROSS)gcc
OBJCOPY := $(CROSS)objcopy
CFLAGS  := -m68000 -O2 -ffreestanding -fno-pic -fno-builtin -nostdlib -Wall -Wextra -fomit-frame-pointer
LDFLAGS := -m68000 -nostdlib -static -T link.ld -Wl,--build-id=none -Wl,-z,noexecstack
DEPS    := crt0_md.s diag.c link.ld ../vdpx.h ../assets.h font_tiles.h

all: diag_md.bin
sim: diag_sim.hex

font_tiles.h: gen_font_tiles.py ../../scripts/font5x7.py
	python3 gen_font_tiles.py $@

diag_md.elf: $(DEPS)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ crt0_md.s diag.c
diag_md.bin: diag_md.elf
	$(OBJCOPY) -O binary $< $@
	python3 fixsum.py $@

diag_sim.elf: $(DEPS)
	$(CC) $(CFLAGS) -DSIM $(LDFLAGS) -o $@ crt0_md.s diag.c
diag_sim.bin: diag_sim.elf
	$(OBJCOPY) -O binary $< $@
diag_sim.hex: diag_sim.bin
	python3 ../../scripts/bin2hex16.py $< $@

clean:
	rm -f *.elf *.bin *.hex font_tiles.h
