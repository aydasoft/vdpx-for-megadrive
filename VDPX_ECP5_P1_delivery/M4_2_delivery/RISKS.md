# Riscos e gates M4.2

| Risco | Estado | Evidência necessária para fechar |
|---|---|---|
| Auditoria M4.1 e folhas PAL VA4/Model 2 recebidas | revisão documental concluída | ver CONFRONTO_DOCUMENTAL.md; esquema específico VA6 ainda ausente |
| Pinagem japonesa VA6 desconhecida | BLOCKED físico | continuidade, fotos e esquema da revisão |
| CDC de barramento multibit | BLOCKED físico | setup/hold medidos após tradutores; análise CDC/MTBF; simulação digital não modela metastabilidade |
| Sem backpressure CN2 | mitigado para rajada finita; sustentado BLOCKED | limite superior demonstrado de serviço para todas as classes/SDRAM/arbitragem |
| Escrita byte indistinguível | restrição software | somente words alinhadas; captura de /LWR e /UWR antes de suportar bytes |
| RESET descarta fila e transação em curso | definido | reset simultâneo do core; software reinicializa estado e orçamento |
| Leitura e /CAS0 | desabilitada | evidência do strobe, turnaround, atrasos min/max, prova de exclusão de drivers |
| FIFO cheia | drop-new + flag sticky local | LED de erro; host não recebe confirmação nem deve ignorar orçamento |
| MCLK fracionário PCM1808 | BLOCKED áudio externo | clock limpo/síncrono validado e ensaio analógico; média correta não prova qualidade |
| Artefato M4.1 prebuilt | não seguro para CN2 | não gravar como M4.2; gerar novo e conferir hash |
| Modelo 245 | só funcional | não cobre SI, alimentação em rampa, thresholds ou falhas físicas |

Nenhum PASS de regressão, síntese ou P&R é PASS físico. Não há medições de hardware nesta entrega.

O ROM m68k/main.c continua sendo o programa de regressão M2 e faz leituras; não é ROM de produção M4.2. scripts/m42_credit_example.h fornece somente o orçamento de uma época write-only. A integração em jogo/ROM real exige implementar os intervalos medidos, inicialização e política de reinício; permanece BLOCKED junto da qualificação física.
