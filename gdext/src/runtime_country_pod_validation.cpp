#include "runtime_country_pod.h"
#include "runtime_country_pod_internal.h"
#include <cmath>

namespace pk {

bool RuntimeCountryPodAdapter::validate_snapshot(
        const RuntimeCountryPodSnapshot &snapshot, std::string &error) {
    error.clear();
    if (!snapshot.bootstrapped) {
        error = "country_pod_not_bootstrapped";
        return false;
    }
    if (snapshot.last_research_day > snapshot.committed_day) {
        error = "country_pod_research_day_ahead_of_state";
        return false;
    }
    const size_t countries = snapshot.country_count;
    const size_t cells = snapshot.cell_count;
    if (snapshot.country_stable_ids.size() != countries ||
        snapshot.country_display_names.size() != countries ||
        snapshot.profession_count == 0 || snapshot.building_type_count == 0) {
        error = "country_pod_identity_or_tax_catalog_missing";
        return false;
    }
    const bool political_state_absent =
        snapshot.country_political_regime_ids.empty() &&
        snapshot.country_political_regime_capabilities.empty();
    if (snapshot.country_active.size() != countries ||
        snapshot.country_generation.size() != countries ||
        (!political_state_absent &&
         (snapshot.country_political_regime_ids.size() != countries ||
          snapshot.country_political_regime_capabilities.size() != countries)) ||
        snapshot.territory_count.size() != countries ||
        snapshot.country_cash.size() != countries ||
        snapshot.cell_country_slot.size() != cells ||
        (!snapshot.is_water.empty() && snapshot.is_water.size() != cells)) {
        error = "country_pod_snapshot_shape_mismatch";
        return false;
    }
    if (snapshot.technology_words > 0 &&
        snapshot.country_technologies.size() != countries * snapshot.technology_words) {
        error = "country_pod_technology_shape_mismatch";
        return false;
    }
    if (snapshot.technology_words > 0 &&
        snapshot.country_pending_technologies.size() != countries * snapshot.technology_words) {
        error = "country_pod_pending_shape_mismatch";
        return false;
    }
    if (snapshot.country_state_version.size() != countries ||
        snapshot.country_goods.size() != countries * snapshot.good_count ||
        snapshot.territory_offsets.size() != countries + 1u ||
        snapshot.territory_cells.size() !=
            static_cast<size_t>(snapshot.territory_offsets.empty()
                                    ? 0 : snapshot.territory_offsets.back()) ||
        snapshot.research_auto_purchase.size() != countries ||
        snapshot.research_deferred_points.size() != countries ||
        snapshot.research_progress_total.size() != countries ||
        snapshot.research_completed_total.size() != countries ||
        snapshot.research_purchased_total.size() != countries ||
        snapshot.research_consumed_total.size() != countries ||
        snapshot.research_progress.size() != countries * snapshot.technology_count ||
        snapshot.research_cost_factor.size() != countries ||
        snapshot.research_efficiency.size() != countries * 4u ||
        snapshot.research_peer_flags.size() != countries * snapshot.technology_count) {
        error = "country_pod_authority_state_shape_mismatch";
        return false;
    }
    if (snapshot.research_signal_words != 0 &&
        snapshot.country_research_signals.size() !=
            countries * snapshot.research_signal_words) {
        error = "country_pod_signal_shape_mismatch";
        return false;
    }
    if (snapshot.research_signal_evidence_offsets.size() != countries + 1u ||
        snapshot.research_signal_evidence_offsets.empty() ||
        snapshot.research_signal_evidence_offsets.front() != 0 ||
        snapshot.research_signal_evidence_offsets.back() !=
            static_cast<int32_t>(snapshot.research_signal_evidence.size())) {
        error = "country_pod_signal_evidence_csr_invalid";
        return false;
    }
    for (size_t i = 1; i < snapshot.research_signal_evidence_offsets.size(); ++i) {
        if (snapshot.research_signal_evidence_offsets[i] <
            snapshot.research_signal_evidence_offsets[i - 1u]) {
            error = "country_pod_signal_evidence_csr_invalid";
            return false;
        }
    }
    for (const auto &entry : snapshot.research_signal_evidence) {
        if (entry.signal < 0 || entry.signal >= static_cast<int32_t>(snapshot.research_signal_count) ||
            entry.count < 0 || entry.first_day > entry.last_day) {
            error = "country_pod_signal_evidence_invalid";
            return false;
        }
    }
    if (snapshot.territory_offsets.empty() || snapshot.territory_offsets.front() != 0) {
        error = "country_pod_territory_csr_invalid";
        return false;
    }
    for (size_t i = 1; i < snapshot.territory_offsets.size(); ++i) {
        if (snapshot.territory_offsets[i] < snapshot.territory_offsets[i - 1]) {
            error = "country_pod_territory_csr_invalid";
            return false;
        }
    }
    int32_t previous_active_slot = -1;
    for (const int32_t active_slot : snapshot.research_active_country_slots) {
        if (active_slot < 0 || active_slot >= static_cast<int32_t>(countries) ||
            active_slot <= previous_active_slot ||
            snapshot.country_active[static_cast<size_t>(active_slot)] == 0) {
            error = "country_pod_active_index_invalid";
            return false;
        }
        previous_active_slot = active_slot;
    }
    if (snapshot.research_weights_bp.size() != countries * RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT ||
        snapshot.research_queue_lengths.size() != countries * RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT) {
        error = "country_pod_research_shape_mismatch";
        return false;
    }
    for (size_t cell = 0; cell < cells; ++cell) {
        const int32_t owner = snapshot.cell_country_slot[cell];
        if (owner < -1 || owner >= static_cast<int32_t>(countries)) {
            error = "country_pod_invalid_cell_owner";
            return false;
        }
        if (!snapshot.is_water.empty() && snapshot.is_water[cell] != 0 && owner != -1) {
            error = "country_pod_water_owned";
            return false;
        }
    }
    std::vector<int32_t> territory_seen(cells, -1);
    for (size_t slot = 0; slot < countries; ++slot) {
        const int32_t begin = snapshot.territory_offsets[slot];
        const int32_t end = snapshot.territory_offsets[slot + 1u];
        if (begin < 0 || end < begin ||
            end > static_cast<int32_t>(snapshot.territory_cells.size())) {
            error = "country_pod_territory_csr_invalid";
            return false;
        }
        if (snapshot.country_active[slot] != 0 && end - begin == 0) {
            error = "country_pod_active_country_without_territory";
            return false;
        }
        if (snapshot.territory_count[slot] != end - begin) {
            error = "country_pod_territory_count_mismatch";
            return false;
        }
        for (int32_t cursor = begin; cursor < end; ++cursor) {
            const int32_t cell = snapshot.territory_cells[static_cast<size_t>(cursor)];
            if (cell < 0 || cell >= static_cast<int32_t>(cells) ||
                territory_seen[static_cast<size_t>(cell)] != -1 ||
                snapshot.cell_country_slot[static_cast<size_t>(cell)] !=
                    static_cast<int32_t>(slot) ||
                (!snapshot.is_water.empty() && snapshot.is_water[static_cast<size_t>(cell)] != 0)) {
                error = "country_pod_territory_csr_invalid";
                return false;
            }
            territory_seen[static_cast<size_t>(cell)] = static_cast<int32_t>(slot);
        }
    }
    for (size_t slot = 0; slot < countries; ++slot) {
        if (snapshot.country_active[slot] != 0 && snapshot.country_generation[slot] == 0) {
            error = "country_pod_invalid_country_generation";
            return false;
        }
        if (snapshot.territory_count[slot] < 0 || snapshot.country_cash[slot] < 0) {
            error = "country_pod_negative_country_state";
            return false;
        }
        if (snapshot.research_auto_purchase[slot] > 1 ||
            snapshot.research_deferred_points[slot] < 0 ||
            snapshot.research_progress_total[slot] < 0 ||
            snapshot.research_completed_total[slot] < 0 ||
            snapshot.research_purchased_total[slot] < 0 ||
            snapshot.research_consumed_total[slot] < 0) {
            error = "country_pod_negative_research_state";
            return false;
        }
        if (!(snapshot.research_cost_factor[slot] > 0.0) ||
            !std::isfinite(snapshot.research_cost_factor[slot])) {
            error = "country_pod_invalid_research_cost_factor";
            return false;
        }
        for (uint32_t domain = 0; domain < 4u; ++domain) {
            const double efficiency = snapshot.research_efficiency[
                slot * 4u + domain];
            if (!(efficiency > 0.0) || !std::isfinite(efficiency)) {
                error = "country_pod_invalid_research_efficiency";
                return false;
            }
        }
        for (uint32_t technology = 0;
             technology < snapshot.technology_count; ++technology) {
            const int64_t progress = snapshot.research_progress[
                slot * snapshot.technology_count + technology];
            if (progress < 0) {
                error = "country_pod_negative_research_progress";
                return false;
            }
        }
        for (uint32_t domain = 0; domain < RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT; ++domain) {
            const int32_t weight = snapshot.research_weights_bp[
                slot * RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT + domain];
            if (weight < 0 || weight > 10000) {
                error = "country_pod_invalid_research_weight";
                return false;
            }
        }
        const auto begin = snapshot.research_weights_bp.begin() +
            static_cast<ptrdiff_t>(slot * RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT);
        if (!runtime_country_research_weights_valid({begin[0], begin[1], begin[2], begin[3]})) {
            error = "country_pod_research_weight_sum";
            return false;
        }
    }
    for (size_t index = 0; index < snapshot.research_queue_lengths.size(); ++index) {
        if (snapshot.research_queue_lengths[index] > COUNTRY_QUEUE_SLOTS) {
            error = "country_pod_research_queue_length_invalid";
            return false;
        }
    }
    return true;
}

bool RuntimeCountryPodAuthority::validate_catalog(
        const RuntimeCountryPodCatalog &catalog, std::string &error) const {
    error.clear();
    if (catalog.catalog_hash == 0 ||
        catalog.technology_words == 0 ||
        catalog.technology_words !=
            (catalog.technology_count + 63u) / 64u) {
        error = "country_catalog_shape_invalid";
        return false;
    }
    if (catalog.political_regime_ids.size() !=
            catalog.political_regime_capability_bits.size()) {
        error = "country_catalog_political_regime_shape_invalid";
        return false;
    }
    const size_t count = catalog.technology_count;
    if (catalog.technology_count == 0 || catalog.technology_costs.size() != count ||
        catalog.technology_domains.size() != count ||
        catalog.technology_flags.size() != count ||
        catalog.technology_effect_required.size() != count ||
        catalog.prerequisite_offsets.size() != count + 1u ||
        catalog.entry_milestone_indices.size() != count) {
        error = "country_catalog_shape_invalid";
        return false;
    }
    if (catalog.prerequisite_offsets.front() != 0 ||
        catalog.prerequisite_offsets.back() !=
            static_cast<int32_t>(catalog.prerequisites.size())) {
        error = "country_catalog_prerequisite_csr_invalid";
        return false;
    }
    for (size_t i = 1; i < catalog.prerequisite_offsets.size(); ++i) {
        if (catalog.prerequisite_offsets[i] < catalog.prerequisite_offsets[i - 1]) {
            error = "country_catalog_prerequisite_csr_invalid";
            return false;
        }
    }
    for (int32_t technology : catalog.prerequisites) {
        if (technology < 0 || technology >= static_cast<int32_t>(count)) {
            error = "country_catalog_prerequisite_target_invalid";
            return false;
        }
    }
    if (!catalog.milestone_offsets.empty()) {
        if (catalog.milestone_offsets.size() != count + 1u ||
            catalog.milestone_offsets.front() != 0 ||
            catalog.milestone_offsets.back() !=
                static_cast<int32_t>(catalog.milestone_candidates.size()) ||
            catalog.milestone_required_counts.size() != count) {
            error = "country_catalog_milestone_csr_invalid";
            return false;
        }
        for (size_t i = 1; i < catalog.milestone_offsets.size(); ++i)
            if (catalog.milestone_offsets[i] < catalog.milestone_offsets[i - 1]) {
                error = "country_catalog_milestone_csr_invalid";
                return false;
            }
        for (int32_t technology : catalog.milestone_candidates)
            if (technology < 0 || technology >= static_cast<int32_t>(count)) {
                error = "country_catalog_milestone_target_invalid";
                return false;
            }
    }
    if (catalog.research_conditions_complete) {
        if (catalog.research_condition_offsets.size() != count + 1u ||
            catalog.research_condition_offsets.front() != 0 ||
            catalog.research_condition_offsets.back() !=
                static_cast<int32_t>(catalog.research_condition_ops.size()) ||
            catalog.research_condition_ops.size() !=
                catalog.research_condition_refs.size() ||
            catalog.research_condition_ops.size() !=
                catalog.research_condition_values.size()) {
            error = "country_catalog_research_condition_csr_invalid";
            return false;
        }
    }
    if (catalog.reveal_condition_offsets.size() != count + 1u ||
        catalog.reveal_condition_offsets.front() != 0 ||
        catalog.reveal_condition_offsets.back() !=
            static_cast<int32_t>(catalog.reveal_condition_ops.size()) ||
        catalog.reveal_condition_ops.size() !=
            catalog.reveal_condition_refs.size() ||
        catalog.reveal_condition_ops.size() !=
            catalog.reveal_condition_values.size()) {
        error = "country_catalog_reveal_condition_csr_invalid";
        return false;
    }
    for (size_t i = 1; i < catalog.reveal_condition_offsets.size(); ++i)
        if (catalog.reveal_condition_offsets[i] <
            catalog.reveal_condition_offsets[i - 1]) {
            error = "country_catalog_reveal_condition_csr_invalid";
            return false;
        }
    for (size_t i = 0; i < count; ++i) {
        // Production catalogs use zero cost for non-researchable/content
        // placeholder entries. The authoritative core already rejects such
        // entries when they are queued; capture validation must not reject a
        // complete catalog merely because it contains those slots.
        if (catalog.technology_costs[i] < 0 ||
            catalog.technology_domains[i] < 0 ||
            catalog.technology_domains[i] >=
                static_cast<int32_t>(RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT)) {
            error = "country_catalog_technology_value_invalid";
            return false;
        }
        if (catalog.technology_effect_required[i] > 1u) {
            error = "country_catalog_effect_requirement_invalid";
            return false;
        }
    }
    return true;
}

bool RuntimeCountryPodAuthority::validate_state(
        const RuntimeCountryPodSnapshot &snapshot, std::string &error) const {
    if (!RuntimeCountryPodAdapter::validate_snapshot(snapshot, error)) return false;
    if (snapshot.catalog_hash == 0 || snapshot.technology_count == 0 ||
        snapshot.generation == 0) {
        error = "country_pod_capture_contract_incomplete";
        return false;
    }
    if (snapshot.territory_offsets.size() !=
        static_cast<size_t>(snapshot.country_count) + 1u ||
        snapshot.territory_offsets.front() != 0 ||
        snapshot.territory_offsets.back() !=
            static_cast<int32_t>(snapshot.territory_cells.size())) {
        error = "country_pod_territory_csr_invalid";
        return false;
    }
    if (!_catalog.political_regime_ids.empty() &&
        !snapshot.country_political_regime_ids.empty()) {
        for (size_t slot = 0; slot < snapshot.country_count; ++slot) {
            const int32_t regime = snapshot.country_political_regime_ids[slot];
            if (regime < 0 || static_cast<size_t>(regime) >= _catalog.political_regime_ids.size() ||
                snapshot.country_political_regime_capabilities[slot] !=
                    _catalog.political_regime_capability_bits[static_cast<size_t>(regime)]) {
                error = "country_pod_political_regime_invalid";
                return false;
            }
        }
    }
    return true;
}


} // namespace pk
