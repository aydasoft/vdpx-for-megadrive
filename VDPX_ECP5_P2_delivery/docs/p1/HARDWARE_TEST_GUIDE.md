# Guia de teste em hardware: Colorlight i9 v7.2 + Ext-Board

**HARDWARE VALIDATION: PENDING.** Nada abaixo foi executado: é o roteiro para quando houver a placa.
Nenhum Mega Drive é necessário nas etapas 1–4. **Não ligar o CN2 nesta fase.**

## 0. Material

- Colorlight i9 **v7.2** (conferir a etiqueta "i9 V7.2" e o FPGA **LFE5U-45F-6BG381C**) encaixada na Ext-Board
  i5/i9 (esquema `i5-i9-extboard.pdf`). Uma i9 **v7.1** deve funcionar igual (GPIO idêntico pela documentação). A
  **i9plus** (Xilinx) **não serve**.
- Alimentação de 5 V da Ext-Board (USB-C ou entrada própria), capaz de ≥ 1 A.
- Monitor/TV HDMI que aceite 640×480 (VIC 1). Para o áudio, um monitor com alto-falante ou uma TV.
- Programador: o CMSIS-DAP da própria Ext-Board (MCU) com `openFPGALoader -c cmsisdap` (ou `ecpdap`).
- Multímetro.

## 1. Antes de programar (desenergizado/energizado sem bitstream novo)

1. Inspecionar os capacitores C6..C13 (0,1 µF) entre o conector HDMI e o SODIMM (esquema S1).
2. Energizar só a Ext-Board + módulo. Medir 3,3 V e 1,1 V do módulo, se acessíveis.
3. **Medir VCCIO do banco 2** (HDMI): o LPF assume 3,3 V (`LVCMOS33D`). Se for 2,5 V, trocar `IO_TYPE=LVCMOS33D`
   por `LVDS` nas 4 linhas `gpdi_dp` do LPF e gerar de novo (sem mudar o RTL).
4. Com o bitstream de fábrica (pisca LED), confirmar que o LED do módulo (L2) responde, para validar o programador.

## 2. Programação

```sh
sha256sum artifacts/vdpx_ecp5_p1.bit     # deve bater com SHA256SUMS / logs/ecp5_build/report.md
openFPGALoader -c cmsisdap artifacts/vdpx_ecp5_p1.bit          # SRAM (volátil): primeiro teste
# só depois de aprovado:  openFPGALoader -c cmsisdap -f artifacts/vdpx_ecp5_p1.bit   (flash)
```

## 3. Vídeo (autoteste, sem Mega Drive)

Esperado na tela (o mesmo da M4.2): céu em degradê, texto "VDPX OK", amostras de cores, chão de tijolos, seis
bolas animadas e o **painel da sonda CN2** nas linhas de baixo, com `AUTOTESTE:S MD:N` e `(UNIDADE 20.0 NS)`.

| Verificação | Critério |
|---|---|
| Imagem estável | Sem rolagem nem cintilação; o monitor informa 640×480 ~59,5 Hz |
| Cores | Barras e degradê como em `out/ecp5_hdmi_frame*.ppm` (gerados pela simulação) |
| Animação | Bolas em movimento contínuo |
| LED L2 | Pisca **lento** = autoteste ativo (aceso direto = MD ativo; rápido = erro: FIFO de vídeo, overflow) |

Se não houver imagem: trocar de monitor (alguns rejeitam 59,52 Hz ou o sinal pseudo-diferencial), conferir o banco
2 (§1.3), testar outro cabo. Registrar modelo e resultado de cada monitor.

## 4. Áudio HDMI e SDRAM

- O autoteste toca música (wavetable) e um "kick" PCM **lido da SDRAM**. Ouvir no monitor/TV.
- Wavetable soando e PCM limpo = caminho SDRAM RMW funcionando.
- PCM ausente ou ruidoso com a música normal = **suspeitar da janela de leitura da SDRAM**. Varrer a fase do
  clock da SDRAM em `rtl/ecp5/colorlight_i9_top.v` (`CLKOS3_CPHASE` 8..12, passo 2 ns; `CLKOS3_FPHASE` 0..7,
  passo 0,25 ns), gerar de novo e anotar a faixa em que o PCM fica limpo. Escolher o centro da faixa.
- Se o monitor não tiver som: o áudio também sai em I2S nos pinos provisórios do PMOD P5 (BCK D18, WS G5, DOUT
  F5), para um DAC/amplificador I2S de 3,3 V (ex.: MAX98357A).

## 5. Somente depois: CN2 (fase futura, fora da P1)

A interface com o Mega Drive continua **somente escrita** e com as pendências da M4.2 (pinagem VA6, medições).
Uma placa adaptadora com SN74LVC4245A (A = 5 V do console, B = 3,3 V do FPGA, **direção fixa A→B**, /OE com
pull-up) ligaria nos PMODs P3/P4 conforme `HDMI_PINOUT.md`. Antes de ligar ao console:
- confirmar a pinagem VA6 (checklist da M4.2 em `M4_2_delivery/PINOUT_VA6_TO_CONFIRM.md`);
- medir o 5 V do console para o VCCA e verificar o sequenciamento VCCA/VCCB e o comportamento com uma das fontes
  desligada no datasheet do 4245A;
- usar a sonda CN2 (painel na TV) para medir /FDC, /FDWR e /CAS0 com a ROM de diagnóstico (`make diagrom`).

## 6. O que registrar

Fotos da placa (etiquetas do módulo e da Ext-Board), VCCIO medido, monitor usado, foto da tela, presença de áudio,
fase da SDRAM aprovada, hash do bitstream gravado. Só com esse registro a validação física pode mudar de PENDING.
