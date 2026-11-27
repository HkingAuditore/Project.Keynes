#include "economy_runtime_family_founding_includes.inc"
#include "economy_runtime_binary_codec.h"

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
constexpr uint8_t kFoundingRecordSplitParent = 5;
constexpr uint32_t kFoundingMaxTraitsPerCard = 64;

} // namespace

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
        // Ordinary v55 offers retain their hash during explicit migration.
        if (offer.source_family_handle != 0) mix(offer.source_family_handle);
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
    for (const auto &row : _family_split_parents) {
        mix(static_cast<uint64_t>(row.first));
        mix(static_cast<uint64_t>(row.second));
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
    const int32_t lineages = static_cast<int32_t>(_family_split_parents.size());
    const int32_t total = 1 + milestones + offers + choices + effects + lineages;
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
            append_le<int32_t>(record, lineages);
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
            append_le<uint64_t>(record, offer.source_family_handle);
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
        } else if ((index -= choices) < effects) {
            const auto &row = _family_founding_effects[static_cast<size_t>(index)];
            append_le<uint8_t>(record, kFoundingRecordEffect);
            append_le<int64_t>(record, row.first);
            append_le<int32_t>(record, row.second);
        } else {
            const auto &row = _family_split_parents[static_cast<size_t>(index - effects)];
            append_le<uint8_t>(record, kFoundingRecordSplitParent);
            append_le<int64_t>(record, row.first);
            append_le<int64_t>(record, row.second);
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
        _family_split_parents.clear();
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
            int32_t milestones = 0, offers = 0, choices = 0, effects = 0, lineages = 0;
            if (!read_le(bytes, cursor, next_offer) ||
                !read_le(bytes, cursor, milestones) ||
                !read_le(bytes, cursor, offers) ||
                !read_le(bytes, cursor, choices) ||
                !read_le(bytes, cursor, effects) ||
                (_restore.schema_version >= 56 && !read_le(bytes, cursor, lineages)) || next_offer <= 0 ||
                milestones < 0 || milestones > _cell_count.get() || offers < 0 ||
                offers > _cell_count.get() || choices < 0 || choices > _cell_count.get() ||
                effects < 0 || effects > 10000000 || lineages < 0 || lineages > 10000000) {
                error = "save_family_founding_header_invalid";
                return false;
            }
            _next_family_founding_offer_id = next_offer;
            _restore.expected_family_founding_records =
                1 + milestones + offers + choices + effects + lineages;
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
                (_restore.schema_version >= 56 && !read_le(bytes, cursor, offer.source_family_handle)) ||
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
        } else if (kind == kFoundingRecordSplitParent && _restore.schema_version >= 56) {
            int64_t child = 0, parent = 0;
            if (!read_le(bytes, cursor, child) || !read_le(bytes, cursor, parent) ||
                child <= 0 || parent <= 0 || child == parent ||
                (!_family_split_parents.empty() && _family_split_parents.back().first >= child)) {
                error = "save_family_split_parent_invalid";
                return false;
            }
            _family_split_parents.push_back({child, parent});
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
        if (offer.source_family_handle != 0) {
            int32_t parent = -1;
            if (families_store().valid_handle(offer.source_family_handle, parent)) {
                for (const auto &candidate : offer.candidates) {
                    if (candidate.surname_id != families_store().surname_id[parent] ||
                        candidate.culture_group_id != families_store().culture_group_id[parent]) {
                        error = "restore_family_split_identity_invalid";
                        return false;
                    }
                }
            }
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
