/* MD-VDPX ECP5-P2 - benchmark 68000 x DMA (co-simulação fx68k, build SIM apenas).
 *
 * Para cada tamanho n (128 .. 32768 words = 256 B .. 64 KiB), com marcadores na porta de
 * depuração $600000 (0xBkii: k = ponto, ii = índice do tamanho) que o testbench marca com o
 * ciclo de 50 MHz em que chegaram:
 *   B0..B1  Método A1: cópia ROM -> VRAM pela CPU, MOVE.W (A0)+,(A1) desenrolado (o mais rápido
 *           que um laço de cópia consegue: 12 clocks do 68000 por word)
 *   B2..B3  Método A2: cópia com laço MOVE.W (A0)+,(A1) / DBRA (22 clocks por word)
 *   B4..B5  carga inicial da memória de samples (alvo 5) com os mesmos dados (A1 de novo):
 *           o DMA não elimina este custo, ele só é pago uma vez para dados reutilizados
 *   B6..B7  Método B: a CPU envia o comando de DMA (COPY memória de samples -> VRAM)
 *   B8      fim da espera fixa (sem leitura): o testbench exige que o DMA já tenha terminado
 * O tempo de execução do DMA vem do evento de fim do próprio DMA (testbench).
 */
#include "../vdpx.h"

#define DBG (*(volatile u16 *)0x600000)
#define VX_DMA 6

static const u16 src[256] = {
#define R4(i) (u16)((i) * 0x9E37u ^ 0x5A5Au), (u16)(((i) + 1) * 0x9E37u ^ 0x5A5Au), \
              (u16)(((i) + 2) * 0x9E37u ^ 0x5A5Au), (u16)(((i) + 3) * 0x9E37u ^ 0x5A5Au)
#define R16(i) R4(i), R4((i) + 4), R4((i) + 8), R4((i) + 12)
#define R64(i) R16(i), R16((i) + 16), R16((i) + 32), R16((i) + 48)
    R64(0), R64(64), R64(128), R64(192)
};

static void reg(u16 r, u16 v) { VX_REGSEL = r; VX_REGDATA = v; }
static void access(u16 tgt, u16 a) { reg(VX_TGT, tgt); reg(VX_INC, 1); reg(VX_ADDR, a); }

/* n words (multiple of 256, or 128) from src[] (repeated) to the DATA port, unrolled */
static void copy_unrolled(u16 n)
{
    u16 blocks = n >= 256 ? n / 256 : 0;
    if (n < 256) {
        __asm__ volatile(
            "lea %0, %%a0\n\t"
            "move.l #0xA12000, %%a1\n\t"
            ".rept 128\n\t move.w (%%a0)+, (%%a1)\n\t .endr"
            :: "m"(src) : "a0", "a1", "memory");
        return;
    }
    __asm__ volatile(
        "move.w %0, %%d1\n\t"
        "subq.w #1, %%d1\n\t"
        "move.l #0xA12000, %%a1\n"
        "1:\n\t"
        "lea %1, %%a0\n\t"
        ".rept 256\n\t move.w (%%a0)+, (%%a1)\n\t .endr\n\t"
        "dbra %%d1, 1b"
        :: "d"(blocks), "m"(src) : "d1", "a0", "a1", "memory");
}

/* the same with a plain DBRA loop (one word per iteration) */
static void copy_loop(u16 n)
{
    u16 blocks = n >= 256 ? n / 256 : 1, per = n >= 256 ? 256 : n;
    __asm__ volatile(
        "move.w %0, %%d1\n\t"
        "subq.w #1, %%d1\n\t"
        "move.l #0xA12000, %%a1\n"
        "1:\n\t"
        "lea %2, %%a0\n\t"
        "move.w %1, %%d0\n\t"
        "subq.w #1, %%d0\n"
        "2:\n\t"
        "move.w (%%a0)+, (%%a1)\n\t"
        "dbra %%d0, 2b\n\t"
        "dbra %%d1, 1b"
        :: "d"(blocks), "d"(per), "m"(src) : "d0", "d1", "a0", "a1", "memory");
}

static void spin(u16 n) { volatile u16 i; for (i = 0; i < n; i++) ; }

int main(void)
{
    static const u16 sizes[6] = {128, 512, 2048, 8192, 16384, 32768};
    u16 i;
    DBG = 0xC001;
    for (i = 0; i < 6; i++) {
        u16 n = sizes[i];
        /* A1 */
        access(VX_VRAM, 0);
        DBG = 0xB000 | i; copy_unrolled(n); DBG = 0xB100 | i;
        /* A2 */
        access(VX_VRAM, 0);
        DBG = 0xB200 | i; copy_loop(n); DBG = 0xB300 | i;
        /* carga inicial da memória de samples (word 0x10000..) */
        reg(VX_TGT, VX_SMEM); reg(VX_INC, 1); reg(VX_AHI, 1); reg(VX_ADDR, 0);
        DBG = 0xB400 | i; copy_unrolled(n); DBG = 0xB500 | i;
        /* B: comando de DMA COPY (fonte 0x10000, destino 0, n words) */
        DBG = 0xB600 | i;
        reg(VX_TGT, VX_DMA); reg(VX_INC, 1); reg(VX_ADDR, 0);
        VX_DATA = 0x0000; VX_DATA = 0x0001;     /* SRC_LO, SRC_HI */
        VX_DATA = 0x0000; VX_DATA = n;          /* DST, LEN */
        VX_DATA = 0; VX_DATA = 0; VX_DATA = 0;  /* VALUE0, VALUE1, (6) */
        VX_DATA = 0x0002 | (i << 8);            /* COMMAND: COPY, tag = i */
        DBG = 0xB700 | i;
        /* espera fixa, sem leitura: limite de pior caso do DMA_ARBITRATION.md (6 ciclos de
         * 50 MHz por word com memória lenta) folgado: ~n/4 voltas de ~1,3 us */
        spin((u16)(n / 4 + 200));
        DBG = 0xB800 | i;
    }
    DBG = 0xD000;
    for (;;) ;
    return 0;
}
