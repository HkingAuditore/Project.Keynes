#include "ideology_runtime.h"
#include "ideology_runtime_internal.h"
#include "ideology_runtime_common.inc"
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
            std::string ignored;
            reconcile_effect_activations(country, state, day, ignored);
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
        std::string ignored;
        reconcile_effect_activations(country, state, day, ignored);
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


void NativeIdeologyRuntime::ensure_derived_program_sampler() {
    if (_derived_program_sampler) return;
    _derived_program_metric_scratch.assign(
        static_cast<size_t>(EconomyApi::FAMILY_METRIC_COUNT), 0);
    _derived_program_sampler = [this](const std::string &program_key, int32_t cell,
                                      uint64_t source_country) -> double {
        (void)source_country;   // the program reads cell metrics; scope is the cell
        if (_economy_runtime == nullptr || _effect_runtime == nullptr) return 0.0;
        // Every declared metric, not a narrowed mask: the program's own READ_METRIC
        // decides what it needs, and a mask here would be a second, drifting copy of
        // that knowledge.
        const int32_t count =
            static_cast<int32_t>(_derived_program_metric_scratch.size());
        const pk::MetricMask all = pk::MetricMask::all_declared(count);
        economy_api::sample_effect_metrics(*_economy_runtime, cell, count,
            _derived_program_metric_scratch.data(), all);
        int64_t magnitude = 0;
        std::string error;
        if (!_effect_runtime->evaluate_program_magnitude_for_metrics(
                program_key, _derived_program_metric_scratch.data(), count,
                magnitude, error)) {
            // Counted, never silently zeroed: a muted effect and an effect evaluated to
            // zero look identical in the output, and only the counter separates them.
            ++_derived_program_failures;
            return 0.0;
        }
        ++_derived_program_evaluations;
        return static_cast<double>(magnitude) / static_cast<double>(Q16_ONE);
    };
}

void NativeIdeologyRuntime::ensure_derived_ramp_sampler() {
    if (!_derived_ramp_sampler) {
        _derived_ramp_metric_scratch.resize(
            static_cast<size_t>(EconomyApi::FAMILY_METRIC_COUNT), 0);
        // Captures MEMBERS, not locals: the job outlives this call.
        _derived_ramp_sampler = [this](int32_t metric_id, int32_t cell,
                                       uint64_t source_country) -> double {
            const bool country_scope =
                (metric_id >= 56 && metric_id <= 61) ||
                (metric_id >= 63 && metric_id <= 69) || metric_id == 91;
            if (country_scope) {
                static_assert(EconomyApi::FAMILY_METRIC_COUNT <= 256,
                    "ramp country-metric cache key packs metric_id into 8 bits");
                const uint64_t key = (source_country << 8U) ^
                    static_cast<uint64_t>(metric_id);
                const auto found = _derived_ramp_country_cache.find(key);
                if (found != _derived_ramp_country_cache.end()) {
                    ++_derived_ramp_samples_memoised;
                    return found->second;
                }
            }
            economy_api::sample_effect_metrics(*_economy_runtime, cell,
                static_cast<int32_t>(_derived_ramp_metric_scratch.size()),
                _derived_ramp_metric_scratch.data());
            ++_derived_ramp_samples_taken;
            const double sample = metric_id >= 0 &&
                    metric_id < static_cast<int32_t>(_derived_ramp_metric_scratch.size())
                ? static_cast<double>(
                      _derived_ramp_metric_scratch[static_cast<size_t>(metric_id)])
                : 0.0;
            if (country_scope) {
                const uint64_t key = (source_country << 8U) ^
                    static_cast<uint64_t>(metric_id);
                _derived_ramp_country_cache[key] = sample;
            }
            return sample;
        };
    }
}

bool NativeIdeologyRuntime::step_derived_rebuild(int64_t day,
                                               std::string &error) {
    error.clear();
    if (!_configured || _modifier_runtime == nullptr || _effect_runtime == nullptr)
        return true;
    // Counted HERE, not in the deleted `rebuild_derived_cell_layer`.
    //
    // When the old one-shot rebuild was removed its `++_cell_layer_rebuild_visits`
    // went with it while the export stayed, so the counter was permanently 0 and
    // `ideology_cell_layer_e2e_test` failed on a truthful-looking message
    // ("0 means run_daily never reached the hook") that was actually my oversight.
    ++_cell_layer_rebuild_visits;

    if (day != _derived_rebuild_day) {
        // A new day invalidates any half-built job: the epoch's inputs differ, so
        // splicing two days together would be wrong.
        _derived_rebuild_day = day;
        _derived_rebuild_slices = 0;
        _derived_rebuild_total_ms = 0.0;
        _cell_layer_rebuild_ms = 0.0;
        _derived_materialise_ms = 0.0;
        // Reset with the two above, not left to accumulate. `_derived_collect_ms` is a
        // MAX, so an un-reset member reports the worst collect of the WHOLE RUN while
        // `cell_layer_rebuild_ms` / `cell_layer_materialise_ms` describe the LAST day --
        // three numbers that cannot be compared with each other (measured: an un-reset
        // collect read 1.377 ms at 6400 against a per-day 0.69 ms, and the difference
        // looked like a regression that was not there).
        _derived_collect_ms = 0.0;
        _derived_rebuild_contributions.clear();
    _collect_pod_fail_keys.clear();
    _collect_pod_ok_keys.clear();
        _derived_rebuild_collected = false;
        _derived_rebuild_job.reset();
    }

    // ── plan §9.3: do not adopt a projection before its eligibility day ────
    //
    // Placed AFTER the day-reset above, deliberately. An earlier version sat before it,
    // so a refused rebuild left `_derived_rebuild_day` pointing at the confirmation day;
    // `derived_rebuild_pending()` then stayed true and `drain_derived_cell_layer` burned
    // its whole 4096-step budget and reported `complete=false` (measured). Clearing the
    // job first makes "refused" indistinguishable from "nothing to do", which is what a
    // caller should see.
    if (_derived_basis_eligible_day >= 0 && day < _derived_basis_eligible_day) {
        ++_derived_rebuild_gated_by_eligibility;
        // Clear the day marker as well. `derived_rebuild_pending()` is
        // `_derived_rebuild_day >= 0`, and the reset block above has just set it to
        // `day`, so leaving it set made a REFUSED rebuild look like an in-flight one:
        // `drain_derived_cell_layer` then looped its entire 4096-step budget and
        // reported `complete=false` (measured in B12's continuous branch). Clearing it
        // is what makes "refused" indistinguishable from "nothing to do", which is what
        // a caller should see.
        _derived_rebuild_day = -1;
        return true;
    }

    const Clock::time_point started = Clock::now();

    if (!_derived_rebuild_collected) {
        // Collect only after the day's own active progress finished. Collecting
        // earlier reads a half-advanced world: `run_daily_slices` walks
        // `_active_country_cursor` across slices, so a second country's card may not
        // be ACTIVE yet. That is exactly what produced `collect_count = 3200`
        // against 6400 in M4-18.
        if (_active_progress_day == day) return false;
        _derived_rebuild_contributions.clear();
        for (const CountryState &country : _countries) {
            if (country.handle == 0) continue;
            for (const IdeaState &state : country.ideas) {
                if (state.location == INACTIVE || state.level < 0) continue;
                std::vector<EffectActivation> throwaway;
                collect_effect_activations(country, state, throwaway,
                    &_derived_rebuild_contributions);
            }
        }
        _derived_rebuild_collected = true;
        // Plan §18.2: record the basis this projection is being built from. Done HERE,
        // at the collect step, because the collect loop above already resolved exactly
        // these programs -- and because collection honours a pending transition's OLD
        // level (§10.1), so the rows describe the basis in force, not the one that is
        // still waiting for its ACK. Diagnostics only: a capture re-derives its own rows.
        rebuild_applied_program_basis(_countries, _applied_program_basis);
        // Collection is a STEP of its own. At 6400 cells it costs 0.68 ms, and folding
        // in the same call pushed the first step to 1.03 ms -- over the 1 ms gate even
        // though the fold itself was budgeted. Returning here keeps each step's work
        // bounded by ONE kind of cost.
        // The collect's own cost, and ONLY its own. This assignment is what makes
        // `cell_layer_collect_ms` a measurement instead of a constant: the field was
        // declared and exported but never written, so the report said 0.0 on every run
        // and the perf table quoted that zero as if it were data (found 2026-10-29).
        _derived_collect_ms = std::max(_derived_collect_ms, elapsed_ms(started));
        _cell_layer_rebuild_ms = std::max(_cell_layer_rebuild_ms,
                                          elapsed_ms(started));
        // `_derived_materialise_ms` is deliberately NOT set here. It used to be assigned
        // the same collect duration, which made a "materialise" number that contained no
        // materialisation; it is the fold's cost and is set in the fold branch only.
        _derived_rebuild_steps = ++_derived_rebuild_slices;
        // Ramp terms must be EVALUATED, not deferred. Passing an empty options struct
        // here silently turned every ramp program into "no contribution" on the
        // sharded path while the single-shot path still evaluated them.
        DerivedMaterializeOptions job_options;
        _derived_ramp_country_cache.clear();
        _derived_ramp_samples_taken = 0;
        _derived_ramp_samples_memoised = 0;
        if (_economy_runtime != nullptr) {
            ensure_derived_ramp_sampler();
            job_options.ramp_sampler = &_derived_ramp_sampler;
            // Preferred over the metric sampler for every ramp term that names a
            // program (which is all of them, since the collector fills `program_key`).
            if (_effect_runtime != nullptr) {
                ensure_derived_program_sampler();
                job_options.program_magnitude_sampler = &_derived_program_sampler;
            }
        }
        _derived_rebuild_job.reset(new DerivedCellMaterializeJob(
            _derived_world_identity, _derived_map_generation, day,
            _derived_epoch_id, compute_execution_contract_hash(), job_options));
        return false;   // fold happens in later steps
    }

    ++_derived_rebuild_slices;
    if (_derived_rebuild_job == nullptr) return true;
    const bool folded = _derived_rebuild_job->fold_step(
        _derived_rebuild_contributions, DERIVED_REBUILD_STEP_BUDGET_MS);
    const double step_ms = elapsed_ms(started);
    _cell_layer_rebuild_ms = std::max(_cell_layer_rebuild_ms, step_ms);
    _derived_materialise_ms = std::max(_derived_materialise_ms, step_ms);
    _derived_rebuild_steps = _derived_rebuild_slices;
    _derived_rebuild_total_ms += step_ms;

    if (!folded) return false;   // more steps needed; nothing installed yet

    DerivedCellFront front;
    DerivedMaterializeReport report;
    bool skipped = false;
    const DerivedCellFront *previous = modifier_api::derived_cell_front(*_modifier_runtime);
    if (!_derived_rebuild_job->finish(previous, front, report, skipped)) {
        error = "derived_cell_layer_finish_failed";
        return true;
    }
    _last_derived_materialize = report;
    // PEAK MEMORY (§18.3): the only point where the RETAINED front (still serving
    // readers) and the CANDIDATE front (just built, not yet installed) both exist.
    // `previous` is null on the very first build -- a real case, reported as retained 0.
    {
        const int64_t retained_bytes =
            previous != nullptr ? pk::derived_cell_front_bytes(*previous) : 0;
        const int64_t candidate_bytes = pk::derived_cell_front_bytes(front);
        _derived_peak_retained_bytes =
            std::max(_derived_peak_retained_bytes, retained_bytes);
        _derived_peak_candidate_bytes =
            std::max(_derived_peak_candidate_bytes, candidate_bytes);
        _derived_peak_total_bytes = std::max(
            _derived_peak_total_bytes, retained_bytes + candidate_bytes);
    }
    // Export the JOB's ramp counters.
    //
    // These were only ever assigned on the (now dead) single-shot path, so a fixture
    // reading `ramp_terms_evaluated` saw a stale 0 no matter what the job did -- which
    // made "the ramp path works" unprovable and "the ramp path is broken" equally
    // unfalsifiable.
    _ramp_terms_evaluated = report.ramp_terms_evaluated;
    _ramp_terms_deferred = report.ramp_terms_deferred;
    bool installed = true;
    if (!skipped) {
        bool install_skipped = false;
        installed = modifier_api::install_derived_cell_layer(*_modifier_runtime,
            std::move(front), 0, install_skipped, error);
        // §18.5: the sample day of the projection that is now serving readers. Read
        // back from the INSTALLED front rather than from the job argument, because
        // those are not the same thing: an idempotent install is skipped (§I13), an
        // install can be refused (`derived_cell_layer_identity_mismatch`), and a build
        // in flight is not a projection yet. Reading it back makes this member equal to
        // `derived_cell_front()->sample_day` by construction instead of by assumption.
        const DerivedCellFront *serving = modifier_api::derived_cell_front(*_modifier_runtime);
        _derived_basis_sample_day = serving != nullptr ? serving->sample_day : -1;
    }
    if (installed) {
        // A refused install keeps the previous attribution, which still matches the
        // front that is serving.
        _derived_installed_contributions.swap(_derived_rebuild_contributions);
        const DerivedCellFront *serving = modifier_api::derived_cell_front(*_modifier_runtime);
        _derived_installed_generation = serving != nullptr ? serving->generation : 0;
    }
    _derived_rebuild_contributions.clear();
    // ── the step does not END until the front is built and installed ────────────
    //
    // `step_ms` above is taken BEFORE `finish()` and `install_derived_cell_layer()`, so
    // `cell_layer_rebuild_ms` used to publish a number that excluded the most expensive
    // part of the tail: measured at 12800 rows, the front build alone was 0.93 ms, so a
    // slice that really took 1.32 ms reported itself as 0.69 ms. That is a green number
    // quoting a subset of the work (found 2026-10-29 against the 5-run per-call trace).
    //
    // The max now covers the WHOLE step. `_derived_materialise_ms` stays fold-only, so
    // the two reported numbers still answer different questions: "what did the fold
    // cost" versus "what did one slice of this stage cost".
    {
        const double whole_step_ms = elapsed_ms(started);
        _cell_layer_rebuild_ms = std::max(_cell_layer_rebuild_ms, whole_step_ms);
        // The tail (build + install + release) is part of the same day's total. The
        // fold's part was already added above, so only the delta is added here.
        _derived_rebuild_total_ms += whole_step_ms - step_ms;
    }
    _derived_rebuild_day = -1;
    _derived_rebuild_collected = false;
    _derived_rebuild_job.reset();
    return true;
}

} // namespace pk
