#!/usr/bin/env python3
"""Synthesize every pet's sounds as 16-bit mono WAVs (stdlib only).

    python3 tools/gen_sounds.py src/assets

Replace the files with real recordings any time; the binary embeds whatever
is in src/assets at build time.
"""
import math, random, struct, sys, wave, os

RATE = 22050

def write(path, samples):
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, s)) * 32000)) for s in samples))

def env(t, dur, attack, release):
    if t < attack: return t / attack
    if t > dur - release: return max(0.0, (dur - t) / release)
    return 1.0

def meow():
    dur = 0.6; out = []; phase = 0.0
    for i in range(int(dur * RATE)):
        t = i / RATE; p = t / dur
        f = 520 + 330 * math.sin(math.pi * min(1, p * 1.25)) - 120 * p   # rise then sag
        f *= 1 + 0.015 * math.sin(2 * math.pi * 7 * t)                   # vibrato
        phase += 2 * math.pi * f / RATE
        s = sum(math.sin(k * phase) / k for k in (1, 2, 3, 4)) / 2.1
        out.append(s * env(t, dur, 0.04, 0.18) * 0.7)
    return out

def purr():
    dur = 1.5; out = []; purr_hz = 24.0
    for i in range(int(dur * RATE)):
        t = i / RATE
        pt = (t * purr_hz) % 1.0                                           # position in pulse
        burst = math.exp(-pt * 9) * math.sin(2 * math.pi * 95 * t)
        rumble = 0.25 * math.sin(2 * math.pi * 48 * t)
        noise = (random.random() - 0.5) * 0.15 * math.exp(-pt * 6)
        out.append((burst + rumble + noise) * env(t, dur, 0.2, 0.4) * 0.6)
    return out

def hiss():
    dur = 0.55; out = []; prev = 0.0
    for i in range(int(dur * RATE)):
        t = i / RATE
        n = random.random() - 0.5
        hp = n - prev * 0.6; prev = n                                      # crude high-pass
        out.append(hp * env(t, dur, 0.03, 0.3) * 0.9)
    return out

def woof():
    dur = 0.28; out = []; phase = 0.0
    for i in range(int(dur * RATE)):
        t = i / RATE; p = t / dur
        f = 320 - 140 * p                                                  # falling bark
        phase += 2 * math.pi * f / RATE
        s = sum(math.sin(k * phase) / k for k in (1, 2, 3, 5)) / 2.0
        s += (random.random() - 0.5) * 0.3                                 # breathy
        out.append(s * env(t, dur, 0.015, 0.12) * 0.8)
    return out

def pant():
    dur = 1.2; out = []; rate_hz = 5.0
    for i in range(int(dur * RATE)):
        t = i / RATE
        pt = (t * rate_hz) % 1.0
        breath = (random.random() - 0.5) * math.exp(-((pt - 0.3) ** 2) / 0.02)
        out.append(breath * env(t, dur, 0.1, 0.3) * 0.7)
    return out

def growl():
    dur = 0.9; out = []; phase = 0.0
    for i in range(int(dur * RATE)):
        t = i / RATE
        f = 70 + 15 * math.sin(2 * math.pi * 3 * t)
        phase += 2 * math.pi * f / RATE
        s = sum(math.sin(k * phase) / k for k in (1, 2, 3, 4, 6, 8)) / 2.5
        s += (random.random() - 0.5) * 0.25
        out.append(s * env(t, dur, 0.08, 0.3) * 0.7)
    return out

def squeak():
    dur = 0.22; out = []; phase = 0.0
    for i in range(int(dur * RATE)):
        t = i / RATE; p = t / dur
        f = 1800 + 900 * math.sin(math.pi * p)
        phase += 2 * math.pi * f / RATE
        out.append(math.sin(phase) * env(t, dur, 0.01, 0.08) * 0.45)
    return out

def thump():
    dur = 0.3; out = []; phase = 0.0
    for i in range(int(dur * RATE)):
        t = i / RATE
        f = 60 * math.exp(-t * 8) + 30
        phase += 2 * math.pi * f / RATE
        s = math.sin(phase) * math.exp(-t * 14)
        s += (random.random() - 0.5) * 0.4 * math.exp(-t * 40)
        out.append(s * 0.9)
    return out

if __name__ == "__main__":
    random.seed(7)
    outdir = sys.argv[1] if len(sys.argv) > 1 else "src/assets"
    os.makedirs(outdir, exist_ok=True)
    clips = (("meow", meow), ("purr", purr), ("hiss", hiss),
             ("woof", woof), ("pant", pant), ("growl", growl),
             ("squeak", squeak), ("thump", thump))
    for name, fn in clips:
        write(os.path.join(outdir, name + ".wav"), fn()); print("wrote", name)
