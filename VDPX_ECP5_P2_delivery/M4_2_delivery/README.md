# Entrega M4.2

Começar por RELATORIO_TECNICO.md, TEST_REPORT.md e RISKS.md. CONFRONTO_DOCUMENTAL.md incorpora a auditoria e as duas folhas fornecidas posteriormente; references/ preserva os originais, hashes e imagens inspecionadas. Esquema lógico em CN2_WRITE_ONLY_SCHEMATIC.md; contatos VA6 e medições em PINOUT_VA6_TO_CONFIRM.md.

- sources/: snapshot completo de fontes necessárias, incluindo fx68k fixado; não inclui builds/cache.
- baseline/: cópias anteriores dos principais arquivos alterados, somente para auditoria; NÃO sintetizar como M4.2.
- logs/: stdout/stderr completos, exit codes, versões, relatórios de pinos/síntese/P&R e VCD sintético.
- artifacts/: bitstream novo, sem validação física; nome explicita WRITE_ONLY_UNVALIDATED.
- SHA256SUMS: hashes relativos à pasta; verificar com `sha256sum -c SHA256SUMS`.
- scripts/reproduce.sh: executar a partir da raiz do projeto ou de sources/. Requer GCC C++, Icarus, Verilator, toolchain m68k-elf, Python, Yosys, nextpnr-himbaechel e Apycula. Não grava hardware.

O script usa `M2_VERILATOR_FLAGS=--no-assert-case` somente no fx68k legado para assertions implícitas de case antes de reset (ver TEST_REPORT.md) e `CFG_CXXFLAGS_PCH_I=-include` para contornar configuração incompleta do pacote local Verilator/GCC. Dependências, versões efetivas e revisão fx68k constam nos logs. Em outra máquina, configurar PATH correspondente; não há promessa de bitstream byte-idêntico com versões distintas.

Não usar o prebuilt histórico M4.1 com CN2. Nenhum arquivo desta entrega contém medições reais de hardware.
