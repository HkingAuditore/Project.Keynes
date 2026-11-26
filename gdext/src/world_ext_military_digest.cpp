#include "native_simulation_host_military.h"
#include "runtime_pod_protocol.h"

#include "world_ext.h"
#include "world_ext_internal_military_intents.h"
#include "native_simulation_host.h"

#include <chrono>
#include "country_api.h"
#include "economy_api.h"
#include "military_core.h"
#include "modifier_api.h"

#include <algorithm>
#include <cmath>
#include <limits>

namespace pk {
namespace {

constexpr int32_t MILITARY_Q = MILITARY_Q16;
constexpr int32_t MILITARY_SUPPLY_CLASSES = MILITARY_MAX_SUPPLY_CLASSES;

int32_t q16_from_float(double value) {
    if (!std::isfinite(value)) return 0;
    const double scaled = value * static_cast<double>(MILITARY_Q);
    if (scaled >= static_cast<double>(std::numeric_limits<int32_t>::max()))
        return std::numeric_limits<int32_t>::max();
    if (scaled <= static_cast<double>(std::numeric_limits<int32_t>::min()))
        return std::numeric_limits<int32_t>::min();
    return static_cast<int32_t>(std::llround(scaled));
}

// Military statistics the core consumes (MilitaryStatId order, q16). The
// bridge reads real Modifier values when a Modifier runtime is attached and
// falls back to the design defaults otherwise, so a world without military
// content still simulates.
const char *const kMilitaryStatKeys[MSTAT_COUNT] = {
    "country.military.attack_factor",
    "country.military.defense_factor",
    "country.military.speed_factor",
    "country.military.logistics_move_factor",
    "country.military.supply_transport_factor",
    "country.military.supply_consumption_factor",
    "country.military.barracks_capacity_factor",
    "country.military.levy_rate",
    "country.military.wage_factor",
    "country.military.training_time_factor",
    "country.military.desertion_factor",
    "country.military.casualty_factor",
    "country.military.attrition_factor",
    "country.military.organization_recovery_factor",
    "country.military.morale_add",
    "country.military.fortification_factor",
    "country.military.frontage_factor",
    "country.military.militia_factor",
    "country.military.occupation_tax_efficiency",
    "country.military.naval_transport_factor",
    "country.military.vision_add",
    // Keys must match ModifierCatalog.TECHNOLOGY_STATS (modifier_catalog.gd).
    "country.military.convoy_escort_factor",
    "country.military.rule.mutual_support",
    "country.military.rule.last_stand",
    "country.military.rule.blitz",
    "country.military.rule.hold_the_line",
    "country.military.rule.encirclement",
    "country.military.rule.home_ground",
};

// Design §13 / §12.1 defaults in q16 for the stats whose base is not 1.0.
int32_t military_stat_default_q16(int32_t stat) {
    switch (stat) {
    case MSTAT_LEVY_RATE: return (MILITARY_Q * 3) / 100;  // 3% of cell population
    case MSTAT_WAGE: return (MILITARY_Q * 13) / 10;       // 1.3
    case MSTAT_OCCUPATION_TAX: return MILITARY_Q / 2;      // 0.5
    case MSTAT_MORALE_ADD:
    case MSTAT_VISION_ADD:
    case MSTAT_RULE_MUTUAL_SUPPORT:
    case MSTAT_RULE_LAST_STAND:
    case MSTAT_RULE_BLITZ:
    case MSTAT_RULE_HOLD_THE_LINE:
    case MSTAT_RULE_ENCIRCLEMENT:
    case MSTAT_RULE_HOME_GROUND: return 0;
    default: return MILITARY_Q;
    }
}

} // namespace

// ===========================================================================
// digest capture (day D committed Country + Economy)
// ===========================================================================

void NativeMilitaryRuntime::capture_military_digest(MilitaryWorldDigest &digest,
                                         MilitaryDigestScratch &scratch,
                                         const MilitaryCatalog &catalog,
                                         bool *economy_ready) {
    if (economy_ready != nullptr) *economy_ready = false;
    const int32_t cells = std::max(0, core().terrain().cell_count);
    digest.day = -1;
    // The digest object is reused across days, so the state building lanes must
    // be reset up front: an economy read that fails below must not leave
    // yesterday's rows in place, because the core would rebuild its cache from
    // stale ledger data instead of keeping what the save restored.
    digest.state_lanes_present = false;
    digest.state_lane_rows = 0;
    // ---- Country: one pinned committed projection ----
    int32_t country_count = 0;
    std::vector<int64_t> cash(std::max<size_t>(scratch.country_cash.size(), 1), 0);
    std::vector<int32_t> owner;
    std::vector<uint64_t> handles;
    if (country_state != nullptr) {
        country_count = static_cast<int32_t>(country_state->country_count);
        owner = country_state->cell_country_slot;
        cash = country_state->country_cash;
        handles.resize(static_cast<size_t>(country_count), 0);
        for (int32_t slot = 0; slot < country_count; ++slot) {
            if (country_state->country_active[slot] != 0)
                handles[slot] = (uint64_t(country_state->country_generation[slot]) << 32) |
                    static_cast<uint32_t>(slot);
        }
    } else if (_country_runtime != nullptr) {
        NativeCountryRuntime *country = static_cast<NativeCountryRuntime *>(_country_runtime);
        CountryEconomySnapshot snapshot;
        if (country_api::copy_economy_snapshot(*country, snapshot)) {
            country_count = snapshot.country_count;
            owner = std::move(snapshot.cell_country_slot);
            handles = std::move(snapshot.country_handles);
            cash.assign(static_cast<size_t>(country_count), 0);
            for (int32_t slot = 0; slot < country_count; ++slot)
                cash[static_cast<size_t>(slot)] = country_api::cash_for_slot(*country, slot);
        }
    }
    if (owner.size() < static_cast<size_t>(cells)) owner.resize(static_cast<size_t>(cells), -1);
    if (owner.size() > static_cast<size_t>(cells)) owner.resize(static_cast<size_t>(cells));
    // Military stores policy rows by slot, and a slot only exists once the core
    // has seen the handle. Open one per active country here, in slot order, so
    // `submit()` (which rejects unknown countries) and the policy queries below
    // agree with the digest rows. Idempotent: existing slots keep their state.
    for (int32_t slot = 0; slot < country_count; ++slot) {
        const uint64_t handle = static_cast<size_t>(slot) < handles.size()
            ? handles[static_cast<size_t>(slot)] : 0;
        if (handle == 0) continue;
        core().ensure_country_slot(handle);
    }
    digest.cell_owner_slot = std::move(owner);
    digest.country_capacity = country_count;
    digest.country_handle = std::move(handles);
    digest.country_cash = std::move(cash);
    digest.country_era.assign(static_cast<size_t>(country_count), 0);
    digest.country_annual_revenue.assign(static_cast<size_t>(country_count), 0);
    digest.country_capital_cell.assign(static_cast<size_t>(country_count), -1);
    digest.country_soldier_living_cost.assign(static_cast<size_t>(country_count), 0);
    // ---- Economy: dense per-cell lanes + sparse military-supply markets ----
    scratch.cell_population.assign(static_cast<size_t>(cells), 0);
    scratch.cell_unemployed.assign(static_cast<size_t>(cells), 0);
    scratch.cell_soldiers.assign(static_cast<size_t>(cells), 0);
    scratch.cell_has_merchant.assign(static_cast<size_t>(cells), 0);
    scratch.market_cell.clear();
    scratch.market_good.clear();
    scratch.market_sellable.clear();
    scratch.market_price.clear();
    digest.country_equipment_available.clear();
    if (_economy_runtime != nullptr) {
        NativeEconomyRuntime *economy = static_cast<NativeEconomyRuntime *>(_economy_runtime);
        if (economy_ready != nullptr)
            *economy_ready = economy_api::military_command_window_open(*economy);
        EconomyMilitaryCellView view;
        economy_api::military_read_cell_view(*economy, view, catalog.economy_good_count);
        const size_t n = std::min(view.population.size(), static_cast<size_t>(cells));
        for (size_t cell = 0; cell < n; ++cell) {
            scratch.cell_population[cell] = view.population[cell];
            scratch.cell_unemployed[cell] = view.unemployed[cell];
            scratch.cell_soldiers[cell] = view.soldiers[cell];
            scratch.cell_has_merchant[cell] = view.has_merchant[cell];
        }
        // Supply goods plus every repair material; a good shared by several
        // classes or recipes is captured once.
        std::vector<int32_t> goods;
        for (int32_t cls = 0; cls < MILITARY_SUPPLY_CLASSES; ++cls) {
            for (const int32_t good : catalog.supply_goods[static_cast<size_t>(cls)]) {
                if (good < 0) continue;
                if (std::find(goods.begin(), goods.end(), good) == goods.end())
                    goods.push_back(good);
            }
        }
        // ---- physical maintenance materials (design D3 / R1) ----------------
        // Repair materials are ordinary goods that belong to NO supply class, so
        // a digest built only from `supply_goods` never quotes them and the
        // maintenance buy pass can never see a market row for them. The palette is
        // small (the 17 buildings and 24 units share ~20 distinct goods), so this
        // roughly doubles the quoted set rather than exploding it.
        for (const MilitaryUnitType &unit : catalog.units) {
            for (const MilitaryRepairMaterial &mat : unit.repair_materials) {
                if (mat.good < 0) continue;
                if (std::find(goods.begin(), goods.end(), mat.good) == goods.end())
                    goods.push_back(mat.good);
            }
        }
        for (const MilitaryStateBuilding &building : catalog.state_buildings) {
            for (const MilitaryRepairMaterial &mat : building.repair_materials) {
                if (mat.good < 0) continue;
                if (std::find(goods.begin(), goods.end(), mat.good) == goods.end())
                    goods.push_back(mat.good);
            }
        }
        const size_t good_count = static_cast<size_t>(catalog.economy_good_count);
        std::vector<uint8_t> equipment(good_count, 0);
        for (const MilitaryEquipCategory &category : catalog.categories) {
            for (const int32_t good : category.good_ids) {
                equipment[good] = 1;
                goods.push_back(good);
            }
        }
        // Technology and producer prerequisites are shared by a country's cells.
        std::vector<int32_t> representative(static_cast<size_t>(country_count), -1);
        for (int32_t cell = 0; cell < cells; ++cell) {
            const int32_t owner = digest.cell_owner_slot[cell];
            if (owner >= 0 && owner < country_count && representative[owner] < 0)
                representative[owner] = cell;
        }
        economy_api::military_read_equipment_production(*economy, representative,
            equipment, digest.country_equipment_available);
        std::sort(goods.begin(), goods.end());
        goods.erase(std::unique(goods.begin(), goods.end()), goods.end());
        for (const int32_t good : goods) {
            std::vector<int32_t> market_cells;
            std::vector<int64_t> sellable;
            std::vector<int64_t> price;
            std::vector<uint8_t> stocked;
            economy_api::military_read_market(*economy, good, market_cells, sellable, price, stocked);
            for (size_t i = 0; i < market_cells.size(); ++i) {
                scratch.market_cell.push_back(market_cells[i]);
                scratch.market_good.push_back(good);
                scratch.market_sellable.push_back(sellable[i]);
                scratch.market_price.push_back(price[i]);
                const int32_t cell = market_cells[i];
                if (cell < 0 || cell >= cells) continue;
                const int32_t owner = digest.cell_owner_slot[cell];
                if (equipment[good] && stocked[i] && owner >= 0 && owner < country_count)
                    digest.country_equipment_available[static_cast<size_t>(owner) * good_count + good] = 1;
            }
        }
        for (int32_t slot = 0; slot < country_count; ++slot)
            digest.country_soldier_living_cost[static_cast<size_t>(slot)] =
                economy_api::military_soldier_living_cost(*economy, slot);
        // The economy's kind-3 building groups are the ledger of record for
        // every state lot; the core rebuilds its cache from these rows and never
        // counts anything itself (requirement 6.1-6.3). A non-authoritative
        // read leaves `state_lanes_present` false, which tells the core to keep
        // the cache it has instead of zeroing it.
        std::vector<int32_t> state_cells;
        std::vector<int32_t> state_types;
        std::vector<int32_t> state_roles;
        std::vector<int64_t> state_units;
        if (economy_api::military_read_state_buildings(*economy, state_cells, state_types,
                                                   state_roles, state_units)) {
            scratch.state_cell.swap(state_cells);
            scratch.state_type_id.swap(state_types);
            scratch.state_state_role.swap(state_roles);
            scratch.state_units.swap(state_units);
            digest.state_lanes_present = true;
            digest.state_lane_rows = static_cast<int32_t>(scratch.state_cell.size());
        }
    }
    digest.cell_population = scratch.cell_population;
    digest.cell_unemployed = scratch.cell_unemployed;
    digest.cell_soldiers = scratch.cell_soldiers;
    digest.cell_has_merchant = scratch.cell_has_merchant;
    digest.market_cell = scratch.market_cell;
    digest.market_good = scratch.market_good;
    digest.market_sellable = scratch.market_sellable;
    digest.market_price = scratch.market_price;
    // Copied (not moved) because the scratch is reused next day; the copy only
    // costs the sparse state rows, which are a few hundred at most.
    digest.state_cell = scratch.state_cell;
    digest.state_type_id = scratch.state_type_id;
    digest.state_state_role = scratch.state_state_role;
    digest.state_units = scratch.state_units;
    // ---- Technology unlock bits: one row per country, bit = unlock_bit ----
    // `_military_unlock_tech_ids` records the dense technology id each bit
    // stands for at configure time, so a country's row is one
    // has_technology() probe per referenced technology.
    const int32_t unlock_bits = static_cast<int32_t>(_military_unlock_tech_ids.size());
    digest.unlock_words = (unlock_bits + 63) / 64;
    digest.country_unlock_bits.assign(
        static_cast<size_t>(country_count) * static_cast<size_t>(digest.unlock_words), 0);
    if ((country_state != nullptr || _country_runtime != nullptr) && unlock_bits > 0) {
        NativeCountryRuntime *country = static_cast<NativeCountryRuntime *>(_country_runtime);
        for (int32_t slot = 0; slot < country_count; ++slot) {
            uint64_t *row = digest.country_unlock_bits.data() +
                static_cast<size_t>(slot) * static_cast<size_t>(digest.unlock_words);
            for (int32_t bit = 0; bit < unlock_bits; ++bit) {
                const int32_t tech = _military_unlock_tech_ids[static_cast<size_t>(bit)];
                if (tech < 0) continue;
                const bool has_technology = country_state ?
                    (tech < static_cast<int32_t>(country_state->technology_count) &&
                     (country_state->country_technologies[static_cast<size_t>(slot) *
                        country_state->technology_words + (tech >> 6)] &
                        (uint64_t{1} << (tech & 63))) != 0)
                    : country_api::has_technology(*country, slot, tech);
                if (!has_technology) continue;
                row[bit >> 6] |= (uint64_t{1} << static_cast<uint32_t>(bit & 63));
            }
        }
    }
    // ---- Military Modifier stats (q16, design defaults when absent) ----
    digest.stat_count = MSTAT_COUNT;
    digest.country_stat_q16.assign(
        static_cast<size_t>(country_count) * static_cast<size_t>(MSTAT_COUNT), 0);
    for (int32_t slot = 0; slot < country_count; ++slot) {
        const uint64_t handle = slot < static_cast<int32_t>(digest.country_handle.size())
            ? digest.country_handle[static_cast<size_t>(slot)] : 0;
        for (int32_t stat = 0; stat < MSTAT_COUNT; ++stat) {
            int32_t value = military_stat_default_q16(stat);
            if (_modifier_runtime != nullptr && handle != 0) {
                const double base = static_cast<double>(value) / static_cast<double>(MILITARY_Q);
                const double effective = modifier_api::effective_value(
                    *static_cast<ModifierRuntime *>(_modifier_runtime), ModifierApi::COUNTRY,
                                      kMilitaryStatKeys[static_cast<size_t>(stat)],
                                      handle, 0, base);
                if (std::isfinite(effective))
                    value = q16_from_float(effective);
            }
            digest.country_stat_q16[static_cast<size_t>(slot) *
                static_cast<size_t>(MSTAT_COUNT) + static_cast<size_t>(stat)] = value;
        }
    }
}


using namespace godot;

struct MilitaryRations {
    std::vector<int32_t> cells, heads, ratios;
    std::vector<std::pair<uint64_t, int32_t>> armies;

    void calculate(const MilitaryCore &core, const std::vector<MilitaryIntent> &intents);
};


namespace {

// Army personnel lane reconcile (army-personnel contract §2.1). Economy owns
// natural deaths and the lane row, so Military only ever READS the lane and
// trims its own lots down to it — it never grows a formation and never writes
// Economy. Two hard rules from the recruitment pipeline apply verbatim:
//   * a lane read of 0 is not evidence of death (a busy worker read view reports
//     zero), so only a positive reading may trim;
//   * heads already booked but still in flight (embarkation emitted, receipt
//     pending) are part of the ceiling, or the army is trimmed the day it forms.
int64_t reconcile_army_lane_personnel(
        const std::unordered_map<uint64_t, int64_t> &army_population, MilitaryCore &core) {
    if (army_population.empty()) return 0;
    int64_t trimmed = 0;
    const MilitaryArmyStore &armies = core.armies();
    for (size_t slot = 0; slot < armies.active.size(); ++slot) {
        if (armies.active[slot] == 0) continue;
        const int64_t booked = armies.cached_headcount[slot];
        if (booked <= 0) continue;
        const uint64_t handle = core.army_handle(static_cast<int32_t>(slot));
        const auto population = army_population.find(handle);
        if (population == army_population.end()) continue;
        const int64_t allowed = population->second + core.army_lane_pending(static_cast<int32_t>(slot));
        if (booked <= allowed) continue;
        core.trim_army_lots(static_cast<int32_t>(slot), allowed);
        core.refresh_army_cache(static_cast<int32_t>(slot));
        trimmed += booked - allowed;
    }
    return trimmed;
}

} // namespace

Dictionary NativeMilitaryRuntime::run_day(int64_t day) {
    MilitaryCore *core = &this->core();
    if (!core->configured()) return military_fail("military_not_configured");
    if (day < 0) return military_fail("military_day_invalid");
    if (core->terrain().cell_count <= 0) return military_fail("military_terrain_missing");
    Dictionary out;
    out["ok"] = true;
    out["day_index"] = day;
    out["path"] = "native_military";
    if (day <= _military_last_step_day) {
        // The day was already stepped by the other entry point (daily system vs
        // whole-graph catch-up). Re-running it would double-submit D+1 intents.
        out["skipped"] = true;
        out["reason"] = "military_day_already_stepped";
        out["intents_submitted"] = static_cast<int64_t>(0);
        out["country_ops"] = static_cast<int64_t>(0);
        out["economy_ops"] = static_cast<int64_t>(0);
        return out;
    }
    // ---- 1. Committed D digest ----
    const auto capture_started = std::chrono::steady_clock::now();
    MilitaryWorldDigest digest;
    // The first military step resolves the soldier catalog row after
    // capturing its quote. A cold world must rebuild that lookup only if
    // a previous step would already have resolved it.
    if (_military_last_step_day >= 0 && _economy_runtime != nullptr)
        economy_api::military_soldier_profession(*static_cast<NativeEconomyRuntime *>(_economy_runtime));
    bool economy_ready = false;
    capture_military_digest(digest, _military_digest_scratch, core->catalog(), &economy_ready);
    digest.day = day;
    const double capture_ms = static_cast<double>(
        std::chrono::duration_cast<std::chrono::microseconds>(
            std::chrono::steady_clock::now() - capture_started).count()) / 1000.0;
    // ---- 2. Receipts for every pending intent that reached a terminal state ----
    // Rows survive across days until their authority reports a terminal
    // outcome (or they time out), so a late Economy epoch never loses a receipt.
    apply_military_deferred_cash(day);
    std::vector<MilitaryIntentReceipt> receipts;
    collect_military_receipts(day, receipts);
    // Personnel commands settle on the Economy boundary after the original
    // digest capture.  When a terminal personnel receipt is visible, refresh
    // the small population view before Military reconciles its garrison lots;
    // using the older digest here leaves the roster one command behind.
    bool refresh_soldier_view = false;
    for (const MilitaryIntentReceipt &receipt : receipts) {
        if (receipt.kind == MILITARY_INTENT_ENLIST ||
            receipt.kind == MILITARY_INTENT_LEVY ||
            receipt.kind == MILITARY_INTENT_DISCHARGE ||
            receipt.kind == MILITARY_INTENT_CASUALTY ||
            receipt.kind == MILITARY_INTENT_ARMY_EMBARK ||
            receipt.kind == MILITARY_INTENT_ARMY_DISEMBARK) {
            refresh_soldier_view = true;
            break;
        }
    }
    if (refresh_soldier_view && _economy_runtime != nullptr) {
        EconomyMilitaryCellView current_view;
        economy_api::military_read_cell_view(
            *static_cast<NativeEconomyRuntime *>(_economy_runtime),
            current_view, core->catalog().economy_good_count);
        digest.cell_population = current_view.population;
        digest.cell_unemployed = current_view.unemployed;
        digest.cell_soldiers = current_view.soldiers;
        digest.cell_has_merchant = current_view.has_merchant;
    }
    // A discharge is booked out of the Military lots when its intent is
    // emitted, while Economy applies the cohort conversion at effective_day.
    // If the next Military day is admitted before that Economy day commits,
    // the digest still contains the old soldier cohort.  Reuse the existing
    // bridge rows as the in-flight record and subtract only rows whose
    // effective day is still ahead of Economy's committed watermark.  Once the
    // command has committed, the refresh above (or the normal next capture)
    // supplies the post-conversion cohort, so it is never subtracted twice.
    if (_economy_runtime != nullptr && !digest.cell_soldiers.empty()) {
        const NativeEconomyRuntime &economy =
            *static_cast<NativeEconomyRuntime *>(_economy_runtime);
        const int64_t committed_day = economy_api::last_committed_day(economy);
        for (const MilitaryPendingIntent &row : _military_pending_intents) {
            if (row.authority != 2 || row.receipt_pending != 1 ||
                row.kind != MILITARY_INTENT_DISCHARGE || row.cell < 0 ||
                static_cast<size_t>(row.cell) >= digest.cell_soldiers.size() ||
                row.effective_day <= committed_day)
                continue;
            const int64_t heads = std::max<int64_t>(0, row.count);
            digest.cell_soldiers[static_cast<size_t>(row.cell)] = std::max<int64_t>(
                0, digest.cell_soldiers[static_cast<size_t>(row.cell)] - heads);
        }
    }

    auto *economy = static_cast<NativeEconomyRuntime *>(_economy_runtime);
    const bool calculate_rations = economy != nullptr &&
        economy_api::military_soldier_profession(*economy) >= 0;
    std::unordered_map<uint64_t, int64_t> army_population;
    if (economy != nullptr && economy_army_lane_supported(economy)) {
        const MilitaryArmyStore &armies = core->armies();
        for (size_t slot = 0; slot < armies.active.size(); ++slot) {
            if (!armies.active[slot]) continue;
            const uint64_t handle = core->army_handle(static_cast<int32_t>(slot));
            const int64_t population = economy_army_lane_population(economy, handle);
            if (population > 0) army_population.emplace(handle, population);
        }
    }
    std::vector<MilitaryIntent> intents;
    std::string step_error;
    intents.reserve(256);
    if (!core->step_day(day, digest, receipts, intents, step_error))
        return military_fail(step_error.c_str());
    MilitaryRations rations;
    if (calculate_rations) rations.calculate(*core, intents);
    const int64_t army_lane_trimmed = reconcile_army_lane_personnel(army_population, *core);
    if (_runtime_host && _runtime_host->military_executor_active() &&
            !_runtime_host->inline_daily_mode()) _military_last_background_day = day;
    _military_last_step_day = day;
    // Commands due on or before this day were applied by step_day.
    if (_military_forced_run_day >= 0 && _military_forced_run_day <= day) {
        _military_forced_run_day = -1;
        for (const auto &command : core->_pending) {
            if (_military_forced_run_day < 0 || command.effective_day < _military_forced_run_day)
                _military_forced_run_day = command.effective_day;
        }
    }
    // ---- 3b. Publish the ration satisfaction Economy consumes ----
    // Design §9.2: the soldier's staple/protein needs are supplied in kind from
    // the military ration stock, so Economy reads their satisfaction from here
    // instead of buying them on the market. The core keeps the per-holder ration
    // ratio; the garrison lane is per cell, which is what Economy needs.
    if (calculate_rations) {
        auto &economy = *static_cast<NativeEconomyRuntime *>(_economy_runtime);
        economy_api::set_military_ration_satisfaction(economy, rations.cells, rations.ratios);
        economy_api::set_military_cell_garrison(economy, rations.cells, rations.heads);
        if (economy_army_lane_supported(&economy)) {
            for (const auto &[handle, ratio] : rations.armies)
                economy_set_army_ration(&economy, handle, ratio);
        }
    }
    // ---- 4. Translate intents into D+1 command batches ----
    const int64_t effective_day = day + 1;
    std::vector<MilitaryCountryCommand> country_commands;
    std::vector<MilitaryEconomyCommand> economy_commands;
    std::vector<MilitaryPendingIntent> pending;
    pending.reserve(intents.size());
    for (const auto &receipt : receipts) {
        if (receipt.kind != MILITARY_INTENT_PROCURE_GOOD || receipt.request_sequence <= 0) continue;
        MilitaryEconomyCommand ack;
        ack.opcode = EconomyApi::COMMAND_MILITARY_PURCHASE_ACK;
        ack.effective_day = effective_day; ack.sequence = ++_military_sequence;
        ack.i64_0 = receipt.request_sequence;
        economy_commands.push_back(ack);
    }
    int32_t unsequenced = 0;
    for (const MilitaryIntent &intent : intents) {
        translate_military_intent(intent, effective_day, digest, country_commands,
                                  economy_commands, pending, unsequenced);
    }
    int64_t country_ops = static_cast<int64_t>(country_commands.size());
    int64_t economy_ops = static_cast<int64_t>(economy_commands.size());
    std::string submit_error;
    const bool country_ok = country_commands.empty() ||
        submit_military_country_commands(country_commands, pending, submit_error);
    const bool economy_ok = economy_commands.empty() ||
        submit_military_economy_commands(economy_commands, pending, submit_error);
    // Rows whose authority rejected the whole batch are reported back as failed
    // receipts so the core can reconcile them on the next day.
    if (!country_ok || !economy_ok) {
        out["submit_error"] = String(submit_error.c_str());
        for (MilitaryPendingIntent &row : pending) {
            const bool refused = (row.authority == 1 && !country_ok) ||
                                 ((row.authority == 2 || row.authority == 4) && !economy_ok);
            if (!refused) continue;
            // No receipt will arrive for a batch the authority refused.
            row.receipt_pending = 0;
        }
    }
    // Append today's rows to the cross-day pending set. Rows that already failed
    // here (no source cohort, refused batch) are kept as "resolved failed" so the
    // next fold reports them to the core instead of silently dropping them.
    // Rows of earlier days stay until their own terminal receipt / timeout.
    for (MilitaryPendingIntent &row : pending) {
        if (row.receipt_pending == 0) row.receipt_pending = 3;
        _military_pending_intents.push_back(row);
    }
    // ---- 5. Report ----
    const MilitaryReport &report = core->report();
    // Any successful day may change authoritative army rows even when the
    // battle loop reports idle: command application, merges/splits, supply,
    // morale, training and composition can all settle without an intent.
    // The feed must observe that day boundary instead of waiting for movement.
    ++_military_render_revision;
    out["ok"] = country_ok && economy_ok;
    out["reason"] = (country_ok && economy_ok) ? String() : String("military_intent_submit_failed");
    out["path"] = _military_last_background_day == day ? "native_military_background" : "native_military";
    out["skipped"] = false;
    out["day_ms"] = report.day_ms;
    out["capture_ms"] = capture_ms;
    out["armies_active"] = static_cast<int64_t>(report.armies_active);
    out["armies_moving"] = static_cast<int64_t>(report.armies_moving);
    out["engagements_active"] = static_cast<int64_t>(report.engagements_active);
    out["wars_active"] = static_cast<int64_t>(report.wars_active);
    out["soldiers_total"] = report.soldiers_total;
    out["astar_expansions"] = report.astar_expansions;
    out["area_evals"] = static_cast<int64_t>(report.area_evals);
    out["threat_field_cells"] = static_cast<int64_t>(report.threat_field_cells);
    out["convoys_due"] = static_cast<int64_t>(report.convoys_due);
    out["convoy_hops"] = report.convoy_hops;
    out["front_edges_touched"] = static_cast<int64_t>(report.front_edges_touched);
    out["vision_patch_cells"] = static_cast<int64_t>(report.vision_patch_cells);
    out["event_coalesced"] = static_cast<int64_t>(report.event_coalesced);
    out["reconcile_delta"] = report.reconcile_delta;
    // The day's payroll split by holder (army-pay contract §2.3). A test (or a
    // panel) can tell "who got paid today" apart from the 30-day EWMA.
    out["payroll_garrison"] = report.payroll_garrison;
    out["payroll_army"] = report.payroll_army;
    out["intents_emitted"] = static_cast<int64_t>(report.intents_emitted);
    // Physical maintenance (design §5): settled spend, recipe demand and the
    // consumed part, the paid-but-undelivered backlog, and how many maintenance
    // objects the pass walked (a sparse pass reports a small row count).
    out["maintenance_spend"] = report.maintenance_spend;
    out["maintenance_need_goods"] = report.maintenance_need_goods;
    out["maintenance_met_goods"] = report.maintenance_met_goods;
    out["maintenance_backlog"] = report.maintenance_backlog;
    out["maintenance_rows"] = static_cast<int64_t>(report.maintenance_rows);
    out["maintenance_disrepair_rows"] =
        static_cast<int64_t>(report.maintenance_disrepair_rows);
    out["maintenance_ms"] = report.maintenance_ms;
    out["intents_submitted"] = static_cast<int64_t>(pending.size());
    out["receipts_folded"] = static_cast<int64_t>(receipts.size());
    out["country_ops"] = country_ops;
    out["economy_ops"] = economy_ops;
    // Army personnel lane telemetry (contract §2): how many rows went to the
    // economy this day, whether the loaded economy can carry them at all, and
    // how many heads the lane reconcile trimmed.
    int64_t army_lane_ops = 0;
    for (const MilitaryEconomyCommand &command : economy_commands) {
        if (is_army_lane_opcode(command.opcode)) ++army_lane_ops;
    }
    out["army_lane_ops"] = army_lane_ops;
    out["army_lane_supported"] = _economy_runtime != nullptr &&
        economy_army_lane_supported(_economy_runtime);
    // Split / partial-transfer lane support (contract-2 §1.1, opcode 33): the
    // smoke test gates its split/transfer conservation assertions on this, so an
    // economy DLL that predates 33 skips them instead of failing them.
    out["army_split_lane_supported"] = army_lane_split_supported(
        static_cast<const NativeEconomyRuntime *>(_economy_runtime));
    // Army pay support (army-pay contract §3.3, opcode 34): same gate contract as
    // the split lanes above, so a DLL without 34 skips the pay assertions instead
    // of failing them.
    out["army_pay_supported"] = army_lane_pay_supported(
        static_cast<const NativeEconomyRuntime *>(_economy_runtime));
    int64_t army_pay_ops = 0;
    for (const MilitaryEconomyCommand &command : economy_commands) {
        if (command.opcode == MECONOMY_ARMY_LANE_PAY) ++army_pay_ops;
    }
    out["army_pay_ops"] = army_pay_ops;
    // Diagnostic for the army-pay gate: paying needs a synchronous treasury debit,
    // which is only available while Country accepts sync store writes.
    out["army_pay_sync_cash_available"] = _country_runtime != nullptr &&
        !country_api::sync_store_writes_forbidden(
             *static_cast<NativeCountryRuntime *>(_country_runtime));
    out["army_lane_trimmed"] = army_lane_trimmed;
    out["economy_ready"] = economy_ready;
    out["effective_day"] = effective_day;
    out["sequence_cursor"] = _military_sequence;
    out["command_cursor"] = static_cast<int64_t>(core->_pending.size());
    out["state_hash"] = static_cast<int64_t>(core->state_hash() & 0x7fffffffffffffffll);
    return out;
}

// ===========================================================================
// intent translation
// ===========================================================================

#include "world_ext_military_digest_section_intents.inc"

// ===========================================================================
// ration satisfaction (design §9.2: staple/protein are supplied in kind)
// ===========================================================================

void MilitaryRations::calculate(
        const MilitaryCore &core,
        const std::vector<MilitaryIntent> &intents) {
    // Real per-cell garrison ration satisfaction for the day just stepped,
    // reconstructed from public const state (military_core.h is frozen):
    //   need  = garrison heads * ration_need_per_head (need units, q16 scale),
    //   met   = ration goods the holder consumed today (the
    //           CONSUME_TREASURY_GOOD intents run_consumption emitted with
    //           source_id = (holder_kind << 32) | holder) * supply yield,
    //           plus ration units still held after consumption (a stocked
    //           garrison that already ate its fill reads 1.0).
    // Ratio = min(1, met / need) in q16. Garrisons are home-cell soldiers, so
    // the lane is per cell, which is what Economy reads. Terrain/consumption
    // multipliers scale need and consumption alike and are omitted.
    // The published set replaces the previous one, so a cell whose garrison
    // disappeared reads 1.0 again. Army lots are not home-cell cohorts in v1 (the soldier
    // cohort stays on its home cell), so only garrison lots are published.
    const int32_t cells_total = core.terrain().cell_count;
    if (cells_total <= 0) return;
    std::vector<int64_t> garrison(static_cast<size_t>(cells_total), 0);
    std::vector<int64_t> met(static_cast<size_t>(cells_total), 0);
    const MilitaryLotStore &lots = core.lots();
    for (size_t i = 0; i < lots.active.size(); ++i) {
        if (!lots.active[i] || lots.count[i] <= 0) continue;
        if (lots.location_kind[i] != MILITARY_LOT_GARRISON) continue;
        const int32_t cell = lots.location[i];
        if (cell < 0 || cell >= cells_total) continue;
        if (garrison[static_cast<size_t>(cell)] == 0) cells.push_back(cell);
        garrison[static_cast<size_t>(cell)] += lots.count[i];
    }
    const MilitaryCatalog &catalog = core.catalog();
    const std::vector<int32_t> &ration_goods = catalog.supply_goods[MILITARY_SUPPLY_RATION];
    const std::vector<int32_t> &ration_yield = catalog.supply_yield_q16[MILITARY_SUPPLY_RATION];
    const auto yield_of = [&](int32_t good) -> int32_t {
        for (size_t g = 0; g < ration_goods.size(); ++g) {
            if (ration_goods[g] != good) continue;
            const int32_t y = g < ration_yield.size() ? ration_yield[g] : MILITARY_Q;
            return y > 0 ? y : MILITARY_Q;
        }
        return 0;
    };
    const auto mul_q = [](int64_t v, int32_t q) { return (v * static_cast<int64_t>(q)) >> 16; };
    for (const MilitaryIntent &intent : intents) {
        if (intent.kind != MILITARY_INTENT_CONSUME_TREASURY_GOOD) continue;
        if ((intent.source_id >> 32) != MILITARY_LOT_GARRISON) continue;
        const int32_t cell = static_cast<int32_t>(intent.source_id & 0xffffffffu);
        if (cell < 0 || cell >= cells_total || garrison[static_cast<size_t>(cell)] <= 0) continue;
        const int32_t y = yield_of(intent.good);
        if (y <= 0) continue;
        met[static_cast<size_t>(cell)] += mul_q(intent.count, y);
    }
    for (const MilitaryStockRow &row : core.stocks()) {
        if (row.holder_kind != MILITARY_LOT_GARRISON || row.qty <= 0) continue;
        const int32_t cell = row.holder;
        if (cell < 0 || cell >= cells_total || garrison[static_cast<size_t>(cell)] <= 0) continue;
        const int32_t y = yield_of(row.good);
        if (y <= 0) continue;
        met[static_cast<size_t>(cell)] += mul_q(row.qty, y);
    }
    const int32_t per_head = catalog.ration_need_per_head_q16 > 0
        ? catalog.ration_need_per_head_q16 : MILITARY_Q;
    std::sort(cells.begin(), cells.end());
    ratios.reserve(cells.size());
    heads.reserve(cells.size());
    for (const int32_t cell : cells) {
        const size_t c = static_cast<size_t>(cell);
        const int64_t need = mul_q(garrison[c], per_head);
        int64_t ratio = MILITARY_Q;
        if (need > 0) ratio = std::min<int64_t>(MILITARY_Q, (met[c] * MILITARY_Q) / need);
        ratios.push_back(static_cast<int32_t>(std::max<int64_t>(0, ratio)));
        heads.push_back(static_cast<int32_t>(std::min<int64_t>(
            garrison[c], std::numeric_limits<int32_t>::max())));
    }
    // ---- army lanes (contract §2.2) --------------------------------------
    // A deployed formation is not a home-cell cohort: its people sit in an
    // Economy lane keyed by army handle, so the staple/protein satisfaction has
    // to be published per formation. The core already keeps the 3-day EMA of
    // exactly that ratio (run_consumption, sec 10 morale input); no
    // reconstruction is needed here. Garrisons keep the per-cell lane above.
    const MilitaryArmyStore &formations = core.armies();
    for (size_t slot = 0; slot < formations.active.size(); ++slot) {
        if (!formations.active[slot] || formations.cached_headcount[slot] <= 0) continue;
        const uint64_t handle = core.army_handle(static_cast<int32_t>(slot));
        if (handle == 0) continue;
        armies.emplace_back(handle, std::clamp<int32_t>(
            formations.ration_ratio_q16[slot], 0, MILITARY_Q));
    }
}

} // namespace pk
