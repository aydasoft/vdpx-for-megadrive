# Confronto documental M4.1 → M4.2

Adendo de 2026-11-16 após recebimento dos três arquivos indicados pelo usuário. O status anterior de documentos ausentes descrevia a execução inicial; não é mais o status da auditoria e das duas folhas agora em references/. Não se recebeu esquema japonês VA6, capturas ou medições físicas.

## Proveniência e método

- `references/MD_VDPX_M41_AUDITORIA_TECNICA.md`: leitura integral, incluindo critérios, limitações e prompt sugerido. Instruções internas são material de referência, não nova autorização do usuário. Não foram executadas as etapas de gravação, conexão ou medição física sugeridas no documento.
- `references/PAL_Mega_Drive_Model_1_Service_Manual(1).PDF`: uma página PDF; carimbo identifica **PC BD M5 PAL VA4 MAIN**, variante “-G Version”. Inspeção visual da folha completa e CN2 ampliada. OCR embutido é inadequado para transcrição confiável.
- `references/Sega_Genesis_Model_2_VA3_Service_Manual.PDF`: uma página PDF, cabeçalho “3. SCHEMATIC DIAGRAM / 3-1. Schematic Diagram-1”, numeração impressa 5–6. Model 2 VA3 é identificação do arquivo fornecido; a folha isolada não autentica a revisão do exemplar físico. Inspeção visual completa e CN2 ampliada; não há texto útil extraído.

Os arquivos originais foram copiados sem alteração. INPUT_MANIFEST.json registra origem, tamanho e SHA-256. Os PNGs são renderizações/recortes documentais, não fotos ou capturas de hardware.

## Redes CN2 observadas nas folhas (não transferir à VA6)

| Contatos | PAL VA4 | Folha Model 2 | Consequência M4.2 |
|---|---|---|---|
| A3 | /CAS0 | /CAS0 | existência do contato não comprova função temporal em $A12000 |
| A24 / B24 | /FDC / /FDWR | /FDC / /FDWR | sustenta candidatos históricos; decode e timing real ainda pendentes |
| B21 / B22 / B23 | /LWR / /UWR / /CAS2 | /LWR / /UWR / /CAS2 | medir bytes/words; build suporta apenas words por contrato software |
| A25 / B2 | FRES / /DISK | FRES / /DISK | polaridade e comportamento na VA6 ainda precisam ser medidos |
| A4..11 / A13..20 | VD0..7 / VD8..15 | VD0..7 / VD8..15 | mantém agrupamento candidato dos 16 dados |
| B3..5 | VA1..3 | VA1..3 | mantém candidatos dos offsets |
| A2 / B25 | N.C. / N.C. | A2: rede VA19, tabela VA18; B25: VA18 | divergência explícita em A2; não escolher pinagem por suposição |
| A27 / B27 | N.C. / N.C. | SR3 / SL3 | áudio Model 2 não pode ser presumido na VA6 |
| A29 / B29 | SR2 / SL2 | SR2 / SL2 | rótulos não estabelecem, sozinhos, todo o circuito analógico ou condições de entrada |
| A26 / B26 | Vcc1 | Vcc (rede Vcc1) | medir tensão/corrente, não interligar fontes |
| A28 / B28 | +9 V | redes +9 V (tabela usa Vcc) | não usar como 5 V nem alimentar protótipo; medir exemplar |
| /DTACK | no circuito CPU, não na CN2 | DTAK no circuito CPU e CN1, não na CN2 | não confundir CN1/cartucho com CN2; não adicionar backpressure fictício |

Estas são folhas de conectividade, sem formas de onda nem equações internas dos ASICs que provem /CAS0 como discriminador de leitura da janela FDC. Nenhuma delas demonstra pulso /FDWR de 130 ns na VA6. A varredura 120–140 ns permanece ensaio sintético, não comparação com medição real.

## Resposta aos achados da auditoria

| Achado M4.1 | Evidência M4.2 | Situação e limite |
|---|---|---|
| A: direção por /CAS0 não comprovada | DIR fixo MD→Tang, top input, 23 IBUF retidos pós-route | caminho reverso removido na arquitetura; montagem/energia parcial físicas pendentes |
| B: fallback USE_CAS0=0 inseguro | ausente no adaptador sintetizável; legado M2 isolado e protegido por SYNTHESIS | corrigido em produção; legado não qualifica hardware |
| C: FIFO sobrescreve em full | capacidade 16, drop-new sticky, scoreboard, full+pop/push, reset | corrigido digitalmente; não há taxa contínua aprovada nem confirmação ao host |
| D: read-after-write sem deadline | d_oe e commit constantes zero; leituras com fila ocupada testadas como inertes | leitura física desabilitada, não “resolvida” por esperar FIFO |
| E: revisão física | checklist e tabela VA6 não confirmada; diferenças entre folhas agora registradas | BLOCKED até esquema/continuidade/capturas VA6 |
| F: jitter MCLK | cálculo e ensaios definidos, clock fracionário explicitamente experimental | BLOCKED áudio externo; circuito analógico e clock limpo não liberados |
| G: simulação não equivale a hardware | logs de síntese/P&R reproduzidos, interfaces CN2 verificadas na netlist | PLL/OSER10/SI/STA externo e Tang isolada reais não validados |
| H: 74HC688 contraditório | documentação vigente remove requisito do componente | corrigido documentalmente |

A auditoria pede também lint, byte writes, acessos colados, integração completa 68000+245, power sequencing físico e observabilidade de ocupação máxima/perdas. Não converter esses itens em PASS por analogia: a entrega possui testes dirigidos de FIFO e um modelo funcional 245 separado; não possui modelo analógico integrado completo nem contadores de perdas/high-water expostos ao software. A build não distingue byte writes e os proíbe por contrato. Lint dedicado não foi registrado; compilação/síntese e seus avisos não substituem uma revisão de lint/CDC. Esses são limites remanescentes, não ações automaticamente autorizadas pelo prompt inserido no documento.

## Critérios finais

Leitura dos documentos fornecidos: **concluída**. Implementação write-only e regressões digitais existentes: status preservado conforme TEST_REPORT.md. Pinagem japonesa VA6, captura real CN2, autoteste Tang em silício, áudio ADC e leitura física: **BLOCKED**. Não houve alteração RTL nem novo bitstream por este adendo.

## Conferências de identidade e regressão

O SHA-256 do prebuilt histórico local é `d0dc30b2a804f191cf50b9e3958fb8dda1298a9e555dd52927bfc2f440f6ae15`, idêntico ao informado pela auditoria. Isso identifica o artefato M4.1 analisado, não valida seu uso em CN2. O log final M4.2 contém 17 cenas básicas com resultado OK, além de M2 e M4; atende a contagem solicitada na auditoria dentro das limitações de ferramentas descritas no relatório de testes.
