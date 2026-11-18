# Riscos, bloqueios e pendências (ECP5-P2)

Legenda:
- **PASS:** aprovado em simulação/síntese, com evidência em `logs/`.
- **PENDING:** falta hardware.
- **BLOCKED:** depende de algo que não existe.
- **RISCO:** aprovado, mas com hipótese não verificada.

Todos os itens 1–17 da P1 (`docs/p1/RISKS_AND_BLOCKERS.md`) continuam valendo sem mudança. Entre eles: VCCIO,
HDMI elétrico, E/S da SDRAM, PCM1808 e CN2/4245A. Abaixo, apenas o que a P2 acrescenta ou altera.

| # | Item | Status | Detalhe / como fechar |
|---|---|---|---|
| R-P2-1 | Desempenho do DMA em hardware | **PENDING** | Todos os números são de simulação. O COPY depende da fase da SDRAM aprovada na placa. O painel mostra a taxa medida pelo próprio DMA (`HARDWARE_TEST_GUIDE.md` §2). |
| R-P2-2 | Prazo da APU no pior caso | **RISCO baixo** | Medido: 387 de 1041 ciclos (`dma_pcm`). Não há prova formal do pior caso, porque o árbitro é não-preemptivo e a medição cobre os padrões das cenas. Para fechar: monitor de prazo na placa, ou árbitro que reserve janelas para a APU. |
| R-P2-3 | Tearing | **documentado** | O DMA escreve durante a área ativa. Se mexer em tiles/nametables visíveis no mesmo quadro, há tearing. Mitigação: bit VSYNC (comprovado em `dma_vsync`: 0 escritas com o renderizador ocupado). COPY > ~23 mil words não cabe num vblank. |
| R-P2-4 | Protocolo sem leitura | **RISCO de uso** | O 68000 não sabe quando o DMA terminou nem se um comando foi rejeitado. Depende de contar comandos e esperar o limite de tempo (`DMA_REGISTER_MAP.md`). Um software que emita mais de 5 comandos sem esperar perde comandos (REJECT, visível só no painel). Fechar só com uma via de retorno (leitura pela CN2, fora do escopo, ou um sinal/IRQ, que exige hardware). |
| R-P2-5 | Limite de pior caso publicado para o software | **RISCO baixo** | FILL `N + ⌈N/25⌉ + 20`; COPY `16·N + 64`. Derivado do árbitro e ~3× o medido, não provado formalmente. O benchmark fx68k usou espera ainda maior e o TB confirmou o término. |
| R-P2-6 | Ordem CPU × DMA no mesmo endereço | **documentado** | Vale a ordem da porta (CPU antes no mesmo ciclo). O resultado depende do tempo; o software não deve escrever pela CPU onde há DMA pendente. |
| R-P2-7 | Caminho crítico na estatística do DMA | **aceito** | clk_sys 65,3 MHz no pior caso (+30,7 %). Correção simples: registrar antes do `× 1000`. Não aplicada. |
| R-P2-8 | COPY limitado pela SDRAM de página fechada | **limitação** | 19,8 MB/s, abaixo de 25–50 MB/s. Melhorar exige um controlador com rajada ou página aberta. A melhoria é hipótese para a próxima fase, não um resultado. |
| R-P2-9 | Carga inicial dos dados | **limitação de arquitetura** | Os dados do COPY entram na SDRAM pela CN2, ao custo do método A. O DMA só ganha com reuso ou FILL/PATTERN. Fontes locais (flash SPI, ROM do EverDrive) ficaram fora do escopo. |
| R-P2-10 | Tang: BSRAM 44/46 | **RISCO de capacidade** | O RTL comum da P2 cabe e fecha timing (82,3 MHz), mas sobram 2 BSRAM. Nenhum recurso de memória novo cabe na Tang. |
| R-P2-11 | Área comparada nos TBs de placa | **documentado** | O painel cresceu 2 linhas. A comparação pixel a pixel com o painel ligado cobre as linhas de texto 0..18 (era 0..20). O painel é conferido por OCR. |
| R-P2-12 | Leitura durante escrita na mesma posição da VRAM | **documentado** | O valor visto pelo renderizador (antigo/novo) depende do bloco RAM. O conteúdo final é sempre correto. Faz parte do R-P2-3. |
| R-P2-13 | Validação física | **PENDING** | Nenhuma placa usada. `HARDWARE_TEST_GUIDE.md`. |
