# Economy recorder v18 analysis — `economy_record_20260723_213138_v19_cell886_q39_r14`

## Executive summary

- Horizon: day 6 → 3490 (3485 committed records).
- Selected-cell population: 11,347 → 9,560 (-1,787). Global births/deaths recorded: 673,281 / 1,418,032 (net -744,751).
- Exact audit maxima: population=0, money=0, goods=0.
- Active goods touching price 1: 0 / 15.
- Building types below owner-livelihood coverage or ending suspended/recovery: 12 / 14.
- Lifecycle churn: 1,234,867 buildings liquidated, 172,027 investments started, and 68,255 recovery restarts.

## Global yearly dynamics

| Year | Days | Births | Deaths | Net | Owner jobs first→last | Building groups first→last | Liquidated | Invested | Suspended end |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 0 | 6–370 | 80,289 | 123,905 | -43,616 | 632,677→313,880 | 9,350→10,304 | 585,258 | 34,355 | 496 |
| 1 | 371–735 | 78,306 | 146,128 | -67,822 | 365,338→303,757 | 10,299→9,915 | 161,199 | 26,296 | 419 |
| 2 | 736–1100 | 76,830 | 157,405 | -80,575 | 378,084→258,202 | 9,915→9,862 | 90,021 | 20,367 | 479 |
| 3 | 1101–1465 | 73,865 | 158,728 | -84,863 | 302,598→227,036 | 9,862→9,859 | 91,880 | 17,629 | 492 |
| 4 | 1466–1830 | 72,104 | 152,547 | -80,443 | 303,694→227,641 | 9,860→9,846 | 62,736 | 16,169 | 496 |
| 5 | 1831–2195 | 68,863 | 155,644 | -86,781 | 293,798→202,330 | 9,846→9,835 | 53,906 | 14,237 | 485 |
| 6 | 2196–2560 | 66,036 | 152,880 | -86,844 | 289,442→217,650 | 9,834→9,830 | 58,698 | 13,119 | 489 |
| 7 | 2561–2925 | 63,646 | 151,541 | -87,895 | 255,509→206,752 | 9,830→9,789 | 64,562 | 12,182 | 486 |
| 8 | 2926–3290 | 60,486 | 147,736 | -87,250 | 248,594→199,025 | 9,790→9,803 | 46,595 | 11,622 | 486 |
| 9 | 3291–3490 | 32,856 | 71,518 | -38,662 | 238,056→196,213 | 9,803→9,802 | 20,012 | 6,051 | 470 |

## Population and cohorts

| Profession | Population first→last | Δ | Min livelihood coverage | Min satisfaction | Final worst need | First loss day |
|---|---:|---:|---:|---:|---|---:|
| forager | 4,593→719 | -3,874 | 2.9% | 0.0% | protein | 16 |
| fisher | 2,147→495 | -1,652 | 0.0% | 0.0% | protein | 21 |
| artisan | 1,511→136 | -1,375 | 0.0% | 22.3% | protein | 16 |
| merchant | 977→1 | -976 | 0.0% | 5.6% | protein | 16 |
| miner | 1,499→865 | -634 | 58.3% | 23.4% | protein | 16 |

## Building viability

| Building | Revenue/viability cost | Owner livelihood coverage | Sell-through | Discard | Util early→late | Margin late | State end | First suspended |
|---|---:|---:|---:|---:|---:|---:|---|---:|
| marine_fish_collector | 0.0% | 0.0% | — | — | 100.0%→100.0% | -100.0% | active | — |
| merchant_post | 0.0% | 0.0% | — | — | 100.0%→100.0% | -100.0% | active | — |
| flint_quarry | 18.7% | 18.7% | 82.5% | 17.5% | 3.5%→0.0% | 0.0% | suspended | 21 |
| lumber_plant | 35.8% | 40.3% | 89.5% | 10.5% | 3.3%→0.0% | 0.0% | suspended | 21 |
| stone_collector | 59.3% | 78.4% | 76.4% | 23.6% | 11.5%→0.0% | 0.0% | suspended | 16 |
| knapping_workshop | 91.3% | 91.4% | 98.7% | 1.3% | 35.1%→43.6% | 0.4% | suspended | 46 |
| freshwater_fishing_camp | 57.9% | 120.1% | 44.5% | 1.2% | 33.4%→0.0% | 0.0% | suspended | 26 |
| gathering_ground | 231.6% | 320.9% | 55.9% | 0.2% | 35.7%→29.3% | -5.2% | suspended | 26 |
| placer_gold_working | 120.2% | 423.1% | 100.0% | 0.0% | 100.0%→0.0% | 0.0% | suspended | 2226 |
| surface_silver_working | 138.3% | 631.9% | 100.0% | 0.0% | 100.0%→0.0% | 0.0% | suspended | 626 |
| communal_hearth | 160.2% | 907.9% | 99.7% | 0.3% | 40.3%→0.0% | 0.0% | suspended | 2336 |
| household_weaving_shelter | 1728.6% | 1813.2% | 85.7% | 14.3% | 33.3%→33.0% | 35.7% | suspended | 186 |

### Artisan target buildings

| Building | Owner livelihood coverage | Revenue/viability | Util early→late | Margin late | First suspended | State end |
|---|---:|---:|---:|---:|---:|---|
| knapping_workshop | 91.4% | 91.3% | 35.1%→43.6% | 0.4% | 46 | suspended |
| household_weaving_shelter | 1813.2% | 1728.6% | 33.3%→33.0% | 35.7% | 186 | suspended |

## Market stress

| Good | Price first→last | Price=1 share while active | Late shortage | Late demand | Late business demand | Late stock | Cost anchor last |
|---|---:|---:|---:|---:|---:|---:|---:|
| processed_food | 17,272→926,104 | 0.0% | 100.0% | 865,375 | 0 | 0 | 14,602 |
| fish | 8,669→2,922,230 | 0.0% | 100.0% | 519,225 | 0 | 0 | 18,255 |
| fur | 35,909→74,469,532 | 0.0% | 19.4% | 18 | 0 | 115 | 6,582,197 |
| cloth | 18,734,877→99,509 | 0.0% | 2.8% | 7,976 | 0 | 99,487 | 168,811 |
| chipped_stone_tools | 81,859→35,030 | 0.0% | 1.1% | 14,545 | 32,786 | 391,782 | 90,048 |
| gathered_plants | 4,342→2,052 | 0.0% | 0.7% | 7,166,636 | 4,993 | 92,341,699 | 2,255 |
| logs | 11,862→5,681 | 0.0% | 0.3% | 1,095,707 | 18 | 3,552,902 | 8,030 |
| flint | 3,258→12 | 0.0% | 0.0% | 0 | 3,116 | 17,113,648 | 57,773 |
| bronze_tools | 22,097→12 | 0.0% | 0.0% | 0 | 0 | 125,140 | 0 |
| game_meat | 13,818→56,953,667 | 0.0% | 0.0% | 0 | 0 | 56 | 2,734,430 |
| gold | 9,805→9,886 | 0.0% | 0.0% | 0 | 0 | 0 | 0 |
| lumber | 14,864→12 | 0.0% | 0.0% | 0 | 0 | 14,833,670 | 148,376 |
| raw_hide | 19,533→12 | 0.0% | 0.0% | 0 | 0 | 328,800 | 6,565,932 |
| raw_stone | 8,648→12 | 0.0% | 0.0% | 0 | 0 | 50,478,222 | 42,680 |
| silver | 9,805→9,949 | 0.0% | 0.0% | 0 | 0 | 0 | 0 |

## Resource stock-flow

| Resource | Reserve first→last | Δ | Natural + | Natural - | Extraction | Replacement ratio |
|---|---:|---:|---:|---:|---:|---:|
| clay | 29,414,558→5,772,209 | -23,642,349 | 0 | 23,642,349 | 0 | 0.00 |
| fertile_soil | 346,773→9,225 | -337,549 | 265 | 337,814 | 0 | 0.00 |
| silver_ore | 18,915,656→18,720,004 | -195,652 | 195,652 | 195,652 | 195,652 | 0.50 |
| gold_ore | 43,362,344→43,175,944 | -186,400 | 186,398 | 186,400 | 186,398 | 0.50 |
| wild_game | 23,582→1 | -23,580 | 25,623 | 23,813 | 25,391 | 0.52 |
| stone | 415,366,820→415,363,550 | -3,270 | 3,278 | 3,264 | 3,278 | 0.50 |
| flint | 131,285,550→131,284,936 | -614 | 612 | 616 | 612 | 0.50 |

## Recorder scope

- Summary rows are global runtime aggregates; cohort, market, building, and resource rows describe the selected cell.
- Early/late windows are the first/last 180 simulation days.
- Money, goods, and Q16 values remain in recorder integer units unless shown as percentages.
