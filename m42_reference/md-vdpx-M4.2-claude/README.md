> **M4.2 vigente:** protótipo CN2 somente escrita. Leitura física desabilitada, pinagem VA6 e hardware BLOCKED. Ver [entrega e evidências](M4_2_delivery/RELATORIO_TECNICO.md). Os resultados M1–M4.1 abaixo são históricos, não comprovação elétrica.
>
> **M4.2 Claude:** conferência da entrega + sonda CN2 com painel no HDMI, co-simulação fx68k com o adaptador somente escrita (`make m2wo`) e ROM de diagnóstico para o console (`make diagrom`). Ver [docs/M4_2_relatorio_claude.md](docs/M4_2_relatorio_claude.md).

# MD-VDPX

VDP estendido em FPGA (Tang Nano 20K) para o Mega Drive, ligado pela porta de expansão do Mega CD.
A especificação está em `docs/M0_especificacao.md`.

## Estado: M0 a M4.1 concluídas (em simulação; bitstream gerado para a Tang Nano 20K)

- **M1/M1.5:** núcleo com timing HDMI 640×480 e clock de sistema 2× (50,4 MHz); planos A/B de tiles com scroll por plano, por linha e por coluna; 128 sprites até 64×64 (32 por linha, 512 px por linha); 256 cores RGB555 em 16 paletas; prioridades e flips. Cada frame é comparado **pixel a pixel** com um modelo de referência em C++ (`sim/refmodel.h`), escrito a partir da especificação e não do RTL.
- **M3:** APU com 8 canais PCM (memória de samples), 8 wavetable/ruído e mixer estéreo de 48 kHz. O som original do Mega Drive entra por um ADC I2S (pinos SL2/SR2 da porta no Model 2, fone de ouvido no Model 1) e é misturado. Cada amostra é comparada com um modelo bit-exato (`sim/apumodel.h`), e as cenas de áudio geram arquivos WAV em `out/`.
- **M4.1:** interface com o Mega Drive refeita a partir dos esquemas (CN2): a VDPX fica na janela /FDC ($A12000–$A120FF), sem /DTACK e sem wait states (FIFO de escrita, leitura com prefetch), com /CAS0 e FRES. O áudio do MD entra pelo fone (Model 1) ou por SL3/SR3 (Model 2).
- **M4:** placa completa para a Tang Nano 20K: HDMI com áudio (InfoFrames, ACR, Audio Sample Packets), controlador da SDRAM embutida (memória de samples), padrão de autoteste com som, PLLs e serializadores. A simulação da placa decodifica o HDMI como uma TV e compara imagem e som com os modelos. Para gravar, veja `board/LEIAME_placa.md`.
- **M2:** `sim/m2/legacy_read_adapter.v` preserva somente o modelo hipotético M4.1; não representa os sinais comprovados da VA6. Na simulação, o "console" decodifica $A12000 em /FDC, /FDWR e /CAS0 e não espera a placa (zero wait states). A co-simulação usa o **fx68k** (68000 com precisão de ciclo) rodando `m68k/main.c`, compilado com gcc para 68000. O modelo de referência é alimentado pelos **pinos do 68000**, então o teste cobre o caminho inteiro: programa → barramento → adaptador → núcleo → HDMI.

## Fedora

```sh
sudo dnf install verilator yosys python3-pillow make gcc-c++ git
# para a M2, um destes compiladores 68000:
#   marsdev (já instalado em ~/marsdev, detectado automaticamente)
#   ou: sudo dnf install gcc-m68k-linux-gnu binutils-m68k-linux-gnu

make scenes     # gera scenes/*.scn
make test       # M1/M1.5/M3: compila com Verilator, roda as 17 cenas (vídeo e áudio) e compara
make m2         # M2: baixa o fx68k, compila o programa 68000 e roda a co-simulação (adaptador legado)
make m2wo       # M4.2: fx68k + adaptador SOMENTE ESCRITA real + ROM de diagnóstico (SIM)
make diagrom    # M4.2: m68k/diag/diag_md.bin para o Mega Drive real
make all_tests  # regressão completa
make png        # out/*.ppm -> out/*.png
make synth      # estimativa de recursos Gowin (Yosys)
make m4sim      # M4: placa inteira (autoteste -> SDRAM/APU -> HDMI decodificado)
make tang       # M4: bitstream com Yosys + nextpnr-himbaechel + gowin_pack
# ou, com o Gowin EDA:  cd board && gw_sh gowin_build.tcl
```

O fx68k (GPL-3, de Jorge Cwik) é baixado em `ext/fx68k` pelo `make m2` e não faz parte deste projeto.

## Estrutura

```
rtl/        vdpx_top.v, vdpx_render.v, vdpx_timing.v, vdpx_sdpram.v, vdpx_apu.v, vdpx_i2s.v, md_fdc_adapter.v
sim/        tb_main.cpp (BFM + captura HDMI), refmodel.h (vídeo), apumodel.h (áudio), audio_tb.h (ADC/DAC I2S, WAV),
            vdpx_sim.v + vdpx_sim_smem.v (memória de samples simulada)
sim/m2/     md_sim_top.sv ("Mega Drive" mínimo: fx68k + ROM + RAM + VDPX), tb_m2.cpp
m68k/       main.c, vdpx.h (API C da VDPX), crt0.s, link.ld, Makefile
scripts/    vdpx.py (API de cena), gen_scenes.py, gen_audio.py, gen_m2_assets.py, ppm2png.py, bin2hex16.py
rtl/hdmi/   tmds_enc.v, hdmi_tx.v
rtl/board/  vdpx_board.v, tang_top.v, sdram_ctrl.v, vdpx_selftest.v, async_fifo.v, selftest.hex
sim/m4/     board_sim.v, sdram_model.v, hdmi_dec.h (modelo de TV), tb_m4.cpp
board/      tang_nano_20k.cst/.sdc, gowin_build.tcl, LEIAME_placa.md
docs/       M0_especificacao.md, img/
```

## Próximo

- **M5:** placa adaptadora (SN74LVC245A em direção fixa, ADC pendente de clock validado) e testes com o Mega Drive real.
