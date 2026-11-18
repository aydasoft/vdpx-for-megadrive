# Programa 68000 da M2. Usa o gcc do marsdev (m68k-elf-) se existir,
# senão m68k-linux-gnu- (Fedora: dnf install gcc-m68k-linux-gnu binutils-m68k-linux-gnu).
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
OBJDUMP := $(CROSS)objdump
CFLAGS  := -m68000 -O2 -ffreestanding -fno-pic -fno-builtin -nostdlib -Wall -Wextra \
           -fomit-frame-pointer
LDFLAGS := -m68000 -nostdlib -static -T link.ld -Wl,--build-id=none -Wl,-z,noexecstack
# sem libgcc de propósito: o libgcc do toolchain Linux é compilado para 68020+.
# Se o link falhar com __mulsi3/__divsi3, o código usou mul/div de 32 bits.

all: rom.bin rom.hex

assets.h: ../scripts/gen_m2_assets.py ../scripts/gen_scenes.py ../scripts/vdpx.py
	cd ../scripts && python3 gen_m2_assets.py ../m68k/assets.h

rom.elf: crt0.s main.c vdpx.h assets.h link.ld
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ crt0.s main.c

rom.bin: rom.elf
	$(OBJCOPY) -O binary rom.elf rom.bin

rom.hex: rom.bin
	python3 ../scripts/bin2hex16.py rom.bin rom.hex

dis: rom.elf
	$(OBJDUMP) -d rom.elf | less

clean:
	rm -f rom.elf rom.bin rom.hex
