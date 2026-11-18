# P2: benchmark 68000 x DMA para a co-simulação fx68k (build SIM; usa o crt0/link da ROM de diagnóstico)
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
CFLAGS  := -m68000 -O2 -ffreestanding -fno-pic -fno-builtin -nostdlib -Wall -Wextra -fomit-frame-pointer -DSIM
LDFLAGS := -m68000 -nostdlib -static -T ../diag/link.ld -Wl,--build-id=none -Wl,-z,noexecstack
all: bench_sim.hex
bench_sim.elf: bench.c ../diag/crt0_md.s ../diag/link.ld ../vdpx.h
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ ../diag/crt0_md.s bench.c
bench_sim.bin: bench_sim.elf
	$(OBJCOPY) -O binary $< $@
bench_sim.hex: bench_sim.bin
	python3 ../../scripts/bin2hex16.py $< $@
clean:
	rm -f *.elf *.bin *.hex
