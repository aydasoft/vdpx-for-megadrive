# CHANGELOG: ECP5-P2 (DMA/Blitter)

Base: entrega ECP5-P1 (`VDPX_ECP5_P1_delivery/`, preservada sem alterações neste repositório). O histórico da P1
está em `docs/p1/CHANGELOG.md`.

## RTL

- **Novo `rtl/vdpx_dma.v`**:
  - motor FILL, COPY (memória de samples → VRAM), PATTERN e CANCEL;
  - registradores de preparação com commit atômico e validação completa (códigos de erro 1–6);
  - fila de 4 comandos com REJECT quando cheia; bit VSYNC;
  - estatísticas e taxa por divisor sequencial + BCD.
- **`rtl/vdpx_top.v`**:
  - target 6 = DMA (índices 0..7; 8..15 são leituras de diagnóstico, só em simulação);
  - porta de escrita da VRAM compartilhada (CPU > DMA, combinacional);
  - árbitro não-preemptivo da memória de samples (porta da APU > DMA);
  - saídas `sm_pair`/`sm_rdata_hi` (leitura de 32 bits) e taps de depuração `dbg_vw_*`, `dma_status`, `dma_events`.
- **`rtl/board/sdram_ctrl.v`**: saída `rdata_hi` (a outra metade da word de 32 bits já lida). O caminho de
  leitura/escrita da P1 não mudou.
- **`rtl/board/vdpx_board.v`**: parâmetro `ST_ROM_AW`; duas linhas de DMA no painel; taps.
- **`rtl/board/vdpx_overlay.v`** (gerado): 11 linhas a partir da linha de texto 19, índices de slot de 8 bits,
  campos enumerados.
- **`rtl/ecp5/vdpx_ecp5_core.v`, `colorlight_i9_top.v`**: ROM do autoteste de 8192 words (`selftest_dma.hex`).
- **`rtl/board/tang_top.v`**: só a ligação das novas portas (taps sem uso). O autoteste da Tang (`selftest.hex`,
  4096 words) **não mudou**.
- Inalterados: renderizador, APU, adaptador CN2 somente escrita, sonda CN2, HDMI/TMDS, PLL, LPF, os 16
  registradores de `REG_SEL`, o target 7 e os offsets `$A1200E/F` (sem uso).

## Autoteste

- `scripts/gen_selftest.py --dma`: demonstração com 4 quadros de animação na SDRAM (word 0x2000):
  - FILL limpa os tiles 0x60/0x61;
  - PATTERN preenche as linhas 5 (com VSYNC) e 6 do plano A;
  - um COPY de 32 words por quadro.

## Verificação

- **Novo `sim/p2/tb_dma_unit.sv`** (Icarus, semente 0x0DA00001):
  - casos dirigidos + 4000 comandos aleatórios;
  - CPU concorrente com prioridade e latência aleatória da memória;
  - 3 mutações que precisam falhar.
- **Novo `sim/p2/dma_check.h`**: modelo de referência do DMA (`RefDMA`) e scoreboard da porta de escrita
  (`DmaCheck`). Ele é ligado em `tb_main`, `tb_m4`, `tb_ecp5` e `tb_m2wo`.
- **`sim/refmodel.h`**: target 6, escritas de CPU na VRAM conferidas na ordem da porta.
- **Novas cenas** (`scripts/gen_dma_scenes.py`): `dma_basic`, `dma_render`, `dma_pcm`, `dma_errors`, `dma_cpu`,
  `dma_vsync`, `dma_bench`. Novos comandos de cena: `dmawait`, `dmastat`, `dmalog`, `echo`, `framebegin`/`frameend`.
- **Monitores:**
  - `APU_DEADLINE` (tick 48 kHz → amostra pronta);
  - escritas do DMA com o renderizador ocupado.
- **Novo `m68k/bench/`**: benchmark do 68000 (fx68k) com a cópia desenrolada, o laço DBRA, a carga da memória de
  samples e o envio do comando de DMA.
- **Novo `scripts/p2_bench_report.py`**: tabelas a partir dos logs.
- **`Makefile`**: alvos `dma_unit`, `m2wo50`, `m2bench`, `p2_bench_report` e `p2_test`; `ecp5_test` inclui
  `p2_test`; nomes `vdpx_ecp5_p2`.
- **`scripts/run_p2_all.sh`**: execução completa reprodutível (regressão da P1 + P2 + síntese) com logs em `logs/`.
- **`scripts/expect_fail.py`**: tolera bytes não UTF-8 na saída do simulador.

## Organização

- Documentos da P1 movidos para `docs/p1/`, logs da P1 para `logs/p1_history/`. O bitstream da P1 está apenas na
  entrega P1.
