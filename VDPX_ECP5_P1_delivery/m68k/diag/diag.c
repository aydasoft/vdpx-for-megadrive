/* MD-VDPX M4.2 - ROM de diagnóstico SOMENTE ESCRITA para a porta CN2.
 *
 * Não depende de nenhuma leitura de $A12000 (a placa M4.2 não dirige o barramento).
 * Fases:
 *   1 SONDA     64 leituras de $A12000-$A1200E (o resultado é ignorado: servem para a
 *               sonda da Tang medir /FDC e /CAS0 numa leitura) e 32 escritas de BYTE no
 *               offset reservado $A1200E/F (para ver se /FDWR aparece em escrita de byte)
 *   2 CENA      paletas, tiles, planos e sprites (escritas normais)
 *   3 ESTRESSE  rajadas no pior caso de velocidade do 68000 (MOVE.W/MOVE.L desenrolados)
 *   4 ANIMAÇÃO  bolas, scroll, música; a cor de fundo pisca a cada segundo
 *
 * Build HW (padrão): mostra no vídeo do PRÓPRIO Mega Drive quantas escritas, bytes e
 * leituras foram emitidos, para comparar com o overlay HDMI da Tang ("ESCRITAS ACEITAS").
 * Build SIM (-DSIM): sem VDP; fala com o testbench pela porta $600000.
 */
#include "../vdpx.h"
#include "../assets.h"

typedef unsigned long u32;

/* ------------------------------------------------------------------ contagem das escritas */
static u32 n_words;     /* escritas de word emitidas para $A12000-$A1200E */
static u32 n_bytes;     /* escritas de byte emitidas */
static u32 n_reads;     /* leituras emitidas */
static u16 phase;

#define VXW(port, v)   do { VX_PORT(port) = (u16)(v); n_words++; } while (0)
static void reg(u16 r, u16 v)            { VXW(0x4, r); VXW(0x6, v); }
static void access(u16 tgt, u16 a, u16 inc) { reg(VX_TGT, tgt); reg(VX_INC, inc); reg(VX_ADDR, a); }
static void upload(u16 tgt, u16 a, const u16 *s, u16 n)
{
    access(tgt, a, 1);
    while (n--) VXW(0x0, *s++);
}

#ifdef SIM
/* ------------------------------------------------------------------ simulação */
#define DBG (*(volatile u16 *)0x600000)
static void frame_wait(void)                   /* ~1 quadro (~40 clocks por volta) */
{
    volatile u16 i;
    for (i = 0; i < 3000; i++) ;
}
static void show(void) { }
static void capture(u16 id)
{
    u16 k;
    DBG = 0x1000 | id;
    for (k = 0; k < 4; k++) frame_wait();      /* nenhuma escrita durante o quadro capturado */
}
#else
/* ------------------------------------------------------------------ Mega Drive real: texto no VDP */
#define VDP_DATA  (*(volatile u16 *)0xC00000)
#define VDP_CTRL  (*(volatile u16 *)0xC00004)
#define VDP_CTRL_L (*(volatile u32 *)0xC00004)
static const u16 vdp_regs[] = {
    0x8004, 0x8144, 0x8230, 0x8407, 0x8578, 0x8700, 0x8AFF, 0x8B00,
    0x8C81, 0x8D3F, 0x8F02, 0x9001, 0x9100, 0x9200
};
#include "font_tiles.h"        /* FONT_CHARS, font_tiles[] (gerado por gen_font_tiles.py) */

static void vdp_vram(u16 addr) { VDP_CTRL_L = 0x40000000UL | ((u32)(addr & 0x3FFF) << 16) | (addr >> 14); }
static void vdp_init(void)
{
    u16 i;
    for (i = 0; i < sizeof vdp_regs / 2; i++) VDP_CTRL = vdp_regs[i];
    VDP_CTRL_L = 0xC0000000UL;                 /* CRAM 0 */
    VDP_DATA = 0x0000; VDP_DATA = 0x0EEE; VDP_DATA = 0x00E0; VDP_DATA = 0x00EE;
    vdp_vram(0x0000);                          /* limpa a VRAM inteira (planos, SAT, tiles) */
    for (i = 0; i < 32768; i++) VDP_DATA = 0;
    vdp_vram(0x0020);                          /* tiles 1.. = fonte */
    for (i = 0; i < FONT_WORDS; i++) VDP_DATA = font_tiles[i];
}
static void frame_wait(void)
{
    while (VDP_CTRL & 0x0008) ;                /* sai do vblank atual */
    while (!(VDP_CTRL & 0x0008)) ;             /* espera o próximo */
}
static u16 glyph(char c)
{
    u16 i;
    for (i = 0; FONT_CHARS[i]; i++) if (FONT_CHARS[i] == c) return i + 1;
    return 1;
}
static void text(u16 row, u16 col, const char *s, u16 pal)
{
    vdp_vram(0xC000 + ((row << 6) + col) * 2);
    while (*s) VDP_DATA = (u16)(glyph(*s++) | (pal << 13));
}
static void hex(u16 row, u16 col, u32 v, u16 nd, u16 pal)
{
    static const char hx[] = "0123456789ABCDEF";
    char b[9];
    u16 i;
    for (i = 0; i < nd; i++) b[nd - 1 - i] = hx[(v >> (4 * i)) & 15];
    b[nd] = 0;
    text(row, col, b, pal);
}
static void show(void)
{
    text(2, 2, "MD-VDPX M4.2  DIAGNOSTICO CN2", 0);
    text(3, 2, "SOMENTE ESCRITA EM A12000", 0);
    text(6, 2, "FASE", 0);              hex(6, 22, phase, 1, 0);
    text(8, 2, "WORDS EMITIDAS", 0);    hex(8, 22, n_words, 8, 0);
    text(9, 2, "BYTES EMITIDOS", 0);    hex(9, 22, n_bytes, 8, 0);
    text(10, 2, "WORDS+BYTES", 0);      hex(10, 22, n_words + n_bytes, 8, 0);
    text(11, 2, "LEITURAS EMITIDAS", 0); hex(11, 22, n_reads, 8, 0);
    text(14, 2, "COMPARE COM O OVERLAY HDMI:", 0);
    text(15, 2, "ESCRITAS ACEITAS = WORDS+BYTES", 0);
    text(16, 2, "CICLO S/ FDWR    = LEITURAS", 0);
    text(17, 2, "PERDIDAS         = 0000", 0);
}
static void capture(u16 id) { (void)id; }
#endif

/* ------------------------------------------------------------------ fases */
#define TILE_BASE 0x0000
#define B_BASE    0x4000
#define A_BASE    0x6000
#define HS_BASE   0x7C00
#define SCRATCH   0x3800      /* VRAM não usada: alvo das rajadas de estresse */
#define NBALLS    12

static void phase_probe(void)
{
    u16 i;
    volatile u16 sink;
    phase = 1;
    for (i = 0; i < 64; i++) { sink = VX_PORT((i & 7) << 1); n_reads++; }
    (void)sink;
    for (i = 0; i < 16; i++) { *(volatile u8 *)0xA1200E = (u8)i; n_bytes++; }
    for (i = 0; i < 16; i++) { *(volatile u8 *)0xA1200F = (u8)i; n_bytes++; }
}

static void phase_scene(void)
{
    u16 row, col, t0 = 1;
    phase = 2;
    reg(VX_MODE, 0);
    upload(VX_CRAM, 0, palette, 256);
    upload(VX_VRAM, TILE_BASE, tile_data, TILE_WORDS);
    access(VX_VRAM, B_BASE, 1);
    for (row = 0; row < 32; row++) {
        u16 t = t0;
        for (col = 0; col < 64; col++) {
            VXW(0x0, VX_NT0(t, 0, 0)); VXW(0x0, VX_NT1(0, 0));
            if (++t > 15) t = 1;
        }
        if (++t0 > 15) t0 = 1;
    }
    access(VX_VRAM, A_BASE, 1);
    for (row = 0; row < 32; row++)
        for (col = 0; col < 64; col++) {
            if (row >= 23)      { VXW(0x0, VX_NT0(T_PILLAR, 0, 0)); VXW(0x0, VX_NT1(1, 0)); }
            else if (row == 22) { VXW(0x0, VX_NT0(T_CAP, 0, 0));    VXW(0x0, VX_NT1(1, 1)); }
            else                { VXW(0x0, 0);                       VXW(0x0, 0); }
        }
    access(VX_VRAM, HS_BASE, 1);
    for (row = 0; row < 448; row++) VXW(0x0, 0);
    access(VX_SAT, 0, 1);
    for (row = 0; row < 512; row++) VXW(0x0, 0);
    /* áudio */
    {
        static const u16 kick_regs[6] = { 0, 0, KICK_LEN, 0, 0x1000, VX_VOL(230, 230) };
        reg(VX_TGT, VX_SMEM); reg(VX_INC, 1); reg(VX_AHI, 0); reg(VX_ADDR, 0);
        for (row = 0; row < KICK_WORDS; row++) VXW(0x0, kick_data[row]);
        upload(VX_APU, VX_APU_WAVE, wave_data, 16);
        upload(VX_APU, 0 * 8 + VX_PCM_START_L, kick_regs, 6);
        access(VX_APU, 8 * 8 + VX_WAV_VOL, 1); VXW(0x0, VX_VOL(90, 70));
        access(VX_APU, 9 * 8 + VX_WAV_VOL, 1); VXW(0x0, VX_VOL(40, 55));
        access(VX_APU, 8 * 8 + VX_WAV_CTRL, 1); VXW(0x0, VX_WAV_EN);
        access(VX_APU, 9 * 8 + VX_WAV_CTRL, 1); VXW(0x0, VX_WAV_EN);
        access(VX_APU, VX_APU_MASTER, 1); VXW(0x0, VX_VOL(255, 255));
    }
    reg(VX_TBASE, TILE_BASE); reg(VX_ABASE, A_BASE); reg(VX_BBASE, B_BASE);
    reg(VX_PSIZE, 1 | (1 << 4)); reg(VX_HSBASE, HS_BASE); reg(VX_SMODE, VX_SM_B_HLINE);
    reg(VX_BG, 0); reg(VX_MODE, 1);
}

/* rajadas no pior caso: o 68000 não consegue escrever mais rápido que isto */
static void phase_stress(void)
{
    u16 k;
    phase = 3;
    for (k = 0; k < 4; k++) {
        /* 64 x MOVE.W Dn,(An) na porta DATA, VRAM livre (8 clocks por escrita) */
        access(VX_VRAM, SCRATCH, 1);
        __asm__ volatile(
            "move.l #0xA12000, %%a0\n\t"
            "move.w #0x1234, %%d0\n\t"
            ".rept 64\n\t move.w %%d0, (%%a0)\n\t .endr"
            ::: "a0", "d0", "memory");
        n_words += 64;
        /* 64 x MOVE.W na memória de samples (o caminho mais lento: SDRAM via árbitro da APU) */
        reg(VX_TGT, VX_SMEM); reg(VX_INC, 1); reg(VX_AHI, 0); reg(VX_ADDR, 0x8000);
        __asm__ volatile(
            "move.l #0xA12000, %%a0\n\t"
            "move.w #0x0000, %%d0\n\t"
            ".rept 64\n\t move.w %%d0, (%%a0)\n\t .endr"
            ::: "a0", "d0", "memory");
        n_words += 64;
        /* 32 x MOVE.L em REG_SEL/REG_DATA: duas words coladas (4 clocks entre elas) */
        __asm__ volatile(
            "move.l #0xA12004, %%a0\n\t"
            "move.l #0x00010000, %%d0\n\t"
            ".rept 32\n\t move.l %%d0, (%%a0)\n\t .endr"
            ::: "a0", "d0", "memory");
        n_words += 64;
    }
}

typedef struct { s16 x, y, dx, dy; u16 size, pal; } Ball;
static Ball balls[NBALLS];

static void anim_init(void)
{
    u16 i;
    for (i = 0; i < NBALLS; i++) {
        Ball *b = &balls[i];
        b->x = (s16)(20 + i * 23);
        b->y = (s16)(10 + (i & 3) * 30);
        b->dx = (s16)((i & 1) ? 2 : -3) + (s16)(i & 2);
        b->dy = (s16)(1 + (i & 1) + ((i >> 2) & 1));
        b->size = (i == 0) ? 8 : ((i & 1) ? 4 : 2);
        b->pal = 2 + i;
    }
}

static void anim_frame(u16 f)
{
    u16 i, y;
    access(VX_SAT, 0, 1);
    for (i = 0; i < NBALLS; i++) {
        Ball *b = &balls[i];
        s16 px = (s16)(b->size << 3);
        u16 tile = (b->size == 8) ? T_BALL8 : (b->size == 4) ? T_BALL4 : T_BALL2;
        b->x += b->dx; b->y += b->dy;
        if (b->x < 0)        { b->x = 0;               b->dx = -b->dx; }
        if (b->x > 320 - px) { b->x = (s16)(320 - px); b->dx = -b->dx; }
        if (b->y < 0)        { b->y = 0;               b->dy = -b->dy; }
        if (b->y > 176 - px) { b->y = (s16)(176 - px); b->dy = -b->dy; }
        VXW(0x0, VX_SPR0(b->y, b->size, b->size));
        VXW(0x0, VX_SPR1(b->x, b->pal, 1));
        VXW(0x0, VX_SPR2(tile, 0, 0));
        VXW(0x0, 1);
    }
    access(VX_VRAM, HS_BASE + 1, 2);
    for (y = 0; y < 224; y++) VXW(0x0, (u16)sine[(u16)((y << 1) + (f << 2)) & 255]);
    reg(VX_AX, (u16)(f << 1));
    reg(VX_BG, ((f >> 5) & 1) ? 0x0001 : 0x0000);          /* pisca ~1x por segundo */
    if ((f & 3) == 0) {
        u16 n = (u16)((f >> 2) % NOTES);
        access(VX_APU, 8 * 8 + VX_WAV_FREQ, 1); VXW(0x0, melody_freq[n]);
        access(VX_APU, 9 * 8 + VX_WAV_FREQ, 1); VXW(0x0, bass_freq[n]);
    }
    if ((f & 7) == 0) { access(VX_APU, 0 * 8 + VX_PCM_CTRL, 1); VXW(0x0, VX_PCM_KEY); }
}

int main(void)
{
    u16 f;
#ifndef SIM
    vdp_init();
#else
    DBG = 0xC001;
#endif
    show();
    phase_probe();
    show();
    phase_scene();
    anim_init();
    anim_frame(0);
    show();
    capture(1);                              /* SIM: quadro estático comparado com o modelo */
    phase_stress();
    reg(VX_BG, 0);                           /* desfaz o efeito visual do estresse */
    show();
    phase = 4;
#ifdef SIM
    for (f = 1; f < 16; f++) { anim_frame(f); frame_wait(); }
    capture(2);
    DBG = 0xD000;
    for (;;) ;
#else
    for (f = 1;; f++) {
        frame_wait();
        anim_frame(f);
        show();
    }
#endif
    return 0;
}
