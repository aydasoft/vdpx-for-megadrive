# Áudio: base de 50 MHz, HDMI (ACR) e clock do PCM1808

| Item | Status |
|---|---|
| Mixer/APU a 48 kHz exatos com clock de 50 MHz | **PASS (simulação)** |
| Áudio HDMI (Audio Sample Packets, ACR N=6144/CTS=25000, InfoFrames) decodificado do TMDS serial | **PASS (simulação)** |
| Canais PCM e wavetable preservados (bit a bit com o modelo da APU) | **PASS (simulação)** |
| PCM1808 com clock limpo | **BLOCKED** (MCLK fracionário segue EXPERIMENTAL; opções abaixo) |
| Áudio em monitor/TV real | **PENDING** (hardware) |

## 1. Dependências de 50,4 MHz encontradas e corrigidas

| Arquivo | Na M4.2 (50,4 MHz) | Na P1 (parâmetro `CLK50` / `I2S_NUM`/`I2S_DEN`) |
|---|---|---|
| `rtl/vdpx_i2s.v` | quadro = 1050 ciclos (contador fixo) | acumulador fracionário: passo 128·N, módulo D. Tang: N=1, D=1050 (**idêntico ciclo a ciclo à M4.2**, regressão M4.2 aprovada). ECP5: N=3, D=3125 → quadros de 1042/1042/1041 ciclos, **48 000 Hz exatos em média** |
| `rtl/board/vdpx_board.v` MCLK | passo 512 / módulo 1050 | passo 512·N / módulo D → 12,288 MHz médios nos dois clocks |
| `rtl/hdmi/hdmi_tx.v` ACR | CTS = 25200 fixo | parâmetro: 25200 (25,2 MHz) / **25000 (25,0 MHz)** |
| `scripts/gen_overlay.py` | "UNIDADE 19.8 NS" fixo | campo do painel (19.8 / 20.0) passado pela placa |
| `sdram_ctrl` INIT/refresh | 10080 ciclos / 700 | inalterados: 201,6 µs ≥ 200 µs e 14 µs < 15,6 µs a 50 MHz |
| `md_fdc_adapter` (4 clocks de captura) | 79,4 ns | 80 ns: mesma hipótese de largura mínima do strobe |
| Vídeo | 800×525 em clocks de pixel | inalterado (59,5238 Hz a 25 MHz; os totais VGA **não** foram mudados) |

A APU passou a usar o multiplicador com registros (+72 ciclos por amostra, de ~1042 disponíveis); a aritmética é a
mesma, e a regressão de áudio confirma.

## 2. ACR (Audio Clock Regeneration)

HDMI: 128 · fs = f_TMDS · N / CTS. Com f_TMDS = 25 MHz, fs = 48 kHz e N = 6144 (valor recomendado para 48 kHz):
CTS = 25 000 000 · 6144 / (128 · 48 000) = **25 000 exatos** (inteiro: sem alternância de CTS). Como o áudio e o
TMDS saem do mesmo cristal (o quadro I2S é derivado de `clk_sys`), a relação é exata e não há deriva.
Conferido por `scripts/ecp5_audit.py` e pelo decodificador nos testes (N=6144, CTS=25000 em todos os pacotes ACR).

## 3. Sincronismo áudio/vídeo, FIFO e CDC

- O mixer produz uma amostra por quadro I2S em `clk_sys`; a amostra cruza para `clk_pix` por toggle + 2 FFs, com
  o dado estável por ~1000 ciclos (como na M4.2).
- O `hdmi_tx` tem FIFO de 16 amostras e envia até 4 por linha (31 250 linhas/s → capacidade de 125 k amostras/s
  contra 48 k/s necessários).
- Taxa medida no mixer em simulação: **48 000,00 Hz** (±0,002 Hz de quantização). No receptor: ~806 amostras por
  quadro de vídeo (48 000 / 59,524 = 806,4), a média por quadro converge com quadros suficientes.
- Overflow da FIFO de áudio HDMI: flag `aud_overflow` = 0 em todas as execuções; underrun não existe no
  protocolo (linha sem amostra envia Null). Áudio do receptor = sequência contígua da saída do mixer
  (`REGRESSION_REPORT.md`).

## 4. PCM1808: investigação do clock limpo

O PCM1808 em modo escravo exige SCKI (256/384/512 fs) **síncrono** com BCK/LRCK. Hoje o MCLK é um divisor
fracionário de 50 MHz: meios períodos de 2 ou 3 ciclos (40/60 ns), média 12,288 MHz, jitter determinístico de
~20 ns. Isso não é um clock limpo (como já era na M4.2 com 50,4 MHz), e continua **EXPERIMENTAL / BLOCKED**.

| Opção | Viabilidade | O que exige | Conclusão |
|---|---|---|---|
| PLL dedicada a partir dos 25 MHz | O ECP5 tem 4 EHXPLLL (1 em uso). Melhor aproximação encontrada (busca exaustiva): **12,288136 MHz, erro 11 ppm** (CLKI 1, CLKFB 1, CLKOP /29, VCO 725 MHz, saída /59). 24,576 MHz: 156 ppm. 12,288 MHz exatos são impossíveis (1536/3125 exigiria divisores > 128). | Mover o I2S (e o tick da APU) para o domínio do MCLK, com FIFO para `clk_sys`, e **medir o CTS** no HDMI (o áudio deixaria de ser coerente com o TMDS: fs = 48 000,53 Hz) | Viável sem hardware novo, mas é mudança de arquitetura do áudio: **fora da P1**. Jitter de PLL (centenas de ps) em vez de 20 ns. |
| Oscilador externo 24,576 MHz | Entradas de PLL livres na Ext-Board: **A19 (`URC_GPLL1T_IN`) e B20 (`URC_GPLL1C_IN`)** no PMOD P3 (`pmode`). Hoje estão reservadas, provisoriamente, para md_d[5]/md_d[2]; podem ser trocadas. | **Oscilador não instalado** + a mesma mudança de domínio + CTS medido | **BLOCKED por hardware.** Não se inventa uma montagem. |
| Gerar SCKI = clk_sys/4 (12,5 MHz) e quadro de 260,4 fs | Fora das razões aceitas pelo PCM1808 (256/384/512 fs) | — | Descartada |
| Manter o fracionário | Funciona como hoje, jitter de 20 ns | — | EXPERIMENTAL, sem homologação |

Nenhuma dessas opções foi implementada: a P1 não sacrifica o HDMI nem o timing. A recomendação para a fase de
áudio externo é a PLL dedicada com CTS medido (sem hardware novo) ou, se houver placa adaptadora, o oscilador de
24,576 MHz em A19.
