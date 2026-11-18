# CN2 write-only — esquema lógico M4.2 (não liberado para fabricação)

Folhas PAL VA4 e Model 2 examinadas em references/; ainda sem esquemático VA6 autenticado neste checkout. Os nomes CN2 abaixo são redes funcionais; os contatos candidatos estão em PINOUT_VA6_TO_CONFIRM.md. Não transferir automaticamente pinagem PAL/Model 2.

```
CN2 VD[7:0]  ---> U1 A[1:8] SN74LVC245APW B[1:8] ---> Tang md_d[7:0]
CN2 VD[15:8] ---> U2 A[1:8] SN74LVC245APW B[1:8] ---> Tang md_d[15:8]
CN2 VA1..3, /FDC, /FDWR, FRES, /CAS0 ---> U3 A1..7 ---> B1..7 ---> Tang inputs
U1/U2/U3: DIR pin 1 diretamente a VCC 3V3 (sem jumper, trilha ou FPGA para inverter)
          /OE pin 19 = RX_DISABLE: pull-up 10 kΩ a 3V3; jumper local para GND habilita recepção
          jumper não toca CN2 nem FPGA; deixar aberto sem console/alimentação validada
          VCC pin 20 = 3V3 Tang; GND pin 10 = comum
          A8 de U3 a GND; B8 NC
          100 nF cerâmico em cada VCC/GND; 4.7 µF local
```

Pinagem PW: A1..A8 = 2..9; B1..B8 = 18..11. U3 canais 1..7 na ordem escrita acima. /CAS0 é observação sem função de direção. Todos os controles são entradas. /LWR e /UWR são pontos de medição, não conectados nesta revisão: software somente MOVE.W alinhado. Escritas byte são incompatíveis e não detectáveis com os sinais hoje usados.

| Alimentação | /OE | DIR | A (console) | B (Tang) |
|---|---|---|---|---|
| 3V3 válida | 0 | 1 fixo | entrada | saída A→B |
| 3V3 válida | 1 | X | alta impedância | alta impedância |
| 0 V | X | X | Ioff | Ioff |
| 3V3 válida | 0 | 0 | saída B→A | entrada; **estado proibido na montagem** |

Não há caminho de saída lógica para o console nesta topologia, mesmo se o firmware Tang tentasse dirigir B: isso causaria conflito somente do lado B, nunca transmissão B→A. O top também declara md_d como input, sem IOBUF de saída. Esta propriedade pressupõe componente correto, ligação correta, alimentação dentro da especificação e ausência de falhas físicas; não é proteção contra curto de montagem.

Usar exatamente componente com entradas tolerantes a 5 V e Ioff; não substituir por HC245/HC688. Ver [TI SN74LVC245A, tabelas elétricas e função](https://www.ti.com/lit/ds/symlink/sn74lvc245a.pdf). Não aplicar 5 V ao VCC do LVC nem diretamente à Tang. Alimentar Tang pelo USB, unir GND verificado; não unir fontes 5 V. Não conectar /DISK, +9 V ou linhas de áudio ao digital. Não colocar pull-ups alimentados pela Tang no lado A/CN2. Sem console, manter RX_DISABLE alto; pulls do CST no lado B estabelecem repouso de FDC/FDWR/CAS0 e FRES. Com recepção habilitada, nenhum A pode flutuar: console deve estar conectado e alimentado. Não hot-plug; verificar corrente com uma fonte desligada. O modelo digital de Ioff não modela rampa de alimentação, correntes nem overshoot.

| /FDC sincronizado | /FDWR sincronizado | ciclo já capturado | ação RTL |
|---|---|---|---|
| 0 | 0 | não, armado | captura uma palavra se espaço; senão overflow sticky |
| 0 | 1 | qualquer | nenhuma; leitura nunca habilitada |
| 1 | 0 | qualquer | nenhuma |
| 1 | 1 | qualquer | rearmar após repouso confirmado |

md_d_oe=0 e rd_commit=0 em todos os casos, inclusive reset. Não existe fallback temporal USE_CAS0=0 no RTL sintetizável. /DTACK não é sinal disponível nem utilizado.
