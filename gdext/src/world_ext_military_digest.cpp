#include "native_simulation_host_military.h"
#include "runtime_pod_protocol.h"

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
        std::sort(goods.begin(), goods.end());
        for (const int32_t good : goods) {
            std::vector<int32_t> market_cells;
            std::vector<int64_t> sellable;
            std::vector<int64_t> price;
            economy_api::military_read_market(*economy, good, market_cells, sellable, price);
            for (size_t i = 0; i < market_cells.size(); ++i) {
                scratch.market_cell.push_back(market_cells[i]);
                scratch.market_good.push_back(good);
                scratch.market_sellable.push_back(sellable[i]);
                scratch.market_price.push_back(price[i]);
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

} // namespace pk
