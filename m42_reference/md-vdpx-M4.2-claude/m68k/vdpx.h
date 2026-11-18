/* MD-VDPX: acesso pelo 68000 (especificação M0, seção 2) */
#ifndef VDPX_H
#define VDPX_H

typedef unsigned short u16;
typedef signed short   s16;
typedef unsigned char  u8;

#ifndef VDPX_BASE
#define VDPX_BASE 0xA12000      /* janela /FDC da porta de expansão ($A12000-$A120FF) */
#endif

#define VX_PORT(o)   (*(volatile u16 *)(VDPX_BASE + (o)))
#define VX_DATA      VX_PORT(0x0)
#define VX_STATUS    VX_PORT(0x2)
#define VX_REGSEL    VX_PORT(0x4)
#define VX_REGDATA   VX_PORT(0x6)
#define VX_VCOUNT    VX_PORT(0x8)
#define VX_HCOUNT    VX_PORT(0xA)
#define VX_ID        VX_PORT(0xC)

/* registradores internos */
enum { VX_MODE = 0, VX_BG, VX_ABASE, VX_BBASE, VX_PSIZE, VX_AX, VX_AY, VX_BX, VX_BY,
       VX_TBASE, VX_SMODE, VX_HSBASE, VX_TGT, VX_ADDR, VX_INC, VX_AHI };
/* alvos da porta DATA */
enum { VX_VRAM = 0, VX_CRAM, VX_VSRAM, VX_SAT, VX_APU, VX_SMEM };
/* bits de STATUS */
#define VX_ST_VBLANK  0x0001
#define VX_ST_HBLANK  0x0002
#define VX_ST_ROVF    0x0004
#define VX_ST_SPROVF  0x0008
/* bits de SMODE */
#define VX_SM_A_HLINE 1
#define VX_SM_B_HLINE 2
#define VX_SM_A_VCOL  4
#define VX_SM_B_VCOL  8

static inline void vx_reg(u16 r, u16 v) { VX_REGSEL = r; VX_REGDATA = v; }

static inline void vx_access(u16 tgt, u16 addr, u16 inc)
{
    vx_reg(VX_TGT, tgt);
    vx_reg(VX_INC, inc);
    vx_reg(VX_ADDR, addr);
}

static inline void vx_upload(u16 tgt, u16 addr, const u16 *src, u16 n)
{
    vx_access(tgt, addr, 1);
    while (n--) VX_DATA = *src++;
}

/* entrada de nametable (2 words) */
#define VX_NT0(tile, hf, vf)  ((u16)((tile) | ((hf) << 14) | ((vf) << 15)))
#define VX_NT1(pal, pri)      ((u16)((pal) | ((pri) << 4)))

/* sprite (4 words); w, h em tiles 1..8 */
#define VX_SPR0(y, w, h)      ((u16)(((y) & 0x3FF) | (((h) - 1) << 10) | (((w) - 1) << 13)))
#define VX_SPR1(x, pal, pri)  ((u16)(((x) & 0x3FF) | ((pal) << 11) | ((pri) << 15)))
#define VX_SPR2(tile, hf, vf) ((u16)((tile) | ((hf) << 14) | ((vf) << 15)))

/* espera o início do próximo vblank */
static inline void vx_wait_vblank(void)
{
    while (VX_STATUS & VX_ST_VBLANK) ;
    while (!(VX_STATUS & VX_ST_VBLANK)) ;
}

/* ------------------------------------------------------------------ áudio (APU, M3) */
/* canais PCM 0..7 e wavetable 8..15: registradores a partir de canal*8 */
enum { VX_PCM_CTRL = 0, VX_PCM_START_L, VX_PCM_START_H, VX_PCM_LEN, VX_PCM_LOOP,
       VX_PCM_PITCH, VX_PCM_VOL };
enum { VX_WAV_CTRL = 0, VX_WAV_FREQ, VX_WAV_VOL };
#define VX_APU_WAVE    128     /* onda w: 128 + w*8, 8 words de 4 nibbles */
#define VX_APU_MASTER  192
#define VX_APU_EXTVOL  193     /* volume do áudio do próprio Mega Drive (ADC), 0x80 = 1,0 */
#define VX_APU_STATUS  194
#define VX_PCM_KEY     1
#define VX_PCM_LOOPF   2
#define VX_WAV_EN      1
#define VX_WAV_NOISE   2
#define VX_VOL(l, r)   ((u16)(((l) << 8) | (r)))

/* escreve n registradores da APU a partir de reg (valem a partir do próximo tick de 48 kHz) */
static inline void vx_apu_write(u16 reg, const u16 *v, u16 n)
{
    vx_access(VX_APU, reg, 1);
    while (n--) VX_DATA = *v++;
}
static inline void vx_apu_reg(u16 reg, u16 v) { vx_access(VX_APU, reg, 1); VX_DATA = v; }

/* memória de samples: endereço de word de 23 bits */
static inline void vx_smem_upload(unsigned long waddr, const u16 *src, u16 n)
{
    vx_reg(VX_TGT, VX_SMEM);
    vx_reg(VX_INC, 1);
    vx_reg(VX_AHI, (u16)(waddr >> 16));
    vx_reg(VX_ADDR, (u16)waddr);
    while (n--) VX_DATA = *src++;
}

#endif
