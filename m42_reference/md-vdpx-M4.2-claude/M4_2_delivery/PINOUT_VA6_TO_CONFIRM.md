# CN2 japonês Model 1 VA6 — todos os contatos A/B a confirmar

**BLOCKED:** não há fotos, continuidade, esquema específico VA6 ou capturas. As folhas PAL VA4 e Model 2 fornecidas posteriormente foram examinadas; ver CONFRONTO_DOCUMENTAL.md. A tabela abaixo transcreve candidatos históricos do projeto, NÃO uma pinagem VA6 aprovada. Identificar lado de componentes/solda e orientação do conector antes de numerar.

| Rede | Contato candidato (não confirmado VA6) | Tang FPGA |
|---|---|---|
| VD0..7 | A4..A11 | 73 74 76 77 27 28 29 30 |
| VD8..15 | A13..A20 | 31 41 42 48 49 71 72 75 |
| VA1..3 | B3..B5 | 86 80 85 |
| /FDC | A24 | 15 |
| /FDWR | B24 | 16 |
| /CAS0 | A3 | 17 (somente entrada) |
| FRES | A25 | 79 |
| /LWR, /UWR | B21, B22 | analisador apenas |
| /DISK | B2 | NC; medir sem forçar |
| GND | A1 A12 A30 B1 B12 B30 | GND após continuidade |
| +5 V | A26 B26 | NC |
| alimentação não regulada | A28 B28 | NC |
| áudio candidatos | A27 B27 A29 B29 | NC; função desconhecida VA6 |

Checklist de bancada e evidências obrigatórias:

- [ ] Fotografar identificação PCB VA6 japonesa, console, CN2 dos dois lados e orientação; registrar revisão e SHA-256 das fotos/esquema.
- [ ] Desenergizado: continuidade ponto a ponto de cada GND, alimentação, dados e controles até IC/test point identificado no esquema desta revisão. Registrar resistência; não testar continuidade energizado.
- [ ] Energizado sem Tang: medir DC, ripple, overshoot, undershoot de alimentações, níveis high/low de controles; verificar faixa de entrada do LVC e 3V3 local. Não tratar linha não regulada como 5 V.
- [ ] Capturar /FDC, /FDWR, /CAS0, /LWR, /UWR, /DISK, FRES e clock CPU; depois VA1..3 e todos os VD0..15 com referência de tempo comum. Sondas/analisador tolerantes a 5 V, GND curto; registrar modelo, banda, taxa, limiar, carga, calibração.
- [ ] ROM diagnóstica: MOVE.W alinhado em $A12000..$A1200E, leituras isoladas, write→read imediato, rajadas, writes bytes alto/baixo apenas para caracterizar (não aceitos pelo protótipo), endereços vizinhos fora da janela, reset durante ciclo, DMA/Z80/arbitragem.
- [ ] Para cada operação: min/max de largura /FDWR (~130 ns é hipótese), /FDC→/FDWR, skew entre controles, setup/hold de endereço/dados, intervalo alto entre ciclos, jitter de CPU, frequência CPU real. Incluir bordas no lado B após tradutor.
- [ ] Demonstrar se /CAS0 realmente ocorre em leituras $A12000, e também em escritas/áreas vizinhas. Ausência de /FDWR não comprova leitura. Nenhuma captura habilita leitura nesta build.
- [ ] Verificar /DISK sem pull-down adicional e estado de boot com adaptador; não conectar /DTACK.
- [ ] Áudio: rastrear origem/destino dos contatos VA6; medir DC, amplitude pico a pico, impedância e clipping em silêncio/tom/volume mínimo e máximo. Usar saída de fone somente com condicionamento dimensionado após medição; não assumir SL3/SR3 do Model 2.
- [ ] Alimentação parcial e desligamento: verificar que console não é alimentado pela Tang e vice-versa, buffers não dirigem A, ausência de sobrecorrente.
- [ ] Arquivar capturas brutas CSV/VCD/formato nativo, screenshots, programa ROM e hash, setup das sondas, temperatura, carga e conclusão por ensaio. Comparar envelope com sim/m42/tb_adapter.sv e repetir regressão com valores medidos.

Pinos 80/85 compartilham SD: remover cartão. LEDs/RGB conectados aos pinos reaproveitados exigem inspeção elétrica da Tang. CST é alocação FPGA, não confirmação de contatos CN2. Pinos HDMI DDC 52/53 e banco 1V8 25/26 não foram usados para CN2.

## Evidência documental recebida posteriormente

As duas folhas corroboram, para os modelos nelas representados, A3=/CAS0, A24=/FDC, B24=/FDWR, B21=/LWR, B22=/UWR, B2=/DISK e A25=FRES, além dos grupos VD e VA1..3 acima. Isso não aprova nenhum contato VA6. Na folha PAL VA4, A27/B27 são N.C.; na folha Model 2 são SR3/SL3. A2 na folha Model 2 tem rótulos conflitantes VA19 (rede) e VA18 (conector); não resolver por inferência. A28/B28 aparecem como +9 V nas redes das folhas, mas continuam NC no protótipo e exigem medição da VA6.
