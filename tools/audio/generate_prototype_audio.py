"""Generate original, disposable FMOD integration fixtures; not the game's soundtrack."""
from pathlib import Path
import math
import struct
import wave

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / 'Audio/ProjectKeynes/Assets/Prototype'
RATE = 24000


def write(name, duration, sample):
    path = OUTPUT / name
    if path.exists():
        raise FileExistsError(f'Refusing to replace existing audio: {path}')
    with wave.open(str(path), 'wb') as stream:
        stream.setparams((1, 2, RATE, 0, 'NONE', 'not compressed'))
        stream.writeframes(b''.join(struct.pack('<h', round(max(-1, min(1, sample(i / RATE))) * 32767))
                                   for i in range(round(duration * RATE))))


if __name__ == '__main__':
    OUTPUT.mkdir(parents=True, exist_ok=True)
    write('base.wav', 8, lambda t: 0.09 * math.sin(2 * math.pi * 110 * t)
          + 0.04 * math.sin(2 * math.pi * 165 * t))
    write('melody.wav', 8, lambda t: 0.08 * math.sin(2 * math.pi * [220, 264, 330, 264][int(t) % 4] * t)
          * math.sin(math.pi * (t % 1)) ** 2)
    write('pulse.wav', 8, lambda t: 0.16 * math.exp(-35 * (t % 0.5))
          * math.sin(2 * math.pi * 64 * (t % 0.5)))
    write('click.wav', 0.07, lambda t: 0.12 * math.exp(-80 * t) * math.sin(2 * math.pi * 660 * t))
    print(OUTPUT)
