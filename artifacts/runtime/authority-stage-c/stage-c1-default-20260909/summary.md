# Authority Stage C1 client report

Debug development profile only. This is not Release acceptance evidence.

Verdict: **mixed_or_no_material_evidence** (all three directions must reach both 0.25 ms and 3%).

| Pair | Direction | OFF p50 ms | ACTIVE p50 ms | Delta ms | Delta % |
|---:|---|---:|---:|---:|---:|
| 1 | OFF->ACTIVE | 11.581 | 11.974 | 0.393 | 3.39% |
| 2 | ACTIVE->OFF | 11.600 | 11.803 | 0.203 | 1.75% |
| 3 | OFF->ACTIVE | 12.419 | 11.908 | -0.511 | -4.11% |

Frame distributions for all, fast-tick, and non-fast-tick frames are in `summary.csv`; worker ACTIVE and SHADOW diagnostic timings are separate columns.
