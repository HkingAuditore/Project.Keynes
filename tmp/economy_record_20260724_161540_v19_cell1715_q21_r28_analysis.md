# Economy recorder v18 analysis — `economy_record_20260724_161540_v19_cell1715_q21_r28`

## Executive summary

- Horizon: day 4 → 3550 (3547 committed records).
- Selected-cell population: 8,846 → 5,723 (-3,123). Global births/deaths recorded: 743,467 / 1,654,605 (net -911,138).
- Exact audit maxima: population=0, money=0, goods=0.
- Active goods touching price 1: 0 / 13.
- Building types below owner-livelihood coverage or ending suspended/recovery: 11 / 14.
- Lifecycle churn: 784,838 buildings liquidated, 108,600 investments started, and 7,510 recovery restarts.

## Global yearly dynamics

| Year | Days | Births | Deaths | Net | Owner jobs first→last | Building groups first→last | Liquidated | Invested | Suspended end |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 0 | 4–368 | 90,253 | 132,667 | -42,414 | 511,284→515,626 | 10,268→11,343 | 573,419 | 34,804 | 146 |
| 1 | 369–733 | 86,896 | 158,138 | -71,242 | 406,669→506,999 | 11,344→11,269 | 114,169 | 20,689 | 84 |
| 2 | 734–1098 | 84,818 | 174,500 | -89,682 | 400,219→499,858 | 11,268→11,282 | 34,728 | 13,574 | 71 |
| 3 | 1099–1463 | 81,590 | 189,698 | -108,108 | 404,415→499,611 | 11,282→11,274 | 7,930 | 9,913 | 54 |
| 4 | 1464–1828 | 77,893 | 223,630 | -145,737 | 399,568→493,218 | 11,274→11,267 | 8,559 | 8,623 | 72 |
| 5 | 1829–2193 | 73,222 | 210,684 | -137,462 | 393,905→486,753 | 11,267→11,271 | 8,400 | 6,131 | 75 |
| 6 | 2194–2558 | 69,945 | 177,960 | -108,015 | 388,285→480,903 | 11,270→11,297 | 11,102 | 4,749 | 72 |
| 7 | 2559–2923 | 67,658 | 158,970 | -91,312 | 380,317→472,771 | 11,296→11,300 | 8,751 | 4,076 | 91 |
| 8 | 2924–3288 | 65,196 | 139,508 | -74,312 | 374,348→465,850 | 11,300→11,289 | 10,755 | 3,588 | 84 |
| 9 | 3289–3550 | 45,996 | 88,850 | -42,854 | 366,620→411,803 | 11,289→11,291 | 7,025 | 2,453 | 115 |

## Population and cohorts

| Profession | Population first→last | Δ | Min livelihood coverage | Min satisfaction | Final worst need | First loss day |
|---|---:|---:|---:|---:|---|---:|
| forager | 4,716→2,745 | -1,971 | 1.7% | 92.2% | produce | 10 |
| artisan | 1,500→446 | -1,054 | 0.0% | 0.0% | produce | 10 |
| unemployed | 442→2 | -440 | 0.0% | 0.0% | -1 | 5 |

## Building viability

| Building | Revenue/viability cost | Owner livelihood coverage | Sell-through | Discard | Util early→late | Margin late | State end | First suspended |
|---|---:|---:|---:|---:|---:|---:|---|---:|
| merchant_post | 0.0% | 0.0% | — | — | 100.0%→100.0% | 0.0% | active | — |
| marine_fish_collector | 0.0% | 0.0% | — | — | 2.8%→0.0% | -44.8% | active | — |
| placer_gold_working | 0.0% | 0.0% | — | — | 2.9%→0.0% | 0.0% | active | — |
| surface_silver_working | 0.0% | 0.0% | — | — | 2.9%→0.0% | -100.0% | active | — |
| lumber_plant | 35.9% | 38.9% | 71.9% | 28.1% | 11.9%→0.0% | 0.0% | suspended | 30 |
| stone_collector | 37.4% | 42.9% | 70.5% | 29.5% | 17.1%→0.0% | 0.0% | suspended | 40 |
| flint_quarry | 53.7% | 53.7% | 84.9% | 15.1% | 11.9%→0.0% | 0.0% | suspended | 30 |
| gathering_ground | 34.2% | 83.5% | 37.8% | 0.2% | 31.9%→18.3% | -71.6% | active | — |
| freshwater_fishing_camp | 22.4% | 92.0% | 21.5% | 0.0% | 30.4%→26.1% | -55.8% | active | — |
| knapping_workshop | 94.8% | 94.9% | 96.3% | 3.7% | 14.3%→54.3% | -11.1% | active | 75 |
| communal_hearth | 243.1% | 579.5% | 97.2% | 2.8% | 27.0%→0.0% | 0.0% | suspended | 690 |

### Artisan target buildings

| Building | Owner livelihood coverage | Revenue/viability | Util early→late | Margin late | First suspended | State end |
|---|---:|---:|---:|---:|---:|---|
| knapping_workshop | 94.9% | 94.8% | 14.3%→54.3% | -11.1% | 75 | active |
| household_weaving_shelter | 199.1% | 195.7% | 31.5%→20.9% | -53.2% | 350 | active |

## Market stress

| Good | Price first→last | Price=1 share while active | Late shortage | Late demand | Late business demand | Late stock | Cost anchor last |
|---|---:|---:|---:|---:|---:|---:|---:|
| game_meat | 10,000→16,071,288 | 0.0% | 66.8% | 12 | 0 | 0 | 586,261 |
| processed_food | 16,000→678,163 | 0.0% | 65.3% | 556,087 | 0 | 2,097,910 | 7,374 |
| fur | 24,000→30,366,212 | 0.0% | 60.8% | 24 | 0 | 222 | 1,415,113 |
| fish | 10,000→10,834 | 0.0% | 9.4% | 494,838 | 0 | 7,632,450 | 16,906 |
| chipped_stone_tools | 75,000→94,956 | 0.0% | 5.1% | 12,495 | 13,844 | 393,627 | 74,172 |
| cloth | 24,000→26,663 | 0.0% | 3.4% | 13,193 | 0 | 230,481 | 404,916 |
| gathered_plants | 5,000→1,972 | 0.0% | 1.6% | 1,260,042 | 623,222 | 43,472,997 | 9,256 |
| logs | 10,000→7,030 | 0.0% | 0.0% | 479,608 | 0 | 3,230,237 | 1,781 |
| flint | 4,000→12 | 0.0% | 0.0% | 0 | 3,116 | 12,829,218 | 15,358 |
| bronze_tools | 26,000→12 | 0.0% | 0.0% | 0 | 0 | 125,140 | 0 |
| lumber | 18,000→12 | 0.0% | 0.0% | 0 | 0 | 4,496,917 | 46,822 |
| raw_hide | 24,000→12 | 0.0% | 0.0% | 0 | 0 | 181,200 | 1,408,436 |
| raw_stone | 10,000→12 | 0.0% | 0.0% | 0 | 0 | 10,355,179 | 14,977 |

## Resource stock-flow

| Resource | Reserve first→last | Δ | Natural + | Natural - | Extraction | Replacement ratio |
|---|---:|---:|---:|---:|---:|---:|
| clay | 41,509,904→9,644,356 | -31,865,548 | 0 | 31,865,548 | 0 | 0.00 |
| timber | 5,961,691→5,632,828 | -328,863 | 11,341,025 | 11,946,227 | 0 | 0.97 |
| fertile_soil | 350,000→54,940 | -295,060 | 6,845 | 301,904 | 0 | 0.02 |
| wild_game | 24,435→4 | -24,430 | 35,352 | 24,749 | 35,033 | 0.59 |
| oil | 4,933,396→4,915,646 | -17,750 | 0 | 17,750 | 0 | 0.00 |
| stone | 128,360,696→128,359,960 | -736 | 734 | 736 | 734 | 0.50 |
| flint | 48,165,136→48,164,540 | -596 | 595 | 596 | 595 | 0.50 |

## Recorder scope

- Summary rows are global runtime aggregates; cohort, market, building, and resource rows describe the selected cell.
- Early/late windows are the first/last 180 simulation days.
- Money, goods, and Q16 values remain in recorder integer units unless shown as percentages.
