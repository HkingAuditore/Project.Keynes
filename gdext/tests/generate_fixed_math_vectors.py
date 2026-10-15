"""Independent arbitrary-precision oracle for native saturating integer math."""
import itertools
from pathlib import Path
import random
import sys

low, high = -(1 << 63), (1 << 63) - 1
edges = [low, -(1 << 62), -(1 << 32), -65536, -1, 0, 1, 2,
         65535, 65536, 65537, 1000000, (1 << 31) - 1, 1 << 32,
         1 << 48, 1 << 62, high]
rng = random.Random(20261015)
cases = list(itertools.product(edges, repeat=3))
for index in range(20000):
    bound = (1 << 31) if index % 2 else (1 << 63)
    a = rng.randrange(-bound, bound)
    b = rng.randrange(-bound, bound)
    d = rng.choice([0, 1, -1, 1000, 65536, -65536, rng.randrange(low, high)])
    cases.append((a, b, d))

def clamp(value):
    return max(low, min(high, value)), int(value < low or value > high)

output = Path(sys.argv[1])
output.parent.mkdir(parents=True, exist_ok=True)
with output.open("w", encoding="ascii", newline="") as stream:
    for a, b, d in cases:
        product, product_sat = clamp(a * b)
        if d == 0:
            quotient = low if (a < 0) ^ (b < 0) else high
            quotient_sat = 1
        else:
            magnitude = abs(a * b) // abs(d)
            quotient, quotient_sat = clamp(-magnitude if (a < 0) ^ (b < 0) ^ (d < 0) else magnitude)
        stream.write(f"{a},{b},{d},{product},{product_sat},{quotient},{quotient_sat}\n")
print(f"wrote {len(cases)} bigint oracle vectors")
