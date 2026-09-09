# Authority Stage C1 client report

Debug development profile only. This is not Release acceptance evidence.

Verdict: **mixed_or_no_material_evidence** (all three directions must agree, and the median difference must reach both 0.25 ms and 3%).

| Pair | Direction | OFF p50 ms | ACTIVE p50 ms | Delta ms | Delta % |
|---:|---|---:|---:|---:|---:|
| 1 | OFF->ACTIVE | 12.530 | 11.728 | -0.802 | -6.40% |
| 2 | ACTIVE->OFF | 12.371 | 12.315 | -0.056 | -0.45% |
| 3 | OFF->ACTIVE | 12.134 | 12.266 | 0.132 | 1.09% |

Frame distributions for all, fast-tick, and non-fast-tick frames are in `summary.csv`; worker ACTIVE and SHADOW diagnostic timings are separate columns.
