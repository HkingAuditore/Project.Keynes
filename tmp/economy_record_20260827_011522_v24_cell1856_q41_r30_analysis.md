# Economy recorder v18 analysis — `economy_record_20260827_011522_v24_cell1856_q41_r30`

## Executive summary

- Horizon: day 16 → 580 (565 committed records).
- Selected-cell population: 20 → 12 (-8). Global births/deaths recorded: 0 / 46 (net -46).
- Exact audit maxima: population=0, money=0, goods=0.
- Active goods touching price 1: 0 / 7.
- Building types below owner-livelihood coverage or ending suspended/recovery: 2 / 5.
- Lifecycle churn: 0 buildings liquidated, 87 investments started, and 0 recovery restarts.

## Global yearly dynamics

| Year | Days | Births | Deaths | Net | Owner jobs first→last | Building groups first→last | Liquidated | Invested | Suspended end |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 0 | 16–380 | 0 | 33 | -33 | 107→82 | 30→30 | 0 | 76 | 0 |
| 1 | 381–580 | 0 | 13 | -13 | 81→74 | 30→30 | 0 | 11 | 0 |

## Population and cohorts

| Profession | Population first→last | Δ | Min livelihood coverage | Min satisfaction | Final worst need | First loss day |
|---|---:|---:|---:|---:|---|---:|
| forager | 13→1 | -12 | 131.4% | 0.0% | staple_food | 17 |
| hunter | 2→1 | -1 | 12.0% | 100.0% | staple_food | 47 |
| miner | 2→1 | -1 | 335.8% | 0.0% | staple_food | 86 |

## Building viability

| Building | Revenue/viability cost | Owner livelihood coverage | Sell-through | Discard | Util early→late | Margin late | State end | First suspended |
|---|---:|---:|---:|---:|---:|---:|---|---:|
| early_merchant_post | 0.0% | 0.0% | — | — | 0.0%→0.0% | 0.0% | active | — |
| placer_gold_working | 60.7% | 71.5% | 100.0% | 0.0% | 100.0%→100.0% | -100.0% | active | — |

## Market stress

| Good | Price first→last | Price=1 share while active | Late shortage | Late demand | Late business demand | Late stock | Cost anchor last |
|---|---:|---:|---:|---:|---:|---:|---:|
| gathered_plants | 4,846→50,000 | 0.0% | 100.0% | 12,015 | 0 | 0 | 7,152 |
| logs | 7,639→50,162 | 0.0% | 76.7% | 1,962 | 24 | 40,263 | 5,024 |
| game_meat | 13,242→100,000 | 0.0% | 45.9% | 1,923 | 0 | 0 | 7,551 |
| bast_fiber | 5,363→700 | 0.0% | 0.0% | 0 | 17 | 5,105 | 0 |
| clothing | 18,369→2,400 | 0.0% | 0.0% | 0 | 0 | 60,000 | 0 |
| gold | 9,902→9,355 | 0.0% | 0.0% | 0 | 0 | 0 | 0 |
| raw_hide | 21,586→2,400 | 0.0% | 0.0% | 0 | 0 | 1,320 | 18,177 |

## Resource stock-flow

| Resource | Reserve first→last | Δ | Natural + | Natural - | Extraction | Replacement ratio |
|---|---:|---:|---:|---:|---:|---:|
| clay | 29,936,162→21,741,790 | -8,194,372 | 0 | 8,194,372 | 0 | 0.00 |
| timber | 5,859,342→4,974,134 | -885,208 | 966,757 | 1,851,879 | 87 | 0.52 |
| marine_fish | 904,088→551,278 | -352,810 | 0 | 352,810 | 0 | 0.00 |
| fertile_soil | 340,439→137,675 | -202,765 | 0 | 202,765 | 0 | 0.00 |
| wild_game | 118,323→79,436 | -38,887 | 0 | 38,437 | 450 | 0.00 |
| oil | 41,255→38,435 | -2,820 | 0 | 2,820 | 0 | 0.00 |
| gold_ore | 8,593,804→8,593,781 | -23 | 17 | 17 | 23 | 0.42 |

## Recorder scope

- Summary rows are global runtime aggregates; cohort, market, building, and resource rows describe the selected cell.
- Early/late windows are the first/last 180 simulation days.
- Money, goods, and Q16 values remain in recorder integer units unless shown as percentages.
