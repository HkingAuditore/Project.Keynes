# Economy recorder v18 analysis — `economy_record_20260722_151716_v18_cell620_q15_r10`

## Executive summary

- Horizon: day 2 → 7360 (7359 committed records).
- Selected-cell population: 29 → 28 (-1). Global births/deaths recorded: 3,670 / 14,991 (net -11,321).
- Exact audit maxima: population=0, money=0, goods=0.
- Active goods touching price 1: 0 / 10.
- Building types below owner-livelihood coverage or ending suspended/recovery: 2 / 9.
- Lifecycle churn: 64,628 buildings liquidated, 70,251 investments started, and 89,762 recovery restarts.

## Global yearly dynamics

| Year | Days | Births | Deaths | Net | Owner jobs first→last | Building groups first→last | Liquidated | Invested | Suspended end |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 0 | 2–366 | 385 | 4,958 | -4,573 | 3,007→1,530 | 4,269→3,007 | 11,571 | 9,394 | 344 |
| 1 | 367–731 | 255 | 2,981 | -2,726 | 1,434→1,239 | 3,006→2,878 | 8,000 | 7,843 | 321 |
| 2 | 732–1096 | 195 | 1,285 | -1,090 | 1,168→1,220 | 2,876→2,883 | 7,047 | 6,958 | 300 |
| 3 | 1097–1461 | 238 | 832 | -594 | 1,116→1,118 | 2,879→2,945 | 6,023 | 6,469 | 288 |
| 4 | 1462–1826 | 194 | 698 | -504 | 1,074→1,107 | 2,945→2,996 | 4,913 | 5,869 | 301 |
| 5 | 1827–2191 | 234 | 601 | -367 | 1,046→1,150 | 2,996→3,062 | 3,683 | 4,834 | 287 |
| 6 | 2192–2556 | 187 | 521 | -334 | 1,076→1,146 | 3,061→3,191 | 3,134 | 4,228 | 281 |
| 7 | 2557–2921 | 166 | 420 | -254 | 1,074→1,131 | 3,191→3,242 | 2,635 | 3,373 | 287 |
| 8 | 2922–3286 | 132 | 343 | -211 | 1,062→1,100 | 3,241→3,249 | 2,505 | 2,825 | 287 |
| 9 | 3287–3651 | 148 | 400 | -252 | 1,059→1,097 | 3,245→3,322 | 2,042 | 2,644 | 255 |
| 10 | 3652–4016 | 149 | 283 | -134 | 1,030→1,057 | 3,321→3,348 | 1,726 | 2,245 | 256 |
| 11 | 4017–4381 | 160 | 223 | -63 | 1,041→1,060 | 3,348→3,354 | 1,367 | 1,803 | 262 |
| 12 | 4382–4746 | 156 | 231 | -75 | 1,053→1,051 | 3,351→3,410 | 1,484 | 1,742 | 253 |
| 13 | 4747–5111 | 172 | 219 | -47 | 1,041→1,064 | 3,409→3,415 | 1,282 | 1,695 | 264 |
| 14 | 5112–5476 | 148 | 154 | -6 | 1,020→1,054 | 3,412→3,420 | 1,208 | 1,481 | 256 |
| 15 | 5477–5841 | 166 | 174 | -8 | 1,009→1,044 | 3,417→3,415 | 1,427 | 1,529 | 260 |
| 16 | 5842–6206 | 143 | 165 | -22 | 1,015→1,047 | 3,417→3,434 | 1,208 | 1,427 | 253 |
| 17 | 6207–6571 | 107 | 165 | -58 | 1,011→1,043 | 3,434→3,428 | 1,104 | 1,299 | 264 |
| 18 | 6572–6936 | 148 | 159 | -11 | 1,009→1,032 | 3,428→3,438 | 1,104 | 1,262 | 255 |
| 19 | 6937–7301 | 159 | 152 | 7 | 996→1,017 | 3,436→3,440 | 950 | 1,147 | 255 |
| 20 | 7302–7360 | 28 | 27 | 1 | 1,004→1,002 | 3,442→3,441 | 215 | 184 | 250 |

## Population and cohorts

| Profession | Population first→last | Δ | Min livelihood coverage | Min satisfaction | Final worst need | First loss day |
|---|---:|---:|---:|---:|---|---:|
| forager | 9→3 | -6 | 11.1% | 0.0% | home_energy | 25 |
| unemployed | 2→1 | -1 | 0.0% | 0.0% | -1 | 5 |

## Building viability

| Building | Revenue/viability cost | Owner livelihood coverage | Sell-through | Discard | Util early→late | Margin late | State end | First suspended |
|---|---:|---:|---:|---:|---:|---:|---|---:|
| merchant_post | 0.0% | 0.0% | — | — | 9.9%→0.0% | 0.0% | suspended | 20 |
| flint_quarry | 88.1% | 88.1% | 96.0% | 4.0% | 18.5%→3.1% | 0.0% | active | 25 |

### Artisan target buildings

| Building | Owner livelihood coverage | Revenue/viability | Util early→late | Margin late | First suspended | State end |
|---|---:|---:|---:|---:|---:|---|
| knapping_workshop | 103.6% | 103.4% | 47.7%→33.6% | 3.3% | 35 | active |
| household_weaving_shelter | 187.1% | 182.7% | 35.2%→33.0% | 0.1% | 95 | active |

## Market stress

| Good | Price first→last | Price=1 share while active | Late shortage | Late demand | Late business demand | Late stock | Cost anchor last |
|---|---:|---:|---:|---:|---:|---:|---:|
| fur | 24,000→67,322 | 0.0% | 29.6% | 97 | 0 | 434 | 16,586 |
| cloth | 24,000→75,900 | 0.0% | 13.5% | 122 | 0 | 3,082 | 59,975 |
| gathered_plants | 5,000→1,884 | 0.0% | 11.5% | 14,498 | 12,826 | 542,109 | 1,777 |
| chipped_stone_tools | 75,000→13,182 | 0.0% | 10.6% | 134 | 191 | 8,541 | 41,194 |
| logs | 10,000→8,407 | 0.0% | 7.3% | 11,486 | 35 | 264,264 | 1,111 |
| game_meat | 10,000→4,470 | 0.0% | 5.5% | 5,689 | 6,373 | 158,127 | 6,911 |
| fish | 10,000→5,945 | 0.0% | 3.4% | 8,274 | 0 | 48,120 | 2,268 |
| processed_food | 16,000→1,532 | 0.0% | 3.1% | 29,302 | 0 | 761,447 | 2,910 |
| flint | 4,000→12 | 0.0% | 0.0% | 0 | 39 | 30,431 | 12,571 |
| raw_hide | 24,000→12 | 0.0% | 0.0% | 0 | 0 | 14,400 | 17,331 |

## Resource stock-flow

| Resource | Reserve first→last | Δ | Natural + | Natural - | Extraction | Replacement ratio |
|---|---:|---:|---:|---:|---:|---:|
| clay | 23,002,214→9,688,813 | -13,313,401 | 483,126 | 13,796,527 | 0 | 0.04 |
| fertile_soil | 350,000→64,893 | -285,107 | 47,496 | 332,603 | 0 | 0.14 |
| oil | 26,935,452→26,900,124 | -35,328 | 0 | 35,328 | 0 | 0.00 |
| flint | 61,933,584→61,933,576 | -8 | 6 | 8 | 6 | 0.43 |

## Recorder scope

- Summary rows are global runtime aggregates; cohort, market, building, and resource rows describe the selected cell.
- Early/late windows are the first/last 180 simulation days.
- Money, goods, and Q16 values remain in recorder integer units unless shown as percentages.
