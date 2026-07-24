# Economy recorder v18 analysis — `economy_record_20260724_105324_v19_cell902_q-5_r15`

## Executive summary

- Horizon: day 4 → 1080 (1077 committed records).
- Selected-cell population: 10,571 → 10,046 (-525). Global births/deaths recorded: 219,964 / 953,161 (net -733,197).
- Exact audit maxima: population=0, money=0, goods=0.
- Active goods touching price 1: 0 / 14.
- Building types below owner-livelihood coverage or ending suspended/recovery: 5 / 10.
- Lifecycle churn: 843,289 buildings liquidated, 9,926 investments started, and 52,479 recovery restarts.

## Global yearly dynamics

| Year | Days | Births | Deaths | Net | Owner jobs first→last | Building groups first→last | Liquidated | Invested | Suspended end |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 0 | 4–368 | 82,383 | 190,261 | -107,878 | 504,789→256,196 | 9,566→7,511 | 541,427 | 2,379 | 407 |
| 1 | 369–733 | 77,308 | 254,263 | -176,955 | 228,818→251,051 | 7,509→7,104 | 117,589 | 4,527 | 342 |
| 2 | 734–1080 | 60,273 | 508,637 | -448,364 | 230,190→224,639 | 7,103→6,982 | 184,273 | 3,020 | 343 |

## Population and cohorts

| Profession | Population first→last | Δ | Min livelihood coverage | Min satisfaction | Final worst need | First loss day |
|---|---:|---:|---:|---:|---|---:|
| forager | 6,498→5,498 | -1,000 | 33.3% | 0.0% | home_energy | 22 |
| artisan | 1,000→500 | -500 | 0.0% | 74.4% | home_energy | 12 |
| merchant | 1,002→1,000 | -2 | 0.0% | 81.1% | home_energy | 7 |

## Building viability

| Building | Revenue/viability cost | Owner livelihood coverage | Sell-through | Discard | Util early→late | Margin late | State end | First suspended |
|---|---:|---:|---:|---:|---:|---:|---|---:|
| merchant_post | 0.0% | 0.0% | — | — | 100.0%→100.0% | -100.0% | active | — |
| flint_quarry | 43.0% | 43.0% | 80.5% | 19.5% | 10.2%→0.0% | 0.0% | suspended | 22 |
| stone_collector | 48.9% | 57.0% | 75.1% | 24.9% | 15.4%→0.0% | 0.0% | suspended | 32 |
| knapping_workshop | 69.0% | 69.1% | 91.4% | 8.6% | 27.9%→34.9% | -5.5% | suspended | 37 |
| gathering_ground | 60.4% | 92.1% | 65.0% | 0.0% | 41.8%→46.0% | -7.3% | active | 27 |

### Artisan target buildings

| Building | Owner livelihood coverage | Revenue/viability | Util early→late | Margin late | First suspended | State end |
|---|---:|---:|---:|---:|---:|---|
| knapping_workshop | 69.1% | 69.0% | 27.9%→34.9% | -5.5% | 37 | suspended |
| household_weaving_shelter | 434.5% | 431.7% | 33.3%→31.1% | -6.1% | 17 | active |

## Market stress

| Good | Price first→last | Price=1 share while active | Late shortage | Late demand | Late business demand | Late stock | Cost anchor last |
|---|---:|---:|---:|---:|---:|---:|---:|
| fish | 12,368→558,253 | 0.0% | 100.0% | 399,349 | 0 | 0 | 0 |
| logs | 12,428→551,301 | 0.0% | 95.4% | 409,556 | 94 | 52,476 | 0 |
| game_meat | 12,120→467,798 | 0.0% | 76.8% | 518,341 | 807,852 | 0 | 4,512 |
| fur | 29,921→650,762 | 0.0% | 21.7% | 1,235 | 0 | 1,486 | 10,837 |
| processed_food | 16,889→20,440 | 0.0% | 14.1% | 3,825,906 | 0 | 9,415,538 | 9,790 |
| chipped_stone_tools | 73,541→32,279 | 0.0% | 3.3% | 16,756 | 200 | 608,555 | 558,348 |
| gathered_plants | 4,708→2,660 | 0.0% | 3.1% | 5,246,611 | 1,623,893 | 89,158,236 | 7,852 |
| cloth | 29,885→73,335 | 0.0% | 3.0% | 11,707 | 0 | 519,021 | 337,639 |
| flint | 3,688→15 | 0.0% | 0.0% | 0 | 4,499 | 15,215,115 | 14,240 |
| bronze_tools | 23,969→12 | 0.0% | 0.0% | 0 | 0 | 62,640 | 0 |
| gold | 10,000→170 | 0.0% | 0.0% | 0 | 0 | 0 | 0 |
| raw_hide | 22,127→17 | 0.0% | 0.0% | 0 | 0 | 24,000 | 10,836 |
| raw_stone | 9,219→12 | 0.0% | 0.0% | 0 | 0 | 11,479,490 | 17,656 |
| silver | 10,000→170 | 0.0% | 0.0% | 0 | 0 | 0 | 0 |

## Resource stock-flow

| Resource | Reserve first→last | Δ | Natural + | Natural - | Extraction | Replacement ratio |
|---|---:|---:|---:|---:|---:|---:|
| clay | 30,475,540→14,762,965 | -15,712,575 | 0 | 15,712,575 | 0 | 0.00 |
| fertile_soil | 350,000→63,897 | -286,103 | 0 | 286,103 | 0 | 0.00 |
| silver_ore | 143,822,910→143,552,910 | -270,000 | 268,750 | 270,000 | 268,750 | 0.50 |
| gold_ore | 309,683,650→309,656,640 | -27,010 | 26,875 | 27,008 | 26,875 | 0.50 |
| wild_game | 19,205→10,579 | -8,626 | 15,372 | 8,626 | 15,372 | 0.64 |
| oil | 7,225,186→7,219,786 | -5,400 | 0 | 5,400 | 0 | 0.00 |
| stone | 425,861,060→425,860,300 | -760 | 755 | 768 | 755 | 0.50 |
| flint | 101,066,550→101,065,970 | -580 | 90 | 584 | 90 | 0.13 |

## Recorder scope

- Summary rows are global runtime aggregates; cohort, market, building, and resource rows describe the selected cell.
- Early/late windows are the first/last 180 simulation days.
- Money, goods, and Q16 values remain in recorder integer units unless shown as percentages.
