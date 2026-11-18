# MD-VDPX — simulação M1 (Fedora: dnf install verilator yosys python3-pillow)
RTL     := rtl/vdpx_top.v rtl/vdpx_timing.v rtl/vdpx_render.v rtl/vdpx_sdpram.v rtl/vdpx_apu.v rtl/vdpx_i2s.v
RTL_M2  := $(RTL) sim/m2/legacy_read_adapter.v
SIM     := sim/tb_main.cpp
BUILD   := build
OUT     := out
SCENES  := $(wildcard scenes/*.scn)
TB      := $(BUILD)/Vvdpx_sim

.PHONY: all lint sim scenes test png synth clean m2 fx68k rom diagrom m2wo m2wo1 all_tests

all: test

$(TB): $(RTL) $(SIM) sim/refmodel.h sim/apumodel.h sim/audio_tb.h sim/vdpx_sim.v sim/vdpx_sim_smem.v
	verilator --cc --exe --build -O3 -Wall -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-PINCONNECTEMPTY \
	  --top-module vdpx_sim -Mdir $(BUILD) -CFLAGS "-O2 -std=c++17" \
	  -o Vvdpx_sim $(RTL) sim/vdpx_sim.v sim/vdpx_sim_smem.v $(SIM)

lint:
	verilator --lint-only -Wall -Wno-UNUSEDSIGNAL --top-module vdpx_top $(RTL)

scenes:
	cd scripts && python3 gen_scenes.py ../scenes && python3 gen_audio.py ../scenes

sim: $(TB)

test: $(TB)
	@test -n "$(SCENES)" || $(MAKE) scenes
	@mkdir -p $(OUT)
	@fail=0; for s in scenes/*.scn; do ./$(TB) $$s $(OUT) || fail=1; done; \
	 if [ $$fail = 0 ]; then echo "== TODOS OS TESTES OK =="; else echo "== FALHAS =="; exit 1; fi

png:
	python3 scripts/ppm2png.py $(OUT)

# estimativa de recursos (Yosys, família Gowin GW2A).
# Obs.: no Yosys 0.33 "synth_gowin -json" desliga a inferência de BSRAM; por isso write_json separado.
synth:
	@mkdir -p $(BUILD)
	yosys -q -p "read_verilog $(RTL); synth_gowin -top vdpx_top; write_json $(BUILD)/vdpx.json; tee -o $(BUILD)/synth_stat.txt stat"
	@cat $(BUILD)/synth_stat.txt | tail -40

# ------------------------------------------------------------ M2: co-simulação 68000
# fx68k (GPL-3, Jorge Cwik) é baixado para ext/fx68k; não faz parte deste repositório.
FX68K_DIR ?= ext/fx68k
FX68K_SRC := $(FX68K_DIR)/fx68k.sv $(FX68K_DIR)/fx68kAlu.sv $(FX68K_DIR)/uaddrPla.sv
M2_VERILATOR_FLAGS ?=
BUILD_M2  := build_m2
TB_M2     := $(BUILD_M2)/Vmd_sim_top

fx68k: $(FX68K_DIR)/fx68k.sv
$(FX68K_DIR)/fx68k.sv:
	mkdir -p ext && git clone --depth 1 https://github.com/ijor/fx68k.git $(FX68K_DIR)

rom:
	$(MAKE) -C m68k

$(TB_M2): $(RTL_M2) sim/vdpx_sim_smem.v sim/audio_tb.h sim/apumodel.h sim/m2/md_sim_top.sv sim/m2/tb_m2.cpp sim/refmodel.h $(FX68K_DIR)/fx68k.sv
	verilator $(M2_VERILATOR_FLAGS) --cc --exe --build -O3 -Wno-fatal -Wno-lint -Wno-style -Wno-BLKANDNBLK \
	  --top-module md_sim_top -Mdir $(BUILD_M2) -CFLAGS "-O2 -std=c++17" \
	  -o Vmd_sim_top $(RTL_M2) sim/vdpx_sim_smem.v sim/m2/md_sim_top.sv $(FX68K_SRC) sim/m2/tb_m2.cpp

m2: rom $(TB_M2)
	@mkdir -p $(OUT)
	cp $(FX68K_DIR)/microrom.mem $(FX68K_DIR)/nanorom.mem m68k/rom.hex $(BUILD_M2)/
	cd $(BUILD_M2) && ./Vmd_sim_top ../$(OUT)

# ------------------------------------------------------------ M4.2: fx68k + adaptador SOMENTE ESCRITA real
# m2wo  = PREFETCH 0 (o que vai para a Tang); m2wo1 = PREFETCH 1 (comparação)
TB_M2WO_SRC := $(RTL) rtl/md_fdc_adapter.v sim/m2/legacy_read_adapter.v sim/vdpx_sim_smem.v sim/m2/md_sim_top.sv $(FX68K_SRC)
build_m2wo%/Vmd_sim_top: $(TB_M2WO_SRC) sim/m2/tb_m2wo.cpp sim/audio_tb.h sim/apumodel.h sim/refmodel.h
	verilator $(M2_VERILATOR_FLAGS) --cc --exe --build -O3 -Wno-fatal -Wno-lint -Wno-style -Wno-BLKANDNBLK \
	  --top-module md_sim_top -Mdir build_m2wo$* -DM2WO -DM2_PREFETCH=$* -CFLAGS "-O2 -std=c++17 -DM2_PREFETCH_VAL=$*" \
	  -o Vmd_sim_top $(TB_M2WO_SRC) sim/m2/tb_m2wo.cpp
diagrom:
	$(MAKE) -C m68k/diag all sim
m2wo: diagrom build_m2wo0/Vmd_sim_top
	@mkdir -p $(OUT)
	cp $(FX68K_DIR)/microrom.mem $(FX68K_DIR)/nanorom.mem build_m2wo0/
	cp m68k/diag/diag_sim.hex build_m2wo0/rom.hex
	cd build_m2wo0 && ./Vmd_sim_top ../$(OUT)
m2wo1: diagrom build_m2wo1/Vmd_sim_top
	@mkdir -p $(OUT)
	cp $(FX68K_DIR)/microrom.mem $(FX68K_DIR)/nanorom.mem build_m2wo1/
	cp m68k/diag/diag_sim.hex build_m2wo1/rom.hex
	cd build_m2wo1 && ./Vmd_sim_top ../$(OUT)

clean:
	rm -rf $(BUILD) $(BUILD_M2) build_m2wo0 build_m2wo1 $(OUT)
	$(MAKE) -C m68k/diag clean
	$(MAKE) -C m68k clean

# ------------------------------------------------------------ M4: simulação da placa (HDMI + SDRAM + autoteste)
BUILD_M4 := build_m4
RTL_M4   := $(RTL) rtl/md_fdc_adapter.v rtl/hdmi/tmds_enc.v rtl/hdmi/hdmi_tx.v \
            rtl/board/async_fifo.v rtl/board/sdram_ctrl.v rtl/board/vdpx_selftest.v rtl/board/vdpx_board.v \
            rtl/board/cn2_probe.v rtl/board/vdpx_overlay.v

rtl/board/vdpx_overlay.v: scripts/gen_overlay.py scripts/font5x7.py
	cd scripts && python3 gen_overlay.py ../rtl/board/vdpx_overlay.v

rtl/board/selftest.hex: scripts/gen_selftest.py scripts/vdpx.py scripts/gen_scenes.py
	cd scripts && python3 gen_selftest.py ../rtl/board/selftest.hex

$(BUILD_M4)/Vboard_sim: $(RTL_M4) sim/m4/board_sim.v sim/m4/sdram_model.v sim/m4/tb_m4.cpp sim/m4/hdmi_dec.h sim/refmodel.h sim/apumodel.h sim/audio_tb.h
	verilator --cc --exe --build -O3 -Wno-fatal -Wno-lint -Wno-style --top-module board_sim \
	  -Mdir $(BUILD_M4) -CFLAGS "-O2 -std=c++17" -o Vboard_sim \
	  $(RTL_M4) sim/m4/board_sim.v sim/m4/sdram_model.v sim/m4/tb_m4.cpp

m4sim: rtl/board/selftest.hex $(BUILD_M4)/Vboard_sim
	@mkdir -p $(OUT)
	cp rtl/board/selftest.hex $(BUILD_M4)/
	cd $(BUILD_M4) && ./Vboard_sim ../$(OUT) 40

# ------------------------------------------------------------ M4: Tang Nano 20K (fluxo aberto)
# Requer Yosys recente (>= 0.40), nextpnr-himbaechel (gowin) e apycula (gowin_pack).
YOSYS   ?= yosys
NEXTPNR ?= nextpnr-himbaechel
GWPACK  ?= gowin_pack
TANG_RTL := $(RTL_M4) rtl/board/tang_top.v

tang: rtl/board/selftest.hex
	@mkdir -p build_tang
	cp rtl/board/selftest.hex build_tang/
	cd build_tang && $(YOSYS) -q -l synth.log -p "read_verilog -D SYNTHESIS $(addprefix ../,$(TANG_RTL)); \
	  synth_gowin -family gw2a -top tang_top -json tang.json; tee -q -o synth_stat.txt stat"
	cd build_tang && $(NEXTPNR) --json tang.json --write pnr.json --device GW2AR-LV18QN88C8/I7 \
	  --vopt family=GW2A-18C --vopt cst=../board/tang_nano_20k.cst --freq 50.4 -l pnr.log
	cd build_tang && $(GWPACK) -d GW2A-18C -o md_vdpx.fs pnr.json
	@grep -E "Max frequency" build_tang/pnr.log | tail -4

# regressão completa
all_tests: m42test test m2 m2wo m4sim

.PHONY: m42test
m42test:
	@mkdir -p build_m42
	iverilog -g2012 -s tb_adapter -o build_m42/adapter rtl/md_fdc_adapter.v sim/m42/tb_adapter.sv
	vvp build_m42/adapter
	iverilog -g2012 -s tb_lvc245 -o build_m42/lvc245 sim/m42/lvc245.sv sim/m42/tb_lvc245.sv
	vvp build_m42/lvc245
	python3 scripts/m42_audit.py
