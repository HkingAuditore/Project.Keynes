# Economy recorder v18 analysis — `economy_record_20260831_140522_v25_cell650_q45_r10`

## Executive summary

- Horizon: day 49054 → 49606 (553 committed records).
- Selected-cell population: 34 → 32 (-2). Global births/deaths recorded: 16 / 15 (net 1).
- Exact audit maxima: population=0, money=0, goods=0.
- Active goods touching price 1: 2 / 16.
- Building types below owner-livelihood coverage or ending suspended/recovery: 5 / 13.
- Lifecycle churn: 0 buildings liquidated, 0 investments started, and 2 recovery restarts.

## Global yearly dynamics

| Year | Days | Births | Deaths | Net | Owner jobs first→last | Building groups first→last | Liquidated | Invested | Suspended end |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 0 | 49054–49418 | 10 | 9 | 1 | 117→118 | 38→38 | 0 | 0 | 0 |
| 1 | 49419–49606 | 6 | 6 | 0 | 118→118 | 38→38 | 0 | 0 | 0 |

## Population and cohorts

| Profession | Population first→last | Δ | Min livelihood coverage | Min satisfaction | Final worst need | First loss day |
|---|---:|---:|---:|---:|---|---:|
| fisher | 3→2 | -1 | 1.3% | 75.9% | staple_food | 49271 |
| hunter | 16→15 | -1 | 19.4% | 28.9% | staple_food | 49406 |

## Building viability

| Building | Revenue/viability cost | Owner livelihood coverage | Sell-through | Discard | Util early→late | Margin late | State end | First suspended |
|---|---:|---:|---:|---:|---:|---:|---|---:|
| lumber_plant | 0.0% | 0.0% | 0.0% | 100.0% | 100.0%→100.0% | -100.0% | active | — |
| bast_fiber_camp | 45.4% | 45.4% | 0.1% | 99.9% | 35.1%→48.4% | -54.6% | active | — |
| deadwood_gathering_camp | 61.8% | 85.9% | 70.5% | 0.0% | 100.0%→100.0% | -36.1% | active | — |
| stone_age_hunting_camp | 0.0% | 99.8% | 0.0% | 8.5% | 9.0%→8.8% | 0.0% | active | — |
| placer_gold_working | — | — | — | — | 0.0%→0.0% | 0.0% | suspended | 49054 |

## Market stress

| Good | Price first→last | Price=1 share while active | Late shortage | Late demand | Late business demand | Late stock | Cost anchor last |
|---|---:|---:|---:|---:|---:|---:|---:|
| raw_hide | 1→1 | 100.0% | 0.0% | 0 | 0 | 10,560 | 144,483 |
| technology_points | 1→1 | 100.0% | 0.0% | 0 | 0 | 488,418 | 4,448 |
| charcoal | 3,354,849→3,223,256 | 0.0% | 100.0% | 3,777 | 0 | 2 | 18,759 |
| rice_grain | 15,676,066→15,955,431 | 0.0% | 100.0% | 3,710 | 0 | 0 | 0 |
| turf_block | 6,584,570→6,672,794 | 0.0% | 100.0% | 44 | 0 | 0 | 0 |
| reed_bundle | 5,978,633→6,057,834 | 0.0% | 100.0% | 36 | 0 | 0 | 0 |
| game_meat | 620,940→1,258,803 | 0.0% | 100.0% | 26 | 0 | 0 | 60,030 |
| bast_fiber | 2,651,238→2,666,119 | 0.0% | 100.0% | 12 | 9 | 352,789 | 6,264 |
| lumber | 12,429,313→12,468,434 | 0.0% | 100.0% | 16 | 0 | 40,109 | 11,825 |
| chipped_stone_tools | 1,137,322→1,076,265 | 0.0% | 100.0% | 0 | 0 | 0 | 0 |
| clothing | 787,301,823→786,383,971 | 0.0% | 90.1% | 96 | 0 | 0 | 1,066,885 |
| prepared_staples | 25,319,378→25,527,214 | 0.0% | 84.5% | 4,963 | 0 | 0 | 0 |
| gathered_plants | 7,969,418→7,993,433 | 0.0% | 55.2% | 1,794 | 0 | 0 | 17,453 |
| logs | 3,205→3,042 | 0.0% | 47.3% | 9,865 | 2,288 | 64,588 | 4,865 |
| fish | 10,969→97,199 | 0.0% | 21.6% | 4,366 | 0 | 0 | 13,057 |
| natural_rubber | 634,409→639,059 | 0.0% | 0.0% | 0 | 61 | 0 | 0 |

## Resource stock-flow

| Resource | Reserve first→last | Δ | Natural + | Natural - | Extraction | Replacement ratio |
|---|---:|---:|---:|---:|---:|---:|
| clay | 10,419,110→10,392,753 | -26,357 | 58,004 | 84,361 | 0 | 0.69 |
| timber | 4,562,104→4,559,502 | -2,601 | 31,294 | 33,065 | 831 | 0.92 |
| wild_game | 1,865→1,865 | -1 | 499 | 0 | 500 | 1.00 |

## Recorder scope

- Summary rows are global runtime aggregates; cohort, market, building, and resource rows describe the selected cell.
- Early/late windows are the first/last 180 simulation days.
- Money, goods, and Q16 values remain in recorder integer units unless shown as percentages.
