# Economy recorder v18 analysis — `economy_record_20260802_162733_v22_cell1393_q87_r13`

## Executive summary

- Horizon: day 21 → 2214 (2194 committed records).
- Selected-cell population: 20 → 1 (-19). Global births/deaths recorded: 20 / 64 (net -44).
- Exact audit maxima: population=0, money=0, goods=0.
- Active goods touching price 1: 0 / 11.
- Building types below owner-livelihood coverage or ending suspended/recovery: 3 / 8.
- Lifecycle churn: 6 buildings liquidated, 125 investments started, and 0 recovery restarts.

## Global yearly dynamics

| Year | Days | Births | Deaths | Net | Owner jobs first→last | Building groups first→last | Liquidated | Invested | Suspended end |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 0 | 21–385 | 0 | 6 | -6 | 0→9 | 34→40 | 6 | 88 | 0 |
| 1 | 386–750 | 6 | 10 | -4 | 0→6 | 40→42 | 0 | 16 | 0 |
| 2 | 751–1115 | 5 | 16 | -11 | 0→1 | 42→45 | 0 | 7 | 0 |
| 3 | 1116–1480 | 3 | 14 | -11 | 0→1 | 45→48 | 0 | 10 | 0 |
| 4 | 1481–1845 | 3 | 15 | -12 | 0→1 | 48→49 | 0 | 3 | 0 |
| 5 | 1846–2210 | 3 | 3 | 0 | 0→1 | 49→49 | 0 | 1 | 0 |
| 6 | 2211–2214 | 0 | 0 | 0 | 0→39 | 49→49 | 0 | 0 | 0 |

## Population and cohorts

| Profession | Population first→last | Δ | Min livelihood coverage | Min satisfaction | Final worst need | First loss day |
|---|---:|---:|---:|---:|---|---:|
| unemployed | 6→1 | -5 | 0.0% | 0.0% | -1 | 43 |
| miner | 4→1 | -3 | 100.0% | 0.0% | staple_food | 638 |
| forager | 3→1 | -2 | 19.7% | 0.0% | staple_food | 33 |
| merchant | 3→1 | -2 | 34.7% | 0.0% | staple_food | 73 |
| hunter | 2→1 | -1 | 0.0% | 0.0% | staple_food | 118 |

## Building viability

| Building | Revenue/viability cost | Owner livelihood coverage | Sell-through | Discard | Util early→late | Margin late | State end | First suspended |
|---|---:|---:|---:|---:|---:|---:|---|---:|
| merchant_post | 0.0% | 0.0% | — | — | 100.0%→100.0% | 0.0% | active | — |
| household_weaving_shelter | 72.1% | 78.9% | 98.6% | 0.2% | 60.4%→100.0% | 0.0% | active | — |
| communal_hearth | 460.5% | 2032.1% | 85.7% | 0.0% | 35.5%→0.0% | 0.0% | suspended | 123 |

### Artisan target buildings

| Building | Owner livelihood coverage | Revenue/viability | Util early→late | Margin late | First suspended | State end |
|---|---:|---:|---:|---:|---:|---|
| household_weaving_shelter | 78.9% | 72.1% | 60.4%→100.0% | 0.0% | — | active |
| knapping_workshop | — | — | 0.0%→100.0% | 0.0% | — | active |

## Market stress

| Good | Price first→last | Price=1 share while active | Late shortage | Late demand | Late business demand | Late stock | Cost anchor last |
|---|---:|---:|---:|---:|---:|---:|---:|
| gathered_plants | 3,780→179,498 | 0.0% | 100.0% | 440 | 1,169 | 0 | 2,525 |
| processed_food | 12,569→3,863,296 | 0.0% | 100.0% | 240 | 0 | 0 | 45,516 |
| game_meat | 7,201→311,964 | 0.0% | 100.0% | 117 | 0 | 0 | 6,428 |
| logs | 7,094→133,516 | 0.0% | 100.0% | 64 | 0 | 0 | 4,040 |
| fish | 20,104→775,441 | 0.0% | 100.0% | 26 | 0 | 0 | 0 |
| fur | 40,503→1,214,727 | 0.0% | 100.0% | 2 | 0 | 0 | 15,520 |
| cloth | 40,844→1,759,253 | 0.0% | 100.0% | 0 | 0 | 0 | 116,174 |
| chipped_stone_tools | 54,769→340,481 | 0.0% | 0.0% | 0 | 0 | 0 | 0 |
| flint | 2,891→12 | 0.0% | 0.0% | 0 | 0 | 499,500 | 0 |
| raw_hide | 19,998→12 | 0.0% | 0.0% | 0 | 0 | 1,800 | 15,452 |
| silver | 9,427→7,625 | 0.0% | 0.0% | 0 | 0 | 0 | 0 |

## Resource stock-flow

| Resource | Reserve first→last | Δ | Natural + | Natural - | Extraction | Replacement ratio |
|---|---:|---:|---:|---:|---:|---:|
| clay | 8,319,781→5,856,482 | -2,463,299 | 91,404 | 2,554,703 | 0 | 0.04 |
| timber | 3,914,418→2,774,327 | -1,140,090 | 963,307 | 2,103,562 | 0 | 0.46 |
| fertile_soil | 337,586→25,317 | -312,270 | 818 | 313,088 | 0 | 0.00 |
| wild_game | 118,141→60,717 | -57,424 | 1,263 | 58,089 | 599 | 0.02 |
| silver_ore | 36,499,988→36,497,436 | -2,552 | 2,550 | 2,552 | 2,550 | 0.50 |

## Recorder scope

- Summary rows are global runtime aggregates; cohort, market, building, and resource rows describe the selected cell.
- Early/late windows are the first/last 180 simulation days.
- Money, goods, and Q16 values remain in recorder integer units unless shown as percentages.
