#include "ideology_runtime.h"
#include "ideology_runtime_internal.h"
#include "ideology_runtime_common.inc"
#include <cstdio>
#include <cstdlib>

// Authority-aware instance queries: the ideology report and the ideology restore
// both ask whether an instance still exists / has fired.

#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstring>
#include <iterator>
#include <limits>
#include <numeric>
#include <tuple>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>


namespace pk {
using namespace godot;

uint64_t NativeIdeologyRuntime::next_random(CountryState&c){return splitmix64(c.rng_state);}


int32_t NativeIdeologyRuntime::sample_weighted(CountryState&c,const std::vector<int32_t>&pool,const std::vector<int64_t>&weights) const { int64_t sum=0;for(int64_t v:weights)sum=add_sat(sum,std::max<int64_t>(0,v));if(sum<=0)return -1;const uint64_t roll=splitmix64(c.rng_state)%static_cast<uint64_t>(sum);int64_t cursor=0;for(size_t i=0;i<pool.size();++i){cursor=add_sat(cursor,weights[i]);if(static_cast<uint64_t>(std::max<int64_t>(0,cursor))>roll)return pool[i];}return pool.back(); }


int32_t NativeIdeologyRuntime::ideology_capacity_for(int32_t slot) const {
    int64_t capacity = _ideology_capacity;
    if (_country_runtime != nullptr)
        for (const CapacityUnlock &unlock : _capacity_unlocks)
            if (unlock.ideology_delta != 0 &&
                    country_api::has_technology(*_country_runtime, slot, unlock.technology_id))
                capacity += unlock.ideology_delta;
    return static_cast<int32_t>(std::min<int64_t>(capacity, _ideology_capacity_max));
}
int32_t NativeIdeologyRuntime::spirit_capacity_for(int32_t slot) const {
    int64_t capacity = _spirit_capacity;
    if (_country_runtime != nullptr)
        for (const CapacityUnlock &unlock : _capacity_unlocks)
            if (unlock.spirit_delta != 0 &&
                    country_api::has_technology(*_country_runtime, slot, unlock.technology_id))
                capacity += unlock.spirit_delta;
    return static_cast<int32_t>(std::min<int64_t>(capacity, _spirit_capacity_max));
}


int64_t NativeIdeologyRuntime::offer_cost_for(uint64_t draw_sequence) const {
    return runtime_ideology_offer_cost_q16(
        _offer_cost_q16, _offer_cost_growth_percent, _offer_cost_max_q16, draw_sequence);
}


int64_t NativeIdeologyRuntime::reroll_cost_for(uint64_t draw_sequence,
                                               uint64_t handle) const {
    // The open offer was paid at draw_sequence - 1; rerolls cost a share of it.
    const int64_t paid = offer_cost_for(draw_sequence == 0 ? 0 : draw_sequence - 1u);
    const int32_t factor = ideology_stat_factor_q16(
        _reroll_cost_stat_key, _reroll_cost_stat_id, handle);
    // Scale the *share*, never the base draw: a discount card must not turn into
    // a blanket discount on the whole draw economy. The cap lives in the shared
    // kernel so the worker cannot round or clamp it differently.
    return mul_sat(paid,
        ideology_reroll_percent(_reroll_cost_percent, factor)) / 100;
}


int32_t NativeIdeologyRuntime::offer_choice_count_for(
        const CountryState &country) const {
    // The catalog's `offer_choice_count` IS the base: the field used to be read,
    // validated to equal 3 and then ignored, with 3 written into the draw. The
    // stat adds rows on top of whatever the catalog authored.
    const int32_t bonus = ideology_stat_count(_offer_choice_bonus_stat_key,
        _offer_choice_bonus_stat_id, country.handle,
        OFFER_CHOICE_CAPACITY - OFFER_CHOICE_BASE);
    const int32_t count = _draw_count + bonus;
    return std::clamp(count, 1, OFFER_CHOICE_CAPACITY);
}


bool NativeIdeologyRuntime::banned(const CountryState &c, int32_t id) const {
    return id >= 0 && id / 64 < static_cast<int32_t>(c.banned_bits.size()) &&
        (c.banned_bits[static_cast<size_t>(id) / 64] & (1ULL << (id % 64))) != 0;
}


void NativeIdeologyRuntime::set_banned(CountryState &c, int32_t id) {
    if (id < 0 || id / 64 >= static_cast<int32_t>(c.banned_bits.size())) return;
    c.banned_bits[static_cast<size_t>(id) / 64] |= (1ULL << (id % 64));
}


int32_t NativeIdeologyRuntime::draw_pool_size(const CountryState &c, int32_t slot) const {
    int32_t count = 0;
    for (int32_t i = 0; i < static_cast<int32_t>(_definitions.size()); ++i) {
        const Definition &d = _definitions[static_cast<size_t>(i)];
        if (banned(c, i)) continue;
        if (!known(c, i) && (d.acquisition & DRAW) != 0 && requirements_met(c, slot, d)) ++count;
    }
    return count;
}


int32_t NativeIdeologyRuntime::unlocked_era_for(int32_t country_slot) const {
    if (_country_runtime == nullptr) return 0;
    int32_t reached = 0;
    for (int32_t era = 0;
            era < static_cast<int32_t>(_era_milestone_technologies.size()); ++era) {
        const int32_t technology =
            _era_milestone_technologies[static_cast<size_t>(era)];
        if (technology < 0 || era <= reached) continue;
        if (country_api::has_technology(*_country_runtime, country_slot, technology)) reached = era;
    }
    return reached;
}


bool NativeIdeologyRuntime::draw_offer(CountryState &c, int32_t slot, std::string &error) {
    // Mirrors RuntimeIdeologyPodAuthority::draw_offer: same eligibility filter,
    // same shared weight kernel, same RNG advance, so the two authorities stay
    // byte-identical stream consumers.
    c.unlocked_era = unlocked_era_for(slot);
    const int32_t decay_floor_bp = ideology_stat_bp(_era_decay_floor_stat_key,
        _era_decay_floor_stat_id, c.handle);
    std::vector<IdeologyDrawCandidate> pool;
    // Parallel to `pool`: 1 when the row may satisfy the current-era guarantee.
    // Kept beside the pool rather than inside the candidate struct so the shared
    // draw kernel keeps its two-field row.
    std::vector<uint8_t> pool_recent;
    std::vector<IdeologyDrawCandidate> fallback_rows;
    for (int32_t i = 0; i < static_cast<int32_t>(_definitions.size()); ++i) {
        const Definition &d = _definitions[static_cast<size_t>(i)];
        // 封存 retires a card from this run's pool for good. Checked before
        // anything else so a banned card can never take part in a draw, a
        // guarantee slot or the rarity fallback.
        if (banned(c, i) || (d.acquisition & DRAW) == 0) continue;
        if (!requirements_met(c, slot, d)) continue;
        const uint8_t recent = d.era_index >= c.unlocked_era - 1 ? 1u : 0u;
        const int32_t weight = ideology_draw_weight(d.rarity_weight,
            _era_decay_bp.data(), _era_decay_bp.size(), c.unlocked_era,
            d.era_index, decay_floor_bp);
        IdeologyDrawCandidate candidate;
        candidate.id = i;
        if (!known(c, i)) {
            candidate.weight = weight;
            pool.push_back(candidate);
            pool_recent.push_back(recent);
            // The rarity fallback is computed from the NEW-card slice only.
            // Including 精进 rows would make the fallback fire (and therefore
            // advance the RNG differently) purely because refine is enabled.
            fallback_rows.push_back(candidate);
        } else if (_refine_weight_bp > 0) {
            // 精进: an owned card that is not maxed comes back as a pick that
            // raises understanding instead of unlocking one. Maxed cards stay
            // out -- a row that cannot do anything is worse than a missing row,
            // and excluding them means there is no refund to price.
            const IdeaState *state = idea_state_for(c, i);
            if (state == nullptr) continue;
            if (state->level >= d.level_count - 1) continue;
            candidate.weight = static_cast<int64_t>(d.rarity_weight) *
                static_cast<int64_t>(_refine_weight_bp);
            pool.push_back(candidate);
            pool_recent.push_back(recent);
        }
    }
    if (pool.empty()) { error = "ideology_offer_pool_insufficient"; return false; }
    std::vector<IdeologyDrawCandidate> weighted;
    std::vector<uint8_t> weighted_recent;
    weighted.reserve(pool.size());
    weighted_recent.reserve(pool.size());
    for (size_t index = 0; index < pool.size(); ++index) {
        if (pool[index].weight > 0) {
            weighted.push_back(pool[index]);
            weighted_recent.push_back(pool_recent[index]);
        }
    }
    // Late eras only carry a handful of ideas, so once they are all known the
    // decayed pool empties out permanently. Falling back to raw rarity weight
    // keeps the offer functional; it is a pure function of the eligible list so
    // both authorities take the same branch on the same day.
    if (weighted.empty()) {
        for (const IdeologyDrawCandidate &candidate : fallback_rows) {
            IdeologyDrawCandidate fallback = candidate;
            fallback.weight = static_cast<int64_t>(
                _definitions[static_cast<size_t>(candidate.id)].rarity_weight) * 10000;
            weighted.push_back(fallback);
            weighted_recent.push_back(
                _definitions[static_cast<size_t>(candidate.id)].era_index
                    >= c.unlocked_era - 1 ? 1u : 0u);
        }
    }
    if (weighted.empty()) { error = "ideology_offer_weight_invalid"; return false; }
    std::array<int32_t, OFFER_CHOICE_CAPACITY> draw;
    draw.fill(-1);
    const int32_t want = std::min(offer_choice_count_for(c),
        static_cast<int32_t>(weighted.size()));
    const int32_t drawn = ideology_weighted_draw_recent_first(weighted,
        weighted_recent, want, [&c]() { return splitmix64(c.rng_state); },
        draw.data());
    if (drawn <= 0) { error = "ideology_offer_weight_invalid"; return false; }
    const uint32_t generation = std::max<uint32_t>(1, c.offer.generation + 1);
    c.offer.clear();
    c.offer.active = 1;
    c.offer.generation = generation;
    for (int32_t i = 0; i < drawn; ++i) c.offer.ideology_ids[static_cast<size_t>(i)] = draw[static_cast<size_t>(i)];
    c.offer.choice_count = static_cast<uint8_t>(drawn);
    return true;
}


bool NativeIdeologyRuntime::open_offer(CountryState &c, int32_t slot, std::string &error) {
    if (c.offer.active != 0) { error = "ideology_offer_pending"; return false; }
    const int64_t cost = offer_cost_for(c.draw_sequence);
    if (c.free_draws == 0 && c.ideology_points_q16 < cost) {
        error = "ideology_points_insufficient"; return false;
    }
    if (!draw_offer(c, slot, error)) return false;
    if (c.free_draws > 0) --c.free_draws;
    else c.ideology_points_q16 -= cost;
    ++c.draw_sequence;
    ++_offers_opened;
    return true;
}


bool NativeIdeologyRuntime::reroll_offer(CountryState &c, int32_t slot,
        const Command &cmd, std::string &error) {
    if (c.offer.active == 0) { error = "ideology_offer_not_active"; return false; }
    if (cmd.offer_generation != 0 && cmd.offer_generation != c.offer.generation) {
        error = "ideology_offer_generation_stale"; return false;
    }
    const int64_t cost = reroll_cost_for(c.draw_sequence, c.handle);
    if (c.ideology_points_q16 < cost) { error = "ideology_points_insufficient"; return false; }
    if (!draw_offer(c, slot, error)) return false;
    c.ideology_points_q16 -= cost;
    return true;
}


void NativeIdeologyRuntime::accrue_points(int64_t day) {
    // Production entry point: settle from Economy's committed snapshot.
    //
    // Read it by REFERENCE -- `ideology_opinion_from_economy` copies every lane
    // (population/funds/satisfaction arrays) and this runs once per day per world.
    if (_economy_runtime == nullptr) {
        _points_accrue_result = 1;
        return;
    }
    accrue_points_from(
        ideology_opinion_from_economy(
            economy_api::country_class_opinion_snapshot(*_economy_runtime)),
        day);
}


void NativeIdeologyRuntime::accrue_points_from(
        const RuntimeIdeologyOpinionSnapshot &opinion, int64_t day) {
    // The single settlement body: ordinary daily work reads Economy's committed
    // snapshot, while explicit SHADOW parity pins that day's reference input.
    // Mirrors RuntimeIdeologyPodAuthority::accrue_points field for field -- the
    // two must stay line-comparable or parity regresses into a business diff.
    _points_accrue_result = -1;
    const uint64_t revision = opinion.revision;
    _points_accrue_revision = revision;
    if (revision == 0) { _points_accrue_result = 2; return; }
    // R9-2: settle once per COMMITTED DAY, never per publish.
    //
    // The key used to be `period_index = commit_day / period_days`, and that
    // divisor is not constant: `period_days` comes from `_epoch_days`
    // (`economy_runtime_epoch.cpp`), recomputed whenever the workset changes. With
    // period 5, day 10 is period 2; once the epoch widens to 6, day 12 is period 2
    // as well, so a genuinely new commit was skipped as "already settled" (and the
    // reverse split one period into two). `commit_day` is monotone and independent
    // of the publish count, so it is the only safe key. `period_index` survives as
    // a diagnostic field only.
    const int64_t commit_day = opinion.committed_day;
    const uint64_t settle_key = commit_day >= 0
        ? static_cast<uint64_t>(commit_day) + 1u
        : revision;
    if (settle_key == _points_revision_seen) { _points_accrue_result = 3; return; }
    const size_t countries = static_cast<size_t>(opinion.country_count);
    if (opinion.country_handles.size() < countries ||
            opinion.country_population.size() != countries ||
            opinion.country_buildings_installed.size() != countries ||
            opinion.country_trade_base_value.size() != countries) {
        _points_accrue_result = 4;
        return;
    }
    if (opinion.class_hash != _political_class_hash ||
            opinion.class_count != _political_class_count) {
        _points_accrue_result = 5;
        return;
    }
    // Mark the key consumed only AFTER every gate passed. The original order
    // consumed it first, so a single snapshot with a mismatched class catalog
    // permanently retired that revision: the next day's identical snapshot fell
    // into the "already seen" branch and the runtime never allocated a single
    // country row. A retryable gate has to stay retryable.
    _points_revision_seen = settle_key;
    _points_accrue_result = 0;
    const int64_t period = std::max<int64_t>(1, opinion.period_days);
    const size_t classes = static_cast<size_t>(std::max(0, _political_class_count));
    for (size_t slot = 0; slot < countries; ++slot) {
        const uint64_t handle = opinion.country_handles[slot];
        if (handle == 0) continue;
        CountryState *row = country_state_for(handle, true);
        if (row == nullptr || row->points_revision == settle_key) continue;
        row->points_revision = settle_key;
        const int64_t population = std::max<int64_t>(0, opinion.country_population[slot]);
        const int64_t buildings = std::max<int64_t>(0, opinion.country_buildings_installed[slot]);
        if (row->baseline_ready == 0) {
            row->baseline_population = population;
            row->baseline_buildings = buildings;
            row->baseline_ready = 1;
            // R9-5: seed the trade marker on the SAME settlement that establishes
            // the baseline. Leaving it at INT64_MIN meant the kernel's first call
            // did the seeding instead, one settlement later, so the whole first
            // period's trade flow was never paid. Seeding here costs nothing (it
            // pays 0 either way) and removes the silent lost period.
            if (row->trade_paid_day == INT64_MIN) row->trade_paid_day = day;
            continue;
        }
        const int64_t population_gain = std::max<int64_t>(0, population - row->baseline_population);
        const int64_t building_gain = std::max<int64_t>(0, buildings - row->baseline_buildings);
        row->baseline_population = std::max(row->baseline_population, population);
        row->baseline_buildings = std::max(row->baseline_buildings, buildings);
        const int64_t trade_per_day = std::max<int64_t>(0, opinion.country_trade_base_value[slot]) / period;
        RuntimeIdeologyPodPointLedger ledger;
        ledger.day = day;
        const int32_t population_factor_q16 = ideology_stat_factor_q16(
            _point_population_factor_stat_key, _point_population_factor_stat_id,
            handle);
        const int32_t building_factor_q16 = ideology_stat_factor_q16(
            _point_building_factor_stat_key, _point_building_factor_stat_id,
            handle);
        const int32_t trade_factor_q16 = ideology_stat_factor_q16(
            _point_trade_factor_stat_key, _point_trade_factor_stat_id, handle);
        const std::vector<int32_t> population_factor = {
            std::clamp<int32_t>(population_factor_q16, Q16_ONE / 2, 3 * Q16_ONE)};
        const std::vector<int32_t> building_factor = {
            std::clamp<int32_t>(building_factor_q16, Q16_ONE / 2, 3 * Q16_ONE)};
        const std::vector<int32_t> trade_factor = {
            std::clamp<int32_t>(trade_factor_q16, Q16_ONE / 2, 3 * Q16_ONE)};
        ledger.population_q16 = ideology_point_term_q16(
            mul_sat(population_gain, _point_population_weight_q16),
            population_factor, 0);
        ledger.building_q16 = ideology_point_term_q16(
            mul_sat(building_gain, _point_building_weight_q16),
            building_factor, 0);
        // Trade is a FLOW, so one settlement pays for the days that actually
        // elapsed. Population and buildings are high-water deltas and already
        // pay at most once whatever the cadence, but trade used to pay its full
        // daily amount per settlement and then suppress a second settlement on
        // the SAME day. That made the total a function of the settlement count:
        // the worker, settling on its own clock, collected 11 days where the
        // main thread collected one (measured 46859 vs 67969, R8-2).
        //
        // `ideology_trade_flow_q16` is the shared kernel: `trade_per_day x
        // clamp(day - trade_paid_day, 0, period_days)`, seeded (not paid) on the
        // first observation. Settling once, thirty times, or a random number of
        // times over the same 30 days now pays the same total, and the marker
        // saves/restores with the row.
        // The span this settlement covers, needed by the cap (R9-3). Trade is the
        // only flow that knows elapsed time, so the kernel reports how many days
        // it paid for; a day already paid counts as 1 so the cap never collapses.
        const int64_t trade_paid_before = row->trade_paid_day;
        const int64_t trade_days_q16 = ideology_trade_flow_q16(
            trade_per_day, day, period, row->trade_paid_day);
        const int64_t ledger_span_days = trade_paid_before == INT64_MIN
            ? 1 : std::max<int64_t>(1, day - trade_paid_before);
        ledger.trade_q16 = ideology_point_term_q16(
            mul_sat(trade_days_q16, _point_trade_weight_q16) / TRADE_MONEY_SCALE,
            trade_factor, 0);
        int64_t total_influence = 0;
        int64_t weighted = 0;
        for (size_t class_index = 0; class_index < classes; ++class_index) {
            const size_t lane = slot * classes + class_index;
            if (lane >= opinion.population.size() || lane >= opinion.owner_employed.size() ||
                    lane >= opinion.funds.size() || lane >= opinion.satisfaction_q16.size())
                continue;
            int64_t influence = std::max<int64_t>(0, opinion.population[lane]);
            influence = add_sat(influence, mul_sat(std::max<int64_t>(0, opinion.owner_employed[lane]),
                _opinion_owner_influence_weight));
            influence = add_sat(influence, std::max<int64_t>(0, opinion.funds[lane]) /
                _opinion_funds_per_influence);
            total_influence = add_sat(total_influence, influence);
            weighted = add_sat(weighted, mul_sat(influence,
                std::clamp<int64_t>(opinion.satisfaction_q16[lane], 0, Q16_ONE)));
        }
        const int64_t satisfaction = total_influence > 0
            ? std::clamp<int64_t>(weighted / total_influence, 0, Q16_ONE) : Q16_ONE / 2;
        int32_t opinion_floor_q16 = static_cast<int32_t>(Q16_ONE / 2);
        if (resolve_ideology_stat_id(
                _opinion_factor_floor_stat_key,
                _opinion_factor_floor_stat_id) >= 0) {
            double floor_value = modifier_api::effective_value(*_modifier_runtime,
                ModifierApi::COUNTRY, _opinion_factor_floor_stat_id,
                handle, 0, 0.5);
            if (!std::isfinite(floor_value)) floor_value = 0.5;
            opinion_floor_q16 = static_cast<int32_t>(std::lround(
                std::clamp(floor_value, 0.3, 0.5) * 65536.0));
        }
        const std::vector<int32_t> opinion_floor = {opinion_floor_q16};
        ledger.opinion_factor_q16 = ideology_opinion_factor_q16(
            satisfaction, opinion_floor, 0);
        double factor = 1.0;
        if (_modifier_runtime != nullptr && modifier_api::configured(*_modifier_runtime) &&
                !_point_gain_stat_key.empty())
            factor = modifier_api::effective_value(*_modifier_runtime, ModifierApi::COUNTRY,
                _point_gain_stat_key.c_str(), handle, 0, 1.0);
        if (!std::isfinite(factor)) factor = 1.0;
        factor = std::clamp(factor, 0.0, 4.0);
        ledger.gain_factor_q16 = static_cast<int32_t>(std::lround(factor * 65536.0));
        const int64_t raw = add_sat(add_sat(ledger.population_q16, ledger.building_q16), ledger.trade_q16);
        int64_t gain = mul_sat(raw, ledger.opinion_factor_q16) / Q16_ONE;
        gain = mul_sat(gain, ledger.gain_factor_q16) / Q16_ONE;
        // R9-3: the single-settlement cap scales with the days this settlement
        // covers.
        //
        // `_point_gain_cap_q16` is authored as a PER-DAY ceiling, but it was
        // applied to the whole settlement. Trade now pays its full elapsed span at
        // once, so a side that settles rarely hits the cap with a large span while
        // a side that settles daily never does -- "1 settlement == 30 settlements"
        // held in the kernel and broke here, paying the rare settler LESS.
        //
        // The span is the number of days this settlement is responsible for. It is
        // 1 when trade was already paid for this day, and `day - previous_day`
        // otherwise. Population and building gains are high-water deltas that
        // describe the whole span, so they are covered by the same multiplier.
        const int64_t covered_days = std::max<int64_t>(1, ledger_span_days);
        if (_point_gain_cap_q16 > 0) {
            gain = std::min(gain, mul_sat(_point_gain_cap_q16, covered_days * Q16_ONE) / Q16_ONE);
        }
        ledger.gain_q16 = std::max<int64_t>(0, gain);
        row->ideology_points_q16 = add_sat(row->ideology_points_q16, ledger.gain_q16);
        row->lifetime_points_q16 = add_sat(row->lifetime_points_q16, ledger.gain_q16);
        row->ledger = ledger;
        row->history_q16[row->history_head] = ledger.gain_q16;
        row->history_head = static_cast<uint8_t>((row->history_head + 1u) % POINT_HISTORY);
        if (row->history_count < POINT_HISTORY) ++row->history_count;
    }
}


bool NativeIdeologyRuntime::choose_offer(CountryState &c, const Command &cmd,
        std::string &error) {
    if (c.offer.active == 0 || cmd.offer_generation != c.offer.generation) {
        error = "ideology_offer_generation_stale";
        return false;
    }
    // Bound by the row count the draw actually produced, not by the array
    // capacity: the tail of `ideology_ids` is -1 and picking there would be an
    // index that looks valid.
    if (cmd.choice_index < 0 ||
            cmd.choice_index >= static_cast<int32_t>(c.offer.choice_count)) {
        error = "ideology_offer_choice_invalid";
        return false;
    }
    const int32_t idea = c.offer.ideology_ids[static_cast<size_t>(cmd.choice_index)];
    if (idea < 0 || banned(c, idea)) {
        error = "ideology_offer_choice_unavailable";
        return false;
    }
    if (known(c, idea)) {
        // 精进: an owned row only ever reaches the offer because the card is not
        // maxed, so the pick pays understanding. `reconcile_level` is what turns
        // that into a level, which is the whole point -- a duplicate is progress
        // instead of a dead pick or a permanently shrinking pool.
        IdeaState *state = idea_state_for(c, idea, false);
        if (state == nullptr) { error = "ideology_offer_choice_unavailable"; return false; }
        state->understanding_q16 += _refine_understanding_q16;
        reconcile_level(*state);
    } else {
        set_known(c, idea);
        idea_state_for(c, idea, true);
    }
    c.offer.clear();
    return true;
}


bool NativeIdeologyRuntime::ban_card(CountryState &c, const Command &cmd,
        std::string &error) {
    const int32_t idea = cmd.ideology_id;
    if (idea < 0 || idea >= static_cast<int32_t>(_definitions.size())) {
        error = "ideology_ideology_invalid";
        return false;
    }
    // Banning an owned card would delete progress, and banning twice would charge
    // twice for the same effect. Both are refused by name.
    if (known(c, idea)) { error = "ideology_ban_known"; return false; }
    if (banned(c, idea)) { error = "ideology_ban_already_banned"; return false; }
    const int64_t cost = offer_cost_for(c.draw_sequence);
    if (c.ideology_points_q16 < cost) {
        error = "ideology_points_insufficient";
        return false;
    }
    c.ideology_points_q16 -= cost;
    set_banned(c, idea);
    return true;
}


Dictionary NativeIdeologyRuntime::preview_offer_eligibility(int64_t handle) const {
    Dictionary out;
    out["ok"] = true;
    out["country_handle"] = handle;
    out["can_draw"] = false;
    out["can_reroll"] = false;
    if (!_configured) { out["ok"] = false; out["reason"] = "ideology_runtime_unconfigured"; return out; }
    int32_t slot = -1;
    if (!validate_country(static_cast<uint64_t>(handle), slot)) {
        out["reason"] = "ideology_country_handle_stale";
        return out;
    }
    const CountryState *country = country_state_for(static_cast<uint64_t>(handle));
    CountryState scratch;
    if (country == nullptr) {
        init_country_state(scratch, static_cast<uint64_t>(handle));
        country = &scratch;
    }
    const int64_t cost = offer_cost_for(country->draw_sequence);
    const int64_t reroll = reroll_cost_for(country->draw_sequence, country->handle);
    const int32_t pool = draw_pool_size(*country, slot);
    out["points_q16"] = country->ideology_points_q16;
    out["free_draws"] = static_cast<int64_t>(country->free_draws);
    out["cost_q16"] = cost;
    out["reroll_cost_q16"] = reroll;
    out["pool_size"] = pool;
    out["offer_active"] = country->offer.active != 0;
    out["offer_generation"] = static_cast<int64_t>(country->offer.generation);
    out["offer_choice_count"] = static_cast<int32_t>(country->offer.choice_count);
    String reason = "";
    if (country->offer.active != 0) reason = "ideology_offer_pending";
    else if (pool <= 0) reason = "ideology_offer_pool_insufficient";
    else if (country->free_draws == 0 &&
            country->ideology_points_q16 < cost)
        reason = "ideology_points_insufficient";
    out["can_draw"] = reason.is_empty();
    out["reason"] = reason;
    out["can_reroll"] = country->offer.active != 0 && pool > 0 &&
        country->ideology_points_q16 >= reroll;
    return out;
}


} // namespace pk
