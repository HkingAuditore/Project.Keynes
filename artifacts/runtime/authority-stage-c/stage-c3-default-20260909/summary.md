# Authority Stage C3 headless report

C3 measures harness-adjusted throughput only. C1 is the frame-latency authority.

Verdict: **mixed_or_no_material_throughput_evidence**

| Pair | Direction | OFF adjusted days/s | ACTIVE adjusted days/s | Delta % |
|---:|---|---:|---:|---:|
| 1 | OFF->ACTIVE | 43.715 | 49.104 | 12.33% |
| 2 | ACTIVE->OFF | 50.868 | 38.436 | -24.44% |
| 3 | OFF->ACTIVE | 44.540 | 40.491 | -9.09% |

`summary.csv` separates raw, idle-adjusted, and whole-window lower-bound timings, plus ACTIVE worker and OFF/SHADOW diagnostic timing.
