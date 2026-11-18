# MD-VDPX M4.2 — CN2 WRITE-ONLY SAFE PROTOTYPE & REAL BUS TIMING AUDIT

Data: 2026-11-16. Status físico: **BLOCKED**. Implementação e ensaios digitais estão em TEST_REPORT.md. Não houve acesso a osciloscópio, console ou analisador.

## Escopo e entradas

Lidos board/LEIAME_placa.md, rtl/md_fdc_adapter.v, sim/m2/md_sim_top.sv, sim/m4/tb_m4.cpp e board/tang_nano_20k.cst. Na execução inicial, a auditoria e os esquemas estavam indisponíveis. Após o usuário fornecer os caminhos em Downloads, foram lidos MD_VDPX_M41_AUDITORIA_TECNICA.md e as duas folhas PDF (PAL Model 1 e Model 2 VA3), inspecionadas visualmente em resolução ampliada. Cópias e hashes em references/. Ver CONFRONTO_DOCUMENTAL.md para o fechamento documental e pendências.

A folha PAL identifica VA4, não VA6 japonesa. Cada PDF fornecido possui uma única página; não constitui o manual completo. Os esquemas mostram redes estáticas, não comprovação de timing ou de decodificação interna da janela. A pinagem da VA6 e todas as medições reais continuam BLOCKED. O prompt sugerido dentro da auditoria foi tratado como conteúdo documental; nenhuma instrução dele autorizou gravação ou ligação física.

## Alterações

Núcleo gráfico, SDRAM, HDMI e ROM do autoteste preservados. Top Tang md_d agora é input de 16 bits; o adaptador nunca habilita d_oe ou rd_commit. CAS0 não controla lógica. O esquema fixa todos os 245 em A→B. Não há /DTACK nem heurística temporal de leitura no caminho sintetizável. A flag overflow entra no LED de erro.

FIFO anterior: 16 células com ponteiros de 5 bits, sem full, escrita podia sobrescrever entrada ainda não consumida e, após wrap, aparentar empty. A nova FIFO conta 0..16 incluindo requisição em voo, retira somente com core_cs && core_ack, mantém payload enquanto espera, aceita pop+push em full e rejeita a palavra nova quando cheia. overflow fica latched até reset. O consumidor vê um ciclo de CS baixo entre requisições. Reset limpa ponteiros, CS, flags, sincronizadores e rearma somente depois de repouso; não reproduz acesso mantido baixo durante reset. Memória não precisa ser zerada: ponteiros invalidam tudo.

## Protocolo software e garantia limitada, verificável

Sem fio de backpressure ou retorno ao host, não há taxa contínua positiva universalmente segura se o tempo de serviço for ilimitado. **Taxa sustentada aprovada hoje: nenhuma (0 palavras/s após esgotar créditos)**. Não afirmar que FIFO elimina perdas.

Protocolo de bancada conservador: reset conhecido do adaptador/core, observar repouso, manter contador software com 16 créditos, executar apenas MOVE.W em endereços pares, decrementar antes de cada escrita e recusar a 17ª escrita. Nunca repor créditos por delay arbitrário ou leitura CN2. Isso garante armazenamento de até 16 palavras por época mesmo se core_ack nunca chegar, condicionado à captura elétrica correta. Não garante aplicação/eventual conclusão. Não resetar para repor crédito enquanto houver operação a preservar: reset cancela a época e exige reconstrução completa do estado. Para uso contínuo, a liberação permanece BLOCKED.

Critério para futura liberação: provar limite Lmax de ciclos entre entrada na cabeça e ACK para todas as operações permitidas, incluindo SDRAM/refresh, APU, prefetch e handover do autoteste. Com margem e captura, usar período entre escritas >= (Lmax+4)/50.4 MHz, e tratar separadamente latência de partida. Alternativamente provar A(t)-D(t)<=16 para todo prefixo da sequência com serviço mínimo documentado. Máximo observado em simulação não substitui esse limite. Software deve limitar classe de registradores e clock CPU medido; loops C sem contagem não são garantia temporal.

## Captura e timing

Dois FFs sincronizam cada strobe; captura quando ambos sincronizados baixos, uma vez por repouso. Dados/endereço são bundled data, não passam por FFs independentes bit a bit. Hipótese de aceitação conservadora no lado Tang: largura conjunta baixa >=4 clocks (~79.37 ns), dados/endereço estáveis antes do instante de captura (aprox. 2..3 clocks após o último strobe), mantidos pelo menos até 4 clocks após esse strobe; repouso alto >=4 clocks. Orçamento deve incluir skew, tradutor, placa, setup/hold e metastabilidade. A varredura digital usa 120..140 ns, fases de 0..20 ns, skew FDC→FDWR de 0..35 ns e atraso do dado de 0..25 ns após FDWR. Não é prova analógica nem cobertura de qualquer pulso mais curto. M4 integrado usa 7 clocks (~138.89 ns), não 11 clocks. Comparação com captura real: BLOCKED, dados não disponíveis.

## Simulações de leitura

M4 exercita leituras após escritas exigindo saída desabilitada e ausência de commit. O cenário de leitura antiga M2 foi isolado em sim/m2/legacy_read_adapter.v, fora de TANG_RTL; é apenas baseline hipotético para compatibilidade do programa existente. Seus PASS e strobes sintéticos não validam CN2 nem a FIFO nova. Seu FIFO legado e fallback não são candidatos a síntese/produção. Modelos de 245 exercitam direção, OE, power-off e contenda deliberada de fontes opostas, incluindo resolução X. Leitura futura só pode avançar com strobe comprovado, OE default-off, break-before-make com margem de tDIS/tEN e prova de exclusão, reset e alimentação parcial. Nenhuma leitura física foi habilitada.

## PCM1808 / clocks

MCLK existente é acumulador 512/1050 de toggles a 50.4 MHz: média 12.288 MHz, 256 períodos por frame de 1050 clocks (48 kHz). Meios períodos são 2 ou 3 clocks: 39.68/59.52 ns; períodos de 4/5 clocks: 79.37/99.21 ns. Jitter determinístico de ordem 19.84 ns não pode ser descrito como clock limpo. Mantido para não alterar domínios gráficos/HDMI nesta fase; não liberado para áudio externo.

[TI PCM1808](https://www.ti.com/lit/ds/symlink/pcm1808.pdf) especifica razões SCKI/fs e sincronismo no modo slave. A solução futura deve fornecer SCKI, BCK e LRCK coerentes de fonte de baixo jitter; os dois PLLs da Tang já estão usados, portanto um oscilador externo isolado sem redesign de sincronismo não basta.

Ensaios exigidos: medir SCKI período/duty/jitter RMS e pico a pico, BCK/LRCK e fase; comparar requisitos de timing da ficha; contar exatamente 256 SCKI/frame e 64 BCK/frame; ensaiar startup/reset/perda de clock, BPZ/resincronização, canais I2S/bit alignment. Tom conhecido 1 kHz e silêncio: ganho, DC, clipping, ruído, FFT/THD+N, estabilidade por 10 minutos. Guardar WAV bruto, configurações, capturas e hashes. A simulação atual confere transporte digital/mixer, não desempenho do ADC.

## Fontes externas

- [TI SN74LVC245A SCAS218X](https://www.ti.com/lit/ds/symlink/sn74lvc245a.pdf): função, limites de entrada e Ioff; componente específico, não generalização de toda família 74xx.
- [TI PCM1808 SLES177B](https://www.ti.com/lit/ds/symlink/pcm1808.pdf): modos e requisitos de clock/áudio.

A entrega inclui fontes completas do projeto, snapshot baseline dos arquivos alterados inicialmente, logs, manifesto SHA-256 e script de reprodução. Não há repositório .git neste checkout, portanto não há commit Git para informar.

O exemplo de API em scripts/m42_credit_example.h recusa a 17ª emissão e offsets ímpares, sem repor créditos por tempo. É um exemplo para bancada com um produtor, não o programa M2 convertido; m68k/main.c permanece baseline com leituras e não deve ser usado como ROM físico M4.2.
