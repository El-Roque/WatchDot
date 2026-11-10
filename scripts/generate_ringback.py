#!/usr/bin/env python3
"""Generate WatchDot's original one-second ringback using two sine waves.

This resource is generated from mathematical oscillators, not sampled from an app.
Playback adds three seconds of silence between repetitions.
"""
from pathlib import Path
import math
import struct
import wave

path = Path(__file__).resolve().parents[1] / 'src/Resources/App/DotRingback.wav'
rate = 16000
frames = bytearray()
for index in range(rate):
    seconds = index / rate
    envelope = min(1.0, seconds / 0.03, (1.0 - seconds) / 0.03)
    sample = 0.14 * envelope * (math.sin(2 * math.pi * 440 * seconds) + math.sin(2 * math.pi * 480 * seconds))
    frames.extend(struct.pack('<h', round(32767 * sample)))
with wave.open(str(path), 'wb') as output:
    output.setnchannels(1)
    output.setsampwidth(2)
    output.setframerate(rate)
    output.writeframes(frames)
print(path.name)
