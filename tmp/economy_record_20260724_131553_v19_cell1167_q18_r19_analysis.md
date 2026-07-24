# Economy recorder v18 analysis — `economy_record_20260724_131553_v19_cell1167_q18_r19`

## Executive summary

- Horizon: day 3 → 1755 (1753 committed records).
- Selected-cell population: 2,301 → 2,300 (-1). Global births/deaths recorded: 407,627 / 452,812 (net -45,185).
- Exact audit maxima: population=0, money=0, goods=0.
- Active goods touching price 1: 0 / 13.
- Building types below owner-livelihood coverage or ending suspended/recovery: 6 / 14.
- Lifecycle churn: 855,007 buildings liquidated, 74,907 investments started, and 27,776 recovery restarts.

## Global yearly dynamics

| Year | Days | Births | Deaths | Net | Owner jobs first→last | Building groups first→last | Liquidated | Invested | Suspended end |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 0 | 3–367 | 85,725 | 83,566 | 2,159 | 497,348→106,867 | 9,091→9,635 | 717,556 | 22,328 | 348 |
| 1 | 368–732 | 84,694 | 91,217 | -6,523 | 91,225→112,613 | 9,629→9,546 | 63,420 | 18,640 | 245 |
| 2 | 733–1097 | 85,309 | 98,103 | -12,794 | 93,364→121,676 | 9,547→9,530 | 21,174 | 14,687 | 231 |
| 3 | 1098–1462 | 84,155 | 100,239 | -16,084 | 103,298→120,025 | 9,529→9,506 | 26,181 | 11,373 | 242 |
| 4 | 1463–1755 | 67,744 | 79,687 | -11,943 | 106,662→118,231 | 9,506→9,492 | 26,676 | 7,879 | 222 |

## Population and cohorts

| Profession | Population first→last | Δ | Min livelihood coverage | Min satisfaction | Final worst need | First loss day |
|---|---:|---:|---:|---:|---|---:|
| fisher | 1,100→4 | -1,096 | 23.2% | 100.0% | produce | 7 |
| forager | 859→143 | -716 | 9.7% | 100.0% | produce | 7 |
| artisan | 300→1 | -299 | 0.0% | 94.7% | produce | 7 |
| hunter | 40→18 | -22 | 0.0% | 100.0% | produce | 22 |

## Building viability

| Building | Revenue/viability cost | Owner livelihood coverage | Sell-through | Discard | Util early→late | Margin late | State end | First suspended |
|---|---:|---:|---:|---:|---:|---:|---|---:|
| merchant_post | 0.0% | 0.0% | — | — | 100.0%→100.0% | -100.0% | active | — |
| stone_collector | 74.2% | 106.1% | 60.0% | 40.0% | 18.8%→0.0% | 0.0% | suspended | 37 |
| lumber_plant | 139.1% | 193.0% | 71.8% | 28.2% | 10.8%→0.0% | 0.0% | suspended | 27 |
| flint_quarry | 216.1% | 216.1% | 84.7% | 15.3% | 8.1%→0.0% | 0.0% | suspended | 27 |
| household_weaving_shelter | 423.3% | 438.8% | 95.4% | 4.6% | 6.4%→16.6% | -6.5% | suspended | 17 |
| communal_hearth | 197.5% | 1126.8% | 77.1% | 22.9% | 16.7%→15.1% | 0.2% | suspended | 82 |

### Artisan target buildings

| Building | Owner livelihood coverage | Revenue/viability | Util early→late | Margin late | First suspended | State end |
|---|---:|---:|---:|---:|---:|---|
| knapping_workshop | 166.6% | 165.3% | 17.9%→64.8% | 47.5% | 52 | active |
| household_weaving_shelter | 438.8% | 423.3% | 6.4%→16.6% | -6.5% | 17 | suspended |

## Market stress

| Good | Price first→last | Price=1 share while active | Late shortage | Late demand | Late business demand | Late stock | Cost anchor last |
|---|---:|---:|---:|---:|---:|---:|---:|
| logs | 11,310→1,077 | 0.0% | 8.7% | 84,297 | 33 | 1,637,234 | 1,358 |
| cloth | 29,795→32,949 | 0.0% | 8.1% | 108 | 0 | 2,051 | 89,836 |
| chipped_stone_tools | 83,171→17,694 | 0.0% | 6.8% | 357 | 2,429 | 45,732 | 31,308 |
| fish | 9,415→7,359 | 0.0% | 5.6% | 23,892 | 0 | 84,059 | 3,109 |
| game_meat | 11,865→3,085 | 0.0% | 4.0% | 95,381 | 35,192 | 974,146 | 3,112 |
| gathered_plants | 4,708→6,741 | 0.0% | 3.8% | 964,043 | 116,208 | 3,735,467 | 1,374 |
| processed_food | 17,053→5,919 | 0.0% | 2.0% | 224,594 | 0 | 3,848,670 | 2,781 |
| fur | 26,607→2,005 | 0.0% | 0.0% | 636 | 0 | 9,288 | 7,479 |
| flint | 3,688→12 | 0.0% | 0.0% | 0 | 317 | 3,722,062 | 1,612 |
| bronze_tools | 23,969→12 | 0.0% | 0.0% | 0 | 0 | 25,140 | 0 |
| lumber | 16,596→12 | 0.0% | 0.0% | 0 | 0 | 1,082,875 | 6,670 |
| raw_hide | 22,127→12 | 0.0% | 0.0% | 0 | 0 | 66,000 | 7,476 |
| raw_stone | 9,219→12 | 0.0% | 0.0% | 0 | 0 | 1,443,840 | 4,767 |

## Resource stock-flow

| Resource | Reserve first→last | Δ | Natural + | Natural - | Extraction | Replacement ratio |
|---|---:|---:|---:|---:|---:|---:|
| clay | 25,114,908→11,982,451 | -13,132,457 | 0 | 13,132,457 | 0 | 0.00 |
| fertile_soil | 350,000→50,000 | -300,000 | 0 | 300,000 | 0 | 0.00 |
| oil | 22,155,124→22,146,700 | -8,424 | 0 | 8,424 | 0 | 0.00 |
| wild_game | 19,668→14,761 | -4,907 | 17,930 | 7,335 | 15,502 | 0.79 |
| stone | 122,420,264→122,420,140 | -124 | 116 | 120 | 116 | 0.49 |
| flint | 81,937,260→81,937,150 | -110 | 18 | 112 | 18 | 0.14 |

## Recorder scope

- Summary rows are global runtime aggregates; cohort, market, building, and resource rows describe the selected cell.
- Early/late windows are the first/last 180 simulation days.
- Money, goods, and Q16 values remain in recorder integer units unless shown as percentages.
