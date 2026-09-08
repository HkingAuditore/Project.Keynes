# Economy recorder v18 analysis — `economy_record_20260828_133019_v25_cell584_q40_r9`

## Executive summary

- Horizon: day 4 → 563 (560 committed records).
- Selected-cell population: 20 → 2 (-18). Global births/deaths recorded: 0 / 95 (net -95).
- Exact audit maxima: population=0, money=0, goods=0.
- Active goods touching price 1: 0 / 7.
- Building types below owner-livelihood coverage or ending suspended/recovery: 1 / 5.
- Lifecycle churn: 0 buildings liquidated, 65 investments started, and 0 recovery restarts.

## Global yearly dynamics

| Year | Days | Births | Deaths | Net | Owner jobs first→last | Building groups first→last | Liquidated | Invested | Suspended end |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 0 | 4–368 | 0 | 68 | -68 | 19→35 | 30→30 | 0 | 65 | 0 |
| 1 | 369–563 | 0 | 27 | -27 | 34→17 | 30→30 | 0 | 0 | 0 |

## Population and cohorts

| Profession | Population first→last | Δ | Min livelihood coverage | Min satisfaction | Final worst need | First loss day |
|---|---:|---:|---:|---:|---|---:|
| unemployed | 16→1 | -15 | 0.0% | 0.0% | staple_food | 14 |

## Building viability

| Building | Revenue/viability cost | Owner livelihood coverage | Sell-through | Discard | Util early→late | Margin late | State end | First suspended |
|---|---:|---:|---:|---:|---:|---:|---|---:|
| placer_gold_working | 2.6% | 2.6% | 100.0% | 0.0% | 97.2%→100.0% | -100.0% | active | — |

## Market stress

| Good | Price first→last | Price=1 share while active | Late shortage | Late demand | Late business demand | Late stock | Cost anchor last |
|---|---:|---:|---:|---:|---:|---:|---:|
| gathered_plants | 4,705→50,000 | 0.0% | 100.0% | 2,949 | 0 | 0 | 5,408 |
| game_meat | 9,394→100,000 | 0.0% | 100.0% | 484 | 0 | 0 | 5,784 |
| logs | 9,403→98,094 | 0.0% | 100.0% | 268 | 8 | 11,745 | 4,941 |
| bast_fiber | 6,471→700 | 0.0% | 0.0% | 0 | 8 | 25,549 | 0 |
| clothing | 22,181→2,400 | 0.0% | 0.0% | 0 | 0 | 60,000 | 0 |
| gold | 10,000→9,951 | 0.0% | 0.0% | 0 | 0 | 0 | 0 |
| raw_hide | 23,869→2,400 | 0.0% | 0.0% | 0 | 0 | 660 | 17,405 |

## Resource stock-flow

| Resource | Reserve first→last | Δ | Natural + | Natural - | Extraction | Replacement ratio |
|---|---:|---:|---:|---:|---:|---:|
| clay | 53,552,316→35,202,940 | -18,349,376 | 0 | 18,349,376 | 0 | 0.00 |
| fertile_soil | 347,887→161,744 | -186,142 | 0 | 186,142 | 0 | 0.00 |
| wild_game | 119,910→100,586 | -19,324 | 69 | 19,344 | 48 | 0.00 |
| oil | 27,413,056→27,410,820 | -2,236 | 0 | 2,236 | 0 | 0.00 |
| gold_ore | 7,241,974→7,241,974 | -0 | 0 | 0 | 0 | 0.38 |

## Recorder scope

- Summary rows are global runtime aggregates; cohort, market, building, and resource rows describe the selected cell.
- Early/late windows are the first/last 180 simulation days.
- Money, goods, and Q16 values remain in recorder integer units unless shown as percentages.
