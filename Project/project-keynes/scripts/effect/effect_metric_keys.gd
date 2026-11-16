# Stable metric prefix shared with NativeEconomyRuntime. Append only.
extends RefCounted

const KEYS := [
	"family.magnitude_q16",
	"family.population",
	"family.cash_claim",
	"branch.prestige_q16",
	"branch.population",
	"cell.temperature_q16",
	"cell.precipitation_q16",
	"cell.resource_shortage_q16",
	"cell.trade_events",
	"cell.population",
	"cell.landform",
	"cell.essentials_shortage_q16",
	"branch.is_local_prestige_max",
	"cell.rain_event",
	"cell.resource_abundance_q16",
	"family.has_owned_manufacturing",
	"family.distinct_sector_count",
	"family.dominant_sector_id",
	"family.dominant_sector_share_q16",
	"family.complete_chain_count",
	"family.max_local_chain_share_q16",
	"family.max_chain_upgrade_family_id",
	"cell.unemployment_q16",
	"cell.resource_class_count",
	"cell.manufacturing_building_count",
	"cell.distinct_sector_count",
	"cell.dominant_sector_id",
	"cell.dominant_sector_share_q16",
	"cell.complete_chain_count",
	"cell.has_extractive_resource",
	"cell.legal_building_type_count",
	"cell.vacant_profession_count",
	"family.branch_count",
	"family.remote_branch_count",
	"family.cash_per_capita_vs_cell_q16",
	"cell.knowledge_building_class_count",
	"cell.can_produce_corn",
	# --- Output-share metrics (ids 37..46) -----------------------------
	# The *_SECTOR_SHARE_Q16 rows above count BUILDINGS, so raising a sector
	# output coefficient leaves them unmoved. These are aggregated from
	# group.last_output (already net of the output factor), so an
	# "industry share >= X -> boost" condition actually closes the loop.
	# Index order below MUST match the C++ FamilyEffectMetricId enum, since
	# the array index is the metric id.
	"cell.sector_output_share.agriculture_q16",
	"cell.sector_output_share.extractive_q16",
	"cell.sector_output_share.manufacturing_q16",
	"cell.sector_output_share.energy_q16",
	"cell.sector_output_share.knowledge_q16",
	"cell.dominant_sector_output_share_q16",
	# Resources (building_resource_ids: iron, corn, ...) and goods
	# (building_outputs[].good_id) are separate id spaces. The stock rows
	# answer "this cell is rich in iron"; the output rows answer "this cell
	# mostly produces X".
	"cell.dominant_resource_id",
	"cell.dominant_resource_stock_share_q16",
	"cell.dominant_output_good_id",
	"cell.top_output_good_share_q16",
	# --- Country scalars (ids 47..49) -----------------------------------
	# Read from the frozen CountryClassOpinionSnapshot, the same source
	# ideology point accrual uses, so a condition never samples a country
	# mid-write. research_speed / build_speed are intentionally absent: the
	# project models neither, and a metric that always reads 0 would make
	# such a card silently inert.
	"country.population_q16",
	"country.buildings_installed",
	"country.trade_base_value_q16",
	# --- Terrain axis (id 50) -------------------------------------------
	# NOT the same id space as `cell.landform` (id 10): that one is the
	# LandformType axis (plain / hills / delta / ...), this one is
	# TerrainType (grassland / floodplain / ...). 「河谷」is a floodplain
	# TERRAIN, so it could not be tagged at all while only landform existed.
	"cell.terrain",
	# --- X3: the cell's profession mix (ids 51..53) ----------------------
	# One id for "this is a hunters' camp", one share for "single-profession
	# town >= 80%", one count for diversity. Deliberately not one metric per
	# profession: the profession list is data-driven, and an enum edited on
	# every content change rots.
	"cell.dominant_profession_id",
	"cell.dominant_profession_share_q16",
	"cell.profession_count",
	# --- X2: the neighbourhood (id 54) ----------------------------------
	# Sum of the six neighbours' populations. The cheap half of X2: O(6) per
	# sample instead of walking every neighbour's buildings.
	"cell.neighbor_population_q16",
	# --- X11: what the state takes (id 55) ------------------------------
	# Mean income-tax rate across professions, basis points (10000 = 100%).
	"country.income_tax_burden_bp",
	# --- X7: how much of the country looks a certain way (ids 56..61) ---
	# Counts of the country's OWN cells matching a compiled-in tag list
	# (economy_runtime_family_buff.cpp `kCountryTagCountSlots`). Slot order
	# is the metric order; appending a tag means appending an id.
	"country.agriculture_cell_count",
	"country.extractive_cell_count",
	"country.manufacturing_cell_count",
	"country.chained_cell_count",
	"country.specialized_cell_count",
	"country.market_cell_count",
	"country.settlement_cell_count",
	# Per-good counts reuse the same slot table: `cell.produces.<good>` is
	# "dominant output good == that good", so a slot is the whole feature.
	"country.silver_cell_count",
	"country.salt_cell_count",
	"country.iron_ore_cell_count",
	"country.coal_cell_count",
	# Distinct goods with at least one specialized cell (share >= 60%).
	# Cannot be derived from tag counts: duplicates must collapse.
	"country.distinct_specialized_good_count",
	# R-4: net tax burden of this cell's cohorts over the current epoch, as a
	# Q16 ratio (0 = untaxed, Q16_ONE = every unit of income taken).
	"cell.net_tax_burden_q16",
	# R-4: country treasury cash as a percentage of one year of national income,
	# as a COUNT of percentage points (1 point = 1%). A ramp's `per` is a fraction
	# of the value, so a count here is what the generator's lint expects.
	"country.treasury_reserve_ratio_pct",
	# --- 19 §3.2 reservation (ids 70..86) ---------------------------------
	# Placeholders: the owning lane renames its key to the real metric name when
	# it implements the sampler. A reserved.* key is never bound by the generator.
	"cell.temperature_annual_q16",
	"cell.dry_streak_days",
	"cell.hazard_today_mask",
	"cell.days_since_hazard",
	"cell.temperature_anomaly_q16",
	"cell.geo_flags",
	"cell.waterway_component_size",
	"country.class_satisfaction_q16",
	"country.weighted_satisfaction_q16",
	"country.completed_tech_count",
	"country.completed_tech_count.agriculture",
	"country.completed_tech_count.engineering",
	"country.completed_tech_count.science",
	"country.completed_tech_count.society",
	"cell.family_branch_count",
	"cell.max_branch_prestige_q16",
	"cell.family_asset_share_q16",
	"cell.neighbor_distinct_goods",
	"country.hazard_free_cell_share_q16",
	# X14 extension: committed `farmer` class satisfaction. This is a
	# separate row from metric 77 (general) so petition_box can gate on the
	# class the design names.
	"country.farmer_satisfaction_q16",
	# X9-b: country-level family aggregates rebuilt at FAMILY_COMMIT.
	"country.family_remote_branch_count",
	"country.families_with_at_least_3_branches",
	"country.max_family_age_days",
	"country.avg_family_age_days",
	# X2 extension: count of the six neighbours whose agriculture output
	# share is at least 50%. 95 remains a reserved X3-b slot.
	"cell.neighbor_agriculture_count",
	"reserved.x3b_95",
	# X3-b profession shares, measured across the cell's known-profession
	# population (the same denominator as metrics 51..53).
	"cell.profession_share_farmer_q16",
	"cell.profession_share_industrial_q16",
	"cell.profession_share_cooperative_q16",
	# X14 extension used by trade_unions: committed `worker` class satisfaction.
	"country.worker_class_satisfaction_q16",
	"reserved.x3b_100",
	"reserved.x3b_101",
	# X7-b: committed country counts for infrastructure/science cards.
	"country.energy_cell_count",
	"country.abundant_mountain_forest_cell_count",
	"country.landform_signal_count",
	"country.weather_signal_count",
	"country.bio_signal_count",
	# The allocation reserves 102-107 for X7-b but names only five
	# mechanics; keep the final slot explicit rather than shifting a count.
	"reserved.x7b_107",
	# NOTE (military §17.1): the `cell.barracks` / `cell.fortified` /
	# `cell.military_industry` / `cell.garrisoned` / `cell.occupied_by_*`
	# tags do NOT add metric ids here. Economy's sampler caps its row count
	# at `FAMILY_METRIC_COUNT` (a constant owned by economy_runtime.h), so an
	# id past 107 would compile in this catalog and then read as 0 forever --
	# a tag that validates and never matches. Military publishes those tags
	# through Economy's `CellTagOverrideSet` instead
	# (gdext/src/world_ext_military_cell_stats.cpp), which forces the bit
	# after predicate evaluation. Their dictionary rows therefore point at a
	# metric that is true for every cell, and the override is what narrows
	# the set.
]
