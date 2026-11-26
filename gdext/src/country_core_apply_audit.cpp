#include "country_core_apply.h"

#include "country_core.h"
#include "fnv1a_bytes.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <limits>
#include <string>
#include <vector>

namespace pk {

bool country_core_first_business_difference(
        const RuntimeCountryPodSnapshot &reference,
        const RuntimeCountryPodSnapshot &worker,
        char *field, size_t field_capacity, int32_t &index) {
    index = -1;
    const auto set_field = [&](const char *name, int32_t at) {
        index = at;
        if (field == nullptr || field_capacity == 0) return;
        size_t i = 0;
        if (name != nullptr) {
            for (; i + 1u < field_capacity && name[i] != '\0'; ++i)
                field[i] = name[i];
        }
        field[i] = '\0';
    };
    if (reference.country_count != worker.country_count) {
        set_field("country_count", 0);
        return true;
    }
    if (reference.cell_count != worker.cell_count) {
        set_field("cell_count", 0);
        return true;
    }
    if (reference.last_research_day != worker.last_research_day) {
        set_field("last_research_day", 0);
        return true;
    }
    if (reference.country_active != worker.country_active) {
        set_field("country_active", 0);
        return true;
    }
    if (reference.country_generation != worker.country_generation) {
        set_field("country_generation", 0);
        return true;
    }
    if (reference.country_stable_ids != worker.country_stable_ids) {
        set_field("country_stable_ids", 0);
        return true;
    }
    if (reference.country_display_names != worker.country_display_names) {
        set_field("country_display_names", 0);
        return true;
    }
    if (reference.territory_count != worker.territory_count) {
        set_field("territory_count", 0);
        return true;
    }
    if (reference.country_cash != worker.country_cash) {
        int32_t at = 0;
        const size_t n = std::min(reference.country_cash.size(),
                                  worker.country_cash.size());
        for (size_t i = 0; i < n; ++i) {
            if (reference.country_cash[i] != worker.country_cash[i]) {
                at = static_cast<int32_t>(i);
                break;
            }
        }
        set_field("country_cash", at);
        return true;
    }
    if (reference.country_goods != worker.country_goods) {
        set_field("country_goods", 0);
        return true;
    }
    if (reference.cell_country_slot != worker.cell_country_slot) {
        int32_t at = 0;
        const size_t n = std::min(reference.cell_country_slot.size(),
                                  worker.cell_country_slot.size());
        for (size_t i = 0; i < n; ++i) {
            if (reference.cell_country_slot[i] != worker.cell_country_slot[i]) {
                at = static_cast<int32_t>(i);
                break;
            }
        }
        set_field("cell_country_slot", at);
        return true;
    }
    if (reference.territory_offsets != worker.territory_offsets) {
        set_field("territory_csr", 0);
        return true;
    }
    if (reference.territory_cells != worker.territory_cells) {
        set_field("territory_cells", 0);
        return true;
    }
    if (reference.country_technologies != worker.country_technologies) {
        set_field("country_technologies", 0);
        return true;
    }
    if (reference.country_discovered != worker.country_discovered) {
        set_field("country_discovered", 0);
        return true;
    }
    if (reference.country_pending_technologies !=
            worker.country_pending_technologies) {
        set_field("country_pending_technologies", 0);
        return true;
    }
    if (reference.country_research_signals != worker.country_research_signals) {
        int32_t at = 0;
        const size_t n = std::min(reference.country_research_signals.size(),
                                  worker.country_research_signals.size());
        for (size_t i = 0; i < n; ++i) {
            if (reference.country_research_signals[i] !=
                    worker.country_research_signals[i]) {
                at = static_cast<int32_t>(i);
                break;
            }
        }
        set_field("country_research_signals", at);
        return true;
    }
    if (reference.research_signal_cell_offsets !=
            worker.research_signal_cell_offsets ||
        reference.research_signal_cells != worker.research_signal_cells) {
        set_field("research_signal_cells", 0);
        return true;
    }
    if (reference.research_signal_evidence_offsets !=
            worker.research_signal_evidence_offsets ||
        reference.research_signal_evidence.size() !=
            worker.research_signal_evidence.size()) {
        set_field("research_signal_evidence", 0);
        return true;
    }
    for (size_t i = 0; i < reference.research_signal_evidence.size(); ++i) {
        const auto &a = reference.research_signal_evidence[i];
        const auto &b = worker.research_signal_evidence[i];
        if (a.signal != b.signal || a.count != b.count ||
            a.first_day != b.first_day || a.last_day != b.last_day ||
            a.first_cell != b.first_cell) {
            set_field("research_signal_evidence", static_cast<int32_t>(i));
            return true;
        }
    }
    if (reference.research_queues != worker.research_queues) {
        set_field("research_queues", 0);
        return true;
    }
    if (reference.research_queue_lengths != worker.research_queue_lengths) {
        set_field("research_queue_lengths", 0);
        return true;
    }
    if (reference.research_weights_bp != worker.research_weights_bp) {
        set_field("research_weights_bp", 0);
        return true;
    }
    if (reference.research_auto_purchase != worker.research_auto_purchase) {
        set_field("research_auto_purchase", 0);
        return true;
    }
    if (reference.research_deferred_points != worker.research_deferred_points) {
        set_field("research_deferred_points", 0);
        return true;
    }
    if (reference.research_progress != worker.research_progress) {
        set_field("research_progress", 0);
        return true;
    }
    if (reference.research_purchased_total != worker.research_purchased_total ||
        reference.research_consumed_total != worker.research_consumed_total ||
        reference.research_progress_total != worker.research_progress_total ||
        reference.research_completed_total != worker.research_completed_total) {
        set_field("research_totals", 0);
        return true;
    }
    if (reference.country_tax_defaults != worker.country_tax_defaults) {
        set_field("country_tax_defaults", 0);
        return true;
    }
    if (reference.cell_tax_policy_ids != worker.cell_tax_policy_ids) {
        set_field("cell_tax_policy_ids", 0);
        return true;
    }
    if (country_core_hash_business_state(reference) !=
        country_core_hash_business_state(worker)) {
        set_field("state_hash", 0);
        return true;
    }
    return false;
}

uint64_t country_core_hash_business_state(const RuntimeCountryPodSnapshot &state) {
    constexpr uint64_t FNV_OFFSET = 1469598103934665603ull;
    constexpr uint64_t FNV_PRIME = 1099511628211ull;
    uint64_t hash = FNV_OFFSET;
    const auto mix_u64 = [&](uint64_t value) {
        for (uint32_t i = 0; i < 8; ++i) {
            hash ^= static_cast<uint8_t>(value >> (i * 8u));
            hash *= FNV_PRIME;
        }
    };
    const auto hash_vector = [&](const auto &values) {
        const uint32_t count = static_cast<uint32_t>(values.size());
        for (size_t i = 0; i < sizeof(count); ++i) {
            hash ^= static_cast<uint8_t>(count >> (i * 8u));
            hash *= FNV_PRIME;
        }
        hash = hashing::fnv1a::bytes(hash, reinterpret_cast<const uint8_t *>(values.data()),
                            values.size() * sizeof(values[0]));
    };
    // generation is transport/bookkeeping state, not Country business state.
    // Production and SHADOW can publish the same canonical Country values
    // through different numbers of internal commits, so including it makes
    // deterministic business parity impossible by construction.
    mix_u64(static_cast<uint64_t>(state.last_research_day));
    hash_vector(state.country_active);
    hash_vector(state.country_generation);
    const auto hash_string = [&](const std::string &value) {
        const uint32_t count = static_cast<uint32_t>(value.size());
        for (size_t i = 0; i < sizeof(count); ++i) {
            hash ^= static_cast<uint8_t>(count >> (i * 8u));
            hash *= FNV_PRIME;
        }
        for (unsigned char byte : value) {
            hash ^= byte;
            hash *= FNV_PRIME;
        }
        mix_u64(0);
    };
    for (const std::string &value : state.country_stable_ids) {
        hash_string(value);
    }
    for (const std::string &value : state.country_display_names) {
        hash_string(value);
    }
    // Per-country state versions are read-view invalidation cursors. They can
    // differ when production batches internal writes differently from SHADOW,
    // without any difference in the canonical Country business values.
    hash_vector(state.territory_count);
    hash_vector(state.capital_cell);
    hash_vector(state.country_political_regime_ids);
    hash_vector(state.country_political_regime_capabilities);
    hash_vector(state.country_cash);
    hash_vector(state.country_goods);
    hash_vector(state.cell_country_slot);
    hash_vector(state.territory_offsets);
    hash_vector(state.territory_cells);
    hash_vector(state.country_technologies);
    hash_vector(state.country_discovered);
    hash_vector(state.country_pending_technologies);
    hash_vector(state.country_research_signals);
    hash_vector(state.research_signal_cell_offsets);
    hash_vector(state.research_signal_cells);
    hash_vector(state.research_signal_evidence_offsets);
    for (const auto &entry : state.research_signal_evidence) {
        mix_u64(static_cast<uint64_t>(entry.signal));
        mix_u64(static_cast<uint64_t>(entry.count));
        mix_u64(static_cast<uint64_t>(entry.first_day));
        mix_u64(static_cast<uint64_t>(entry.last_day));
        mix_u64(static_cast<uint64_t>(entry.first_cell));
    }
    hash_vector(state.research_queues);
    hash_vector(state.research_queue_lengths);
    hash_vector(state.research_weights_bp);
    hash_vector(state.research_auto_purchase);
    hash_vector(state.research_deferred_points);
    hash_vector(state.research_progress);
    hash_vector(state.research_purchased_total);
    hash_vector(state.research_consumed_total);
    hash_vector(state.research_progress_total);
    hash_vector(state.research_completed_total);
    hash_vector(state.country_tax_defaults);
    hash_vector(state.country_tax_default_modes);
    hash_vector(state.country_income_tax_overrides);
    hash_vector(state.country_consumption_tax_overrides);
    hash_vector(state.country_business_tax_overrides);
    hash_vector(state.country_import_tax_overrides);
    hash_vector(state.country_export_tax_overrides);
    hash_vector(state.country_income_tax_mode_overrides);
    hash_vector(state.country_consumption_tax_mode_overrides);
    hash_vector(state.country_business_tax_mode_overrides);
    hash_vector(state.country_import_tax_mode_overrides);
    hash_vector(state.country_export_tax_mode_overrides);
    hash_vector(state.cell_tax_policy_ids);
    for (const auto &policy : state.cell_tax_policies) {
        for (const int32_t value : policy.defaults)
            mix_u64(static_cast<uint64_t>(value));
        for (const int32_t value : policy.modes)
            mix_u64(static_cast<uint64_t>(value));
        for (const auto &entry : policy.overrides) {
            mix_u64(static_cast<uint64_t>(entry.kind));
            mix_u64(static_cast<uint64_t>(entry.item));
            mix_u64(static_cast<uint64_t>(entry.rate));
            mix_u64(static_cast<uint64_t>(entry.mode));
        }
    }
    return hash;
}

} // namespace pk
