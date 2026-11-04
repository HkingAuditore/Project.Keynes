// NativeEconomyRuntime military read view (owner: military bridge B).
//
// Narrow, allocation-free reads used by world_ext_military.cpp to build
// MilitaryWorldDigest. Everything here is read-only: the military bridge never
// mutates Economy state through this surface, because every Economy change it
// needs is expressed as a command batch (contract §0.2).
//
// The declarations live in one contiguous delimited block at the end of
// NativeEconomyRuntime's public section in economy_runtime.h.

#include "economy_runtime.h"
#include "country_runtime.h"

#include <algorithm>
#include <cstdint>
#include <limits>
#include <string>

namespace pk {

namespace {

// The merchant operating floor is 12.5% of a market's stock (design §9.3); the
// military "sellable" lane excludes it exactly like the research and
// procurement lanes do.
constexpr int64_t MILITARY_VIEW_MERCHANT_FLOOR_Q16 = 8192;

// Ration needs are supplied in kind by Military, so the wage basis excludes
// them (design §9.6). These are the same authored need ids the catalog compiler
// reads for the ration candidate table.
const char *const MILITARY_VIEW_RATION_NEEDS[2] = {"staple_food", "protein"};

int64_t military_view_floor(int64_t stock) {
    return (stock * MILITARY_VIEW_MERCHANT_FLOOR_Q16) /
        NativeEconomyRuntime::Q16_ONE;
}

} // namespace

int32_t NativeEconomyRuntime::military_soldier_profession() {
    if (_soldier_profession_id < 0) {
        for (size_t p = 0; p < _profession_ids.size(); ++p) {
            if (_profession_ids[p] == "soldier") {
                _soldier_profession_id = static_cast<int32_t>(p);
                break;
            }
        }
    }
    return _soldier_profession_id;
}

void NativeEconomyRuntime::military_read_cell_view(
        MilitaryCellView &out, int32_t good_count) const {
    (void)good_count;  // reserved: per-good head lanes are not needed by v1
    const int32_t cells = std::max(0, cell_count());
    const size_t want = static_cast<size_t>(cells);
    out.population.assign(want, 0);
    out.unemployed.assign(want, 0);
    out.soldiers.assign(want, 0);
    out.has_merchant.assign(want, 0);
    if (!_bootstrapped || cells <= 0) return;

    const int32_t soldier_profession = _soldier_profession_id;
    const int32_t unemployed_profession = _unemployed_profession_id;
    const int32_t merchant_profession = _merchant_profession_id;
    // Dense (profession, ethnicity) -> signature table read backwards: one
    // signature only ever belongs to one profession, so a signature-id indexed
    // lane built once per call is the cheapest lookup for the cohort walk.
    const size_t n_eth = _ethnicity_ids.size();
    const size_t n_prof = _profession_ids.size();
    _military_signature_profession.assign(_signatures.size(), -1);
    for (size_t p = 0; p < n_prof; ++p) {
        for (size_t e = 0; e < n_eth; ++e) {
            const int32_t signature = signature_for_profession_ethnicity(
                static_cast<int32_t>(p), static_cast<int32_t>(e));
            if (signature >= 0 &&
                static_cast<size_t>(signature) < _military_signature_profession.size())
                _military_signature_profession[static_cast<size_t>(signature)] =
                    static_cast<int32_t>(p);
        }
    }
    const std::vector<int32_t> &signature_profession = _military_signature_profession;

    const RuntimeEconomyPopulationStore &pop = population_store();
    for (size_t slot = 0; slot < pop.active.size(); ++slot) {
        if (pop.active[slot] == 0) continue;
        const int64_t people = std::max<int64_t>(0, pop.population[slot]);
        if (people <= 0) continue;
        const int32_t cell =
            pop.page_cell[slot / RuntimeEconomyPopulationStore::COHORT_PAGE_SIZE];
        if (cell < 0 || cell >= cells) continue;
        const size_t lane = static_cast<size_t>(cell);
        out.population[lane] += people;
        const uint32_t signature = pop.signature_id[slot];
        const int32_t profession = signature < signature_profession.size()
            ? signature_profession[signature] : -1;
        if (profession < 0) continue;
        if (profession == soldier_profession)
            out.soldiers[lane] += people;
        else if (profession == unemployed_profession)
            out.unemployed[lane] += people;
        if (profession == merchant_profession) out.has_merchant[lane] = 1;
    }
    // A market whose primary merchant lane exists is a live market even when no
    // merchant cohort is currently resident (the merchant may be a lane on the
    // market rather than a cell cohort).
    const MarketStore &market = market_store();
    for (size_t m = 0; m < _merchant_primary_slot.size(); ++m) {
        if (_merchant_primary_slot[m] < 0) continue;
        if (m >= market.cell_to_market.size()) break;
        const int32_t cell = market.cell_to_market[m];
        if (cell >= 0 && cell < cells) out.has_merchant[static_cast<size_t>(cell)] = 1;
    }
    (void)good_count;
}

bool NativeEconomyRuntime::military_read_state_buildings(
        std::vector<int32_t> &out_cells,
        std::vector<int32_t> &out_type_ids,
        std::vector<int32_t> &out_state_roles,
        std::vector<int64_t> &out_units) const {
    out_cells.clear();
    out_type_ids.clear();
    out_state_roles.clear();
    out_units.clear();
    // An empty answer and "no state buildings" look identical to the caller,
    // so the two cases have to be separated here: a runtime that has not
    // bootstrapped, or a save/restore mid-flight, is not an empty ledger.
    if (!_bootstrapped) return false;
    if (_save.active || _restore.active) return false;
    // One pass over the committed building groups. Groups are the ledger of
    // record for every kind; only kind 3 (state) rows are military buildings,
    // and a group whose units already reached 0 is "demolished but not yet
    // pruned" - it must not read as a standing building, so it is skipped
    // instead of reported with 0 units (the caller would otherwise create a
    // barracks at tier 0 that does not exist).
    const size_t groups = building_count();
    for (size_t row = 0; row < groups; ++row) {
        const auto group = building_view(row);
        if (group.type_id < 0 ||
            static_cast<size_t>(group.type_id) >= _building_types.size()) continue;
        const BuildingType &type = _building_types[static_cast<size_t>(group.type_id)];
        if (type.kind != 3) continue;
        const int64_t units = group.count;
        if (units <= 0) continue;
        out_cells.push_back(group.cell);
        out_type_ids.push_back(group.type_id);
        out_state_roles.push_back(type.state_role);
        out_units.push_back(units);
    }
    return true;
}

void NativeEconomyRuntime::military_read_market(
        int32_t good, std::vector<int32_t> &out_cells,
        std::vector<int64_t> &out_sellable,
        std::vector<int64_t> &out_price) const {
    out_cells.clear();
    out_sellable.clear();
    out_price.clear();
    const MarketStore &market = market_store();
    if (good < 0 || good >= market.good_count.get()) return;
    const int32_t markets = std::min(market.market_count.get(),
        static_cast<int32_t>(_merchant_primary_slot.size()));
    if (markets <= 0) return;
    out_cells.reserve(static_cast<size_t>(markets));
    out_sellable.reserve(static_cast<size_t>(markets));
    out_price.reserve(static_cast<size_t>(markets));
    for (int32_t m = 0; m < markets; ++m) {
        // A market without a live merchant cannot sell to the army.
        if (_merchant_primary_slot[static_cast<size_t>(m)] < 0) continue;
        if (static_cast<size_t>(m) >= market.cell_to_market.size()) break;
        const int32_t cell = market.cell_to_market[static_cast<size_t>(m)];
        if (cell < 0) continue;
        const size_t index = static_cast<size_t>(market.index(m, good));
        if (index >= market.stock.size() || index >= market.price.size()) continue;
        const int64_t stock = std::max<int64_t>(0, market.stock[index]);
        const int64_t sellable = std::max<int64_t>(0, stock - military_view_floor(stock));
        if (sellable <= 0) continue;
        out_cells.push_back(cell);
        out_sellable.push_back(sellable);
        out_price.push_back(std::max<int64_t>(0, market.price[index]));
    }
}

int64_t NativeEconomyRuntime::military_soldier_living_cost(
        int32_t country_slot) const {
    (void)country_slot;  // the soldier plan is country independent in v1
    const int32_t soldier_profession = _soldier_profession_id;
    if (soldier_profession < 0) return 0;
    // Soldier cohorts exist per (soldier, ethnicity); the plan is identical for
    // every ethnicity, so the first resolvable signature is representative.
    const int32_t signature = military_signature_for(soldier_profession, 0);
    if (signature < 0 || static_cast<size_t>(signature) >= _signatures.size()) return 0;
    const int32_t plan_id = _signatures[static_cast<size_t>(signature)].plan_id;
    if (plan_id < 0 || static_cast<size_t>(plan_id) >= _plans.size()) return 0;
    const Plan &plan = _plans[static_cast<size_t>(plan_id)];
    int64_t total = 0;
    for (int32_t k = 0; k < plan.need_count; ++k) {
        const int32_t need_index = plan.need_begin + k;
        if (need_index < 0 || static_cast<size_t>(need_index) >= _needs.size()) continue;
        const Need &need = _needs[static_cast<size_t>(need_index)];
        if (need.stable_id >= 0 &&
            static_cast<size_t>(need.stable_id) < _need_ids.size()) {
            const std::string &need_id = _need_ids[static_cast<size_t>(need.stable_id)];
            if (need_id == MILITARY_VIEW_RATION_NEEDS[0] ||
                need_id == MILITARY_VIEW_RATION_NEEDS[1])
                continue;  // supplied in kind from the military ration stock
        }
        if (need.living_cost_weight_q16 <= 0) continue;
        // Cheapest reachable variant: a household under wage pressure
        // substitutes down, so the wage basis has to reflect that price and not
        // the preferred one.
        int64_t need_cost = 0;
        for (int32_t v = 0; v < need.variant_count; ++v) {
            const int32_t variant_index = need.variant_begin + v;
            if (variant_index < 0 ||
                static_cast<size_t>(variant_index) >= _variants.size()) continue;
            const VariantChoice &variant =
                _variants[static_cast<size_t>(variant_index)];
            int64_t component_cost = 0;
            for (int32_t c = 0; c < variant.component_count; ++c) {
                const int32_t component_index = variant.component_begin + c;
                if (component_index < 0 ||
                    static_cast<size_t>(component_index) >= _components.size()) continue;
                const NeedComponent &component =
                    _components[static_cast<size_t>(component_index)];
                component_cost += (component.qty_per_need *
                    variant.reference_unit_price) / GOODS_SCALE;
            }
            if (component_cost <= 0) continue;
            if (need_cost == 0 || component_cost < need_cost) need_cost = component_cost;
        }
        if (need_cost <= 0) continue;
        total += (need.base_qty_per_person * need_cost) / GOODS_SCALE;
    }
    return total;
}

uint64_t NativeEconomyRuntime::military_cohort_handle(
        int32_t cell, int32_t signature) const {
    if (cell < 0 || cell >= cell_count() || signature < 0) return 0;
    const int32_t slot = population_store().find_signature(
        cell, static_cast<uint32_t>(signature));
    if (slot < 0 || population_store().active[slot] == 0) return 0;
    return population_store().handle_for_slot(slot);
}

uint64_t NativeEconomyRuntime::military_cohort_handle_any_ethnicity(
        int32_t cell, int32_t profession_id) const {
    if (cell < 0 || cell >= cell_count() || profession_id < 0) return 0;
    const int32_t ethnicity_count = static_cast<int32_t>(_ethnicity_ids.size());
    for (int32_t e = 0; e < ethnicity_count; ++e) {
        const int32_t signature = signature_for_profession_ethnicity(profession_id, e);
        if (signature < 0) continue;
        const int32_t slot = population_store().find_signature(
            cell, static_cast<uint32_t>(signature));
        if (slot >= 0 && population_store().active[slot] != 0 &&
            std::max<int64_t>(0, population_store().population[slot]) > 0)
            return population_store().handle_for_slot(slot);
    }
    return 0;
}

uint64_t NativeEconomyRuntime::military_cohort_handle_from_professions(
        int32_t cell, const int32_t *professions, int32_t count) const {
    if (cell < 0 || cell >= cell_count() || professions == nullptr || count <= 0) return 0;
    const int32_t n_prof = static_cast<int32_t>(_profession_ids.size());
    const int32_t n_eth = static_cast<int32_t>(_ethnicity_ids.size());
    for (int32_t i = 0; i < count; ++i) {
        const int32_t profession = professions[i];
        if (profession < 0 || profession >= n_prof) continue;
        for (int32_t e = 0; e < n_eth; ++e) {
            const int32_t signature = signature_for_profession_ethnicity(profession, e);
            if (signature < 0) continue;
            const int32_t slot = population_store().find_signature(
                cell, static_cast<uint32_t>(signature));
            if (slot >= 0 && population_store().active[slot] != 0 &&
                std::max<int64_t>(0, population_store().population[slot]) > 0)
                return population_store().handle_for_slot(slot);
        }
    }
    return 0;
}

int32_t NativeEconomyRuntime::military_cohort_signature(uint64_t handle) const {
    int32_t slot = -1;
    if (handle == 0 || !population_store().valid_handle(handle, slot)) return -1;
    return static_cast<int32_t>(population_store().signature_id[static_cast<size_t>(slot)]);
}
int32_t NativeEconomyRuntime::military_cohort_ethnicity(uint64_t handle) const {
    int32_t slot = -1;
    if (handle == 0 || !population_store().valid_handle(handle, slot)) return -1;
    const uint32_t signature = population_store().signature_id[static_cast<size_t>(slot)];
    if (static_cast<size_t>(signature) >= _signatures.size()) return -1;
    return _signatures[static_cast<size_t>(signature)].ethnicity_id;
}

int32_t NativeEconomyRuntime::military_signature_for_cell_ethnicity(
        int32_t cell, int32_t profession) const {
    if (cell < 0 || cell >= cell_count() || profession < 0) return -1;
    const int32_t n_eth = static_cast<int32_t>(_ethnicity_ids.size());
    // Prefer the ethnicity the profession already has in this cell, so the move
    // never invents a lane or shifts people into another ethnicity.
    for (int32_t e = 0; e < n_eth; ++e) {
        const int32_t signature = signature_for_profession_ethnicity(profession, e);
        if (signature < 0) continue;
        const int32_t slot = population_store().find_signature(
            cell, static_cast<uint32_t>(signature));
        if (slot >= 0 && population_store().active[slot] != 0 &&
            population_store().population[slot] > 0)
            return signature;
    }
    // Otherwise adopt the ethnicity of somebody already living in the cell.
    const std::vector<int32_t> &signature_profession = _military_signature_profession;
    const RuntimeEconomyPopulationStore &pop = population_store();
    for (size_t slot = 0; slot < pop.active.size(); ++slot) {
        if (pop.active[slot] == 0 || pop.population[slot] <= 0) continue;
        if (pop.page_cell[slot / RuntimeEconomyPopulationStore::COHORT_PAGE_SIZE] != cell) continue;
        const uint32_t signature = pop.signature_id[slot];
        if (signature >= _signatures.size()) continue;
        const int32_t ethnicity = _signatures[signature].ethnicity_id;
        if (ethnicity < 0) continue;
        const int32_t resolved = signature_for_profession_ethnicity(profession, ethnicity);
        if (resolved >= 0) return resolved;
    }
    (void)signature_profession;
    return signature_for_profession_ethnicity(profession, 0);
}
int64_t NativeEconomyRuntime::military_soldier_heads(int32_t cell) const {
    const int32_t soldier_profession = _soldier_profession_id;
    if (cell < 0 || cell >= cell_count() || soldier_profession < 0) return 0;
    const int32_t n_eth = static_cast<int32_t>(_ethnicity_ids.size());
    int64_t total = 0;
    for (int32_t e = 0; e < n_eth; ++e) {
        const int32_t signature = signature_for_profession_ethnicity(soldier_profession, e);
        if (signature < 0) continue;
        const int32_t slot = population_store().find_signature(
            cell, static_cast<uint32_t>(signature));
        if (slot < 0 || population_store().active[slot] == 0) continue;
        total += std::max<int64_t>(0, population_store().population[slot]);
    }
    return total;
}

int64_t NativeEconomyRuntime::military_collect_cash(int64_t country_handle,
                                                    int64_t amount) {
    if (country_handle == 0 || amount <= 0) return 0;
    if (_country_runtime == nullptr || !_country_runtime->economy_available()) return 0;
    // Fiscal escrow is the existing conserved path for "Military spends treasury
    // cash": reserve then collect books the amount into Country's non-tax
    // expenditure slots instead of silently zeroing the balance.
    const int64_t reserved = _country_runtime->reserve_fiscal_cash(
        country_handle, amount);
    if (reserved <= 0) return 0;
    return _country_runtime->collect_fiscal_cash(country_handle, reserved);
}

bool NativeEconomyRuntime::military_command_window_open() const {
    return _bootstrapped && !_epoch_active && !_save.active && !_restore.active &&
        !_fatal;
}

int32_t NativeEconomyRuntime::military_queued_commands_through(int64_t day) const {
    int32_t count = 0;
    for (const Command &command : _pending_commands) {
        if (command.effective_day <= day) ++count;
    }
    return count;
}

} // namespace pk
