#!/usr/bin/env python3
"""Generate a small messy sample library for smoke tests: mixed rates, depths, channels, names."""
import math, os, struct, subprocess, sys

root = sys.argv[1]

def wav(path, rate=44100, bits=16, ch=2, secs=0.4, freq=220.0):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    n = int(rate * secs)
    frames = bytearray()
    for i in range(n):
        v = 0.6 * math.sin(2 * math.pi * freq * i / rate)
        for _ in range(ch):
            if bits == 16:
                frames += struct.pack("<h", int(v * 32767))
            elif bits == 24:
                frames += int(v * 8388607).to_bytes(3, "little", signed=True)
            else:
                frames += struct.pack("<B", int(v * 127 + 128))
    ba = ch * bits // 8
    hdr = b"RIFF" + struct.pack("<I", 36 + len(frames)) + b"WAVE"
    hdr += b"fmt " + struct.pack("<IHHIIHH", 16, 1, ch, rate, rate * ba, ba, bits)
    hdr += b"data" + struct.pack("<I", len(frames))
    with open(path, "wb") as f:
        f.write(hdr + frames)

files = [
    ("Kicks/Kick 01.wav", 44100, 16, 2), ("Kicks/Kick 02 (hard).wav", 48000, 24, 2),
    ("Kicks/Kïck_é 03 🔥.wav", 96000, 24, 1), ("Snares/Snare  01.wav", 44100, 8, 1),
    ("Snares/Sub Folder/Snare 02.wav", 22050, 16, 2), ("Hats/hat:01?.wav", 44100, 16, 1),
    ("Loops/Loop 90bpm.wav", 48000, 16, 2), ("root sample.wav", 44100, 24, 2),
]
for rel, r, b, c in files:
    wav(os.path.join(root, rel), r, b, c)

# Compressed / other containers via afconvert (macOS)
src = os.path.join(root, "Kicks/Kick 01.wav")
conv = [
    ("Converted/kick.m4a", ["-f", "m4af", "-d", "aac"]),
    ("Converted/kick.aif", ["-f", "AIFF", "-d", "BEI16"]),
    ("Converted/kick.caf", ["-f", "caff", "-d", "LEI24"]),
    ("Converted/kick.flac", ["-f", "flac", "-d", "flac"]),
    ("Converted/kick alac.m4a", ["-f", "m4af", "-d", "alac"]),
]
for rel, args in conv:
    out = os.path.join(root, rel)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    r = subprocess.run(["afconvert", *args, src, out], capture_output=True, text=True)
    print(rel, "ok" if r.returncode == 0 else "FAILED " + r.stderr.strip())

with open(os.path.join(root, "readme.txt"), "w") as f:
    f.write("not audio")
with open(os.path.join(root, "Kicks/broken.wav"), "wb") as f:
    f.write(b"RIFF\x00\x00garbage")
print("library ready:", root)

# Bulk: ~900 files across folders (several probe batches), plus MP3s if lame is available
import shutil
lame = shutil.which("lame")
for i in range(880):
    folder = ["Drums/Kicks", "Drums/Snares", "Drums/Hats", "Perc", "FX/Risers", "Loops"][i % 6]
    rate = [44100, 48000, 96000, 22050][i % 4]
    path = os.path.join(root, "Bulk", folder, f"Sample {i:03d}.wav")
    wav(path, rate, [16, 24][i % 2], 1 + (i % 2), secs=0.05, freq=110 + i)
    if lame and i % 30 == 0:
        mp3 = path[:-4] + ".mp3"
        subprocess.run([lame, "--quiet", "-b", "192", path, mp3])
for i in range(250):
    with open(os.path.join(root, "Bulk", f"notes {i}.txt"), "w") as f:
        f.write("x")
print("bulk done; lame:", bool(lame))
