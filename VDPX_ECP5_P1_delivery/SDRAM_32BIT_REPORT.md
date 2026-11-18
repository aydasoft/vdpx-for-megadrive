# SDRAM de 32 bits sem DQM: Colorlight i9 v7.2

Status: **solução aprovada em simulação** (controlador + modelo + atrasos de placa de pior caso). Validação física:
**PENDING**.

## 1. O que a placa tem

| Sinal | i9 v7.2 | Fonte |
|---|---|---|
| Chip | M12L64322A, 512K × 32 × 4 bancos (8 MiB), 2048 linhas × 256 colunas | `colorlight_i9_v7.x.md` (S2) |
| CS# | GND | S2 |
| CKE | VCC | S2 |
| **DQM0–DQM3** | **GND** | S2. A plataforma LiteX (S3) diz o mesmo para a i5 ("dm: gnd") e deriva a i9 dela. |
| Clock / comando / endereço / DQ | 49 pinos (bancos 0, 1, 7) | S2, S3 |

O esquema do **módulo** i9 não é público. A ligação de DQM em GND aparece em **duas fontes independentes** e é
coerente com a ausência de pinos DQM nas listas de esferas. Mesmo assim, segue **"confirmada por documentação, não
por esquema/medição"** (RISKS_AND_BLOCKERS). A solução abaixo funciona com DQM em GND **e também** com DQM ligado e
mantido em 0 pelo FPGA, então não depende dessa confirmação.

Divergência encontrada: `src/amaranth_boards/colorlight_i9_r7_2.py` (no repositório S2) lista **D16** como DQ27.
S2 e S3 listam **D15**, e D16 é o pino 5 do PMOD P5 (`pmodi`). O LPF usa D15 e deixa D16 sem uso. Sem DQM, a
**permutação** dos 32 bits de DQ é indiferente (S2 e S3 usam ordens diferentes do mesmo conjunto de 32 esferas;
conferido pela auditoria), porque todo dado escrito é lido pelos mesmos fios.

## 2. Consequência

O controlador M4.2 grava 16 bits num endereço de 32 bits usando DQM para mascarar a outra metade. Sem DQM, todo
WRITE grava os 32 bits, e **a escrita de uma metade destrói a outra**. Teste negativo: `make ecp5_unit` roda o
controlador M4.2 contra o modelo sem DQM e ele **falha**, como esperado (`logs/ecp5_unit/ecp5_unit.log`).

## 3. Solução: leitura-modificação-escrita (`rtl/board/sdram_ctrl.v`, parâmetro `RMW = 1`)

| Operação | Sequência (ciclos de 50 MHz) |
|---|---|
| Leitura de 16 bits | ACTIVE → (tRCD) READ com auto-precharge → captura na borda `RD_CAPTURE` → metade escolhida por `addr[0]` |
| Escrita de 16 bits | ACTIVE → READ **sem** precharge (linha aberta) → captura do word de 32 bits → merge (`addr[0]`: 0 = DQ[15:0], 1 = DQ[31:16]) → 1 ciclo livre para a SDRAM soltar o DQ → WRITE do word com auto-precharge |
| Refresh | AUTO REFRESH a cada 700 ciclos (14 µs < 15,6 µs) só a partir do estado ocioso; uma sequência RMW é atômica (refresh e outros mestres esperam) |
| Organização lógica | **Igual à M4.2**: endereço de word de 16 bits de 22 bits, `a[0]` metade, `a[8:1]` coluna, `a[10:9]` banco, `a[21:11]` linha; amostras big-endian como na M4.2 |
| Arbitragem | Inalterada: a APU é dona da porta e intercala os acessos da CPU (`vdpx_apu.v`); o controlador atende um pedido por vez |
| Power-on | Pinos de comando com valor inicial NOP (CS# está em GND na placa: RAS/CAS/WE não podem começar em 0) |

Custo: uma escrita leva 1 READ a mais (latência máxima observada de 19 ciclos com refresh no meio). As escritas
na memória de samples são raras (upload de samples); a APU só lê.

## 4. Temporização da SDRAM externa

Na Tang, a SDRAM é **interna** ao GW2AR, e a M4.2 captura a leitura 2 bordas depois do READ, com o clock da SDRAM
igual a `~clk`. Na i9, a SDRAM é externa, e o datasheet M12L64322A (CL2) dá **tAC = 6/7/8 ns** (graus -5/-6/-7),
**tOH = 2 ns**, tSS (setup) = 1,5/2/2 ns, tSH (hold) = 1/1/1,5 ns e tSHZ = 6/7/8 ns. Com o clock invertido, o dado
da leitura chega ao FPGA ~30 + tOC + tAC + tIN ≥ 40 ns depois do READ, **depois** da borda de captura de 40 ns.
**O esquema M4.2 não funciona com SDRAM externa** (teste negativo abaixo).

Nova arquitetura (P1):
- clock da SDRAM = **CLKOS3 do PLL, 50 MHz, 16 ns (288°) depois de `clk_sys`**, levado ao pino por `ODDRX1F`;
- comandos e dados saem em `clk_sys`; a leitura é capturada na **3ª borda** depois do READ (`RD_CAPTURE = 3`),
  e o WRITE do RMW sai na 4ª.

Orçamento (pior caso; R0 = borda que registra o comando; SDRAM amostra em 16 + tOC):

| Hipóteses | Valor | Origem |
|---|---|---|
| tOC (ODDRX1F + saída LVCMOS33 + placa) | 3,5 ns | estimativa (datasheet ECP5 + ~0,3 ns de trilha) |
| Comando: tCO + roteamento + saída | ≤ 0,5 + 3,5 + 3,5 = 7,5 ns | nextpnr: roteamento máximo para pinos de comando 2,9–3,5 ns (`logs/ecp5_build/report.json`, `sdram_io_routing`) |
| Entrada: buffer + roteamento | 1 … 7 ns | nextpnr: roteamento ≤ 6,1 ns |
| tAC / tOH | 8 / 2 ns | M12L64322A grau -7 (o pior listado) |

| Margem | Cálculo | Resultado |
|---|---|---|
| Setup do comando na SDRAM | (16 + 3,5) − 7,5 − tSS 2 | **+10 ns** |
| Hold do comando | próxima mudança ≥ 20 + 2,8 − (19,5 + tSH 1,5) | **+1,8 ns** |
| Setup da leitura no FPGA (borda 60 ns) | 60 − (16 + 20 + 3,5 + 8 + 7) | **+5,5 ns** |
| Hold da leitura | (16 + 40 + 3,5 + 2 + 1) − 60 | **+2,5 ns** |
| Turnaround RMW (SDRAM solta DQ, FPGA dirige) | SDRAM Hi-Z até 56 + 3,5 + tSHZ 8 = 67,5 ns; FPGA dirige a partir de 80 ns + atrasos | **+13 ns** |

O nextpnr **não analisa restrições de E/S externas**: esse orçamento é cálculo, não STA. A fase é o botão de ajuste
para a placa: `CLKOS3_CPHASE` (passos de 2 ns) e `CLKOS3_FPHASE` (passos de 0,25 ns), sem mudar o RTL.

## 5. Verificação

| Teste | Onde | Resultado |
|---|---|---|
| Dirigido + aleatório, controlador RMW + modelo HONOR_DQM=0, **atrasos reais de placa** (Icarus, clock defasado 16 ns, janela de leitura de pior caso, comandos com 5 ns) | `sim/ecp5/tb_sdram_rmw.sv` | ver `REGRESSION_REPORT.md` (walking 1/0 nas duas metades, 12 endereços extremos, 2000 escritas alternadas nas duas metades com leitura do vizinho, 4000 em rajada, 60000 aleatórias em 8 MiB, ~870 refreshes sob carga, 0 erros de protocolo/tempo, 0 falhas de dado) |
| Conferência do word de 32 bits no modelo (metade par = DQ[15:0]) | idem (`chk_word`) | sem falhas |
| **Negativo 1**: esquema M4.2 (clock invertido + captura R2) com os mesmos atrasos | `make ecp5_unit` | **falha**, como esperado |
| **Negativo 2**: controlador sem RMW numa placa sem DQM | `make ecp5_unit` | **falha**, como esperado (metade vizinha destruída) |
| 17 cenas a 50 MHz com a memória de samples **no controlador RMW** (arbitragem APU/CPU, leituras de volta, PCM) | `make test50` (`sim/ecp5/vdpx_sim_sdram.v`) | áudio bit a bit = modelo; 301 leituras de volta conferidas (audio_smem) |
| Placa ECP5 inteira com a janela de pior caso no TB (início +20 ns, fim +6 ns; varredura: passa até +24 ns e exige > +4 ns) | `make ecp5_boardsim` | PCM lido da SDRAM bit a bit = modelo da APU |
| Refresh sob carga e intervalo máximo | modelo (REF_MAX 800 ciclos) em todos os testes | 0 violações; no teste de perda de lock o intervalo é julgado pelo limite JEDEC (9 × tREFI) |

## 6. Pendências

- Medir na placa (`HARDWARE_TEST_GUIDE.md` §4): áudio PCM do autoteste lido da SDRAM; varrer `CLKOS3_CPHASE` para
  achar a janela real e centralizar.
- Grau de velocidade do chip na placa (marcação -5/-6/-7): o orçamento usa o pior (-7).
- Confirmar DQM/CS/CKE no esquema do módulo, se ele for obtido.
