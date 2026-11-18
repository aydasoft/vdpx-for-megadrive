# Relatório técnico: MD-VDPX ECP5-P2 (DMA/Blitter)

## Objetivo

Mover dados para a VRAM sem o 68000 copiar word a word pela CN2, mantendo a interface somente-escrita, a P1 e os
limites da fase:
- sem segunda CPU;
- VRAM com 64 KiB;
- sem leitura pela CN2;
- target 7 e `REG_SEL` intactos;
- `$A1200E/F` sem uso.

## Conclusões

| Rótulo | Resultado | Evidência |
|---|---|---|
| **DMA FUNCTIONAL PASS** | sim (simulação) | `DMA_TEST_REPORT.md` |
| **DMA PERFORMANCE MEASURED** | sim, **em simulação** (não em hardware) | `DMA_BENCHMARKS.md` |
| **TIMING PASS** | sim: 3/3 sementes, clk_sys 68,18 / 65,47 / 65,33 MHz, margem ≥ 30,7 % | `TIMING_REPORT.md` |
| **AUDIO INTEGRITY PASS** | sim (simulação): 0 amostras erradas, APU ≤ 387/1041 ciclos | `AUDIO_INTEGRITY_REPORT.md` |
| **P2 SIMULATION PASS** | sim: 14/14 etapas com exit 0 + build da Tang | `logs/RUN_SUMMARY.txt` |
| **HARDWARE VALIDATION PENDING** | nenhuma placa usada | `HARDWARE_TEST_GUIDE.md` |

## Decisões de projeto

1. **Porta de escrita própria, renderizador intocado.** A VRAM já era SDP: o renderizador só lê. O DMA divide
   apenas a porta de escrita com a CPU (CPU com prioridade, combinacional). O resultado é impacto zero no tempo de
   renderização, por construção e por medição. A alternativa (o DMA disputar a porta de leitura) teria custado
   ciclos de linha.
2. **SDRAM: APU primeiro, sem preempção.** O DMA só lê a SDRAM e só quando a porta da APU está livre. O controlador
   RMW da P1 não foi alterado; ganhou só a saída `rdata_hi`, que permite trazer 2 words por acesso (a SDRAM já tem
   32 bits): um acesso por par de words (≈ 10 ciclos por par, 5,04 ciclos/word medidos).
3. **Validação total no commit.** Escrever `COMMAND` valida tudo e copia os parâmetros para a fila no mesmo ciclo.
   Comando inválido não escreve nada; não há CLAMP nem wraparound. Fila cheia rejeita: WAIT travaria o barramento e
   estouraria a FIFO da CN2.
4. **Protocolo sem leitura.** O 68000 conta comandos (≤ 5 pendentes) e espera por tempo com limites publicados.
   A observabilidade fica no painel HDMI (estado, op, fila, erros, words, ciclos, MB/s, stalls), sem nenhuma
   leitura pela CN2.
5. **VSYNC opcional por comando**, em vez de bloquear o DMA durante a área ativa. O software escolhe entre
   velocidade e ausência de tearing.
6. **Sem divisor combinacional.** A taxa no painel vem de um divisor sequencial + double dabble. O `× 1000` do
   numerador é registrado e virou o caminho crítico de clk_sys (+30,7 % de margem). Pode ser registrado em mais um
   estágio se for preciso.

## Resultados principais

- **Operações:** FILL, COPY (SDRAM → VRAM), PATTERN e CANCEL (ponto seguro + esvaziamento da fila); STATUS
  interno no painel.
- **Taxas (simulação, 50 MHz):**
  - FILL/PATTERN: 1 ciclo/word (100 MB/s) em todas as condições;
  - COPY: 5,04 ciclos/word (19,8 MB/s) em repouso e com renderização pesada; 5,3 (18,9 MB/s) com 8 vozes PCM;
    5,5 (18,2 MB/s) na placa ECP5 simulada.
  - **25–50 MB/s não foi atingido no COPY.** O limite é a SDRAM de página fechada.
- **68000 × DMA (fx68k):**
  - cópia desenrolada pela CN2: 1,27 MB/s (64 KiB em 51,7 ms);
  - comando de DMA: 39,1 µs de CPU, qualquer tamanho;
  - com os dados já na SDRAM, a VRAM fica pronta até 15,4× mais cedo, e a CPU fica livre ~1320× mais tempo
    (64 KiB);
  - a carga inicial na SDRAM custa o mesmo que o método A, então dado de uso único não ganha com COPY.
- **Renderizador:** tempo de linha idêntico à P1 nas 17 cenas da P1; 55.459 escritas DMA concorrentes com a
  renderização em `dma_render`, quadros iguais ao modelo; **tearing possível** fora do vblank; 0 escritas
  concorrentes com VSYNC (`dma_vsync`).
- **APU:** pior prazo 387/1041 ciclos com DMA (312 nas cenas de áudio sem DMA); 0 amostras erradas em todos os
  bancos de teste.
- **Recursos:** +1.366 COMB (21 %), +660 FF, +22 LUT RAM, +4 EBR (ROM do autoteste dobrada; o DMA usa 0 EBR),
  +2 DSP. Tang: BSRAM 44/46, timing PASS.

## Integridade do processo

- Nenhuma assertiva foi enfraquecida e nenhum modelo de referência foi ajustado para obter PASS.
  - Os modelos ganharam o target 6.
  - A ordem das escritas da CPU na VRAM passou a ser conferida na porta (mais estrito).
  - A área de comparação dos TBs de placa encolheu 2 linhas de texto porque o painel cresceu 2 linhas. O painel
    continua conferido por OCR.
- Os testes negativos foram mantidos e um foi acrescentado: a mutação sem a checagem de fim da VRAM precisa
  falhar, e falha.
- Os números de desempenho saem dos logs por script (`scripts/p2_bench_report.py`). Nenhum valor é medição física.

## Próxima fase (recomendação)

1. **Validar a P1 e depois a P2 na placa** (`HARDWARE_TEST_GUIDE.md`): fase da SDRAM, áudio e a taxa exibida no
   painel. Isso é pré-requisito para tudo o que segue.
2. **Controlador SDRAM com rajada/página aberta para leituras do DMA.** É o maior ganho restante do COPY, e o
   motor do DMA já aceita respostas em par. A meta e o ganho serão medidos, não presumidos.
3. **Fonte local para o COPY** (flash SPI da i9 → SDRAM no boot), para eliminar a carga inicial pela CN2.
4. **Via de retorno para o 68000** (status/IRQ). Depende da interface CN2 validada (pendências da M4.2/P1).
5. Depois disso, decidir pelo orçamento de EBR (60 blocos livres): VRAM de 128 KiB (+32) **ou** sub-CPU com RAM
   (+32). As duas juntas não cabem (`RESOURCE_REPORT.md`).
