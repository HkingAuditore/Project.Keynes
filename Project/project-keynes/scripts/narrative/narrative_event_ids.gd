class_name NarrativeEventIds
extends RefCounted

## 叙事事件网的唯一字符串真源。
##
## 规则：
##   1. pack 文件与测试一律从这里取 event_id / flag / tag，禁止手抄字符串；
##   2. 新增一条事件 = 这里加一个常量 + 所属 pack 加一条定义 + pack meta 的 node_ids 加一项；
##   3. 跨包引用（排程、门槛、偏置）必须走常量，测试会逐条校验目标存在。
##
## 命名：EVT_<PACK>_<NAME>；FLAG_<NAME>；TAG_<NAME>；PACK_<NAME>。

# ── 包 id ────────────────────────────────────────────────────────────────────
const PACK_COURT := &"court"
const PACK_FRONTIER := &"frontier"
const PACK_FAITH := &"faith"
const PACK_FISCAL := &"fiscal"
const PACK_LABOR := &"labor"
const PACK_ERA := &"era"
const PACK_PEOPLE := &"family"
const PACK_LAND := &"land"
const PACK_WILDS := &"wilds"
const PACK_TOWN := &"town"
const PACK_AGES := &"ages"
const PACK_DAWN := &"dawn"
const PACK_SEA := &"sea"
const PACK_RAIL := &"rail"
const PACK_ATOM := &"atom"
const PACK_SCHOOL := &"school"
const PACK_PLAGUE := &"plague"
const PACK_LAW := &"law"
const PACK_ENVOY := &"envoy"
const PACK_CITYCHAIN := &"citychain"
const PACK_ATOMCHAIN := &"atomchain"
const PACK_FAMILY2 := &"family2"
const PACK_FAMILY3 := &"family3"
const PACK_WAR := &"war"
const PACK_TECH := &"tech"

# ── 主题标签（权重偏置按 tag 命中；插图/徽章也读它）────────────────────────
const TAG_COURT := &"court"
const TAG_FRONTIER := &"frontier"
const TAG_FAITH := &"faith"
const TAG_MARKET := &"market"
const TAG_LABOR := &"labor"
const TAG_ERA := &"era"
const TAG_PEOPLE := &"people"
const TAG_LAND := &"land"
const TAG_UNREST := &"unrest"
const TAG_CHAIN := &"chain"

# ── 宫廷 ────────────────────────────────────────────────────────────────────
const EVT_COURT_EMPTY_SEAT := &"evt.court.empty_seat"
const EVT_COURT_REGENT := &"evt.court.regent_bargain"
const EVT_COURT_TWO_SEALS := &"evt.court.two_seals"
const EVT_COURT_EXILED := &"evt.court.exiled_official"

const FLAG_SILT_WAITING := &"flag_silt_waiting"
const FLAG_MINE_COLLAPSE := &"flag_mine_collapse"
const FLAG_MINE_SEALED := &"flag_mine_sealed"
const FLAG_FOREST_CLOSED := &"flag_forest_closed"
const FLAG_FOREST_PENDING := &"flag_forest_pending"
const FLAG_SHRINE_KEPT := &"flag_shrine_kept"
const FLAG_SHRINE_WAITING := &"flag_shrine_waiting"

# ── 边镇 ────────────────────────────────────────────────────────────────────
const EVT_FRONTIER_SOLDIER_FARM := &"evt.frontier.soldier_farm"
const EVT_FRONTIER_LONG_GARRISON := &"evt.frontier.long_garrison"
const EVT_FRONTIER_GENERAL_AT_GATE := &"evt.frontier.general_at_gate"
const EVT_FRONTIER_HOSTAGE := &"evt.frontier.hostage_boy"

# ── 信仰 ────────────────────────────────────────────────────────────────────
const EVT_FAITH_TEMPLE_ESTATE := &"evt.faith.temple_estate"
const EVT_FAITH_ONE_BOOK := &"evt.faith.one_book"
const EVT_FAITH_NEW_ALTAR := &"evt.faith.new_altar"
const EVT_FAITH_PLAGUE_PROCESSION := &"evt.faith.plague_procession"

# ── 财政 ────────────────────────────────────────────────────────────────────
const EVT_FISCAL_STATE_LOAN := &"evt.fiscal.state_loan"
const EVT_FISCAL_DEBASED_COIN := &"evt.fiscal.debased_coin"
const EVT_FISCAL_AUDIT := &"evt.fiscal.audit"
const EVT_FISCAL_SALT := &"evt.fiscal.salt_licence"
const EVT_FISCAL_TWO_LEDGERS := &"evt.fiscal.two_ledgers"

# ── 工业与劳工 ──────────────────────────────────────────────────────────────
const EVT_LABOR_ENCLOSURE := &"evt.labor.enclosure"
const EVT_LABOR_BROKEN_LOOM := &"evt.labor.broken_loom"
const EVT_LABOR_FACTORY_ACT := &"evt.labor.factory_act"
const EVT_LABOR_GUILD_CHARTER := &"evt.labor.guild_charter"
const EVT_LABOR_WIDOW_WORKSHOP := &"evt.labor.widow_workshop"

# ── 高时代 ──────────────────────────────────────────────────────────────────
const EVT_ERA_GREAT_WORKS := &"evt.era.great_works"
const EVT_ERA_STANDARD_WAR := &"evt.era.standard_war"
const EVT_ERA_ALGORITHM_SHIFT := &"evt.era.algorithm_shift"
const EVT_ERA_QUIET_ROOM := &"evt.era.quiet_room"

# ── 人与家 ──────────────────────────────────────────────────────────────────
const EVT_FAMILY_SECOND_SON := &"evt.family.second_son"
const EVT_FAMILY_BRIDE_PRICE := &"evt.family.bride_price"
const EVT_FAMILY_FATHERS_DEBT := &"evt.family.fathers_debt"
const EVT_FAMILY_RETURNING_SOLDIER := &"evt.family.returning_soldier"

# ── 地块 ────────────────────────────────────────────────────────────────────
const EVT_LAND_SILTED_HARBOR := &"evt.land.silted_harbor"
const EVT_LAND_OLD_MINE := &"evt.land.old_mine"
const EVT_LAND_FOREST_EDGE := &"evt.land.forest_edge"
const EVT_LAND_RUINED_SHRINE := &"evt.land.ruined_shrine"

# ── 风土（零散：自然与地块）────────────────────────────────────────────────
const EVT_WILDS_DRY_WELL := &"evt.wilds.dry_well"
const EVT_WILDS_LOCUST := &"evt.wilds.locust_swarm"
const EVT_WILDS_WOLF_WINTER := &"evt.wilds.wolf_winter"
const EVT_WILDS_SALT_BLOOM := &"evt.wilds.salt_bloom"
const EVT_WILDS_LANDSLIDE := &"evt.wilds.landslide"
const EVT_WILDS_RIVER_FORD := &"evt.wilds.river_ford"
const EVT_WILDS_REED_FIRE := &"evt.wilds.reed_fire"
const EVT_WILDS_COLD_SPRING := &"evt.wilds.cold_spring"

# ── 市井（零散：行当与纠纷）────────────────────────────────────────────────
const EVT_TOWN_NIGHT_WATCH := &"evt.town.night_watch"
const EVT_TOWN_BEGGAR_GUILD := &"evt.town.beggar_guild"
const EVT_TOWN_FALSE_COIN := &"evt.town.false_coin"
const EVT_TOWN_FIRE := &"evt.town.fire"
const EVT_TOWN_STALL_FIGHT := &"evt.town.stall_fight"
const EVT_TOWN_RUMOR := &"evt.town.rumor"
const EVT_TOWN_GUILD_FUNERAL := &"evt.town.guild_funeral"
const EVT_TOWN_WELL_DISPUTE := &"evt.town.well_dispute"

# ── 历代（零散：补时代空档）────────────────────────────────────────────────
const EVT_AGES_FIRST_SEED := &"evt.ages.first_seed"
const EVT_AGES_FIRST_GRAVE := &"evt.ages.first_grave"
const EVT_AGES_CLAY_FIGURE := &"evt.ages.clay_figure"
const EVT_AGES_CARAVAN_LOST := &"evt.ages.caravan_lost"
const EVT_AGES_COMPASS_DOUBT := &"evt.ages.compass_doubt"
const EVT_AGES_SIGNAL_TOWER := &"evt.ages.signal_tower"
const EVT_AGES_MACHINE_HEARS := &"evt.ages.machine_hears"
const EVT_AGES_LAST_FOREST := &"evt.ages.last_forest"

# ── 标记：短程门（≤1825 日）与权重支点 ─────────────────────────────────────
const FLAG_THRONE_DISPUTED := &"flag_throne_disputed"
const FLAG_REGENT_PAID := &"flag_regent_paid"
const FLAG_REGENT_ENTRENCHED := &"flag_regent_entrenched"
const FLAG_TWO_COURTS := &"flag_two_courts"
const FLAG_OLD_LEDGER := &"flag_old_ledger"

const FLAG_FRONTIER_SELFRAISE := &"flag_frontier_selfraise"
const FLAG_WARLORD := &"flag_warlord"

const FLAG_TEMPLE_SEIZED := &"flag_temple_seized"
const FLAG_TEMPLE_BARGAINED := &"flag_temple_bargained"
const FLAG_TEMPLE_PENDING := &"flag_temple_pending"
const FLAG_ALTAR_OFFICIAL := &"flag_altar_official"
const FLAG_ALTAR_SPLIT := &"flag_altar_split"
const FLAG_ALTAR_EMPTY := &"flag_altar_empty"
const FLAG_OPEN_DISPUTE := &"flag_open_dispute"

const FLAG_TWO_PRICES := &"flag_two_prices"
const FLAG_ACCOUNTS_CLEAN := &"flag_accounts_clean"
const FLAG_ARMY_GRIEVANCE := &"flag_army_grievance"
const FLAG_PATCHED_BOOKS := &"flag_patched_books"
const FLAG_SALT_OPEN := &"flag_salt_open"
const FLAG_COOKED_BOOKS := &"flag_cooked_books"

const FLAG_ENCLOSURE_PETITION := &"flag_enclosure_petition"
const FLAG_CHARTER_PENDING := &"flag_charter_pending"
const FLAG_WIDOW_SIGN := &"flag_widow_sign"
const FLAG_HOURS_TEN := &"flag_hours_ten"

const FLAG_SECOND_SON_SPLIT := &"flag_second_son_split"
const FLAG_SECOND_SON_PENDING := &"flag_second_son_pending"
const FLAG_BRIDE_PENDING := &"flag_bride_pending"
const FLAG_DEBT_PENDING := &"flag_debt_pending"

const FLAG_HEGU_FIRED := &"flag_hegu_fired"
const FLAG_STD_OPEN := &"flag_std_open"
const FLAG_SHIFT_PENDING := &"flag_shift_pending"

# ── 黎明（era 0–2）──────────────────────────────────────────────────────────
const EVT_DAWN_FIRST_WALL := &"evt.dawn.first_wall"
const EVT_DAWN_DIVIDE_FIELDS := &"evt.dawn.divide_fields"
const EVT_DAWN_COMMON_WELL := &"evt.dawn.common_well"
const EVT_DAWN_FIRST_MARKET := &"evt.dawn.first_market"
const EVT_DAWN_FIRST_SMITH := &"evt.dawn.first_smith"
const EVT_DAWN_OATH_STONE := &"evt.dawn.oath_stone"
const EVT_DAWN_WATER_BRAWL := &"evt.dawn.water_brawl"

# ── 远航（era 4–6）──────────────────────────────────────────────────────────
const EVT_SEA_CHART := &"evt.sea.chart"
const EVT_SEA_MONSOON := &"evt.sea.monsoon"
const EVT_SEA_PIRATE := &"evt.sea.pirate"
const EVT_SEA_CHARTER := &"evt.sea.port_charter"
const EVT_SEA_WRECK := &"evt.sea.wreck"
const EVT_SEA_DRYDOCK := &"evt.sea.drydock"
const EVT_SEA_PILOT := &"evt.sea.pilot"

# ── 铁路（era 6–8）──────────────────────────────────────────────────────────
const EVT_RAIL_LAND := &"evt.rail.land_taken"
const EVT_RAIL_STATION := &"evt.rail.station"
const EVT_RAIL_TIMETABLE := &"evt.rail.timetable"
const EVT_RAIL_FARE := &"evt.rail.fare"
const EVT_RAIL_BRIDGE := &"evt.rail.bridge"
const EVT_RAIL_TUNNEL := &"evt.rail.tunnel"
const EVT_RAIL_FREIGHT := &"evt.rail.freight"

# ── 原子（era 8–10）────────────────────────────────────────────────────────
const EVT_ATOM_REACTOR := &"evt.atom.reactor"
const EVT_ATOM_WASTE := &"evt.atom.waste"
const EVT_ATOM_SATELLITE := &"evt.atom.satellite"
const EVT_ATOM_CHANNEL := &"evt.atom.channel"
const EVT_ATOM_NETWORK := &"evt.atom.network"
const EVT_ATOM_PRIVACY := &"evt.atom.privacy"
const EVT_ATOM_AUTOMATION := &"evt.atom.automation"

# ── 学院（era 3–9）──────────────────────────────────────────────────────────
const EVT_SCHOOL_CHARTER := &"evt.school.charter"
const EVT_SCHOOL_SOCIETY := &"evt.school.society"
const EVT_SCHOOL_PRESS := &"evt.school.press"
const EVT_SCHOOL_PATENT := &"evt.school.patent"
const EVT_SCHOOL_EXAM := &"evt.school.exam"
const EVT_SCHOOL_ABROAD := &"evt.school.abroad"
const EVT_SCHOOL_PRIORITY := &"evt.school.priority"

# ── 疫与医（era 1–9）────────────────────────────────────────────────────────
const EVT_PLAGUE_SHIP := &"evt.plague.ship"
const EVT_PLAGUE_QUARANTINE := &"evt.plague.quarantine"
const EVT_PLAGUE_MIDWIFE := &"evt.plague.midwife"
const EVT_PLAGUE_HERBS := &"evt.plague.herbs"
const EVT_PLAGUE_HOSPITAL := &"evt.plague.hospital"
const EVT_PLAGUE_VACCINE := &"evt.plague.vaccine"
const EVT_PLAGUE_QUACK := &"evt.plague.quack"

# ── 律法（era 2–9）──────────────────────────────────────────────────────────
const EVT_LAW_CODE := &"evt.law.code"
const EVT_LAW_ASSIZE := &"evt.law.assize"
const EVT_LAW_DEBT := &"evt.law.debtors"
const EVT_LAW_DEED := &"evt.law.deed"
const EVT_LAW_WITNESS := &"evt.law.witness"
const EVT_LAW_PARDON := &"evt.law.pardon"
const EVT_LAW_NOTARY := &"evt.law.notary"

# ── 使节（era 3–7）──────────────────────────────────────────────────────────
const EVT_ENVOY_TRIBUTE := &"evt.envoy.tribute"
const EVT_ENVOY_INTERPRETER := &"evt.envoy.interpreter"
const EVT_ENVOY_BORDER := &"evt.envoy.border_market"
const EVT_ENVOY_OATH := &"evt.envoy.broken_oath"
const EVT_ENVOY_MARRIAGE := &"evt.envoy.marriage"
const EVT_ENVOY_HORSES := &"evt.envoy.horses"
const EVT_ENVOY_SECRET := &"evt.envoy.secret_clause"

# ── 跨时代链：筑城（0–2）· 停堆（9–10）──────────────────────────────────────
const EVT_CHAIN_CITY_WALL := &"evt.citychain.wall"
const EVT_CHAIN_CITY_KING := &"evt.citychain.king"
const EVT_CHAIN_CITY_SIEGE := &"evt.citychain.siege"
const EVT_CHAIN_ATOM_LIGHT := &"evt.atomchain.light"
const EVT_CHAIN_ATOM_WASTE := &"evt.atomchain.waste"
const EVT_CHAIN_ATOM_VOTE := &"evt.atomchain.vote"

# ── 家族桥（10 条，读家族快照、授/撤家族特质）──────────────────────────────
const EVT_FAMILY2_SCHOOL := &"evt.family2.school"
const EVT_FAMILY2_GRANARY := &"evt.family2.granary"
const EVT_FAMILY2_FEUD := &"evt.family2.feud"
const EVT_FAMILY2_LOAN := &"evt.family2.loan"
const EVT_FAMILY2_OFFICE := &"evt.family2.office"
const EVT_FAMILY2_MIGRATION := &"evt.family2.migration"
const EVT_FAMILY2_GUILD := &"evt.family2.guild"
const EVT_FAMILY2_MARRIAGE := &"evt.family2.marriage"
const EVT_FAMILY2_RELIEF := &"evt.family2.relief"
const EVT_FAMILY2_SEA := &"evt.family2.sea"

# ── 家族桥第二批（12 条：A 层 6 + B 层 6）────────────────────────────────
const EVT_FAMILY3_WET_NURSE := &"evt.family3.wet_nurse"
const EVT_FAMILY3_ANCESTRAL_HALL := &"evt.family3.ancestral_hall"
const EVT_FAMILY3_SCHOLAR_BOARD := &"evt.family3.scholar_board"
const EVT_FAMILY3_TAX_FARM := &"evt.family3.tax_farm"
const EVT_FAMILY3_PRIVATE_ARM := &"evt.family3.private_arm"
const EVT_FAMILY3_CHARITY_ESTATE := &"evt.family3.charity_estate"
const EVT_FAMILY3_ENCLOSURE_RESIST := &"evt.family3.enclosure_resist"
const EVT_FAMILY3_CHARTER_GUILD := &"evt.family3.charter_guild"
const EVT_FAMILY3_CRAFT_SPLIT := &"evt.family3.craft_split"
const EVT_FAMILY3_LETTERS_RAID := &"evt.family3.letters_raid"
const EVT_FAMILY3_MAGNATE_TAX := &"evt.family3.magnate_tax"
const EVT_FAMILY3_COASTAL_SHIFT := &"evt.family3.coastal_shift"

# ── 战争（12 条：6 条事实驱动 + 6 条战时脉冲）──────────────────────────────
const EVT_WAR_DECLARATION := &"evt.war.declaration"
const EVT_WAR_VICTORY := &"evt.war.victory"
const EVT_WAR_BATTLE := &"evt.war.battle"
const EVT_WAR_CITY_TAKEN := &"evt.war.city_taken"
const EVT_WAR_ARMY_LOST := &"evt.war.army_lost"
const EVT_WAR_ANNEXED := &"evt.war.annexed"
const EVT_WAR_CONSCRIPTION := &"evt.war.conscription"
const EVT_WAR_ARREARS := &"evt.war.arrears"
const EVT_WAR_WOUNDED := &"evt.war.wounded"
const EVT_WAR_REFUGEES := &"evt.war.refugees"
const EVT_WAR_ARMY_MARKET := &"evt.war.army_market"
const EVT_WAR_AFTERMATH := &"evt.war.aftermath"
const EVT_WAR_KINDRED_LEVY := &"evt.war.kindred_levy"
const EVT_WAR_KINDRED_WAIT := &"evt.war.kindred_wait"
const EVT_WAR_KINDRED_SHRINE := &"evt.war.kindred_shrine"

const FLAG_WAR_KINDRED_SENT := &"flag_war_kindred_sent"
const FLAG_WAR_KINDRED_DEAD := &"flag_war_kindred_dead"

# ── 技术（6 条，按具体科技分支）────────────────────────────────────────
const EVT_TECH_IRRIGATION := &"evt.tech.irrigation"
const EVT_TECH_PRINTING := &"evt.tech.printing"
const EVT_TECH_GUNPOWDER := &"evt.tech.gunpowder"
const EVT_TECH_STEAM := &"evt.tech.steam"
const EVT_TECH_RAIL := &"evt.tech.rail"
const EVT_TECH_FERTILIZER := &"evt.tech.fertilizer"
