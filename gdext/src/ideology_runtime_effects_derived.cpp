#include "ideology_runtime.h"
#include "ideology_runtime_internal.h"
#include "ideology_runtime_common.inc"
#include <atomic>
#include <cstdio>
#include <cstdlib>


namespace pk {

using namespace godot;

void NativeIdeologyRuntime::publish_effect_input_consumers() {
    if (_economy_runtime == nullptr) return;
    rebuild_level_managed_if_needed();
    constexpr int32_t kEconomyMetricCount =
        EconomyApi::FAMILY_METRIC_COUNT;
    MetricMask mask;
    bool tags = false;
    bool tag_ids_incomplete = false;
    std::vector<int32_t> tag_ids;
    bool families = false;
    MetricMask exact;
    std::array<std::vector<int64_t>, EconomyApi::FAMILY_METRIC_COUNT>
        thresholds;
    for (const LevelManagedInfo &info : _level_managed) {
        if (info.has_managed == 0) continue;
        MetricMask economy_consumer_mask = info.consumer_mask;
        economy_consumer_mask &= MetricMask::all_declared(
            kEconomyMetricCount);
        mask |= economy_consumer_mask;
        if (info.uses_tags != 0) tags = true;
        if (info.tag_ids_incomplete != 0) tag_ids_incomplete = true;
        for (const int32_t tag_id : info.tag_ids) tag_ids.push_back(tag_id);
        if (info.uses_families != 0) families = true;
        exact |= info.exact_mask;
        for (int32_t t = 0; t < info.threshold_count; ++t) {
            const int32_t metric = info.threshold_ids[t];
            if (metric < 0 || metric >= static_cast<int32_t>(thresholds.size()))
                continue;
            thresholds[static_cast<size_t>(metric)].push_back(
                info.threshold_values[t]);
        }
    }
    // One sorted, deduplicated threshold set per metric: the digest asks "how
    // many are <= value", so order is the whole point and duplicates would
    // shift the count without meaning anything.
    for (auto &per_metric : thresholds) {
        if (per_metric.empty()) continue;
        std::sort(per_metric.begin(), per_metric.end());
        per_metric.erase(std::unique(per_metric.begin(), per_metric.end()),
                         per_metric.end());
    }
    // Exact metrics drop every boundary: an empty set means "compare raw values",
    // which is the only safe answer for a Ramp input or a truncated set.
    for (int32_t metric = 0;
            metric < static_cast<int32_t>(thresholds.size()); ++metric) {
        if (exact.test(metric)) thresholds[static_cast<size_t>(metric)].clear();
    }
    std::sort(tag_ids.begin(), tag_ids.end());
    tag_ids.erase(std::unique(tag_ids.begin(), tag_ids.end()), tag_ids.end());
    // Diagnostic: `consumed=0` at the economy means either "no publisher ran" or
    // "the publisher found no named tags". These three counters separate them.
    ++_consumer_publish_calls;
    _consumer_tag_ids_last = static_cast<int64_t>(tag_ids.size());
    _consumer_levels_with_tags = 0;
    for (const LevelManagedInfo &info : _level_managed) {
        if (info.uses_tags != 0) ++_consumer_levels_with_tags;
    }
    // An incomplete set must NOT be published as a narrow one: the economy would then
    // skip tags a synergy rewrite can still read. An empty set with `tags == true` is
    // the protocol's "all tags" signal.
    if (tag_ids_incomplete) tag_ids.clear();
    economy_api::set_effect_input_consumers(
        *_economy_runtime, mask, tags, families, thresholds, tag_ids);
}


void NativeIdeologyRuntime::collect_local_scalars(
        const CountryState &country,
        std::vector<std::pair<std::string, int64_t>> &out) const {
    out.clear();
    static constexpr const char *kEquippedKey =
        "ideology.scalar.equipped_count";
    static constexpr const char *kSynergyKey =
        "ideology.scalar.active_synergy_count";
    static constexpr const char *kEraKey =
        "ideology.scalar.unlocked_era";
    static constexpr const char *kRoutePrefix =
        "ideology.scalar.route_count.";
    // Equipped means ideology-location only; national spirits retain their
    // separate slot capacity and must not inflate this count.
    int32_t equipped = 0;
    std::array<int32_t, 32> routes{};
    for (const IdeaState &idea : country.ideas) {
        if (idea.location != IDEOLOGY || idea.ideology_id < 0 ||
                idea.ideology_id >= static_cast<int32_t>(_definitions.size()))
            continue;
        ++equipped;
        const uint32_t route_mask =
            _definitions[static_cast<size_t>(idea.ideology_id)].route_mask;
        for (int32_t route = 0; route < static_cast<int32_t>(_route_keys.size());
                ++route) {
            if ((route_mask & (uint32_t{1} << route)) != 0)
                ++routes[static_cast<size_t>(route)];
        }
    }
    out.emplace_back(kEquippedKey, static_cast<int64_t>(equipped) * Q16_ONE);
    for (int32_t route = 0; route < static_cast<int32_t>(_route_keys.size());
            ++route) {
        out.emplace_back(
            std::string(kRoutePrefix) + _route_keys[static_cast<size_t>(route)],
            static_cast<int64_t>(routes[static_cast<size_t>(route)]) * Q16_ONE);
    }
    int32_t active_synergies = 0;
    for (const uint64_t word : country.active_synergy_bits)
        active_synergies += popcount64(word);
    out.emplace_back(kSynergyKey,
        static_cast<int64_t>(active_synergies) * Q16_ONE);
    int32_t country_slot = -1;
    if (validate_country(country.handle, country_slot))
        out.emplace_back(kEraKey,
            static_cast<int64_t>(unlocked_era_for(country_slot)) * Q16_ONE);
}

void NativeIdeologyRuntime::fill_ideology_scalars(
        const CountryState &country, const IdeaState &state,
        std::vector<int64_t> &values) const {
    if (_effect_runtime == nullptr || values.empty()) return;
    // ONE computation, two consumers: this slab and the §18.5 save record. Keeping a
    // second copy of "how many cards are equipped" is how a basis drifts from the
    // thing it claims to describe.
    std::vector<std::pair<std::string, int64_t>> scalars;
    collect_local_scalars(country, scalars);
    for (const std::pair<std::string, int64_t> &entry : scalars) {
        const int32_t metric_id = _effect_runtime->metric_id_for_key(entry.first);
        if (metric_id >= 0 && metric_id < static_cast<int32_t>(values.size()))
            values[static_cast<size_t>(metric_id)] = entry.second;
    }
    // Silence the unused parameter without letting the compiler optimize the
    // call-site contract away: the instance is intentionally not part of the
    // country-wide scalar value.
    (void)state;
}

bool NativeIdeologyRuntime::build_local_scalar_basis(
        const CountryState &country, std::vector<LocalScalarValue> &out,
        std::vector<LocalScalarValue> *cross_domain_rows) const {
    out.clear();
    if (_effect_runtime == nullptr || country.handle == 0) return false;
    const int32_t metric_count = _effect_runtime->metric_count();
    if (metric_count <= 0) return false;
    std::vector<std::pair<std::string, int64_t>> scalars;
    collect_local_scalars(country, scalars);
    // EVERY value in this block is a function of (this payload's country row, the
    // catalogs) EXCEPT the era term, whose input is the Country domain's technology set
    // (`unlocked_era_for` -> `has_technology`). PKCN owns and restores that domain, not
    // PKID, so the era row cannot be used as evidence that THIS payload is corrupt:
    //   * a world that has not restored PKCN yet cannot answer at all, and
    //   * a world whose Country section legitimately reached a different era answers a
    //     DIFFERENT number (measured: capture 3, restore 0 in
    //     `ideology_save_worker_authority_test`, which restores PKEF+PKID only).
    // Either way a content comparison over that row would refuse a good save. The row is
    // still persisted, still shape-checked and still covered by the state hash, so a
    // corrupted era value is caught -- by the hash, which is the layer that can see it.
    if (cross_domain_rows != nullptr) {
        const int32_t era_metric = _effect_runtime->metric_id_for_key(
            "ideology.scalar.unlocked_era");
        if (era_metric >= 0 && era_metric < metric_count) {
            LocalScalarValue row;
            row.country_handle = country.handle;
            row.metric_id = era_metric;
            cross_domain_rows->push_back(row);
        }
    }
    for (const std::pair<std::string, int64_t> &entry : scalars) {
        const int32_t metric_id = _effect_runtime->metric_id_for_key(entry.first);
        // A key this catalog does not declare has no slot in the slab, so there is
        // nothing to record: a program's `READ_METRIC` cannot name it either. This is
        // also what makes the content check real -- a payload row for an id the
        // current catalog no longer produces survives into `restored` but never into
        // `rebuilt`, and the two vectors then differ.
        if (metric_id < 0 || metric_id >= metric_count) continue;
        bool replaced = false;
        for (LocalScalarValue &row : out) {
            if (row.metric_id != metric_id) continue;
            // Two keys on one id is a corrupt catalog. The slab's own rule is last
            // write wins, so the record follows the slab instead of inventing a third
            // answer -- and the reader's strictly-ascending rule still holds.
            row.value_q16 = entry.second;
            replaced = true;
            break;
        }
        if (replaced) continue;
        LocalScalarValue row;
        row.country_handle = country.handle;
        row.metric_id = metric_id;
        row.value_q16 = entry.second;
        out.push_back(row);
    }
    std::sort(out.begin(), out.end(),
        [](const LocalScalarValue &lhs, const LocalScalarValue &rhs) {
            return lhs.metric_id < rhs.metric_id;
        });
    return true;
}

void NativeIdeologyRuntime::rebuild_local_scalar_basis(
        const std::vector<CountryState> &countries,
        std::vector<LocalScalarValue> &out,
        std::vector<LocalScalarValue> *cross_domain_rows) const {
    out.clear();
    if (_effect_runtime == nullptr) return;
    std::vector<LocalScalarValue> rows;
    for (const CountryState &country : countries) {
        if (country.handle == 0) continue;
        if (!build_local_scalar_basis(country, rows, cross_domain_rows)) continue;
        out.insert(out.end(), rows.begin(), rows.end());
    }
    // Same ordering contract as the applied basis: strictly ascending (country,
    // metric), which rejects duplicates and an unsorted block on read and makes the
    // byte layout a function of the state rather than of iteration order.
    std::stable_sort(out.begin(), out.end(),
        [](const LocalScalarValue &lhs, const LocalScalarValue &rhs) {
            if (lhs.country_handle != rhs.country_handle)
                return lhs.country_handle < rhs.country_handle;
            return lhs.metric_id < rhs.metric_id;
        });
    out.erase(std::unique(out.begin(), out.end(),
        [](const LocalScalarValue &lhs, const LocalScalarValue &rhs) {
            return lhs.country_handle == rhs.country_handle &&
                lhs.metric_id == rhs.metric_id;
        }), out.end());
}

uint64_t NativeIdeologyRuntime::mix_local_scalar_basis(
        uint64_t hash, const std::vector<LocalScalarValue> &rows) {
    hash = mixv(hash, static_cast<uint64_t>(rows.size()));
    for (const LocalScalarValue &row : rows) {
        hash = mixv(hash, row.country_handle);
        hash = mixv(hash, row.metric_id);
        hash = mixv(hash, row.value_q16);
    }
    return hash;
}


void NativeIdeologyRuntime::rebuild_level_managed_if_needed() const {
    if (_level_managed_built) return;
    _level_managed_built = true;
    _level_managed.assign(_levels.size(), LevelManagedInfo{});
    if (_effect_runtime == nullptr) return;
    for (int32_t id = 0; id < static_cast<int32_t>(_definitions.size()); ++id) {
        const Definition &definition = _definitions[static_cast<size_t>(id)];
        for (int32_t level = 0; level < definition.level_count; ++level) {
            const int32_t index = definition.level_begin + level;
            if (index < 0 || index >= static_cast<int32_t>(_levels.size())) continue;
            const Level &row = _levels[static_cast<size_t>(index)];
            LevelManagedInfo info;
            std::vector<const EffectTemplate *> managed_rows;
            if (definition.copy_left_programs != 0) {
                // Conservative union: every possible left source the copier may
                // read. Legendary sources are excluded at every level. The
                // copier's own managed rows stay excluded.
                for (int32_t source_id = 0;
                        source_id < static_cast<int32_t>(_definitions.size());
                        ++source_id) {
                    if (source_id == id) continue;
                    const Definition &source_definition =
                        _definitions[static_cast<size_t>(source_id)];
                    if (source_definition.copyable == 0) continue;
                    for (int32_t source_level = 0;
                            source_level < source_definition.level_count;
                            ++source_level) {
                        const int32_t source_index =
                            source_definition.level_begin + source_level;
                        if (source_index < 0 ||
                                source_index >= static_cast<int32_t>(
                                    _levels.size()))
                            continue;
                        const Level &source_row =
                            _levels[static_cast<size_t>(source_index)];
                        for (int32_t offset = 0;
                                offset < source_row.persistent_count; ++offset)
                            managed_rows.push_back(&_persistent_templates[
                                static_cast<size_t>(
                                    source_row.persistent_begin + offset)]);
                    }
                }
            } else {
                managed_rows.reserve(
                    static_cast<size_t>(row.persistent_count));
                for (int32_t offset = 0;
                        offset < row.persistent_count; ++offset)
                    managed_rows.push_back(&_persistent_templates[
                        static_cast<size_t>(row.persistent_begin + offset)]);
            }
            for (const EffectTemplate *templ_ptr : managed_rows) {
                const EffectTemplate &templ = *templ_ptr;
                const std::string program = effect_program_key(templ.definition_key);
                if (program.empty()) continue;
                EffectRuntime::FamilyEffectMetadataPod metadata;
                if (!_effect_runtime->family_effect_metadata_pod(program, metadata))
                    continue; // Legacy Modifier row: nothing to reconcile.
                const EffectRuntime::FamilyEffectMetadataPod effective =
                    effective_selector_metadata(CountryState{}, program, metadata);
                info.has_managed = 1;
                info.program_mix = mixv(info.program_mix,
                    effect_program_hash(program));
                if (effective.target_domain == 2 || effective.target_domain == 5)
                    info.uses_economy_inputs = 1;
                if (effective.target_domain == 0) {
                    info.uses_economy_inputs = 1;
                    info.uses_families = 1;
                }
                if (metadata.metric_mask.is_any()) {
                    info.uses_economy_inputs = 1;
                    info.consumer_mask |= metadata.metric_mask;
                    info.exact_mask |= metadata.exact_metric_mask;
                    for (int32_t t = 0; t < metadata.metric_threshold_count; ++t) {
                        if (info.threshold_count >= 8) {
                            // Same reasoning as the pod cap: a dropped boundary
                            // must demote the metric to exact, not vanish.
                            info.exact_mask.set(metadata.metric_threshold_ids[t]);
                            break;
                        }
                        const int32_t slot = info.threshold_count++;
                        info.threshold_ids[slot] = metadata.metric_threshold_ids[t];
                        info.threshold_values[slot] =
                            metadata.metric_threshold_values[t];
                    }
                }
                info.scalar_mask |= metadata.scalar_mask;
                // Selector kinds 12..15 all read the epoch tag bitset: 12/13
                // filter targets by tag, 14/15 select source cells by tag.
                if (effective.target_selector_kind >= 12 &&
                        effective.target_selector_kind <= 16) {
                    info.uses_tags = 1;
                    // `target_selector_param[1]` is the 1-based tag id; 0 means "no
                    // tag filter" (already handled by the selector), so only a positive
                    // value names a tag.
                    const int32_t tag_param = effective.target_selector_param[1];
                    if (tag_param > 0)
                        info.tag_ids.push_back(tag_param - 1);
                }
                // A TAG/KIND rewrite can turn a non-tag program into a tag user,
                // and a TAG rewrite can add a tag to an existing tag program.
                // Declare the consumer conservatively once any override exists;
                // the economy's bitset is small and this avoids a stale digest.
                if (!_synergy_overrides.empty()) {
                    info.uses_tags = 1;
                    // A TAG/KIND rewrite can introduce a tag this level never named,
                    // but the overrides are ENUMERABLE -- `_synergy_tag_overrides` is
                    // keyed by tag index. Collecting them keeps the set exhaustive, so
                    // the economy can still narrow. Marking it "incomplete" instead
                    // discarded all 48 collected ids and fell back to all 296 tags
                    // (measured on B7: `tag_ids=48` at the publisher, `consumed=0` at
                    // the economy).
                    for (const auto &entry : _synergy_tag_overrides) {
                        if (entry.first >= 0)
                            info.tag_ids.push_back(entry.first);
                    }
                    for (const auto &entry : _synergy_program_overrides) {
                        for (const int32_t synergy_id : entry.second) {
                            // `_synergy_overrides` is a VECTOR indexed by synergy id,
                            // not a map.
                            if (synergy_id < 0 ||
                                    synergy_id >= static_cast<int32_t>(
                                        _synergy_overrides.size()))
                                continue;
                            const SynergyOverride &override_row =
                                _synergy_overrides[static_cast<size_t>(synergy_id)];
                            // BOTH ids matter: `match_tag_id` is the tag the selector
                            // reads, `tag_id` is the one the rewrite applies. Naming
                            // only the replacement would make the selector see a tag
                            // whose bits were never computed.
                            if (override_row.match_tag_id >= 0)
                                info.tag_ids.push_back(override_row.match_tag_id);
                            if (override_row.tag_id >= 0)
                                info.tag_ids.push_back(override_row.tag_id);
                        }
                    }
                }
            }
            _level_managed[static_cast<size_t>(index)] = info;
        }
    }
}

const NativeIdeologyRuntime::LevelManagedInfo *
NativeIdeologyRuntime::level_managed_info(
        int32_t ideology_id, int32_t level) const {
    if (ideology_id < 0 ||
            ideology_id >= static_cast<int32_t>(_definitions.size()))
        return nullptr;
    const Definition &definition = _definitions[static_cast<size_t>(ideology_id)];
    if (level < 0 || level >= definition.level_count) return nullptr;
    const int32_t index = definition.level_begin + level;
    if (index < 0 || index >= static_cast<int32_t>(_level_managed.size()))
        return nullptr;
    return &_level_managed[static_cast<size_t>(index)];
}

bool NativeIdeologyRuntime::level_is_managed(
        int32_t ideology_id, int32_t level) const {
    rebuild_level_managed_if_needed();
    const LevelManagedInfo *info = level_managed_info(ideology_id, level);
    return info != nullptr && info->has_managed != 0;
}

uint64_t NativeIdeologyRuntime::activation_signature_for_test(uint64_t handle,
        int32_t ideology_id) const {
    for (const CountryState &country : _countries) {
        if (country.handle != handle) continue;
        const auto found = country.idea_indices.find(ideology_id);
        if (found == country.idea_indices.end()) return 0;
        const size_t index = found->second;
        if (index >= country.ideas.size()) return 0;
        return compute_activation_signature(country, country.ideas[index]);
    }
    return 0;
}

uint64_t NativeIdeologyRuntime::compute_activation_signature(
        const CountryState &country, const IdeaState &state) const {
    rebuild_level_managed_if_needed();
    uint64_t hash = 1469598103934665603ULL;
    hash = mixv(hash, state.ideology_id);
    hash = mixv(hash, state.level);
    hash = mixv(hash, state.location);
    hash = mixv(hash, state.slot_index);
    hash = mixv(hash, state.generation);
    if (state.ideology_id >= 0 &&
            state.ideology_id < static_cast<int32_t>(_definitions.size())) {
        const Definition &definition =
            _definitions[static_cast<size_t>(state.ideology_id)];
        hash = mixv(hash, school_strength_scale_q16(
            country, definition.school_index));
    }
    if (state.ideology_id >= 0 &&
            state.ideology_id < static_cast<int32_t>(_definitions.size()) &&
            _definitions[static_cast<size_t>(
                state.ideology_id)].copy_left_programs != 0) {
        const IdeaState *source = nullptr;
        if (copy_source_state(country, state, source) && source != nullptr) {
            hash = mixv(hash, source->ideology_id);
            hash = mixv(hash, source->level);
            hash = mixv(hash, source->generation);
        } else {
            // Stable "no source" sentinel. 0 is not a valid ideology id.
            hash = mixv(hash, 0);
            hash = mixv(hash, -1);
            hash = mixv(hash, 0);
        }
        hash = mixv(hash,
            static_cast<int32_t>(state.level >= 2 ? 78643 : Q16_ONE));
    }
    const LevelManagedInfo *info =
        level_managed_info(state.ideology_id, state.level);
    if (info == nullptr) return hash;
    hash = mixv(hash, info->program_mix);
    // Ideology scalars are local state, not Economy revisions. Mix only the
    // values this card actually reads so equipping an unrelated card cannot
    // make every active card refresh.
    if (info->scalar_mask.is_any()) {
        std::vector<int64_t> scalars;
        const int32_t metric_count = _effect_runtime == nullptr
            ? 0 : _effect_runtime->metric_count();
        scalars.assign(static_cast<size_t>(metric_count), 0);
        fill_ideology_scalars(country, state, scalars);
        for (int32_t metric = 0; metric < metric_count; ++metric) {
            if (!info->scalar_mask.test(metric)) continue;
            hash = mixv(hash, scalars[static_cast<size_t>(metric)]);
        }
    }
    // X5: a synergy flip changes this card's magnitude without touching the
    // card. Hashing the active set is coarser than a per-program scale lookup
    // but costs a couple of words instead of a catalog scan, and over-triggering
    // here only costs one reconcile.
    if (!_synergy_overrides.empty()) {
        for (const uint64_t word : country.active_synergy_bits)
            hash = mixv(hash, word);
    }
    // Review §3: a card's signature mixes only the metrics it reads. Cards with
    // no metric mask keep the global revision, so nothing that used to refresh
    // stops refreshing -- the change can only narrow.
    if (_economy_runtime != nullptr) {
        // Three independent inputs, mixed only where this card actually reads
        // them (review §3). Anything the old global revision caught is still
        // caught: a cell card that reads neither metrics nor tags depends on
        // ownership, which is the territory revision.
        // ONE snapshot load for the whole signature. Reading it per metric meant a
        // card could mix metric A's new revision with metric B's old one -- the
        // exact torn read the snapshot exists to prevent -- and cost up to 68
        // atomic shared_ptr loads per card, which is lock-prefixed on MSVC.
        const std::shared_ptr<const EffectInputSnapshot> snapshot =
            economy_api::effect_input_snapshot(*_economy_runtime);
        if (snapshot != nullptr) {
            if (info->consumer_mask.is_any()) {
                // SUM, not max: the revisions are independent counters, so a max
                // hides every metric that is not the leading one. With A=5 and B
                // going 3->4, max stays 5 and a card reading both would never
                // refresh. Revisions only increase, so the sum always moves.
                uint64_t metric_revision = 0;
                constexpr int32_t kMetricCount =
                    static_cast<int32_t>(EconomyApi::FAMILY_METRIC_COUNT);
                for (int32_t metric = 0; metric < kMetricCount; ++metric) {
                    if (!info->consumer_mask.test(metric)) continue;
                    metric_revision +=
                        snapshot->metric_revision[static_cast<size_t>(metric)];
                }
                hash = mixv(hash, metric_revision);
            }
            if (info->uses_tags != 0)
                hash = mixv(hash, snapshot->tag_revision);
            if (info->uses_families != 0)
                hash = mixv(hash, snapshot->family_revision);
            if (info->uses_economy_inputs != 0)
                hash = mixv(hash, snapshot->territory_revision);
        }
    }
    return hash;
}


bool NativeIdeologyRuntime::step_effect_instance_refresh(
        int64_t day, int32_t country_budget) {
    if (_effect_runtime == nullptr && _effect_forwarder == nullptr) return false;
    rebuild_level_managed_if_needed();
    if (_level_managed.empty()) return false;
    if (!_instance_refresh_pending) {
        const uint64_t revision = _economy_runtime == nullptr
            ? _effect_input_revision_seen
            : economy_api::effect_input_revision(*_economy_runtime);
        if ((_economy_runtime == nullptr || revision == _effect_input_revision_seen) &&
                !_instance_refresh_dirty)
            return false;
        _instance_refresh_pending = true;
        // Adopt the target only at the START of a pass. Restarting on every new
        // revision would reset the cursor before it ever reaches the tail.
        _effect_input_revision_target = revision;
        _instance_refresh_country_cursor = 0;
        _instance_refresh_dirty = false;
    }
    const Clock::time_point started = Clock::now();
    int32_t budget = country_budget > 0
        ? country_budget : INSTANCE_REFRESH_COUNTRY_BUDGET;
    if (budget <= 0) budget = static_cast<int32_t>(_countries.size());
    int32_t visit_budget = INSTANCE_REFRESH_VISIT_BUDGET;
    while (_instance_refresh_country_cursor <
               static_cast<int32_t>(_countries.size()) && budget > 0) {
        if (visit_budget <= 0) break;
        CountryState &country = _countries[
            static_cast<size_t>(_instance_refresh_country_cursor)];
        --budget;
        ++_instance_refresh_country_cursor;
        if (country.handle == 0) continue;
        for (const int32_t row : country.active_state_indices) {
            if (row < 0 || row >= static_cast<int32_t>(country.ideas.size()))
                continue;
            IdeaState &state = country.ideas[static_cast<size_t>(row)];
            if (state.location == INACTIVE || state.level < 0) continue;
            // A card with an Effect transaction in flight is owned by the ACK
            // branch; touching it here would race the rollback.
            if (state.transition.active != 0) continue;
            if (!level_is_managed(state.ideology_id, state.level)) continue;
            const uint64_t signature = compute_activation_signature(country, state);
            if (signature == state.activation_signature) {
                ++_instance_refresh_skips;
                continue;
            }
            // The error must NOT be dropped. A rejected submit (invalid columns, a
            // refused row, `effect_runtime_unavailable`) leaves `effect_instances`
            // untouched and never stamps the signature, so the visit is counted,
            // NOTHING is created, and the card is retried only when the inputs move
            // again -- while the reason stayed invisible in `get_ideology_report()`,
            // the one place a caller looks. Stored in `_last_error` exactly as the
            // command path does, and counted, so "this card matched cells but
            // produced no instance" has a name instead of reading as "the card does
            // nothing".
            std::string reconcile_error;
            if (!reconcile_effect_activations(country, state, day, reconcile_error)) {
                _last_error = reconcile_error.empty()
                    ? std::string("ideology_effect_instance_refresh_failed")
                    : reconcile_error;
                ++_effect_reconcile_failures;
            }
            --visit_budget;
            ++_instance_refresh_visits;
        }
    }
    _instance_refresh_ms += elapsed_ms(started);
    if (_instance_refresh_country_cursor <
            static_cast<int32_t>(_countries.size()))
        return true;
    _effect_input_revision_seen = _effect_input_revision_target;
    _instance_refresh_pending = false;
    ++_instance_refresh_passes;
    if (_economy_runtime != nullptr) {
        const uint64_t now = economy_api::effect_input_revision(*_economy_runtime);
        if (now > _effect_input_revision_seen) {
            const uint64_t lag = now - _effect_input_revision_seen;
            if (lag > _instance_refresh_lag_revisions)
                _instance_refresh_lag_revisions = lag;
        }
    }
    return false;
}


void NativeIdeologyRuntime::reconcile_country_effect_activations(
        CountryState &country, int64_t day) {
    if (_effect_runtime == nullptr && _effect_forwarder == nullptr) return;
    // Every IdeaState in this country shares one Effect authority, so a flip is
    // detected once here and applied to all of them.
    //
    // Why the refs must be dropped on a flip: `state.effect_instances` records
    // what this runtime believes it wrote, and it wrote to whichever side held
    // EFFECT at the time. When the other side takes over, that memory is a lie
    // in two directions -- retires would target instances the new authority
    // never accepted, and "already present" would skip instances it never got.
    // Forgetting the set makes the next reconcile resubmit everything, which is
    // idempotent per (instance_id, generation).
    if (_effect_forwarder != nullptr) {
        const uint64_t epoch = _effect_forwarder->authority_epoch();
        if (_effect_authority_epoch == AUTHORITY_EPOCH_UNSET) {
            _effect_authority_epoch = epoch;
        } else if (epoch != _effect_authority_epoch) {
            _effect_authority_epoch = epoch;
            for (IdeaState &state : country.ideas)
                state.effect_instances.clear();
        }
    }
    for (IdeaState &state : country.ideas) {
        // Same rule as the refresh path: a reconcile that failed is the difference
        // between "this card has no instances" and "this card's instances were
        // refused", and only `_last_error` can say which.
        std::string reconcile_error;
        if (!reconcile_effect_activations(country, state, day, reconcile_error)) {
            _last_error = reconcile_error.empty()
                ? std::string("ideology_effect_reconcile_failed")
                : reconcile_error;
            ++_effect_reconcile_failures;
        }
    }
}


bool NativeIdeologyRuntime::emit_level_effects(CountryState &country, IdeaState &state,
        int32_t level, bool remove_persistent, bool include_on_enter, int64_t day,
        std::vector<EffectRuntime::ExternalEffectCommandPod> &commands,
        std::string &error) {
    if (level < 0 || state.ideology_id < 0 || state.ideology_id >= static_cast<int32_t>(_definitions.size())) return true;
    const Definition &definition = _definitions[static_cast<size_t>(state.ideology_id)];
    if (level >= definition.level_count) return true;
    const Level &row = _levels[static_cast<size_t>(definition.level_begin + level)];
    if (definition.copy_left_programs != 0) {
        std::vector<const EffectTemplate *> legacy_rows;
        collect_copied_legacy_templates(country, state, legacy_rows);
        for (const EffectTemplate *templ : legacy_rows) {
            if (!emit_templates(country.handle, state.ideology_id, level,
                    static_cast<int32_t>(templ - _persistent_templates.data()),
                    1, remove_persistent, day, 0, commands, error))
                return false;
        }
    } else if (!emit_templates(country.handle, state.ideology_id, level,
            row.persistent_begin, row.persistent_count, remove_persistent, day,
            0, commands, error)) {
        return false;
    }
    if (include_on_enter)
        return emit_templates(country.handle, state.ideology_id, level, row.on_enter_begin,
            row.on_enter_count, false, day, static_cast<uint64_t>(level + 1), commands, error);
    return true;
}


uint64_t NativeIdeologyRuntime::binding_id_for(uint64_t country_handle,
        int32_t ideology_id, uint8_t location) const {
    uint64_t hash = 1469598103934665603ULL;
    hash = mixv(hash, country_handle);
    hash = mixv(hash, ideology_id);
    hash = mixv(hash, location);
    hash = mixv(hash, uint64_t{0x4944454f42494e44ULL}); // IDEOBIND
    return hash & 0x7fffffffffffffffULL;
}

uint64_t NativeIdeologyRuntime::binding_signature_for(int32_t ideology_id,
        int32_t level) const {
    if (ideology_id < 0 || ideology_id >= static_cast<int32_t>(_definitions.size())) return 0;
    uint64_t hash = 1469598103934665603ULL;
    hash = mixv(hash, ideology_id);
    hash = mixv(hash, level);
    const Definition &definition = _definitions[static_cast<size_t>(ideology_id)];
    if (level < 0 || level >= definition.level_count) return hash;
    const Level &row = _levels[static_cast<size_t>(definition.level_begin + level)];
    for (int32_t i = 0; i < row.persistent_count; ++i) {
        const EffectTemplate &templ = _persistent_templates[
            static_cast<size_t>(row.persistent_begin + i)];
        hash = mixv(hash, templ.action); hash = mixv(hash, templ.domain);
        hash = mixv(hash, templ.opcode); hash = mixv(hash, templ.value_q16);
        hash = mixv(hash, templ.duration_days); hash = mixv(hash, templ.stacks);
        hash = mix(hash, templ.command_key.data(), templ.command_key.size());
        hash = mix(hash, templ.definition_key.data(), templ.definition_key.size());
        for (int64_t value : templ.payload) hash = mixv(hash, value);
    }
    return hash;
}

bool NativeIdeologyRuntime::sync_external_binding(uint64_t country_handle,
        IdeaState &state, std::string &error) {
    if (_effect_runtime == nullptr) { error = "ideology_effect_runtime_unavailable"; return false; }
    if (state.location == INACTIVE) return true;
    const uint64_t signature = binding_signature_for(state.ideology_id, state.level);
    const int64_t binding_id = static_cast<int64_t>(binding_id_for(country_handle,
        state.ideology_id, state.location));
    if (!_effect_runtime->upsert_external_binding_pod(binding_id, state.generation,
            0x4944454f, state.ideology_id, country_handle,
            static_cast<uint32_t>(country_handle >> 32U), state.level,
            state.location, signature, _effect_runtime->catalog_hash(), error))
        return false;
    state.binding_id = binding_id;
    state.binding_generation = state.generation;
    state.binding_signature = signature;
    state.binding_program_hash = _effect_runtime->catalog_hash();
    return true;
}
const std::string *NativeIdeologyRuntime::intern_program_key(
        const std::string &key) const {
    const auto found = _program_key_pool.find(key);
    if (found != _program_key_pool.end()) return &*found;
    return &*_program_key_pool.insert(key).first;
}



} // namespace pk
