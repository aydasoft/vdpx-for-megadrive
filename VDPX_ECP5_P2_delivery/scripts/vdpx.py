"""Helper para gerar scripts de cena (.scn) da MD-VDPX.

Cada método emite as mesmas operações de barramento que um programa 68000
faria (move.w para as portas), então as cenas servem de referência para o
código em C/asm da M2.
"""

DATA, STATUS, REG_SEL, REG_DATA, VCOUNT, HCOUNT, ID = range(7)

MODE, BG, ABASE, BBASE, PSIZE, AX, AY, BX, BY, TBASE, SMODE, HSBASE = range(12)
TGT, ADDR, INC, AHI = 12, 13, 14, 15
T_VRAM, T_CRAM, T_VSRAM, T_SAT, T_APU, T_SMEM = 0, 1, 2, 3, 4, 5
T_DMA = 6                       # P2: DMA registers (DMA_REGISTER_MAP.md)
DMA_FILL, DMA_COPY, DMA_PATTERN, DMA_CANCEL = 1, 2, 3, 4
DMA_VSYNC = 8

# APU (alvo 4)
PCM_CTRL, PCM_START_L, PCM_START_H, PCM_LEN, PCM_LOOP, PCM_PITCH, PCM_VOL = range(7)
WAV_CTRL, WAV_FREQ, WAV_VOL = range(3)
APU_WAVE, APU_MASTER, APU_EXTVOL, APU_STATUS = 128, 192, 193, 194


def pcm_pitch(ratio):
    """razão de reprodução (1.0 = 48 kHz) -> PITCH 4.12"""
    return max(0, min(0xFFFF, int(round(ratio * 4096))))


def wav_freq(hz):
    """frequência da nota -> FREQ (fase de 20 bits, 32 passos por ciclo)"""
    return max(0, min(0xFFFF, int(round(hz * (1 << 20) / 48000))))


def vol(l, r=None):
    return ((l & 255) << 8) | ((l if r is None else r) & 255)

# SMODE bits
SM_A_HLINE, SM_B_HLINE, SM_A_VCOL, SM_B_VCOL = 1, 2, 4, 8


def rgb555(r, g, b):
    """r, g, b em 0..255 -> word RGB555."""
    return ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3)


def nt_entry(tile, pal=0, pri=0, hflip=0, vflip=0):
    """Entrada de nametable de 32 bits -> (word0, word1)."""
    w0 = (tile & 0x3FFF) | (hflip << 14) | (vflip << 15)
    w1 = (pal & 15) | ((pri & 1) << 4)
    return w0, w1


def sprite(x, y, w, h, tile, pal=0, pri=0, hflip=0, vflip=0, enable=1):
    """Entrada da SAT (4 words). w, h em tiles (1..8); x, y com sinal (-512..511).
    Os tiles do sprite são em ordem de coluna (como no MD): tile + col*h + linha."""
    w0 = (y & 0x3FF) | ((h - 1) << 10) | ((w - 1) << 13)
    w1 = (x & 0x3FF) | ((pal & 15) << 11) | ((pri & 1) << 15)
    w2 = (tile & 0x3FFF) | (hflip << 14) | (vflip << 15)
    w3 = enable & 1
    return [w0, w1, w2, w3]


def tile_words(pixels):
    """pixels: lista de 64 nibbles (linha a linha) -> 16 words."""
    out = []
    for r in range(8):
        row = pixels[r * 8:(r + 1) * 8]
        out.append((row[0] << 12) | (row[1] << 8) | (row[2] << 4) | row[3])
        out.append((row[4] << 12) | (row[5] << 8) | (row[6] << 4) | row[7])
    return out


class Scene:
    def __init__(self):
        self.lines = []

    def comment(self, txt):
        self.lines.append(f"# {txt}")

    def w(self, a, d):
        self.lines.append(f"w {a:x} {d & 0xFFFF:x}")

    def r(self, a):
        self.lines.append(f"r {a:x}")

    def reg(self, idx, val):
        self.w(REG_SEL, idx)
        self.w(REG_DATA, val)

    def mem_write(self, target, addr, words, inc=1):
        self.reg(TGT, target)
        self.reg(INC, inc)
        self.reg(ADDR, addr)
        for v in words:
            self.w(DATA, v)

    def vram(self, addr, words):
        self.mem_write(T_VRAM, addr, words)

    def cram(self, idx, words):
        self.mem_write(T_CRAM, idx, words)

    def apu(self, reg, vals):
        """escreve registradores da APU a partir de 'reg' (aplicados no próximo tick de 48 kHz)"""
        if isinstance(vals, int):
            vals = [vals]
        self.mem_write(T_APU, reg, vals)

    def smem(self, word_addr, words):
        """memória de samples (alvo 5): endereço de word de 23 bits"""
        self.reg(TGT, T_SMEM)
        self.reg(INC, 1)
        self.reg(AHI, word_addr >> 16)
        self.reg(ADDR, word_addr & 0xFFFF)
        for v in words:
            self.w(DATA, v)

    # ---- P2: DMA (write-only protocol: parameters, then COMMAND commits them atomically)
    def dma(self, op, dst=0, length=0, src=0, v0=0, v1=0, vsync=False, tag=0, regs=None):
        """Programa os parâmetros (índices 0..5) e escreve COMMAND (7). 'regs' limita os
        índices escritos (para testar comandos incompletos); o índice 6 recebe 0 (ignorado)."""
        vals = [src & 0xFFFF, src >> 16, dst, length, v0, v1, 0]
        self.reg(TGT, T_DMA); self.reg(INC, 1)
        if regs is None:
            self.reg(ADDR, 0)
            for v in vals:
                self.w(DATA, v)
        else:
            for i in regs:
                self.reg(ADDR, i); self.w(DATA, vals[i])
            self.reg(ADDR, 7)
        self.w(DATA, ((tag & 0xFF) << 8) | (DMA_VSYNC if vsync else 0) | op)

    def dma_cmd(self, value):
        """Escreve só o registrador COMMAND (ex.: CANCEL, ou op inválida)."""
        self.reg(TGT, T_DMA); self.reg(ADDR, 7); self.w(DATA, value)

    def dmawait(self):
        self.lines.append("dmawait")

    def dmastat(self):
        self.lines.append("dmastat")

    def adc(self, fl, fr, amp):
        self.lines.append(f"adc {fl} {fr} {amp}")

    def rec(self, name):
        self.lines.append(f"rec {name}")

    def stoprec(self):
        self.lines.append("stoprec")

    def samples(self, n):
        self.lines.append(f"samples {int(n)}")

    def wait(self, n):
        self.lines.append(f"wait {n}")

    def frame(self, name):
        self.lines.append(f"frame {name}")

    def save(self, path):
        with open(path, "w") as f:
            f.write("\n".join(self.lines) + "\n")
