#include "runtime_economy_family_store.h"

#include <cstring>

namespace pk {

namespace {
template <typename T>
bool read_pod(const uint8_t *&p, const uint8_t *end, T &value) {
    if (static_cast<size_t>(end - p) < sizeof(T)) return false;
    std::memcpy(&value, p, sizeof(T));
    p += sizeof(T);
    return true;
}
} // namespace

bool RuntimeEconomyFamilyStore::load_wire(
        const uint8_t *data, size_t size, uint32_t family_count,
        uint32_t membership_count, uint32_t ownership_count,
        uint32_t person_count, uint32_t person_need_count,
        uint32_t trait_count, uint32_t influence_count,
        uint32_t trait_command_count, uint32_t expedition_count) {
    clear();
    if (data == nullptr && size != 0) return false;
    const uint8_t *p = data;
    const uint8_t *end = data + size;

    family_slot.reserve(family_count);
    for (uint32_t i = 0; i < family_count; ++i) {
        int32_t v_i32 = 0;
        uint8_t v_u8 = 0;
        uint32_t v_u32 = 0;
        int64_t v_i64 = 0;
        uint16_t v_u16 = 0;
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        family_slot.push_back(v_i32);
        if (!read_pod(p, end, v_u8)) {
            clear();
            return false;
        }
        family_active.push_back(v_u8);
        if (!read_pod(p, end, v_u32)) {
            clear();
            return false;
        }
        family_generation.push_back(v_u32);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        family_stable_id.push_back(v_i64);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        family_surname_id.push_back(v_i32);
        if (!read_pod(p, end, v_u32)) {
            clear();
            return false;
        }
        family_surname_disambiguator.push_back(v_u32);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        family_founded_day.push_back(v_i64);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        family_home_cell.push_back(v_i32);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        family_origin_cell.push_back(v_i32);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        family_origin_ethnicity.push_back(v_i32);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        family_culture_group_id.push_back(v_i32);
        if (!read_pod(p, end, v_u32)) {
            clear();
            return false;
        }
        family_split_sequence.push_back(v_u32);
        if (!read_pod(p, end, v_u16)) {
            clear();
            return false;
        }
        family_decline_reviews.push_back(v_u16);
        if (!read_pod(p, end, v_u16)) {
            clear();
            return false;
        }
        family_flags.push_back(v_u16);
    }

    membership_family_handle.reserve(membership_count);
    for (uint32_t i = 0; i < membership_count; ++i) {
        uint64_t v_u64 = 0;
        int64_t v_i64 = 0;
        if (!read_pod(p, end, v_u64)) {
            clear();
            return false;
        }
        membership_family_handle.push_back(v_u64);
        if (!read_pod(p, end, v_u64)) {
            clear();
            return false;
        }
        membership_cohort_handle.push_back(v_u64);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        membership_people.push_back(v_i64);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        membership_cash_claim.push_back(v_i64);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        membership_population_basis.push_back(v_i64);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        membership_funds_basis.push_back(v_i64);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        membership_owner_employed.push_back(v_i64);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        membership_employee_employed.push_back(v_i64);
    }

    ownership_family_handle.reserve(ownership_count);
    for (uint32_t i = 0; i < ownership_count; ++i) {
        uint64_t v_u64 = 0;
        int64_t v_i64 = 0;
        if (!read_pod(p, end, v_u64)) {
            clear();
            return false;
        }
        ownership_family_handle.push_back(v_u64);
        if (!read_pod(p, end, v_u64)) {
            clear();
            return false;
        }
        ownership_building_handle.push_back(v_u64);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        ownership_owned_count.push_back(v_i64);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        ownership_filled_owner.push_back(v_i64);
    }

    person_slot.reserve(person_count);
    for (uint32_t i = 0; i < person_count; ++i) {
        int32_t v_i32 = 0;
        uint8_t v_u8 = 0;
        uint32_t v_u32 = 0;
        int64_t v_i64 = 0;
        uint64_t v_u64 = 0;
        uint16_t v_u16 = 0;
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        person_slot.push_back(v_i32);
        if (!read_pod(p, end, v_u8)) {
            clear();
            return false;
        }
        person_active.push_back(v_u8);
        if (!read_pod(p, end, v_u32)) {
            clear();
            return false;
        }
        person_generation.push_back(v_u32);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        person_stable_id.push_back(v_i64);
        if (!read_pod(p, end, v_u64)) {
            clear();
            return false;
        }
        person_family_handle.push_back(v_u64);
        if (!read_pod(p, end, v_u64)) {
            clear();
            return false;
        }
        person_cohort_handle.push_back(v_u64);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        person_given_name_id.push_back(v_i32);
        if (!read_pod(p, end, v_u32)) {
            clear();
            return false;
        }
        person_name_disambiguator.push_back(v_u32);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        person_notable_since_day.push_back(v_i64);
        if (!read_pod(p, end, v_u16)) {
            clear();
            return false;
        }
        person_flags.push_back(v_u16);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        person_cash_claim.push_back(v_i64);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        person_family_equity_share_q32.push_back(v_i64);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        person_epoch_job_income.push_back(v_i64);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        person_epoch_business_result.push_back(v_i64);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        person_epoch_consumption_expense.push_back(v_i64);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        person_epoch_tax.push_back(v_i64);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        person_income_ema.push_back(v_i64);
        if (!read_pod(p, end, v_u16)) {
            clear();
            return false;
        }
        person_needs_satisfaction.push_back(v_u16);
        if (!read_pod(p, end, v_u16)) {
            clear();
            return false;
        }
        person_worst_need_id.push_back(v_u16);
        if (!read_pod(p, end, v_u64)) {
            clear();
            return false;
        }
        person_building_handle.push_back(v_u64);
        if (!read_pod(p, end, v_u8)) {
            clear();
            return false;
        }
        person_job_kind.push_back(v_u8);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        person_employee_role_index.push_back(v_i32);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        person_job_since_day.push_back(v_i64);
    }

    need_person_handle.reserve(person_need_count);
    for (uint32_t i = 0; i < person_need_count; ++i) {
        uint64_t v_u64 = 0;
        int32_t v_i32 = 0;
        int64_t v_i64 = 0;
        uint16_t v_u16 = 0;
        if (!read_pod(p, end, v_u64)) {
            clear();
            return false;
        }
        need_person_handle.push_back(v_u64);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        need_stable_need_id.push_back(v_i32);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        need_desired_period_units.push_back(v_i64);
        if (!read_pod(p, end, v_u16)) {
            clear();
            return false;
        }
        need_satisfaction_q16.push_back(v_u16);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        need_attributed_spend.push_back(v_i64);
    }

    trait_family_handle.reserve(trait_count);
    for (uint32_t i = 0; i < trait_count; ++i) {
        uint64_t v_u64 = 0;
        int32_t v_i32 = 0;
        uint8_t v_u8 = 0;
        if (!read_pod(p, end, v_u64)) {
            clear();
            return false;
        }
        trait_family_handle.push_back(v_u64);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        trait_trait_id.push_back(v_i32);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        trait_strength_q16.push_back(v_i32);
        if (!read_pod(p, end, v_u8)) {
            clear();
            return false;
        }
        trait_core.push_back(v_u8);
    }

    influence_slot.reserve(influence_count);
    for (uint32_t i = 0; i < influence_count; ++i) {
        int32_t v_i32 = 0;
        uint8_t v_u8 = 0;
        uint32_t v_u32 = 0;
        uint64_t v_u64 = 0;
        int64_t v_i64 = 0;
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        influence_slot.push_back(v_i32);
        if (!read_pod(p, end, v_u8)) {
            clear();
            return false;
        }
        influence_active.push_back(v_u8);
        if (!read_pod(p, end, v_u32)) {
            clear();
            return false;
        }
        influence_generation.push_back(v_u32);
        if (!read_pod(p, end, v_u64)) {
            clear();
            return false;
        }
        influence_family_handle.push_back(v_u64);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        influence_cell.push_back(v_i32);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        influence_stable_id.push_back(v_i64);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        influence_population.push_back(v_i64);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        influence_cash.push_back(v_i64);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        influence_building_asset.push_back(v_i64);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        influence_population_share_q16.push_back(v_i32);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        influence_cash_share_q16.push_back(v_i32);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        influence_building_share_q16.push_back(v_i32);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        influence_score_q16.push_back(v_i32);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        influence_satisfaction_q16.push_back(v_i32);
        if (!read_pod(p, end, v_u8)) {
            clear();
            return false;
        }
        influence_prestige_level.push_back(v_u8);
        if (!read_pod(p, end, v_u8)) {
            clear();
            return false;
        }
        influence_pending_target_level.push_back(v_u8);
        if (!read_pod(p, end, v_u8)) {
            clear();
            return false;
        }
        influence_review_streak.push_back(v_u8);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        influence_last_review_day.push_back(v_i64);
    }

    command_operation.reserve(trait_command_count);
    for (uint32_t i = 0; i < trait_command_count; ++i) {
        int32_t v_i32 = 0;
        uint64_t v_u64 = 0;
        int64_t v_i64 = 0;
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        command_operation.push_back(v_i32);
        if (!read_pod(p, end, v_u64)) {
            clear();
            return false;
        }
        command_family_handle.push_back(v_u64);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        command_trait_id.push_back(v_i32);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        command_strength_q16.push_back(v_i32);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        command_effective_day.push_back(v_i64);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        command_priority.push_back(v_i32);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        command_sequence.push_back(v_i64);
        if (!read_pod(p, end, v_u64)) {
            clear();
            return false;
        }
        command_submit_order.push_back(v_u64);
    }

#include "runtime_economy_family_store_wire_expeditions.inc"

    if (p != end) {
        clear();
        return false;
    }
    return shape_valid(family_count, membership_count, ownership_count,
                       person_count, person_need_count, trait_count,
                       influence_count, trait_command_count, expedition_count);
}

} // namespace pk
