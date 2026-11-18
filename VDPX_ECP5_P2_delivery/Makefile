# MD-VDPX — simulação M1 (Fedora: dnf install verilator yosys python3-pillow)
RTL     := rtl/vdpx_top.v rtl/vdpx_timing.v rtl/vdpx_render.v rtl/vdpx_sdpram.v rtl/vdpx_apu.v rtl/vdpx_i2s.v rtl/vdpx_dma.v
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
	cd scripts && python3 gen_scenes.py ../scenes && python3 gen_audio.py ../scenes && python3 gen_dma_scenes.py ../scenes

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
rtl/board/selftest_dma.hex: scripts/gen_selftest.py scripts/vdpx.py scripts/gen_scenes.py
	cd scripts && python3 gen_selftest.py ../rtl/board/selftest_dma.hex --dma

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

# ======================================================================================
# ECP5-P1: Colorlight i9 v7.2 (LFE5U-45F-6BG381C) + Ext-Board HDMI
# ======================================================================================
# Ferramentas: yosys / nextpnr-ecp5 / ecppack do PATH, ou os pacotes YoWASP
#   (pip install yowasp-yosys yowasp-nextpnr-ecp5), selecionados com YOWASP=1.
ifeq ($(YOWASP),1)
ECP5_YOSYS   ?= yowasp-yosys
ECP5_NEXTPNR ?= yowasp-nextpnr-ecp5
ECP5_PACK    ?= yowasp-ecppack
else
ECP5_YOSYS   ?= yosys
ECP5_NEXTPNR ?= nextpnr-ecp5
ECP5_PACK    ?= ecppack
endif
ECP5_SEEDS   ?= 1 2 3
ECP5_SEED_BIT ?= 1
ECP5_LPF     := board/colorlight_i9_v72_extboard.lpf
RTL_ECP5_CORE := $(RTL_M4) rtl/ecp5/ecp5_tmds_ser.v rtl/ecp5/vdpx_ecp5_core.v
ECP5_RTL     := $(RTL_ECP5_CORE) rtl/ecp5/colorlight_i9_top.v
BUILD_E5     := build_ecp5
BUILD_E5S    := build_ecp5_sim

# ---- simulação 50 MHz do núcleo: as 17 cenas (pixel a pixel + áudio bit a bit), I2S de
#      3125/3 ciclos, memória de samples = controlador SDRAM RMW + modelo sem DQM (como na i9).
#      O lint -Wall do RTL fica no alvo 'lint'; aqui os avisos do modelo de SDRAM não são fatais.
BUILD50 := build50
$(BUILD50)/Vvdpx_sim: $(RTL) $(SIM) sim/refmodel.h sim/apumodel.h sim/audio_tb.h sim/ecp5/vdpx_sim_sdram.v rtl/board/sdram_ctrl.v sim/m4/sdram_model.v
	verilator --cc --exe --build -O3 -Wno-fatal -Wno-lint -Wno-style -DVDPX_CLK50 \
	  --top-module vdpx_sim -Mdir $(BUILD50) -CFLAGS "-O2 -std=c++17 -DCLK_MHZ_TB=50.0" \
	  -o Vvdpx_sim $(RTL) rtl/board/sdram_ctrl.v sim/ecp5/vdpx_sim_sdram.v sim/m4/sdram_model.v $(SIM)
test50: $(BUILD50)/Vvdpx_sim
	@test -n "$(SCENES)" || $(MAKE) scenes
	@mkdir -p $(OUT)/clk50
	@fail=0; for s in scenes/*.scn; do ./$(BUILD50)/Vvdpx_sim $$s $(OUT)/clk50 || fail=1; done; \
	 if [ $$fail = 0 ]; then echo "== TODOS OS TESTES OK (50 MHz) =="; else echo "== FALHAS (50 MHz) =="; exit 1; fi

# ---- placa ECP5 inteira (TMDS serial decodificado, SDRAM sem DQM, autoteste, CN2, lock)
$(BUILD_E5S)/Vecp5_board_sim: $(RTL_ECP5_CORE) sim/ecp5/ecp5_prims_sim.v sim/ecp5/ecp5_board_sim.v sim/m4/sdram_model.v \
                                 sim/ecp5/tb_ecp5.cpp sim/ecp5/tmds_deser.h sim/m4/hdmi_dec.h sim/refmodel.h sim/apumodel.h sim/audio_tb.h
	verilator --cc --exe --build -O3 -Wno-fatal -Wno-lint -Wno-style --top-module ecp5_board_sim \
	  -Mdir $(BUILD_E5S) -CFLAGS "-O2 -std=c++17" -o Vecp5_board_sim \
	  $(RTL_ECP5_CORE) sim/ecp5/ecp5_prims_sim.v sim/ecp5/ecp5_board_sim.v sim/m4/sdram_model.v sim/ecp5/tb_ecp5.cpp
ecp5_boardsim: rtl/board/selftest_dma.hex $(BUILD_E5S)/Vecp5_board_sim
	@mkdir -p $(OUT)
	cp rtl/board/selftest_dma.hex $(BUILD_E5S)/
	cd $(BUILD_E5S) && ./Vecp5_board_sim ../$(OUT) 40
	cd $(BUILD_E5S) && M42_SELFTEST_ONLY=1 ECP5_INIT_GLITCH=1 ./Vecp5_board_sim ../$(OUT) 12
	cd $(BUILD_E5S) && ECP5_LOCKLOSS=1 ./Vecp5_board_sim ../$(OUT) 16

# ---- testes unitários ECP5: SDRAM RMW sem DQM (Icarus) + HDMI/TMDS serial (Verilator)
BUILD_E5U := build_ecp5_unit
$(BUILD_E5U)/Vhdmi_unit_top: rtl/hdmi/tmds_enc.v rtl/hdmi/hdmi_tx.v rtl/ecp5/ecp5_tmds_ser.v sim/ecp5/ecp5_prims_sim.v \
                             sim/ecp5/hdmi_unit_top.v sim/ecp5/tb_hdmi_unit.cpp sim/ecp5/tmds_deser.h sim/m4/hdmi_dec.h
	verilator --cc --exe --build -O3 -Wno-fatal -Wno-lint -Wno-style --top-module hdmi_unit_top \
	  -Mdir $(BUILD_E5U) -CFLAGS "-O2 -std=c++17" -o Vhdmi_unit_top \
	  rtl/hdmi/tmds_enc.v rtl/hdmi/hdmi_tx.v rtl/ecp5/ecp5_tmds_ser.v sim/ecp5/ecp5_prims_sim.v sim/ecp5/hdmi_unit_top.v sim/ecp5/tb_hdmi_unit.cpp
ecp5_unit: $(BUILD_E5U)/Vhdmi_unit_top
	@mkdir -p $(BUILD_E5U) $(OUT)
	iverilog -g2012 -s tb_sdram_rmw -o $(BUILD_E5U)/sdram rtl/board/sdram_ctrl.v sim/m4/sdram_model.v sim/ecp5/tb_sdram_rmw.sv
	vvp -n $(BUILD_E5U)/sdram
	@echo "== testes negativos (devem FALHAR): esquema M4.2 na i9 e controlador sem RMW =="
	iverilog -g2012 -s tb_sdram_rmw -Ptb_sdram_rmw.PHASE_NS=10.0 -Ptb_sdram_rmw.RDCAP=2 -o $(BUILD_E5U)/sdram_neg_m42 \
	  rtl/board/sdram_ctrl.v sim/m4/sdram_model.v sim/ecp5/tb_sdram_rmw.sv
	python3 scripts/expect_fail.py "clock invertido + captura R2 (M4.2) com atrasos de placa" vvp -n $(BUILD_E5U)/sdram_neg_m42
	iverilog -g2012 -s tb_sdram_rmw -Ptb_sdram_rmw.RMW_UNDER_TEST=0 -o $(BUILD_E5U)/sdram_neg_normw \
	  rtl/board/sdram_ctrl.v sim/m4/sdram_model.v sim/ecp5/tb_sdram_rmw.sv
	python3 scripts/expect_fail.py "controlador M4.2 (DQM) sem RMW numa placa sem DQM" vvp -n $(BUILD_E5U)/sdram_neg_normw
	cd $(OUT) && ../$(BUILD_E5U)/Vhdmi_unit_top 20
	python3 scripts/ecp5_audit.py

# ---- lint do RTL ECP5 (Verilator -Wall, sem modelos de simulação)
ecp5_lint:
	verilator --lint-only -Wall -Wno-fatal -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-PINCONNECTEMPTY -Wno-DECLFILENAME \
	  --top-module vdpx_ecp5_core $(RTL_ECP5_CORE) sim/ecp5/ecp5_prims_sim.v

# ---- regressão ECP5 completa (simulação)
ecp5_test: ecp5_unit test50 m2wo50 ecp5_boardsim p2_test

# ---- síntese / P&R / bitstream / relatório (LFE5U-45F-6BG381C)
ECP5_YOSYS_SCRIPT = read_verilog -D SYNTHESIS $(addprefix ../,$(ECP5_RTL)); \
  synth_ecp5 -top colorlight_i9_top -json vdpx_ecp5_p2.json; tee -q -o synth_stat.txt stat
ecp5_synth: rtl/board/selftest_dma.hex
	@mkdir -p $(BUILD_E5)
	cp rtl/board/selftest_dma.hex $(BUILD_E5)/
	cd $(BUILD_E5) && $(ECP5_YOSYS) -l synth.log -q -p "$(ECP5_YOSYS_SCRIPT)"
	@grep -E "LUT4|TRELLIS_FF|DP16KD|MULT18|EHXPLLL|CCU2C|TRELLIS_DPR16X4|ODDRX1F" $(BUILD_E5)/synth_stat.txt | tail -12
ecp5_pnr:
	@cd $(BUILD_E5) && fail=0; for s in $(ECP5_SEEDS); do \
	  $(ECP5_NEXTPNR) --45k --package CABGA381 --speed 6 --json vdpx_ecp5_p2.json --lpf ../$(ECP5_LPF) \
	    --textcfg vdpx_ecp5_p2_s$$s.config --report report_s$$s.json --detailed-timing-report \
	    --seed $$s -l pnr_s$$s.log > /dev/null 2>&1; rc=$$?; echo "seed $$s: exit $$rc" | tee -a pnr_exit.txt; \
	  grep "Max frequency" pnr_s$$s.log | tail -3; [ $$rc = 0 ] || fail=1; done; exit $$fail
ecp5_bitstream:
	@mkdir -p artifacts
	cd $(BUILD_E5) && $(ECP5_PACK) --input vdpx_ecp5_p2_s$(ECP5_SEED_BIT).config --bit vdpx_ecp5_p2.bit
	cp $(BUILD_E5)/vdpx_ecp5_p2.bit artifacts/vdpx_ecp5_p2.bit
	sha256sum artifacts/vdpx_ecp5_p2.bit
ecp5_report:
	python3 scripts/ecp5_report.py $(BUILD_E5) "$(ECP5_SEEDS)" $(ECP5_SEED_BIT)
ecp5: ecp5_synth ecp5_pnr ecp5_bitstream ecp5_report

# ---- M2WO a 50 MHz (fx68k + adaptador somente escrita real, plano de clock do ECP5)
build_m2wo50/Vmd_sim_top: $(TB_M2WO_SRC) sim/m2/tb_m2wo.cpp sim/audio_tb.h sim/apumodel.h sim/refmodel.h
	verilator $(M2_VERILATOR_FLAGS) --cc --exe --build -O3 -Wno-fatal -Wno-lint -Wno-style -Wno-BLKANDNBLK \
	  --top-module md_sim_top -Mdir build_m2wo50 -DM2WO -DM2_PREFETCH=0 -DVDPX_CLK50 \
	  -CFLAGS "-O2 -std=c++17 -DM2_PREFETCH_VAL=0 -DCLK_MHZ=50.0" \
	  -o Vmd_sim_top $(TB_M2WO_SRC) sim/m2/tb_m2wo.cpp
m2wo50: diagrom build_m2wo50/Vmd_sim_top
	@mkdir -p $(OUT)/clk50
	cp $(FX68K_DIR)/microrom.mem $(FX68K_DIR)/nanorom.mem build_m2wo50/
	cp m68k/diag/diag_sim.hex build_m2wo50/rom.hex
	cd build_m2wo50 && ./Vmd_sim_top ../$(OUT)/clk50

# ---- P2: benchmark 68000 x DMA (fx68k, adaptador somente escrita, 50 MHz)
m2bench: build_m2wo50/Vmd_sim_top
	$(MAKE) -C m68k/bench
	@mkdir -p $(OUT)/clk50
	cp $(FX68K_DIR)/microrom.mem $(FX68K_DIR)/nanorom.mem build_m2wo50/
	cp m68k/bench/bench_sim.hex build_m2wo50/rom.hex
	cd build_m2wo50 && M2_BENCH=1 ./Vmd_sim_top ../$(OUT)/clk50
	cp m68k/diag/diag_sim.hex build_m2wo50/rom.hex

# ======================================================================================
# ECP5-P2: DMA / blitter
# ======================================================================================
BUILD_P2 := build_p2
# teste unitário do motor (Icarus): dirigido + 4000 comandos aleatórios, semente fixa
dma_unit:
	@mkdir -p $(BUILD_P2)
	iverilog -g2012 -s tb_dma_unit -o $(BUILD_P2)/dma_unit rtl/vdpx_dma.v sim/p2/tb_dma_unit.sv
	vvp -n $(BUILD_P2)/dma_unit
	@echo "== mutações (devem FALHAR): PATTERN sempre VALUE0; fonte do par avança 1; sem checagem de fim da VRAM =="
	sed "s/((c_op == 2'd3 \&\& c_ph) ? c_v1 : c_v0)/c_v0/" rtl/vdpx_dma.v > $(BUILD_P2)/mut1.v
	iverilog -g2012 -s tb_dma_unit -Ptb_dma_unit.NRAND=200 -o $(BUILD_P2)/mut1 $(BUILD_P2)/mut1.v sim/p2/tb_dma_unit.sv
	python3 scripts/expect_fail.py "DMA com PATTERN quebrado" vvp -n $(BUILD_P2)/mut1
	sed "s/c_src <= c_src + {{(SW-2){1'b0}}, sm_pair, !sm_pair};/c_src <= c_src + 1'b1;/" rtl/vdpx_dma.v > $(BUILD_P2)/mut2.v
	iverilog -g2012 -s tb_dma_unit -Ptb_dma_unit.NRAND=200 -o $(BUILD_P2)/mut2 $(BUILD_P2)/mut2.v sim/p2/tb_dma_unit.sv
	python3 scripts/expect_fail.py "DMA com avanço errado da fonte" vvp -n $(BUILD_P2)/mut2
	sed "s/else if (s_dst\[15\] || dst_end > 17'd32768)/else if (s_dst[15])/" rtl/vdpx_dma.v > $(BUILD_P2)/mut3.v
	! cmp -s rtl/vdpx_dma.v $(BUILD_P2)/mut3.v
	iverilog -g2012 -s tb_dma_unit -Ptb_dma_unit.NRAND=200 -o $(BUILD_P2)/mut3 $(BUILD_P2)/mut3.v sim/p2/tb_dma_unit.sv
	python3 scripts/expect_fail.py "DMA sem checagem de fim da VRAM (daria a volta)" vvp -n $(BUILD_P2)/mut3

# relatório de benchmark a partir dos logs (A: 68000 pela CN2; B: comando + DMA)
p2_bench_report:
	python3 scripts/p2_bench_report.py logs/p2/m2bench.log logs/ecp5_sim/test50.log logs/ecp5_sim/ecp5_boardsim.log > logs/p2/bench_tables.md

p2_test: dma_unit m2bench
