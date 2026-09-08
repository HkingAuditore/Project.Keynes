# Economy recorder v18 analysis — `economy_record_20260829_140824_v25_cell540_q-4_r9`

## Executive summary

- Horizon: day 1 → 1095 (1095 committed records).
- Selected-cell population: 20 → 21 (1). Global births/deaths recorded: 44 / 22 (net 22).
- Exact audit maxima: population=0, money=0, goods=0.
- Active goods touching price 1: 0 / 7.
- Building types below owner-livelihood coverage or ending suspended/recovery: 0 / 5.
- Lifecycle churn: 0 buildings liquidated, 25 investments started, and 0 recovery restarts.

## Global yearly dynamics

| Year | Days | Births | Deaths | Net | Owner jobs first→last | Building groups first→last | Liquidated | Invested | Suspended end |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 0 | 1–365 | 11 | 5 | 6 | 53→71 | 21→21 | 0 | 6 | 0 |
| 1 | 366–730 | 16 | 8 | 8 | 71→88 | 21→21 | 0 | 18 | 0 |
| 2 | 731–1095 | 17 | 9 | 8 | 88→93 | 21→21 | 0 | 1 | 0 |

## Population and cohorts

| Profession | Population first→last | Δ | Min livelihood coverage | Min satisfaction | Final worst need | First loss day |
|---|---:|---:|---:|---:|---|---:|
| unemployed | 5→1 | -4 | 0.0% | 0.0% | staple_food | 3 |

## Building viability

| Building | Revenue/viability cost | Owner livelihood coverage | Sell-through | Discard | Util early→late | Margin late | State end | First suspended |
|---|---:|---:|---:|---:|---:|---:|---|---:|

## Market stress

| Good | Price first→last | Price=1 share while active | Late shortage | Late demand | Late business demand | Late stock | Cost anchor last |
|---|---:|---:|---:|---:|---:|---:|---:|
| logs | 9,766→8,482 | 0.0% | 51.1% | 4,110 | 9 | 17,855 | 4,977 |
| gathered_plants | 4,883→50,000 | 0.0% | 27.0% | 4,160 | 0 | 0 | 10,225 |
| game_meat | 9,766→17,123 | 0.0% | 0.0% | 3,089 | 0 | 2,049 | 5,697 |
| bast_fiber | 6,782→700 | 0.0% | 0.0% | 0 | 9 | 33,544 | 0 |
| clothing | 23,251→2,400 | 0.0% | 0.0% | 0 | 0 | 60,000 | 0 |
| gold | 10,000→2,198 | 0.0% | 0.0% | 0 | 0 | 0 | 0 |
| raw_hide | 24,000→2,400 | 0.0% | 0.0% | 0 | 0 | 660 | 17,137 |

## Resource stock-flow

| Resource | Reserve first→last | Δ | Natural + | Natural - | Extraction | Replacement ratio |
|---|---:|---:|---:|---:|---:|---:|
| clay | 32,305,136→17,862,908 | -14,442,228 | 0 | 14,442,228 | 0 | 0.00 |
| timber | 6,341,136→4,288,020 | -2,053,116 | 342,308 | 2,394,463 | 960 | 0.14 |
| fertile_soil | 349,457→67,833 | -281,625 | 0 | 281,625 | 0 | 0.00 |
| wild_game | 119,950→60,347 | -59,603 | 0 | 58,288 | 1,315 | 0.00 |
| oil | 20,075,212→20,070,836 | -4,376 | 0 | 4,376 | 0 | 0.00 |
| gold_ore | 15,000→14,891 | -109 | 0 | 0 | 109 | 0.00 |

## Recorder scope

- Summary rows are global runtime aggregates; cohort, market, building, and resource rows describe the selected cell.
- Early/late windows are the first/last 180 simulation days.
- Money, goods, and Q16 values remain in recorder integer units unless shown as percentages.
