# Comparação: Tang Nano 20K × Colorlight i9 (ECP5)

| | Tang Nano 20K (M4.2 Claude) | Tang Nano 20K (RTL P1, parâmetros Tang) | Colorlight i9 v7.2 + Ext-Board (P1) |
|---|---|---|---|
| FPGA | GW2AR-LV18QN88C8/I7 | idem | LFE5U-45F-6BG381C |
| Lógica | 8 532 LUT4 (41%) | 7 898 LUT4 (38%) + 2 782 ALU | 7 655 COMB (17%) |
| FF | 3 713 (23%) | 3 966 (25%) | 3 055 (7%) |
| RAM de bloco | 43/46 BSRAM (93%) | 43/46 | 44/108 EBR (41%) |
| Multiplicadores | 1 | 1 MULT18X18 | 2 MULT18X18D |
| PLL | 2/2 | 2/2 | 1/4 (4 saídas usadas) |
| clk_sys (alvo) | 50,4 MHz | 50,4 MHz | 50,0 MHz |
| Fmax clk_sys (P&R aberto) | 57,7 MHz | 118,0 MHz* | 69,3 / 71,2 / 70,3 MHz (3 sementes) |
| Fmax clk_pix | 69,0 MHz | 83,8 MHz* | 72,0–76,3 MHz |
| Vídeo | 640×480 a 60,0 Hz (25,2 MHz) | idem | 640×480 a 59,52 Hz (25,0 MHz) |
| Serialização | OSER10 + TLVDS_OBUF | idem | ODDRX1F (125 MHz DDR) + LVCMOS33D |
| ACR CTS | 25 200 | 25 200 | 25 000 |
| SDRAM | 8 MiB interna (DQM disponível), captura R2 | idem | 8 MiB externa, **sem DQM** → RMW; clock 288°, captura R3 |
| Áudio 48 kHz | 1050 ciclos/quadro | idem | 3125/3 ciclos/quadro |
| Orçamento da linha | ~2260/3200 | 2349/3200 (medido) | 2349/3200 (medido) |
| HDMI físico | conector na placa | — | Ext-Board: AC 0,1 µF, sem DDC/HPD/CEC |
| Validação física | BLOCKED/PENDING (M4.2) | — | **PENDING** |

\* nextpnr-himbaechel-gowin 0.11.1 (YoWASP), mais novo que o usado na M4.2: não comparar diretamente com 57,7 MHz.
Mesmo assim, as otimizações de pipeline também beneficiam a Tang.

## Leitura

- O ECP5 grau -6 é mais lento por nível de lógica: o RTL da M4.2 fechava 57,7 MHz na Tang e só ~40 MHz no ECP5.
  Depois do pipeline, o ECP5 fecha com +38% de margem.
- A vantagem do ECP5 está na **memória** (108 EBR contra 46 BSRAM), nas **PLLs livres** e nos **pinos**. A lógica
  usada cai de 41% para 17%.
- A desvantagem prática é a **SDRAM externa sem DQM**: exige RMW e cuidado de temporização de E/S, que a SDRAM
  interna da GW2AR não exigia.
