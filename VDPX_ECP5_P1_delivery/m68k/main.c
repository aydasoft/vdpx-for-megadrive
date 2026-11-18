/* M2: programa 68000 que usa a MD-VDPX pela porta de expansão.
 * - confere o ID, sobe paletas/tiles/nametables pela porta DATA
 * - lê de volta VRAM/CRAM e conta erros
 * - anima bolas (sprites), onda por linha no plano B e scroll do plano A
 * - fala com o testbench pela porta de debug $600000 (só simulação)
 */
#include "vdpx.h"
#include "assets.h"

#define DBG (*(volatile u16 *)0x600000)
#define DBG_PROGRESS(n) (DBG = 0xC000 | (n))
#define DBG_ERRORS(n)   (DBG = 0xE000 | (n))
#define DBG_CAPTURE(n)  (DBG = 0x1000 | (n))
#define DBG_DONE()      (DBG = 0xD000)

#define TILE_BASE 0x0000
#define B_BASE    0x4000
#define A_BASE    0x6000
#define HS_BASE   0x7C00

#define NBALLS    12
#define NFRAMES   40

typedef struct { s16 x, y, dx, dy; u16 size, pal; } Ball;
static Ball balls[NBALLS];

static u16 errors;

static void audio_init(void)
{
    static const u16 kick_regs[6] = { 0, 0, KICK_LEN, 0, 0x1000, VX_VOL(230, 230) };
    vx_smem_upload(0, kick_data, KICK_WORDS);
    vx_apu_write(VX_APU_WAVE, wave_data, 16);               /* onda 0 = seno, 1 = quadrada */
    vx_apu_write(0 * 8 + VX_PCM_START_L, kick_regs, 6);     /* PCM 0 = bumbo */
    vx_apu_reg(8 * 8 + VX_WAV_VOL, VX_VOL(90, 70));          /* wav 8 = melodia (seno) */
    vx_apu_reg(9 * 8 + VX_WAV_VOL, VX_VOL(40, 55));          /* wav 9 = baixo (quadrada) */
    vx_apu_reg(8 * 8 + VX_WAV_CTRL, VX_WAV_EN);
    vx_apu_reg(9 * 8 + VX_WAV_CTRL, VX_WAV_EN);
    vx_apu_reg(VX_APU_MASTER, VX_VOL(255, 255));
}

static void audio_frame(u16 f)
{
    if ((f & 3) == 0) {
        u16 n = (u16)(f >> 2);
        if (n >= NOTES) n = NOTES - 1;
        vx_apu_reg(8 * 8 + VX_WAV_FREQ, melody_freq[n]);
        vx_apu_reg(9 * 8 + VX_WAV_FREQ, bass_freq[n]);
    }
    if ((f & 7) == 0)
        vx_apu_reg(0 * 8 + VX_PCM_CTRL, VX_PCM_KEY);         /* bumbo */
}

static void build_planes(void)
{
    u16 row, col, t0 = 1;
    /* plano B 64x32: listras diagonais, tile = 1 + (col + row) mod 15 (sem divisão) */
    vx_access(VX_VRAM, B_BASE, 1);
    for (row = 0; row < 32; row++) {
        u16 t = t0;
        for (col = 0; col < 64; col++) {
            VX_DATA = VX_NT0(t, 0, 0);
            VX_DATA = VX_NT1(0, 0);
            if (++t > 15) t = 1;
        }
        if (++t0 > 15) t0 = 1;
    }
    /* plano A 64x32: chão de colunas */
    vx_access(VX_VRAM, A_BASE, 1);
    for (row = 0; row < 32; row++)
        for (col = 0; col < 64; col++) {
            if (row >= 23)       { VX_DATA = VX_NT0(T_PILLAR, 0, 0); VX_DATA = VX_NT1(1, 0); }
            else if (row == 22)  { VX_DATA = VX_NT0(T_CAP, 0, 0);    VX_DATA = VX_NT1(1, 1); }
            else                 { VX_DATA = 0;                       VX_DATA = 0; }
        }
}

static void check_readback(void)
{
    u16 i;
    vx_access(VX_VRAM, TILE_BASE, 1);
    for (i = 0; i < TILE_WORDS; i++)
        if (VX_DATA != tile_data[i]) errors++;
    vx_access(VX_CRAM, 0, 1);
    for (i = 0; i < 256; i++)
        if (VX_DATA != palette[i]) errors++;
    /* registradores */
    vx_reg(VX_BG, 0x00A5);
    VX_REGSEL = VX_BG;
    if (VX_REGDATA != 0x00A5) errors++;
}

static void init_balls(void)
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

static void update_sprites(void)
{
    u16 i;
    vx_access(VX_SAT, 0, 1);
    for (i = 0; i < NBALLS; i++) {
        Ball *b = &balls[i];
        s16 px = (s16)(b->size << 3);
        b->x += b->dx;
        b->y += b->dy;
        if (b->x < 0)            { b->x = 0;                 b->dx = -b->dx; }
        if (b->x > 320 - px)     { b->x = (s16)(320 - px);   b->dx = -b->dx; }
        if (b->y < 0)            { b->y = 0;                 b->dy = -b->dy; }
        if (b->y > 176 - px)     { b->y = (s16)(176 - px);   b->dy = -b->dy; }
        {
            u16 tile = (b->size == 8) ? T_BALL8 : (b->size == 4) ? T_BALL4 : T_BALL2;
            VX_DATA = VX_SPR0(b->y, b->size, b->size);
            VX_DATA = VX_SPR1(b->x, b->pal, 1);
            VX_DATA = VX_SPR2(tile, 0, 0);
            VX_DATA = 1;                        /* habilitado */
        }
    }
}

static void update_wave(u16 phase)
{
    u16 y;
    vx_access(VX_VRAM, HS_BASE + 1, 2);         /* só a entrada do plano B de cada linha */
    for (y = 0; y < 224; y++)
        VX_DATA = (u16)sine[(u16)((y << 1) + phase) & 255];
}

int main(void)
{
    u16 f;

    DBG_PROGRESS(1);
    if (VX_ID != 0x5658) errors++;

    vx_upload(VX_CRAM, 0, palette, 256);
    vx_upload(VX_VRAM, TILE_BASE, tile_data, TILE_WORDS);
    build_planes();
    /* tabela de hscroll zerada (A e B) */
    vx_access(VX_VRAM, HS_BASE, 1);
    for (f = 0; f < 448; f++) VX_DATA = 0;
    /* SAT: todos desligados */
    vx_access(VX_SAT, 0, 1);
    for (f = 0; f < 512; f++) VX_DATA = 0;
    DBG_PROGRESS(2);

    check_readback();
    DBG_ERRORS(errors);

    vx_reg(VX_TBASE, TILE_BASE);
    vx_reg(VX_ABASE, A_BASE);
    vx_reg(VX_BBASE, B_BASE);
    vx_reg(VX_PSIZE, 1 | (1 << 4));             /* A e B 64x32 */
    vx_reg(VX_HSBASE, HS_BASE);
    vx_reg(VX_SMODE, VX_SM_B_HLINE);
    vx_reg(VX_BG, 0);
    audio_init();
    init_balls();
    update_sprites();
    update_wave(0);
    vx_reg(VX_MODE, 1);
    DBG_PROGRESS(3);

    for (f = 0; f < NFRAMES; f++) {
        vx_wait_vblank();
        update_sprites();
        update_wave((u16)(f << 2));
        vx_reg(VX_AX, (u16)(f << 1));
        audio_frame(f);
        if (f == 1 || f == 20 || f == NFRAMES - 1)
            DBG_CAPTURE(f);
    }
    DBG_DONE();
    for (;;) ;
    return 0;
}
