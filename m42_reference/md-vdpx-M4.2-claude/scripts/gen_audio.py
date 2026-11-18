#!/usr/bin/env python3
"""Cenas de áudio da M3: música de demonstração, teste aleatório e memória de samples."""
import math
import os
import random
import sys

from vdpx import (Scene, T_SMEM, T_APU, DATA, TGT, INC, ADDR, AHI, MODE,
                  PCM_CTRL, PCM_START_L, PCM_START_H, PCM_LEN, PCM_LOOP, PCM_PITCH, PCM_VOL,
                  WAV_CTRL, WAV_FREQ, WAV_VOL, APU_WAVE, APU_MASTER, APU_EXTVOL,
                  pcm_pitch, wav_freq, vol)

OUT = sys.argv[1] if len(sys.argv) > 1 else "../scenes"


def s8(v):
    return max(-128, min(127, int(round(v)))) & 0xFF


def pack8(samples):
    """amostras de 8 bits -> words big-endian (como o 68000 escreve)"""
    if len(samples) % 2:
        samples = samples + [0]
    return [(samples[i] << 8) | samples[i + 1] for i in range(0, len(samples), 2)]


def pcm_ch(c):
    return c * 8


def wav_ch(k):
    return (8 + k) * 8


def wave_nibbles(fn):
    nib = [max(0, min(15, int(round(8 + 7.5 * fn(i / 32))))) for i in range(32)]
    return [(nib[4 * i] << 12) | (nib[4 * i + 1] << 8) | (nib[4 * i + 2] << 4) | nib[4 * i + 3]
            for i in range(8)]


def make_samples():
    rnd = random.Random(7)
    kick = []
    ph = 0.0
    for n in range(12000):
        t = n / 48000
        f = 45 + 140 * math.exp(-t * 25)
        ph += 2 * math.pi * f / 48000
        kick.append(s8(127 * math.sin(ph) * math.exp(-t * 9)))
    snare = []
    for n in range(9000):
        t = n / 48000
        v = (rnd.uniform(-1, 1) * 0.8 + 0.4 * math.sin(2 * math.pi * 185 * t)) * math.exp(-t * 18)
        snare.append(s8(127 * v))
    bass = [s8(110 * (2 * (i / 64) - 1) + 15 * math.sin(2 * math.pi * i / 64)) for i in range(64)]
    return kick, snare, bass


NOTE = {n: i for i, n in enumerate(["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"])}


def hz(name):
    """'A4' -> 440 Hz"""
    n, o = name[:-1], int(name[-1])
    return 440.0 * 2 ** ((NOTE[n] + 12 * (o - 4) - 9) / 12)


# ----------------------------------------------------------------- demo
def scene_music():
    s = Scene()
    s.comment("M3: música de demonstração (PCM: bumbo, caixa, baixo em loop; wavetable: melodia, arpejo; ruído: chimbal)")
    kick, snare, bass = make_samples()
    A_KICK, A_SNARE, A_BASS = 0x0000, 0x4000, 0x8000          # endereços de byte
    s.smem(A_KICK // 2, pack8(kick))
    s.smem(A_SNARE // 2, pack8(snare))
    s.smem(A_BASS // 2, pack8(bass))
    waves = (wave_nibbles(lambda x: math.sin(2 * math.pi * x)) +
             wave_nibbles(lambda x: 1 if x < 0.25 else -1) +
             wave_nibbles(lambda x: 4 * x - 1 if x < 0.5 else 3 - 4 * x) +
             wave_nibbles(lambda x: 2 * x - 1))
    s.apu(APU_WAVE, waves)
    # canais PCM: 0 bumbo, 1 caixa, 2 baixo (loop)
    s.apu(pcm_ch(0) + 1, [A_KICK & 0xFFFF, A_KICK >> 16, len(kick), 0, pcm_pitch(1.0), vol(220)])
    s.apu(pcm_ch(1) + 1, [A_SNARE & 0xFFFF, A_SNARE >> 16, len(snare), 0, pcm_pitch(1.0), vol(150, 170)])
    s.apu(pcm_ch(2) + 1, [A_BASS & 0xFFFF, A_BASS >> 16, 64, 0, 0, vol(0)])
    s.apu(pcm_ch(2), 3)                                          # key on + loop
    # wavetable: 8 = melodia (onda 0, seno), 9 = arpejo (onda 1, quadrada), 10 = chimbal (ruído)
    s.apu(wav_ch(0) + 1, [0, vol(0)])
    s.apu(wav_ch(1) + 1, [0, vol(0)])
    s.apu(wav_ch(2) + 1, [wav_freq(2900), vol(0)])
    s.apu(wav_ch(0), 1); s.apu(wav_ch(1), 1); s.apu(wav_ch(2), 3)
    s.apu(APU_MASTER, vol(200))
    s.apu(APU_EXTVOL, vol(0))
    s.adc(0, 0, 0)
    s.samples(64)

    bpm, steps = 132, 32
    step = 48000 * 60 / bpm / 4
    sub = int(step // 4)
    chords = [["A3", "C4", "E4"], ["F3", "A3", "C4"], ["C4", "E4", "G4"], ["G3", "B3", "D4"]]
    bassn = ["A1", "F1", "C2", "G1"]
    melody = ["E5", None, "A4", "C5", "B4", None, "A4", "G4",
              "F4", None, "A4", "C5", "E5", "D5", "C5", None,
              "G4", None, "C5", "E5", "D5", None, "C5", "B4",
              "B4", "C5", "D5", None, "G4", "A4", "B4", None]
    s.rec("m3_musica")
    for i in range(steps):
        bar = (i // 8) % 4
        if i % 8 in (0, 3, 6) or (i % 16 == 14):
            s.apu(pcm_ch(0), 1)                                   # bumbo
        if i % 8 == 4:
            s.apu(pcm_ch(1), 1)                                   # caixa
        if i % 8 == 0:
            f = hz(bassn[bar])
            s.apu(pcm_ch(2) + PCM_PITCH, [pcm_pitch(f * 64 / 48000), vol(170)])
        m = melody[i]
        if m:
            s.apu(wav_ch(0) + WAV_FREQ, [wav_freq(hz(m)), vol(120)])
        arp = chords[bar][i % 3]
        s.apu(wav_ch(1) + WAV_FREQ, [wav_freq(hz(arp) * 2), vol(45, 25)])
        for k in range(4):                                        # envelopes por software
            if k == 0:
                s.apu(wav_ch(2) + WAV_VOL, vol(30 if i % 2 else 55))
            elif k == 1:
                s.apu(wav_ch(2) + WAV_VOL, vol(0))
            if m:
                s.apu(wav_ch(0) + WAV_VOL, vol(max(0, 120 - 25 * k)))
            s.apu(wav_ch(1) + WAV_VOL, vol(max(0, 45 - 12 * k), max(0, 25 - 6 * k)))
            s.samples(sub)
    # final: acorde e fade
    s.apu(wav_ch(0) + WAV_FREQ, [wav_freq(hz("A4")), vol(110)])
    s.apu(pcm_ch(0), 1)
    for k in range(12):
        s.apu(APU_MASTER, vol(max(0, 200 - 17 * k)))
        s.samples(2000)
    s.stoprec()
    return s


# ----------------------------------------------------------------- áudio do Mega Drive
def scene_md_audio():
    s = Scene()
    s.comment("M3: áudio do Mega Drive pelo ADC (SL2/SR2) misturado com uma voz wavetable")
    s.apu(APU_WAVE, wave_nibbles(lambda x: math.sin(2 * math.pi * x)))
    s.apu(wav_ch(0) + 1, [wav_freq(880), vol(60, 0)])
    s.apu(wav_ch(0), 1)
    s.apu(APU_MASTER, vol(255))
    s.adc(220, 330, 9000)              # "FM do Mega Drive": 220 Hz à esquerda, 330 Hz à direita
    s.rec("m3_md_mix")
    s.samples(12000)
    s.apu(APU_EXTVOL, vol(0x40, 0xC0))  # metade à esquerda, 1,5x à direita
    s.samples(12000)
    s.adc(220, 330, 30000)             # perto do fundo de escala: testa a saturação
    s.apu(APU_EXTVOL, vol(0xFF))
    s.samples(6000)
    s.stoprec()
    return s


# ----------------------------------------------------------------- aleatório
def scene_audio_random(seed):
    rnd = random.Random(1000 + seed)
    s = Scene()
    s.comment(f"M3: APU aleatória seed={seed}")
    s.smem(0, [rnd.getrandbits(16) for _ in range(4096)])
    s.smem((1 << 20) - 1024, [rnd.getrandbits(16) for _ in range(1024)])     # fim da memória
    s.apu(APU_WAVE, [rnd.getrandbits(16) for _ in range(64)])
    s.adc(rnd.choice([110, 997]), rnd.choice([0, 333, 1500]), rnd.randrange(1000, 32768))
    for seg in range(6):
        regs = []
        for c in range(8):
            start = rnd.choice([rnd.randrange(0, 8192), (2 << 20) - rnd.randrange(1, 2048),
                                rnd.getrandbits(23)])
            ln = rnd.choice([0, 1, rnd.randrange(2, 64), rnd.randrange(2, 64), rnd.randrange(64, 3000), 65535])
            lp = rnd.randrange(0, max(1, ln + 2))
            ctrl = (1 if rnd.random() < 0.8 else 0) | (2 if rnd.random() < 0.5 else 0)
            regs = [ctrl, start & 0xFFFF, (start >> 16) & 0x7F, ln, lp,
                    rnd.choice([0, 1, 0x1000, rnd.randrange(0x0400, 0x3000), rnd.getrandbits(16)]),
                    rnd.getrandbits(16), 0]
            s.apu(pcm_ch(c), regs)
        for k in range(8):
            s.apu(wav_ch(k), [rnd.getrandbits(2), rnd.getrandbits(16), rnd.getrandbits(16)])
        s.apu(APU_MASTER, [rnd.getrandbits(16), rnd.getrandbits(16)])
        s.samples(rnd.randrange(200, 3000))
        for _ in range(rnd.randrange(0, 20)):                 # mudanças no meio do segmento
            s.apu(rnd.randrange(0, 196), rnd.getrandbits(16))
            if rnd.random() < 0.3:
                s.samples(rnd.randrange(1, 50))
    s.samples(500)
    return s


# ----------------------------------------------------------------- memória de samples
def scene_smem_readback():
    rnd = random.Random(5)
    s = Scene()
    s.comment("M3: leitura da memória de samples pela porta DATA (alvo 5), com vai-um em ACC_ADDR_HI")
    data = [rnd.getrandbits(16) for _ in range(300)]
    s.smem(0x1FF80, data)                     # cruza 0x1FFFF -> 0x20000
    s.reg(TGT, T_SMEM); s.reg(INC, 1); s.reg(AHI, 1); s.reg(ADDR, 0xFF80)
    for _ in range(300):
        s.r(DATA)
    s.r(4)                                    # REG_SEL... (não determinístico é ignorado)
    s.w(2, AHI); s.r(3)                       # ACC_ADDR_HI depois do vai-um
    s.samples(50)
    return s


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    scene_music().save(f"{OUT}/audio_musica.scn")
    scene_md_audio().save(f"{OUT}/audio_md.scn")
    for i in range(4):
        scene_audio_random(i).save(f"{OUT}/audio_rand{i}.scn")
    scene_smem_readback().save(f"{OUT}/audio_smem.scn")
    print("cenas de áudio geradas em", OUT)
