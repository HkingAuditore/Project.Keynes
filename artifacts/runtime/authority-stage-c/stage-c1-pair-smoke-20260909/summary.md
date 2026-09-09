# Authority Stage C1 client report

Debug development profile only. This is not Release acceptance evidence.

Verdict: **mixed_or_no_material_evidence** (all three directions must reach both 0.25 ms and 3%).

| Pair | Direction | OFF p50 ms | ACTIVE p50 ms | Delta ms | Delta % |
|---:|---|---:|---:|---:|---:|
| 1 | OFF->ACTIVE | 3208.516 | 168.795 | -3039.721 | -94.74% |

Frame distributions for all, fast-tick, and non-fast-tick frames are in `summary.csv`; worker ACTIVE and SHADOW diagnostic timings are separate columns.
