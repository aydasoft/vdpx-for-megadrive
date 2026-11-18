# Test report M4.2

Os status abaixo separam execução digital e liberação física. Logs completos em logs/; erros iniciais também são preservados. VCD é sintético, não medição.

## Critérios objetivos

| Gate | PASS requer | Status |
|---|---|---|
| WRITE ONLY RTL | md_d input na netlist, OE/commit sempre zero nos testes | PASS digital |
| FIFO | scoreboard sem perdas de aceitas, sem duplicação, capacidade 16, overflow explícito, reset limpo | PASS digital |
| Pulsos próximos de 130 ns | todos os 441 bins fase/largura sem erro, skew variável | PASS digital condicionado ao envelope |
| Tradutores | duas direções, OE/high-Z, Ioff funcional, detectar conflito proposital | PASS modelo funcional |
| Core/regressão | all_tests exit 0 | ver resultados finais abaixo |
| HDMI independente | autoteste permanece ativo sem CN2; frames/áudio iguais | PASS digital, execução independente |
| Síntese/P&R | make tang exit 0, recursos cabem, clocks atendidos | ver resultados finais abaixo |
| Interface real VA6 | originais + continuidade + capturas com margens | BLOCKED |
| Transferência sustentada sem perda | limite formal/documentado de serviço e software com orçamento | BLOCKED |
| PCM1808 físico | clock e áudio medidos dentro de especificação | BLOCKED |
| Leitura física | strobe comprovado + prova de não contenção | BLOCKED/desabilitada |

## Coverage funcional dirigida

Não foi coletada cobertura de linhas, toggle ou MC/DC; não há porcentagem de code coverage ou prova formal alegada. A cobertura funcional executada está nos contadores/assertions e logs:

- 441/441 combinações de fase 0..20 ns referenciada à borda negativa do clock e pulso 120..140 ns; skew FDC→FDWR 0..35 ns; dados atrasados 0..25 ns em relação a FDWR.
- 32 padrões walking-one/walking-zero exercitam os 16 bits.
- 491 palavras entregues com comparação de endereço+dados na ordem, >=14 wraps de ponteiro; 20 rejeições em full.
- FIFO full com ACK e captura simultâneos; ocupação permanece 16 e a entrada nova é entregue na ordem.
- 8 leituras após escrita com fila cheia; nenhum drive/commit, escritas permanecem ordenadas.
- Reset em transação/queue pendente, held-low através do reset, recuperação após idle, sticky overflow e ACK espúrio em empty.
- Estabilidade do payload enquanto core aguarda ACK, limite de ocupação, ausência de underflow/duplicações, watchdog.
- Modelo 245 de 8 bits (mesma célula replicada U1/U2): A→B, B→A hipotético, OE desabilitado, power-off, conflito no lado Tang e conflito no lado MD; 1 contenda reversa deliberada explicitamente contada. Não representa níveis analógicos ou delays min/max do componente real.
- Auditoria CST: unicidade de pinos, exclusão dos pinos reservados, md_d input; netlist sintetizada confirmada independentemente.
- Clock: cálculo exato de 5120 transições/10500 ciclos, meios períodos 2/3 clocks; não simulação analógica do PCM1808.

## Logs e interpretação

all_tests.log: primeira tentativa, falha por m68k-linux-gnu-gcc ausente do PATH após os testes básicos passarem. all_tests_retry.log usa toolchain local encontrado (m68k-elf-gcc 15.3.0), sem ocultar a falha inicial. m42test.log contém os testes dirigidos finais, incluindo ampliações de coverage posteriores ao início da suíte longa. M2 usa legacy_read_adapter.v: seu PASS é compatibilidade de software hipotética, não qualificação CN2 M4.2.

m4sim.log é a primeira execução integrada: 6/6 frames, 33600 amostras HDMI, 0 erros HDMI/SDRAM. selftest.log registra execução sem acessos MD: 3/3 frames, 14400 amostras, LEDs autoteste=1 e MD=0. Ver resultados finais para a execução com a assertion adicional de issued==applied.

A síntese pode emitir avisos de largura em bibliotecas de BSRAM e nextpnr pode emitir avisos de rotas dedicadas; o log completo é parte da entrega. Fmax de placement intermediário não substitui timing pós-route. O fluxo aberto usa --freq 50.4; a SDC existente é para Gowin EDA e não foi silenciosamente tratada como aplicada por nextpnr. CN2 assíncrono, atraso externo e serializer DDR requerem qualificação adicional: sucesso do fluxo não é fechamento de todos os requisitos de I/O.

## P&R final efetivamente executado

`make tang`: exit 0. Yosys 0.67+post (22c15a7...), nextpnr 0.11.1-68-g1daf1f5c, Apycula 0.34. Pós-route: clk_sys 62.65 MHz, clk_pix 70.18 MHz, ambos PASS contra --freq 50.4 MHz. Recursos: 5430 LUT4/20736, 2851 FF/15552, 42 BSRAM/46, 2 PLL/2, 1 MULT18X18/48. Log P&R: 3 warnings, 0 errors; advertências de rotas dedicadas resolvidas por recursos alternativos, preservadas no log. Não houve execução Gowin EDA nem validação em silício.

Relatórios: synth_stat.txt, synth.log, pnr.log, pin_clock_report.json (CST), synth_pin_directions.json (netlist), pnr_io_report.json (células I/O e localização pós-route). A netlist confirma md_d input; não há driver CN2 de saída. /CAS0 sem uso funcional pode ser otimizado pelo sintetizador.

A segunda tentativa da suíte encontrou erro do pacote Verilator: CFG_CXXFLAGS_PCH_I vazio fazia GCC tratar o nome do PCH como arquivo de link. Corrigido na invocação por `make CFG_CXXFLAGS_PCH_I=-include ...`; não se editou instalação global. all_tests_retry.log retém a falha, m2_retry.log registra a repetição dirigida.

O fx68k atual também dispara assertion automática de unique case no tempo zero (oper=0 antes do reset) com este Verilator. Na execução final, somente M2 usa `M2_VERILATOR_FLAGS=--no-assert-case`; isso desabilita assertions implícitas de case no modelo legado, não as comparações C++ de frames/barramento/áudio nem os testes M4.2. m2_retry.log preserva a falha de startup. Esta limitação impede alegar qualificação do CPU por assertions internas; M2 continua apenas baseline de compatibilidade.

## Resultado final

- **all_tests_final.log / exit 0 — PASS digital**, com PATH local, CFG_CXXFLAGS_PCH_I=-include e M2_VERILATOR_FLAGS=--no-assert-case. Todos os cenários básicos passaram; M2 terminou em 39424204 ciclos, 3/3 frames, 1890 leituras conferidas sem erro e 37547 amostras sem erro. Resultados M2 são exclusivamente do modelo hipotético legado.
- **M4 integrado final — PASS:** 19 palavras emitidas e aplicadas (assertion de igualdade), 0 commits de leitura, 6/6 frames, 33600 amostras HDMI iguais ao mixer/modelo, zero erros HDMI e SDRAM; 35280000 ciclos.
- **selftest_final.log / exit 0 — PASS independente:** zero operações CN2, autoteste=1, MD=0, 3/3 frames, 14400 amostras, zero erros HDMI/SDRAM.
- **m42test.log / exit 0 — PASS dirigido final:** inclui referência explícita de fase à borda negativa do clock e contadores da tabela. Este teste foi repetido após o início da suíte longa para incluir a última melhoria de referência de fase; nenhuma alteração RTL ocorreu após síntese/P&R.
- **tang.log / exit 0 — PASS build/P&R**, bitstream em artifacts/. Isso não autoriza conexão física.
- **Hardware, pinagem VA6, áudio PCM1808 real, taxa sustentada e leitura física — BLOCKED.** Zero capturas reais disponíveis. Na execução original, a auditoria M4.1 e os esquemas estavam indisponíveis. Foram posteriormente recebidos e confrontados em CONFRONTO_DOCUMENTAL.md; continuam ausentes o esquema específico VA6 e as capturas reais.

Os hashes dos arquivos de núcleo preservados são registrados em preserved_core_hashes.json (estado entregue; não inventam um commit ou hash histórico inexistente). Coverage funcional em functional_coverage.json. Todos os arquivos da entrega são cobertos por SHA256SUMS; o snapshot de fontes também tem SOURCE_SHA256SUMS.

## Adendo documental após recebimento dos anexos

Auditoria M4.1 e duas folhas PDF lidas e inspecionadas visualmente. Nenhum RTL, teste, CST, fonte de clock ou bitstream foi alterado nesta revisão documental; os resultados de execução acima mantêm seu escopo original. Não se repetiram síntese/regressões por uma mudança exclusivamente documental. A revisão não converte qualquer BLOCKED físico em PASS. Hash do prebuilt histórico foi comparado à auditoria; ver CONFRONTO_DOCUMENTAL.md. Os manifestos da entrega foram regenerados e verificados.
