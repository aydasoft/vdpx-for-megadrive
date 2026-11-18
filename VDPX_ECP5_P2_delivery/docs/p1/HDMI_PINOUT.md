# Pinagem: Colorlight i9 v7.2 + Ext-Board (LFE5U-45F-6BG381C)

Arquivo de restrições: `board/colorlight_i9_v72_extboard.lpf`. Bancos e pares: `board/lfe5u45_cabga381_pins_subset.json`
(extraído do prjtrellis-db). Conferência automática: `scripts/ecp5_audit.py` → `logs/ecp5_build/ecp5_audit.log`.

## HDMI (Ext-Board HDMI1)

| Lane | Porta RTL | P (esfera) | N (esfera) | PIO | Banco | Conector HDMI (P/N) | Fonte |
|---|---|---|---|---|---|---|---|
| Dados 0 (azul) | `gpdi_dp[0]` | **G19** | H20 | PR20A/B | 2 | 7 / 9 | esquema S1, LiteX S3 |
| Dados 1 (verde) | `gpdi_dp[1]` | **E20** | F19 | PR17A/B | 2 | 4 / 6 | idem |
| Dados 2 (vermelho) | `gpdi_dp[2]` | **C20** | D19 | PR14A/B | 2 | 1 / 3 | idem |
| Clock | `gpdi_dp[3]` | **J19** | K19 | PR23A/B | 2 | 10 / 12 | idem |

`IO_TYPE=LVCMOS33D DRIVE=4`. O lado N é o complementar automático do par verdadeiro (A = P, B = N).
CEC, SCL, SDA e HOTPLUG: **não conectados ao FPGA**. +5V do conector: 5V da placa.

## Separação dos pinos

| Uso | Pinos | Situação |
|---|---|---|
| HDMI | G19 H20 E20 F19 C20 D19 J19 K19 | fixos na Ext-Board, **dedicados** |
| Clock 25 MHz | P3 | módulo |
| LED (ativo em 0) | L2 | módulo; compartilhado com o pino 41 do SODIMM (pmodc:3) |
| SDRAM (49) | B9 B10 A9 A10 B11 C8; A: B13 C14 A16 A17 B16 B15 A14 A13 A12 A11 B12; DQ: B6 A5 A6 A7 C7 B8 B5 A8 D8 D7 E8 D6 C6 D5 E7 C5 C10 D9 E11 D11 C11 D12 E9 C12 E14 C15 E13 D15 E12 B17 D14 D13 | módulo (bancos 0, 1, 7) |
| Flash SPI | R2 V2 W2 (+U3 dedicado) | módulo, não usados |
| Ethernet ×2 | N5 P5 P4 U19 U20 T19 T20 R20 P19 L19 P20 N19 N20 M19 M20 G1 G2 H1 J1 J3 K1 H2 K2 L1 N1 P1 P2 | módulo, não usados |
| **CN2 (provisório)** | P3 conector `pmode` + `pmodf`: md_d[0..15]; P4 `pmodg`: VA1-3, /FDC, /FDWR, /CAS0, FRES | entradas, sem placa adaptadora nesta fase |
| **Áudio (provisório)** | P5 `pmodi:0..4`: BCK D18, WS G5, DOUT F5, MCLK E5, ADC_DOUT D17 | sem DAC/ADC nesta fase |
| Livres na Ext-Board | P2 (`pmodc`/`pmodd`, exceto L2 e K18), `pmodg:7` E1, `pmodh` (E19 B3 K5 B2 K4 A2), `pmodi:5..7` (D16 evitado, E6 F4), `pmodj` (J17/H18 = serial), P6 (`pmodk`, `pmodl`) | periféricos futuros |

Os pinos "provisórios" existem para que o bitstream tenha a interface CN2 somente-escrita e o I2S no lugar. **Não
são uma pinagem de placa adaptadora aprovada.** A placa com SN74LVC4245A (`HARDWARE_TEST_GUIDE.md` §5) define a
pinagem definitiva.

## Revisão para a futura interface SN74LVC4245A (sem implementação nesta fase)

- 23 entradas hoje (16 dados + VA1-3 + /FDC /FDWR /CAS0 FRES) cabem em três 4245A (8 + 8 + 7), em direção fixa
  A(5 V, console) → B(3,3 V, FPGA). O lado B vai a pinos LVCMOS33 dos PMODs P3/P4. Os PMODs têm 3,3 V e GND, mas
  **não têm 5 V** para o VCCA: o 5 V tem que vir do console (A26/B26, a medir na VA6) ou de uma fonte local com
  sequenciamento. Ver `RISKS_AND_BLOCKERS.md`.
- Para /LWR, /UWR e VA4-VA7 futuros sobram pinos em P2, P4 e P6.
- **Nenhum pino do CN2 tem driver de saída** (netlist conferida: todas as portas `md_*` são `input`).
