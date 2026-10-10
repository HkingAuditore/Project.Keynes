#include "economy_runtime.h"
#include "economy_hash.h"
#include "economy_runtime_binary_codec.h"
#include "economy_runtime_variant_helpers.h"

#include <algorithm>
#include <limits>
#include <tuple>
#include <unordered_set>
#include <vector>

namespace pk {

using namespace godot;
using namespace binary_codec;
using namespace variant_helpers;

namespace {

constexpr uint8_t kFoundingRecordHeader = 0;
constexpr uint8_t kFoundingRecordMilestone = 1;
constexpr uint8_t kFoundingRecordOffer = 2;
constexpr uint8_t kFoundingRecordChoice = 3;
constexpr uint8_t kFoundingRecordEffect = 4;
constexpr uint32_t kFoundingMaxTraitsPerCard = 64;

} // namespace

int64_t NativeEconomyRuntime::family_milestone_hash() const {
    uint64_t hash = 1469598103934665603ULL;
    hash = economy_hash_u64(hash, _family_milestone_populations.size());
    for (int64_t value : _family_milestone_populations)
        hash = economy_hash_u64(hash, static_cast<uint64_t>(value));
    return static_cast<int64_t>(hash & 0x7fffffffffffffffULL);
}

void NativeEconomyRuntime::clear_family_founding_state() {
    _family_milestones_reached.assign(
        static_cast<size_t>(std::max(0, _cell_count.get())), 0);
    _family_founding_offers.clear();
    _family_founding_choices.clear();
    _family_founding_effects.clear();
    _next_family_founding_offer_id = 1;
    _family_founding_offer_by_cell.clear();
    _family_founding_offer_index_dirty = true;
}

void NativeEconomyRuntime::rebuild_family_founding_offer_index() {
    _family_founding_offer_by_cell.assign(
        static_cast<size_t>(std::max(0, _cell_count.get())), -1);
    for (size_t i = 0; i < _family_founding_offers.size(); ++i) {
        const int32_t cell = _family_founding_offers[i].cell;
        if (cell >= 0 && cell < _cell_count.get())
            _family_founding_offer_by_cell[static_cast<size_t>(cell)] =
                static_cast<int32_t>(i);
    }
    _family_founding_offer_index_dirty = false;
}

int32_t NativeEconomyRuntime::family_founding_offer_for_cell(int32_t cell) {
    if (cell < 0 || cell >= _cell_count.get() || _family_founding_offers.empty())
        return -1;
    if (_family_founding_offer_index_dirty ||
        _family_founding_offer_by_cell.size() != static_cast<size_t>(_cell_count.get()))
        rebuild_family_founding_offer_index();
    return _family_founding_offer_by_cell[static_cast<size_t>(cell)];
}

bool NativeEconomyRuntime::family_founding_player_choice(int32_t cell) const {
    return _family_founding_choice_mode == 1 && _epoch_player_country_slot >= 0 &&
        cell >= 0 && static_cast<size_t>(cell) < _epoch_cell_country.size() &&
        _epoch_cell_country[static_cast<size_t>(cell)] == _epoch_player_country_slot;
}

int32_t NativeEconomyRuntime::family_founding_effect_for(int64_t stable_id) const {
    const auto it = std::lower_bound(_family_founding_effects.begin(),
        _family_founding_effects.end(), std::make_pair(stable_id,
            std::numeric_limits<int32_t>::min()));
    return it != _family_founding_effects.end() && it->first == stable_id
        ? it->second : -1;
}

void NativeEconomyRuntime::prune_family_founding_effects() {
    if (_family_founding_effects.empty()) return;
    _family_founding_effects.erase_if(
        [&](const std::pair<int64_t, int32_t> &row) {
            return _family_stable_ids.count(row.first) == 0;
        });
}

// Founders a group could contribute to a brand-new family: the owner-signature
// household (owner posts x dependents per post), minus existing family claims.
// The half-city cap may shrink the household but never below the founder
// minimum.
int64_t NativeEconomyRuntime::family_founding_founders_for_group(
        int32_t cell, int32_t group_index) const {
    if (cell < 0 || cell >= _cell_count.get() || group_index < 0 ||
        group_index >= static_cast<int32_t>(building_count())) return 0;
    const auto group = building_at(static_cast<size_t>(group_index));
    if (group.cell != cell || group.count <= 0 || group.modifier_handle == 0 ||
        group.operating_state != 0 || group.type_id < 0 ||
        group.type_id >= static_cast<int32_t>(_building_types.size()))
        return 0;
    const int64_t owner_slots =
        _building_types[static_cast<size_t>(group.type_id)].owner_slots_per_building;
    if (owner_slots <= 0 || group.filled_owner < owner_slots) return 0;
    const bool csr_exact = !_family_indices_dirty;
    int64_t family_owned = 0;
    if (csr_exact && _family_building_offsets.size() == building_count() + 1) {
        for (int32_t p = _family_building_offsets[group_index];
             p < _family_building_offsets[group_index + 1]; ++p)
            family_owned += family_ownerships().read_at(
                _family_building_edge_indices[p], __FILE__, __LINE__).owned_count;
    } else {
        for (const FamilyBuildingOwnership &edge : family_ownerships())
            if (edge.building_handle == group.modifier_handle)
                family_owned += std::max<int64_t>(0, edge.owned_count);
    }
    if (family_owned >= group.count) return 0;
    const int32_t slot = find_cohort_slot(cell, group.owner_signature_id);
    if (slot < 0) return 0;
    auto people_on_slot = [&](int32_t s) -> int64_t {
        if (csr_exact) return family_people_on_slot(s);
        const uint64_t cohort = population_store().handle_for_slot(s);
        int64_t people = 0;
        for (const FamilyMembershipEdge &edge : family_memberships())
            if (edge.cohort_handle == cohort)
                people += std::max<int64_t>(0, edge.people);
        return people;
    };
    int64_t cell_population = 0;
    int64_t cell_family_people = 0;
    population_store().for_each_in_cell(cell, [&](int32_t s) {
        cell_population += std::max<int64_t>(0, population_store().population[s]);
        cell_family_people += people_on_slot(s);
    });
    const int64_t available = std::max<int64_t>(0,
        population_store().population[slot] - people_on_slot(slot));
    if (available < owner_slots) return 0;
    int64_t room_sat = 0;
    const int64_t room = std::max<int64_t>(0, mul_div_sat(cell_population,
        FAMILY_TARGET_SHARE_TOTAL_Q16, Q16_ONE, room_sat) - cell_family_people);
    const int64_t cap = std::max(_family_min_founder_people.get(), room);
    const int64_t founders = std::min({family_household_target_people(owner_slots),
        available, cap});
    return founders >= _family_min_founder_people.get() ? founders : 0;
}

int32_t NativeEconomyRuntime::build_family_founding_candidates(
        int32_t cell, int32_t milestone_index,
        std::vector<FamilyFoundingCandidate> &out) const {
    out.clear();
    if (cell < 0 || cell >= _cell_count.get() ||
        _building_cell_offsets.size() != static_cast<size_t>(_cell_count.get() + 1))
        return 0;
    struct Ranked {
        int32_t group = -1;
        int64_t founders = 0;
        int32_t margin = 0;
        int64_t revenue = 0;
        int32_t type_id = -1;
        int32_t signature = -1;
    };
    std::vector<Ranked> ranked;
    for (int32_t g = _building_cell_offsets[cell];
         g < _building_cell_offsets[cell + 1]; ++g) {
        const int64_t founders = family_founding_founders_for_group(cell, g);
        if (founders <= 0) continue;
        const auto group = building_at(static_cast<size_t>(g));
        ranked.push_back({g, founders, group.realized_profit_margin_q16,
            group.last_revenue, group.type_id, group.owner_signature_id});
    }
    if (ranked.empty()) return 0;
    std::sort(ranked.begin(), ranked.end(), [](const Ranked &a, const Ranked &b) {
        return std::tie(b.margin, b.revenue, b.type_id, b.signature, a.group) <
            std::tie(a.margin, a.revenue, a.type_id, a.signature, b.group);
    });
    std::vector<Ranked> picks;
    for (const Ranked &row : ranked) {
        bool duplicate = false;
        for (const Ranked &pick : picks)
            duplicate = duplicate || (pick.type_id == row.type_id &&
                pick.signature == row.signature);
        if (duplicate) continue;
        picks.push_back(row);
        if (static_cast<int32_t>(picks.size()) >= FAMILY_FOUNDING_CARD_COUNT) break;
    }
    std::vector<int32_t> used_surnames;
    std::vector<int32_t> used_effects;
    std::unordered_set<int64_t> used_ids;
    for (int32_t card = 0; card < FAMILY_FOUNDING_CARD_COUNT; ++card) {
        const Ranked &pick = picks[static_cast<size_t>(card) % picks.size()];
        const auto group = building_at(static_cast<size_t>(pick.group));
        FamilyFoundingCandidate candidate;
        uint64_t hash = 1469598103934665603ULL;
        hash = trace_hash_mix(hash, static_cast<uint64_t>(_seed.get()));
        hash = trace_hash_mix(hash, 0x464f554e44435244ULL); // "FOUNDCRD"
        hash = trace_hash_mix(hash, static_cast<uint32_t>(cell));
        hash = trace_hash_mix(hash, static_cast<uint32_t>(milestone_index));
        hash = trace_hash_mix(hash, static_cast<uint32_t>(card));
        hash = trace_hash_mix(hash, static_cast<uint64_t>(
            _next_family_founding_offer_id.get()));
        int64_t stable_id = static_cast<int64_t>(
            (hash & 0x7fffffffffffffffULL) | 1ULL);
        for (uint64_t probe = 1; _family_stable_ids.count(stable_id) != 0 ||
             used_ids.count(stable_id) != 0; ++probe)
            stable_id = static_cast<int64_t>((trace_hash_mix(hash, probe) &
                0x7fffffffffffffffULL) | 1ULL);
        used_ids.insert(stable_id);
        candidate.stable_id = stable_id;
        candidate.building_handle = group.modifier_handle;
        candidate.building_type_id = group.type_id;
        candidate.owner_signature_id = group.owner_signature_id;
        candidate.founders = pick.founders;
        const int32_t ethnicity = group.owner_signature_id >= 0 &&
            group.owner_signature_id < static_cast<int32_t>(_signatures.size())
            ? _signatures[static_cast<size_t>(group.owner_signature_id)].ethnicity_id
            : -1;
        const int32_t culture_group = ethnicity >= 0 &&
            ethnicity < static_cast<int32_t>(_ethnicity_culture_group_ids.size())
            ? _ethnicity_culture_group_ids[static_cast<size_t>(ethnicity)] : 0;
        candidate.culture_group_id = culture_group;
        auto surname_weight = [&](int32_t id, bool avoid_used) -> int64_t {
            if (_family_surname_culture_group_ids[static_cast<size_t>(id)] !=
                culture_group) return 0;
            if (avoid_used && std::find(used_surnames.begin(), used_surnames.end(),
                    id) != used_surnames.end()) return 0;
            return std::max(0, _family_surname_weights[static_cast<size_t>(id)]);
        };
        const int32_t surname_count =
            static_cast<int32_t>(_family_surname_weights.size());
        for (int32_t attempt = 0; attempt < 2 && candidate.surname_id < 0; ++attempt) {
            const bool avoid_used = attempt == 0;
            int64_t total = 0;
            for (int32_t id = 0; id < surname_count; ++id)
                total += surname_weight(id, avoid_used);
            if (total <= 0) continue;
            int64_t roll = static_cast<int64_t>(trace_hash_mix(
                trace_hash_mix(static_cast<uint64_t>(stable_id),
                    static_cast<uint64_t>(culture_group)),
                0x5355524eULL) % static_cast<uint64_t>(total));
            for (int32_t id = 0; id < surname_count; ++id) {
                const int64_t weight = surname_weight(id, avoid_used);
                if (weight <= 0) continue;
                if (roll < weight) { candidate.surname_id = id; break; }
                roll -= weight;
            }
        }
        if (candidate.surname_id < 0 && surname_count > 0) candidate.surname_id = 0;
        if (candidate.surname_id >= 0) used_surnames.push_back(candidate.surname_id);
        roll_core_family_traits(static_cast<uint64_t>(stable_id), cell, cell,
            candidate.trait_ids, candidate.trait_strength_q16);
        const std::vector<int32_t> none;
        candidate.effect_id = roll_random_pool_family_effect(
            static_cast<uint64_t>(stable_id), cell, none, used_effects);
        if (candidate.effect_id < 0)
            candidate.effect_id = roll_random_pool_family_effect(
                static_cast<uint64_t>(stable_id), cell, none, none);
        if (candidate.effect_id >= 0) used_effects.push_back(candidate.effect_id);
        out.push_back(std::move(candidate));
    }
    return static_cast<int32_t>(out.size());
}

int32_t NativeEconomyRuntime::family_founding_auto_choice(
        const FamilyFoundingOffer &offer) const {
    if (offer.candidates.empty()) return -1;
    uint64_t hash = 1469598103934665603ULL;
    hash = trace_hash_mix(hash, static_cast<uint64_t>(_seed.get()));
    hash = trace_hash_mix(hash, 0x4155544f5049434bULL); // "AUTOPICK"
    hash = trace_hash_mix(hash, static_cast<uint64_t>(offer.offer_id));
    hash = trace_hash_mix(hash, static_cast<uint32_t>(offer.cell));
    hash = trace_hash_mix(hash, static_cast<uint32_t>(offer.milestone_index));
    return static_cast<int32_t>(hash % offer.candidates.size());
}

bool NativeEconomyRuntime::resolve_family_founding_offer(
        FamilyFoundingOffer &offer, int32_t choice_index) {
    if (choice_index < 0 ||
        choice_index >= static_cast<int32_t>(offer.candidates.size()))
        return false;
    const FamilyFoundingCandidate &candidate =
        offer.candidates[static_cast<size_t>(choice_index)];
    const int32_t cell = offer.cell;
    int32_t group_index = building_index_for_handle(candidate.building_handle);
    int64_t founders = group_index >= 0
        ? family_founding_founders_for_group(cell, group_index) : 0;
    if (founders <= 0) {
        // The chosen house keeps its name, traits and effect; only the
        // founding industry is rebound to the best building still eligible.
        group_index = -1;
        std::tuple<int32_t, int64_t, int32_t, int32_t> best_key{};
        if (_building_cell_offsets.size() == static_cast<size_t>(_cell_count.get() + 1)) {
            for (int32_t g = _building_cell_offsets[cell];
                 g < _building_cell_offsets[cell + 1]; ++g) {
                const int64_t available = family_founding_founders_for_group(cell, g);
                if (available <= 0) continue;
                const auto group = building_at(static_cast<size_t>(g));
                const auto key = std::make_tuple(group.realized_profit_margin_q16,
                    group.last_revenue, group.type_id, group.owner_signature_id);
                if (group_index < 0 || key > best_key) {
                    group_index = g;
                    founders = available;
                    best_key = key;
                }
            }
        }
    }
    if (group_index < 0 || founders <= 0) return false;
    const auto group = building_at(static_cast<size_t>(group_index));
    const int64_t owner_slots =
        _building_types[static_cast<size_t>(group.type_id)].owner_slots_per_building;
    FamilyFoundingIdentity identity;
    identity.stable_id = candidate.stable_id;
    identity.surname_id = candidate.surname_id;
    identity.effect_id = candidate.effect_id;
    identity.trait_ids = &candidate.trait_ids;
    identity.trait_strength_q16 = &candidate.trait_strength_q16;
    return create_family_for_building(cell, group_index, founders, owner_slots,
        false, &identity) >= 0;
}

void NativeEconomyRuntime::review_family_milestone(int32_t cell) {
    if (_family_runtime_mode.get() != 2 || cell < 0 || cell >= _cell_count.get()) return;
    if (_family_milestones_reached.size() != static_cast<size_t>(_cell_count.get()))
        _family_milestones_reached.resize(static_cast<size_t>(_cell_count.get()), 0);
    auto milestone_write = EconomyRowWriteLease::create();
    uint8_t &reached = _family_milestones_reached.borrow_row(static_cast<size_t>(cell), *milestone_write);
    auto finish_offer = [&](int32_t index) {
        const int64_t offer_id = _family_founding_offers[
            static_cast<size_t>(index)].offer_id;
        _family_founding_offers.erase(_family_founding_offers.begin() + index);
        _family_founding_choices.erase_if(
            [&](const FamilyFoundingChoiceCommand &command) {
                return command.offer_id == offer_id;
            });
        _family_founding_offer_index_dirty = true;
    };
    const int32_t existing = family_founding_offer_for_cell(cell);
    if (existing >= 0) {
        const bool finished = [&] {
            auto offer_write = _family_founding_offers.edit_row(static_cast<size_t>(existing));
            FamilyFoundingOffer &offer = offer_write[0];
            int32_t choice = -1;
            bool automatic = false;
            if (offer.status == FAMILY_FOUNDING_SELECTED) choice = offer.chosen_index;
            else if (!family_founding_player_choice(cell)) {
                choice = family_founding_auto_choice(offer); automatic = true;
            }
            if (choice < 0) return false;
            if (resolve_family_founding_offer(offer, choice)) {
                if (reached < 255) ++reached;
                if (automatic) ++_family_offers_auto_resolved;
                return true;
            }
            offer.status = FAMILY_FOUNDING_SELECTED; offer.chosen_index = choice;
            if (++offer.failed_reviews >= FAMILY_FOUNDING_MAX_FAILED_REVIEWS) {
                ++_family_offers_voided; return true;
            }
            return false;
        }();
        if (finished) finish_offer(existing);
        return;
    }
    if (reached >= _family_milestone_populations.size()) return;
    const int64_t threshold = _family_milestone_populations[reached];
    if (_committed_cells[cell].population < threshold) return;
    int32_t families_here = 0;
    if (!_family_indices_dirty &&
        _family_cell_offsets.size() == static_cast<size_t>(_cell_count.get() + 1)) {
        families_here = _family_cell_offsets[cell + 1] - _family_cell_offsets[cell];
    } else {
        std::vector<uint64_t> handles;
        for (const FamilyMembershipEdge &edge : family_memberships()) {
            int32_t slot = -1;
            if (edge.people <= 0 ||
                !population_store().valid_handle(edge.cohort_handle, slot) ||
                population_store().page_cell[slot / COHORT_PAGE_SIZE] != cell)
                continue;
            if (std::find(handles.begin(), handles.end(), edge.family_handle) ==
                handles.end()) handles.push_back(edge.family_handle);
        }
        families_here = static_cast<int32_t>(handles.size());
    }
    if (families_here >= _family_max_per_cell.get()) return;
    FamilyFoundingOffer offer;
    if (build_family_founding_candidates(cell, reached, offer.candidates) <= 0)
        return;
    offer.offer_id = _next_family_founding_offer_id++;
    offer.cell = cell;
    offer.milestone_index = reached;
    offer.milestone_population = threshold;
    offer.created_day = _current_day.get();
    if (family_founding_player_choice(cell)) {
        _family_founding_offers.push_back(std::move(offer));
        _family_founding_offer_index_dirty = true;
        ++_family_offers_opened;
        return;
    }
    if (resolve_family_founding_offer(offer, family_founding_auto_choice(offer))) {
        if (reached < 255) ++reached;
        ++_family_offers_auto_resolved;
    }
}

void NativeEconomyRuntime::apply_due_family_founding_choices() {
    if (!_family_founding_choices.empty()) {
        _family_founding_choices.stable_sort(
            [](const FamilyFoundingChoiceCommand &a,
               const FamilyFoundingChoiceCommand &b) {
                return std::tie(a.effective_day, a.sequence, a.submit_order) <
                    std::tie(b.effective_day, b.sequence, b.submit_order);
            });
        std::vector<FamilyFoundingChoiceCommand> retained;
        for (const FamilyFoundingChoiceCommand &command : _family_founding_choices) {
            if (command.effective_day > _current_day.get()) {
                retained.push_back(command);
                continue;
            }
            auto it = std::find_if(_family_founding_offers.begin(),
                _family_founding_offers.end(), [&](const FamilyFoundingOffer &offer) {
                    return offer.offer_id == command.offer_id;
                });
            if (it == _family_founding_offers.end() ||
                it->generation != command.generation ||
                it->status != FAMILY_FOUNDING_OPEN || command.choice_index < 0 ||
                command.choice_index >= static_cast<int32_t>(it->candidates.size())) {
                ++_family_offer_choice_rejected;
                continue;
            }
            auto offer_write = _family_founding_offers.edit_row(it - _family_founding_offers.begin());
            auto &offer = offer_write[0];
            offer.status = FAMILY_FOUNDING_SELECTED;
            offer.chosen_index = command.choice_index;
            offer.failed_reviews = 0;
        }
        _family_founding_choices.swap(retained);
    }
    if (_family_founding_choice_mode == 0) {
        for (size_t offer_row = 0; offer_row < _family_founding_offers.size(); ++offer_row) {
        auto offer_write = _family_founding_offers.edit_row(offer_row);
        FamilyFoundingOffer &offer = offer_write[0];
            if (offer.status != FAMILY_FOUNDING_OPEN) continue;
            offer.status = FAMILY_FOUNDING_SELECTED;
            offer.chosen_index = family_founding_auto_choice(offer);
            ++_family_offers_auto_resolved;
        }
    }
}

Dictionary NativeEconomyRuntime::family_founding_offers(int32_t offset,
                                                      int32_t limit) const {
    Dictionary out;
    if (!_configured) {
        out["ok"] = false;
        out["reason"] = "economy_not_configured";
        return out;
    }
    const int32_t total = static_cast<int32_t>(_family_founding_offers.size());
    const int32_t begin = std::clamp(offset, 0, total);
    const int32_t end = std::min(total, begin + std::clamp(limit, 1, 256));
    Array offers;
    for (int32_t i = begin; i < end; ++i) {
        const FamilyFoundingOffer &offer = _family_founding_offers[static_cast<size_t>(i)];
        int32_t queued_choice = -1;
        for (const FamilyFoundingChoiceCommand &command : _family_founding_choices)
            if (command.offer_id == offer.offer_id) queued_choice = command.choice_index;
        Dictionary row;
        row["offer_id"] = offer.offer_id;
        row["generation"] = static_cast<int64_t>(offer.generation);
        row["cell"] = offer.cell;
        row["milestone_index"] = offer.milestone_index;
        row["milestone_population"] = offer.milestone_population;
        row["status"] = offer.status == FAMILY_FOUNDING_SELECTED ? String("SELECTED")
            : (queued_choice >= 0 ? String("SELECTED_PENDING") : String("OPEN"));
        row["chosen_index"] = offer.status == FAMILY_FOUNDING_SELECTED
            ? offer.chosen_index : queued_choice;
        row["created_day"] = offer.created_day;
        row["failed_reviews"] = offer.failed_reviews;
        // Offers only persist when opened for the player; before the first
        // post-restore epoch captures country ownership, trust that origin.
        row["player_choice"] = _family_founding_choice_mode == 1 &&
            (_epoch_player_country_slot < 0 ||
             family_founding_player_choice(offer.cell));
        row["cell_population"] = offer.cell >= 0 &&
            offer.cell < static_cast<int32_t>(_committed_cells.size())
            ? _committed_cells[static_cast<size_t>(offer.cell)].population : 0;
        Array candidates;
        for (const FamilyFoundingCandidate &candidate : offer.candidates) {
            Dictionary card;
            card["stable_id"] = candidate.stable_id;
            card["surname_index"] = candidate.surname_id;
            const bool surname_ok = candidate.surname_id >= 0 &&
                candidate.surname_id < static_cast<int32_t>(_family_surname_ids.size());
            card["surname_id"] = surname_ok
                ? from_utf8(_family_surname_ids[static_cast<size_t>(candidate.surname_id)])
                : String();
            card["surname"] = surname_ok && candidate.surname_id <
                    static_cast<int32_t>(_family_surname_text.size())
                ? from_utf8(_family_surname_text[static_cast<size_t>(candidate.surname_id)])
                : String();
            card["culture_group_id"] = candidate.culture_group_id;
            const int32_t culture = candidate.culture_group_id;
            card["culture_group_naming_format"] = culture >= 0 && culture <
                    static_cast<int32_t>(_family_culture_group_naming_formats.size())
                ? from_utf8(_family_culture_group_naming_formats[static_cast<size_t>(culture)])
                : String();
            card["culture_group_separator"] = culture >= 0 && culture <
                    static_cast<int32_t>(_family_culture_group_separators.size())
                ? from_utf8(_family_culture_group_separators[static_cast<size_t>(culture)])
                : String();
            card["culture_group_suffix"] = culture >= 0 && culture <
                    static_cast<int32_t>(_family_culture_group_suffixes.size())
                ? from_utf8(_family_culture_group_suffixes[static_cast<size_t>(culture)])
                : String();
            card["building_handle"] = static_cast<int64_t>(candidate.building_handle);
            card["building_type_index"] = candidate.building_type_id;
            card["building_type_id"] = candidate.building_type_id >= 0 &&
                    candidate.building_type_id < static_cast<int32_t>(_building_type_ids.size())
                ? from_utf8(_building_type_ids[static_cast<size_t>(candidate.building_type_id)])
                : String();
            card["owner_signature_id"] = candidate.owner_signature_id;
            const int32_t profession = candidate.owner_signature_id >= 0 &&
                    candidate.owner_signature_id < static_cast<int32_t>(_signatures.size())
                ? _signatures[static_cast<size_t>(candidate.owner_signature_id)].profession_id
                : -1;
            card["owner_profession_id"] = profession >= 0 &&
                    profession < static_cast<int32_t>(_profession_ids.size())
                ? from_utf8(_profession_ids[static_cast<size_t>(profession)]) : String();
            card["founders"] = candidate.founders;
            card["effect_index"] = candidate.effect_id;
            card["effect_key"] = candidate.effect_id >= 0 &&
                    candidate.effect_id < static_cast<int32_t>(_family_effect_keys.size())
                ? from_utf8(_family_effect_keys[static_cast<size_t>(candidate.effect_id)])
                : String();
            PackedStringArray trait_keys;
            PackedInt32Array strengths;
            for (size_t t = 0; t < candidate.trait_ids.size(); ++t) {
                const int32_t trait_id = candidate.trait_ids[t];
                if (trait_id < 0 || trait_id >= static_cast<int32_t>(_family_trait_ids.size()))
                    continue;
                trait_keys.push_back(from_utf8(_family_trait_ids[static_cast<size_t>(trait_id)]));
                strengths.push_back(candidate.trait_strength_q16[t]);
            }
            card["trait_keys"] = trait_keys;
            card["trait_strength_q16"] = strengths;
            candidates.push_back(card);
        }
        row["candidates"] = candidates;
        offers.push_back(row);
    }
    out["ok"] = true;
    out["total"] = total;
    out["offset"] = begin;
    out["offers"] = offers;
    out["choice_mode"] = _family_founding_choice_mode == 0 ? String("AUTO")
                                                           : String("PLAYER");
    return out;
}

Dictionary NativeEconomyRuntime::submit_family_founding_choice(
        int64_t offer_id, int64_t generation, int32_t choice_index,
        int64_t effective_day, int64_t sequence) {
    Dictionary out;
    auto reject = [&](const char *reason) {
        ++_family_offer_choice_rejected;
        out["ok"] = false;
        out["reason"] = reason;
        return out;
    };
    if (!_configured) return reject("economy_not_configured");
    const auto it = std::find_if(_family_founding_offers.begin(),
        _family_founding_offers.end(), [&](const FamilyFoundingOffer &offer) {
            return offer.offer_id == offer_id;
        });
    if (it == _family_founding_offers.end())
        return reject("family_founding_offer_missing");
    if (static_cast<int64_t>(it->generation) != generation)
        return reject("family_founding_offer_stale");
    if (it->status != FAMILY_FOUNDING_OPEN)
        return reject("family_founding_offer_already_chosen");
    if (choice_index < 0 ||
        choice_index >= static_cast<int32_t>(it->candidates.size()))
        return reject("family_founding_choice_invalid");
    if (effective_day < 0) return reject("family_founding_day_invalid");
    for (const FamilyFoundingChoiceCommand &command : _family_founding_choices)
        if (command.offer_id == offer_id)
            return reject("family_founding_offer_already_chosen");
    FamilyFoundingChoiceCommand command;
    command.offer_id = offer_id;
    command.generation = it->generation;
    command.choice_index = choice_index;
    command.effective_day = effective_day;
    command.sequence = sequence;
    command.submit_order = ++_next_submit_order;
    _family_founding_choices.push_back(command);
    out["ok"] = true;
    out["request_order"] = static_cast<int64_t>(command.submit_order);
    out["pending_count"] = static_cast<int64_t>(_family_founding_choices.size());
    return out;
}

void NativeEconomyRuntime::append_family_founding_hash(uint64_t &hash) const {
    auto mix = [&](uint64_t value) { hash = economy_hash_u64(hash, value); };
    mix(0x464f554e44494e47ULL); // "FOUNDING"
    mix(static_cast<uint64_t>(_next_family_founding_offer_id.get()));
    for (size_t cell = 0; cell < _family_milestones_reached.size(); ++cell) {
        if (_family_milestones_reached[cell] == 0) continue;
        mix(cell);
        mix(_family_milestones_reached[cell]);
    }
    for (const FamilyFoundingOffer &offer : _family_founding_offers) {
        mix(static_cast<uint64_t>(offer.offer_id));
        mix(offer.generation);
        mix(static_cast<uint32_t>(offer.cell));
        mix(static_cast<uint32_t>(offer.milestone_index));
        mix(static_cast<uint64_t>(offer.milestone_population));
        mix(offer.status);
        mix(static_cast<uint32_t>(offer.chosen_index));
        mix(static_cast<uint64_t>(offer.created_day));
        mix(static_cast<uint32_t>(offer.failed_reviews));
        for (const FamilyFoundingCandidate &candidate : offer.candidates) {
            mix(static_cast<uint64_t>(candidate.stable_id));
            mix(static_cast<uint32_t>(candidate.surname_id));
            mix(static_cast<uint32_t>(candidate.culture_group_id));
            mix(candidate.building_handle);
            mix(static_cast<uint32_t>(candidate.building_type_id));
            mix(static_cast<uint32_t>(candidate.owner_signature_id));
            mix(static_cast<uint64_t>(candidate.founders));
            mix(static_cast<uint32_t>(candidate.effect_id));
            for (size_t t = 0; t < candidate.trait_ids.size(); ++t) {
                mix(static_cast<uint32_t>(candidate.trait_ids[t]));
                mix(static_cast<uint32_t>(candidate.trait_strength_q16[t]));
            }
        }
    }
    for (const FamilyFoundingChoiceCommand &command : _family_founding_choices) {
        mix(static_cast<uint64_t>(command.offer_id));
        mix(command.generation);
        mix(static_cast<uint32_t>(command.choice_index));
        mix(static_cast<uint64_t>(command.effective_day));
        mix(static_cast<uint64_t>(command.sequence));
        mix(command.submit_order);
    }
    for (const auto &row : _family_founding_effects) {
        mix(static_cast<uint64_t>(row.first));
        mix(static_cast<uint32_t>(row.second));
    }
}

bool NativeEconomyRuntime::write_family_founding_save_records(
        int32_t budget, std::vector<uint8_t> &payload) {
    if (_save.family_founding_cursor == 0) {
        _save.family_founding_cells.clear();
        for (size_t cell = 0; cell < _family_milestones_reached.size(); ++cell)
            if (_family_milestones_reached[cell] != 0)
                _save.family_founding_cells.push_back(static_cast<int32_t>(cell));
    }
    const int32_t milestones = static_cast<int32_t>(_save.family_founding_cells.size());
    const int32_t offers = static_cast<int32_t>(_family_founding_offers.size());
    const int32_t choices = static_cast<int32_t>(_family_founding_choices.size());
    const int32_t effects = static_cast<int32_t>(_family_founding_effects.size());
    const int32_t total = 1 + milestones + offers + choices + effects;
    const size_t limit = static_cast<size_t>(std::max(64, budget - 16));
    while (_save.family_founding_cursor < total) {
        std::vector<uint8_t> record;
        int32_t index = _save.family_founding_cursor;
        if (index == 0) {
            append_le<uint8_t>(record, kFoundingRecordHeader);
            append_le<int64_t>(record, _next_family_founding_offer_id.get());
            append_le<int32_t>(record, milestones);
            append_le<int32_t>(record, offers);
            append_le<int32_t>(record, choices);
            append_le<int32_t>(record, effects);
        } else if ((index -= 1) < milestones) {
            const int32_t cell = _save.family_founding_cells[static_cast<size_t>(index)];
            append_le<uint8_t>(record, kFoundingRecordMilestone);
            append_le<int32_t>(record, cell);
            append_le<uint8_t>(record, _family_milestones_reached[static_cast<size_t>(cell)]);
        } else if ((index -= milestones) < offers) {
            const FamilyFoundingOffer &offer =
                _family_founding_offers[static_cast<size_t>(index)];
            append_le<uint8_t>(record, kFoundingRecordOffer);
            append_le<int64_t>(record, offer.offer_id);
            append_le<uint32_t>(record, offer.generation);
            append_le<int32_t>(record, offer.cell);
            append_le<int32_t>(record, offer.milestone_index);
            append_le<int64_t>(record, offer.milestone_population);
            append_le<uint8_t>(record, offer.status);
            append_le<int32_t>(record, offer.chosen_index);
            append_le<int64_t>(record, offer.created_day);
            append_le<int32_t>(record, offer.failed_reviews);
            append_le<uint8_t>(record, static_cast<uint8_t>(offer.candidates.size()));
            for (const FamilyFoundingCandidate &candidate : offer.candidates) {
                append_le<int64_t>(record, candidate.stable_id);
                append_le<int32_t>(record, candidate.surname_id);
                append_le<int32_t>(record, candidate.culture_group_id);
                append_le<uint64_t>(record, candidate.building_handle);
                append_le<int32_t>(record, candidate.building_type_id);
                append_le<int32_t>(record, candidate.owner_signature_id);
                append_le<int64_t>(record, candidate.founders);
                append_le<int32_t>(record, candidate.effect_id);
                append_le<uint32_t>(record,
                    static_cast<uint32_t>(candidate.trait_ids.size()));
                for (size_t t = 0; t < candidate.trait_ids.size(); ++t) {
                    append_le<int32_t>(record, candidate.trait_ids[t]);
                    append_le<int32_t>(record, candidate.trait_strength_q16[t]);
                }
            }
        } else if ((index -= offers) < choices) {
            const FamilyFoundingChoiceCommand &command =
                _family_founding_choices[static_cast<size_t>(index)];
            append_le<uint8_t>(record, kFoundingRecordChoice);
            append_le<int64_t>(record, command.offer_id);
            append_le<uint32_t>(record, command.generation);
            append_le<int32_t>(record, command.choice_index);
            append_le<int64_t>(record, command.effective_day);
            append_le<int64_t>(record, command.sequence);
            append_le<uint64_t>(record, command.submit_order);
        } else {
            index -= choices;
            const auto &row = _family_founding_effects[static_cast<size_t>(index)];
            append_le<uint8_t>(record, kFoundingRecordEffect);
            append_le<int64_t>(record, row.first);
            append_le<int32_t>(record, row.second);
        }
        if (!payload.empty() && payload.size() + record.size() > limit) break;
        payload.insert(payload.end(), record.begin(), record.end());
        ++_save.family_founding_cursor;
    }
    return _save.family_founding_cursor >= total;
}

bool NativeEconomyRuntime::read_family_founding_save_records(
        const std::vector<uint8_t> &bytes, size_t &cursor, uint32_t records,
        std::string &error) {
    if (!_restore.family_founding_seen) {
        _family_milestones_reached.assign(static_cast<size_t>(_cell_count.get()), 0);
        _family_founding_offers.clear();
        _family_founding_choices.clear();
        _family_founding_effects.clear();
        _family_founding_offer_index_dirty = true;
        _restore.expected_family_founding_records = -1;
        _restore.restored_family_founding_records = 0;
    }
    for (uint32_t r = 0; r < records; ++r) {
        uint8_t kind = 0;
        if (!read_le(bytes, cursor, kind)) {
            error = "save_family_founding_record_truncated";
            return false;
        }
        const bool header_expected = _restore.restored_family_founding_records == 0;
        if (header_expected != (kind == kFoundingRecordHeader)) {
            error = "save_family_founding_header_order_invalid";
            return false;
        }
        if (kind == kFoundingRecordHeader) {
            int64_t next_offer = 0;
            int32_t milestones = 0, offers = 0, choices = 0, effects = 0;
            if (!read_le(bytes, cursor, next_offer) ||
                !read_le(bytes, cursor, milestones) ||
                !read_le(bytes, cursor, offers) ||
                !read_le(bytes, cursor, choices) ||
                !read_le(bytes, cursor, effects) || next_offer <= 0 ||
                milestones < 0 || milestones > _cell_count.get() || offers < 0 ||
                offers > _cell_count.get() || choices < 0 || choices > _cell_count.get() ||
                effects < 0 || effects > 10000000) {
                error = "save_family_founding_header_invalid";
                return false;
            }
            _next_family_founding_offer_id = next_offer;
            _restore.expected_family_founding_records =
                1 + milestones + offers + choices + effects;
        } else if (kind == kFoundingRecordMilestone) {
            int32_t cell = -1;
            uint8_t count = 0;
            if (!read_le(bytes, cursor, cell) || !read_le(bytes, cursor, count) ||
                cell < 0 || cell >= _cell_count.get() || count == 0 ||
                count > _family_milestone_populations.size() ||
                _family_milestones_reached[static_cast<size_t>(cell)] != 0) {
                error = "save_family_founding_milestone_invalid";
                return false;
            }
            _family_milestones_reached.write_scalar(static_cast<size_t>(cell), count);
        } else if (kind == kFoundingRecordOffer) {
            FamilyFoundingOffer offer;
            uint8_t candidate_count = 0;
            if (!read_le(bytes, cursor, offer.offer_id) ||
                !read_le(bytes, cursor, offer.generation) ||
                !read_le(bytes, cursor, offer.cell) ||
                !read_le(bytes, cursor, offer.milestone_index) ||
                !read_le(bytes, cursor, offer.milestone_population) ||
                !read_le(bytes, cursor, offer.status) ||
                !read_le(bytes, cursor, offer.chosen_index) ||
                !read_le(bytes, cursor, offer.created_day) ||
                !read_le(bytes, cursor, offer.failed_reviews) ||
                !read_le(bytes, cursor, candidate_count) ||
                candidate_count == 0 || candidate_count > FAMILY_FOUNDING_CARD_COUNT) {
                error = "save_family_founding_offer_truncated";
                return false;
            }
            for (uint8_t c = 0; c < candidate_count; ++c) {
                FamilyFoundingCandidate candidate;
                uint32_t trait_count = 0;
                if (!read_le(bytes, cursor, candidate.stable_id) ||
                    !read_le(bytes, cursor, candidate.surname_id) ||
                    !read_le(bytes, cursor, candidate.culture_group_id) ||
                    !read_le(bytes, cursor, candidate.building_handle) ||
                    !read_le(bytes, cursor, candidate.building_type_id) ||
                    !read_le(bytes, cursor, candidate.owner_signature_id) ||
                    !read_le(bytes, cursor, candidate.founders) ||
                    !read_le(bytes, cursor, candidate.effect_id) ||
                    !read_le(bytes, cursor, trait_count) ||
                    trait_count > kFoundingMaxTraitsPerCard) {
                    error = "save_family_founding_candidate_truncated";
                    return false;
                }
                for (uint32_t t = 0; t < trait_count; ++t) {
                    int32_t trait_id = -1, strength = 0;
                    if (!read_le(bytes, cursor, trait_id) ||
                        !read_le(bytes, cursor, strength)) {
                        error = "save_family_founding_candidate_truncated";
                        return false;
                    }
                    candidate.trait_ids.push_back(trait_id);
                    candidate.trait_strength_q16.push_back(strength);
                }
                offer.candidates.push_back(std::move(candidate));
            }
            _family_founding_offers.push_back(std::move(offer));
        } else if (kind == kFoundingRecordChoice) {
            FamilyFoundingChoiceCommand command;
            if (!read_le(bytes, cursor, command.offer_id) ||
                !read_le(bytes, cursor, command.generation) ||
                !read_le(bytes, cursor, command.choice_index) ||
                !read_le(bytes, cursor, command.effective_day) ||
                !read_le(bytes, cursor, command.sequence) ||
                !read_le(bytes, cursor, command.submit_order) ||
                command.submit_order == 0 || command.effective_day < 0) {
                error = "save_family_founding_choice_invalid";
                return false;
            }
            _family_founding_choices.push_back(command);
        } else if (kind == kFoundingRecordEffect) {
            int64_t stable_id = 0;
            int32_t effect_id = -1;
            if (!read_le(bytes, cursor, stable_id) ||
                !read_le(bytes, cursor, effect_id) || stable_id <= 0 ||
                (!_family_founding_effects.empty() &&
                 _family_founding_effects.back().first >= stable_id)) {
                error = "save_family_founding_effect_invalid";
                return false;
            }
            _family_founding_effects.push_back({stable_id, effect_id});
        } else {
            error = "save_family_founding_record_kind_invalid";
            return false;
        }
        ++_restore.restored_family_founding_records;
        if (_restore.expected_family_founding_records >= 0 &&
            _restore.restored_family_founding_records >
                _restore.expected_family_founding_records) {
            error = "save_family_founding_record_count_invalid";
            return false;
        }
    }
    return true;
}

bool NativeEconomyRuntime::validate_restored_family_founding(
        std::string &error) const {
    std::unordered_set<int64_t> offer_ids;
    std::unordered_set<int32_t> offer_cells;
    const int32_t surname_count = static_cast<int32_t>(_family_surname_weights.size());
    const int32_t trait_count = static_cast<int32_t>(_family_trait_ids.size());
    const int32_t effect_count = static_cast<int32_t>(_family_effect_keys.size());
    for (const FamilyFoundingOffer &offer : _family_founding_offers) {
        if (offer.offer_id <= 0 || offer.offer_id >= _next_family_founding_offer_id.get() ||
            !offer_ids.insert(offer.offer_id).second || offer.cell < 0 ||
            offer.cell >= _cell_count.get() || !offer_cells.insert(offer.cell).second ||
            (offer.status != FAMILY_FOUNDING_OPEN &&
             offer.status != FAMILY_FOUNDING_SELECTED) ||
            offer.milestone_index < 0 || offer.milestone_index >=
                static_cast<int32_t>(_family_milestone_populations.size()) ||
            (offer.status == FAMILY_FOUNDING_SELECTED &&
             (offer.chosen_index < 0 || offer.chosen_index >=
                static_cast<int32_t>(offer.candidates.size()))) ||
            offer.failed_reviews < 0) {
            error = "restore_family_founding_offer_invalid";
            return false;
        }
        for (const FamilyFoundingCandidate &candidate : offer.candidates) {
            if (candidate.stable_id <= 0 || candidate.surname_id < -1 ||
                candidate.surname_id >= surname_count || candidate.founders <= 0 ||
                candidate.effect_id < -1 || candidate.effect_id >= effect_count) {
                error = "restore_family_founding_candidate_invalid";
                return false;
            }
            for (int32_t trait_id : candidate.trait_ids) {
                if (trait_id < 0 || trait_id >= trait_count) {
                    error = "restore_family_founding_candidate_invalid";
                    return false;
                }
            }
        }
    }
    for (const FamilyFoundingChoiceCommand &command : _family_founding_choices) {
        if (offer_ids.count(command.offer_id) == 0) {
            error = "restore_family_founding_choice_orphan";
            return false;
        }
    }
    for (const auto &row : _family_founding_effects) {
        if (row.second < 0 || row.second >= effect_count) {
            error = "restore_family_founding_effect_invalid";
            return false;
        }
    }
    return true;
}

} // namespace pk
