void NativeEconomyRuntime::reconcile_family_branch_effects(
        uint64_t branch_handle, bool submit_changes) {
    int32_t branch = -1, family = -1;
    if (!family_influences().valid_handle(branch_handle, branch) ||
        !families_store().valid_handle(family_influences().family_handle[branch], family))
        return;
    const int32_t level = family_influences().prestige_level[branch];
    const uint64_t branch_stable_id = static_cast<uint64_t>(
        family_influences().stable_id[branch]);
    const uint32_t branch_generation = static_cast<uint32_t>(branch_handle >> 32U);
    auto stable_effect_instance_id = [&](const std::string &definition_key) {
        uint64_t identity = trace_hash_mix(1469598103934665603ULL,
            branch_stable_id);
        identity = trace_hash_mix(identity, static_cast<uint32_t>(
            family_influences().cell[branch]));
        uint64_t definition_hash = 1469598103934665603ULL;
        for (unsigned char ch : definition_key)
            definition_hash = trace_hash_mix(definition_hash, ch);
        identity = trace_hash_mix(identity, definition_hash);
        return static_cast<int64_t>(identity & 0x7fffffffffffffffULL);
    };
    // The other identity shape in this file. The founding random-pool grant
    // (grant_family_effect_to_branches) and the trait path above mix the target
    // cell in, because a neighbour-targeted effect owns one instance per target.
    // grant_ancestral_precept_for_country does not, so a (branch, key) pair can
    // legitimately exist under either shape.
    auto shaped_effect_instance_id = [&](const std::string &definition_key,
                                         int32_t target_cell) {
        uint64_t identity = trace_hash_mix(1469598103934665603ULL,
            branch_stable_id);
        identity = trace_hash_mix(identity, static_cast<uint32_t>(
            family_influences().cell[branch]));
        identity = trace_hash_mix(identity, static_cast<uint32_t>(
            std::max(0, target_cell)));
        uint64_t definition_hash = 1469598103934665603ULL;
        for (unsigned char ch : definition_key)
            definition_hash = trace_hash_mix(definition_hash, ch);
        identity = trace_hash_mix(identity, definition_hash);
        return static_cast<int64_t>(identity & 0x7fffffffffffffffLL);
    };
    // Restore rebuild asks "is this instance still alive", and that question has
    // to go to whichever side owns EFFECT. EffectRuntime::has_instance_pod only
    // answers for the legacy authority: under EFFECT worker authority the main
    // thread is a writeback mirror, so every worker-owned instance read as absent
    // and the binding was dropped -- which then also leaked the instance, because
    // clear_family_branch_effects retires by binding.
    auto instance_alive = [&](int64_t instance_id) {
        bool exists = false;
        if (!effect_pod_instance_exists(_effect_runtime, _effect_forwarder,
                instance_id, branch_generation, exists))
            return false;
        return exists;
    };
    auto resolve_effect_target = [&](const std::string &definition_key,
                                     uint64_t &target_handle,
                                     uint32_t &target_generation,
                                     EffectRuntime::FamilyEffectMetadataPod &metadata)
                                     -> bool {
        if (_effect_runtime == nullptr ||
            !_effect_runtime->family_effect_metadata_pod(
                definition_key, metadata))
            return false;
        const int32_t cell = family_influences().cell[branch];
        auto source_country = [&]() -> bool {
            if (_country_runtime == nullptr) return false;
            target_handle = static_cast<uint64_t>(
                country_reads().country_handle_for_cell(cell));
            if (target_handle == 0) return false;
            target_generation = static_cast<uint32_t>(target_handle >> 32U);
            return target_generation != 0;
        };
        if (metadata.target_selector_kind == 1) { // SOURCE_BRANCH.
            if (metadata.target_domain != 1) return false;
            target_handle = branch_handle;
            target_generation = branch_generation;
            // Every other branch of this resolver rejects a zero generation; so
            // must this one. A domain-1 (Branch) row with generation 0 passes
            // the forwarder and is then rejected by the pod's own identity
            // check, which surfaces as a family effect that silently never
            // exists instead of a resolver that declined the target.
            return target_generation != 0;
        }
        if (metadata.target_selector_kind == 2) { // SOURCE_CELL.
            if (metadata.target_domain != 2 && metadata.target_domain != 4 &&
                metadata.target_domain != 5) return false;
            if (cell < 0 || cell >= _cell_count.get()) return false;
            target_handle = static_cast<uint64_t>(cell);
            target_generation = 1;
            return true;
        }
        if (metadata.target_selector_kind == 3) { // SOURCE_COUNTRY.
            return metadata.target_domain == 3 && source_country();
        }
        if (metadata.target_selector_kind == 4) { // STATIC_HANDLE.
            const char *begin = metadata.target_selector_id.data();
            const char *end = begin + metadata.target_selector_id.size();
            uint64_t parsed = 0;
            const auto result = std::from_chars(begin, end, parsed);
            if (result.ec != std::errc{} || result.ptr != end || parsed == 0)
                return false;
            target_handle = parsed;
            target_generation = metadata.target_domain == 2 ||
                    metadata.target_domain == 4 || metadata.target_domain == 5
                ? 1 : static_cast<uint32_t>(parsed >> 32U);
            return target_generation != 0;
        }
        if (metadata.target_selector_kind == 5) { // SELECTOR_ID.
            if (metadata.target_domain != 5 || cell < 0 || cell >= _cell_count.get())
                return false;
            const std::string &selector = metadata.target_selector_id;
            const bool known = std::binary_search(_building_type_ids.begin(),
                    _building_type_ids.end(), selector) ||
                std::binary_search(_resource_ids.begin(), _resource_ids.end(),
                                   selector) ||
                std::binary_search(_good_ids.begin(), _good_ids.end(), selector);
            if (!known) return false;
            target_handle = static_cast<uint64_t>(cell);
            target_generation = 1;
            return true;
        }
        switch (metadata.target_domain) {
            case 0: // Family.
                target_handle = family_influences().family_handle[branch];
                target_generation = static_cast<uint32_t>(target_handle >> 32U);
                break;
            case 1: // Branch.
                target_handle = branch_handle;
                target_generation = branch_generation;
                break;
            case 2: // Settlement cell.
            case 4: // Climate cell.
            case 5: // Building/resource selector is evaluated within the cell.
                if (cell < 0 || cell >= _cell_count.get()) return false;
                target_handle = static_cast<uint64_t>(cell);
                target_generation = 1;
                break;
            case 3: // Country owning the source branch cell.
                return source_country();
            default:
                return false;
        }
        return target_generation != 0;
    };
    auto submit_effect_instance = [&](const std::string &definition_key,
                                      int32_t magnitude_q16) -> bool {
        if (_effect_runtime == nullptr || !submit_changes) return false;
        const uint64_t stable_id = static_cast<uint64_t>(
            family_influences().stable_id[branch]);
        uint64_t identity = trace_hash_mix(1469598103934665603ULL, stable_id);
        identity = trace_hash_mix(identity, static_cast<uint32_t>(
            family_influences().cell[branch]));
        uint64_t definition_hash = 1469598103934665603ULL;
        for (unsigned char ch : definition_key)
            definition_hash = trace_hash_mix(definition_hash, ch);
        identity = trace_hash_mix(identity, definition_hash);
        const int64_t instance_id = static_cast<int64_t>(identity &
            0x7fffffffffffffffULL);
        const uint32_t generation = static_cast<uint32_t>(branch_handle >> 32U);
        std::string error;
        if (!effect_pod_upsert(_effect_runtime, _effect_forwarder, instance_id,
                std::string("family.modifier.") + definition_key, generation,
                0x46414d494c59, static_cast<int64_t>(stable_id), branch_handle,
                stable_id,
                static_cast<uint32_t>(family_influences().cell[branch]), 0,
                _current_day.get(), -1, true, error))
            return false;
        if (!effect_pod_metric(_effect_runtime, _effect_forwarder, instance_id,
                generation, 0, family_effect_metric_revision(1), magnitude_q16,
                error))
            return false;
        return true;
    };
    std::map<std::string, int32_t> desired;
    std::map<std::string, int32_t> desired_effects;
    std::map<std::string, int32_t> desired_triggers;
    const uint64_t family_handle = family_influences().family_handle[branch];
    const auto trait_begin = std::lower_bound(family_trait_rolls().begin(),
        family_trait_rolls().end(), family_handle,
        [](const FamilyTraitRoll &roll, uint64_t handle) {
            return roll.family_handle < handle;
        });
    const auto trait_end = std::upper_bound(trait_begin, family_trait_rolls().end(),
        family_handle, [](uint64_t handle, const FamilyTraitRoll &roll) {
            return handle < roll.family_handle;
        });
    for (auto trait_it = trait_begin; trait_it != trait_end; ++trait_it) {
        const FamilyTraitRoll &roll = *trait_it;
        if (roll.trait_id < 0 || roll.trait_id >= static_cast<int32_t>(
                _family_trait_modifier_offsets.size()) - 1) continue;
        for (int32_t edge = _family_trait_modifier_offsets[roll.trait_id];
             edge < _family_trait_modifier_offsets[roll.trait_id + 1]; ++edge) {
            if (_family_trait_modifier_targets[edge] != 0) continue;
            const int32_t tier_magnitude =
                _family_trait_modifier_tier_magnitudes_q16[edge * 6 + level];
            const int64_t scaled = static_cast<int64_t>(tier_magnitude) *
                roll.strength_q16 / Q16_ONE;
            int32_t &value = desired[
                _family_trait_modifier_definition_keys[edge]];
            value = std::clamp<int64_t>(static_cast<int64_t>(value) + scaled,
                                        0, 4 * Q16_ONE);
        }
        if (roll.trait_id < static_cast<int32_t>(
                _family_trait_effect_offsets.size()) - 1) {
            for (int32_t edge = _family_trait_effect_offsets[roll.trait_id];
                 edge < _family_trait_effect_offsets[roll.trait_id + 1]; ++edge) {
                const std::string &key = _family_trait_effect_keys[edge];
                int32_t tier = Q16_ONE;
                const int32_t effect_id = family_effect_id_for_key(key);
                if (effect_id >= 0)
                    tier = family_effect_prestige_magnitude_q16(effect_id, level);
                else {
                    EffectRuntime::FamilyEffectMetadataPod metadata;
                    if (_effect_runtime != nullptr &&
                        _effect_runtime->family_effect_metadata_pod(key, metadata))
                        tier = metadata.magnitude_by_prestige_q16[
                            std::clamp(level, 0, 5)];
                }
                const int64_t scaled = static_cast<int64_t>(tier) *
                    roll.strength_q16 / Q16_ONE;
                int32_t &value = desired_effects[key];
                value = std::clamp<int64_t>(static_cast<int64_t>(value) + scaled,
                    0, 4 * Q16_ONE);
            }
        }
        if (roll.trait_id >= static_cast<int32_t>(
                _family_trait_trigger_offsets.size()) - 1) continue;
        for (int32_t edge = _family_trait_trigger_offsets[roll.trait_id];
             edge < _family_trait_trigger_offsets[roll.trait_id + 1]; ++edge) {
            const std::string &key =
                _family_trait_trigger_definition_keys_by_tier[edge * 6 + level];
            if (!key.empty()) desired_triggers[key] =
                _family_trait_trigger_reward_targets[edge];
        }
    }
    auto add_effect_triggers = [&](const std::string &program_key) {
        const int32_t effect_id = family_effect_id_for_key(program_key);
        if (effect_id < 0 ||
            _family_effect_trigger_definition_keys_by_tier.size() <
                static_cast<size_t>(effect_id + 1) * 6U)
            return;
        const std::string &key = _family_effect_trigger_definition_keys_by_tier[
            static_cast<size_t>(effect_id) * 6U + static_cast<size_t>(
                std::clamp(level, 0, 5))];
        if (key.empty()) return;
        const int32_t reward = effect_id < static_cast<int32_t>(
                _family_effect_trigger_reward_targets.size())
            ? _family_effect_trigger_reward_targets[static_cast<size_t>(effect_id)] : 0;
        desired_triggers[key] = reward;
    };
    if (_effect_runtime != nullptr) {
        const auto branch_bindings = _family_effect_instances_by_branch.find(
            branch_handle);
        std::vector<int64_t> existing_instance_ids = branch_bindings ==
                _family_effect_instances_by_branch.end()
            ? std::vector<int64_t>() : branch_bindings->second;
        existing_instance_ids.erase(std::remove_if(existing_instance_ids.begin(), existing_instance_ids.end(),
            [&](int64_t id) { return _family_effect_binding_by_instance.count(id) == 0; }),
            existing_instance_ids.end());
        auto binding_order = [&](int64_t id) {
            const auto &binding = _family_effect_bindings[_family_effect_binding_by_instance.at(id)];
            return std::tie(binding.definition_key, binding.target_handle, binding.instance_id);
        };
        std::sort(existing_instance_ids.begin(), existing_instance_ids.end(),
            [&](int64_t a, int64_t b) { return binding_order(a) < binding_order(b); });
        std::vector<std::string> desired_non_trait;
        for (const int64_t existing_instance_id : existing_instance_ids) {
            const auto indexed = _family_effect_binding_by_instance.find(
                existing_instance_id);
            if (indexed == _family_effect_binding_by_instance.end()) continue;
            const size_t binding_index = indexed->second;
            const bool remove_binding = [&] {
            auto binding_write = _family_effect_bindings.edit_row(binding_index);
            FamilyEffectBinding &binding = binding_write[0];
            const std::string definition_key = binding.definition_key;
            EffectRuntime::FamilyEffectMetadataPod metadata;
            const bool trait_source = _effect_runtime->family_effect_metadata_pod(
                    definition_key, metadata) && metadata.source_kind == 0;
            if (!trait_source) {
                if (definition_key == "family.effect.knowledge_spread" &&
                    submit_changes) {
                    desired_non_trait.push_back(definition_key);
                }
                int32_t magnitude = metadata.magnitude_by_prestige_q16[
                    std::clamp(level, 0, 5)];
                const int32_t effect_id = family_effect_id_for_key(definition_key);
                if (effect_id >= 0)
                    magnitude = family_effect_prestige_magnitude_q16(effect_id, level);
                magnitude = std::clamp(magnitude, 0,
                    static_cast<int32_t>(4 * Q16_ONE));
                if (definition_key == "family.effect.knowledge_spread" &&
                    submit_changes) {
                    std::vector<int32_t> allowed_cells;
                    collect_family_effect_target_cells(
                        family_influences().cell[branch],
                        metadata.target_selector_kind, allowed_cells,
                        definition_key, level);
                    const int32_t bound_cell = static_cast<int32_t>(
                        binding.target_handle);
                    if (std::find(allowed_cells.begin(), allowed_cells.end(),
                                  bound_cell) == allowed_cells.end()) {
                        std::string error;
                        if (effect_pod_retire(_effect_runtime, _effect_forwarder,
                                binding.instance_id, binding.generation,
                                _current_day.get(), error)) {
                            return true;
                        }
                    }
                }
                if (submit_changes && magnitude != binding.strength_q16) {
                    std::string error;
                    if (effect_pod_upsert(_effect_runtime, _effect_forwarder,
                            binding.instance_id, binding.definition_key,
                            binding.generation, 0x46414d50,
                            static_cast<int64_t>(branch_stable_id), branch_handle,
                            binding.target_handle, binding.target_generation, level,
                            _current_day.get(), -1, true, error) &&
                        effect_pod_metric(_effect_runtime, _effect_forwarder,
                            binding.instance_id, binding.generation, 0,
                            family_effect_metric_revision(1), magnitude, error)) {
                        binding.strength_q16 = magnitude;
                        mark_family_behavior_cache_dirty(
                            FAMILY_BEHAVIOR_DIRTY_EFFECT_BINDINGS);
                    }
                }
                publish_family_effect_metrics(binding,
                    family_effect_metric_revision(1),
                    MetricMask::all_declared(FAMILY_METRIC_COUNT));
                return false;
            }
            const auto found = desired_effects.find(definition_key);
            const int32_t strength = found == desired_effects.end() ? 0 : found->second;
            bool consumed = strength == binding.strength_q16;
            if (submit_changes && strength != binding.strength_q16) {
                std::string error;
                if (strength == 0) {
                    if (effect_pod_retire(_effect_runtime, _effect_forwarder,
                            binding.instance_id, binding.generation,
                            _current_day.get(), error)) {
                        desired_effects.erase(definition_key);
                        return true;
                    }
                } else if (effect_pod_upsert(_effect_runtime, _effect_forwarder,
                        binding.instance_id, binding.definition_key,
                        binding.generation, 0x46414d54,
                        static_cast<int64_t>(branch_stable_id), branch_handle,
                        binding.target_handle, binding.target_generation, level,
                        _current_day.get(), -1, true, error) &&
                        effect_pod_metric(_effect_runtime, _effect_forwarder,
                            binding.instance_id, binding.generation, 0,
                            family_effect_metric_revision(1), strength, error)) {
                    binding.strength_q16 = strength;
                    mark_family_behavior_cache_dirty(
                        FAMILY_BEHAVIOR_DIRTY_EFFECT_BINDINGS);
                    publish_family_effect_metrics(binding,
                        family_effect_metric_revision(1),
                        MetricMask::all_declared(FAMILY_METRIC_COUNT));
                    consumed = true;
                }
            }
            if (consumed && (found == desired_effects.end() ||
                    binding.strength_q16 == 0))
                desired_effects.erase(definition_key);
            else if (consumed)
                desired_effects.erase(found);
            return false;
            }();
            if (remove_binding) remove_family_effect_binding(binding_index);
        }
        for (const auto &item : desired_effects) {
            if (item.second == 0) continue;
            uint64_t base_target_handle = 0;
            uint32_t base_target_generation = 0;
            EffectRuntime::FamilyEffectMetadataPod metadata;
            if (!resolve_effect_target(item.first, base_target_handle,
                    base_target_generation, metadata))
                continue;
            add_effect_triggers(item.first);
            const bool event_once = metadata.lifecycle == 2;
            std::vector<int32_t> target_cells;
            collect_family_effect_target_cells(family_influences().cell[branch],
                metadata.target_selector_kind, target_cells, item.first, level);
            if (target_cells.empty())
                target_cells.push_back(family_influences().cell[branch]);
            for (int32_t target_cell : target_cells) {
                uint64_t identity = trace_hash_mix(1469598103934665603ULL,
                    branch_stable_id);
                identity = trace_hash_mix(identity, static_cast<uint32_t>(
                    family_influences().cell[branch]));
                identity = trace_hash_mix(identity, static_cast<uint32_t>(
                    std::max(0, target_cell)));
                uint64_t definition_hash = 1469598103934665603ULL;
                for (unsigned char ch : item.first)
                    definition_hash = trace_hash_mix(definition_hash, ch);
                identity = trace_hash_mix(identity, definition_hash);
                const int64_t instance_id = static_cast<int64_t>(identity &
                    0x7fffffffffffffffULL);
                uint64_t target_handle = base_target_handle;
                uint32_t target_generation = base_target_generation;
                // Every fan-out kind (6 and above) creates one instance per
                // resolved cell, so each instance must carry its own cell
                // handle. The old 6/7 test meant kinds 8..11 fanned out into N
                // instances that all still pointed at the anchor, which made
                // "component" and "within N" behave as N copies of one cell.
                // No shipped family program uses 8..12 (family_official_buffs
                // only declares 0/2/3/5/6), so widening this cannot move an
                // existing family number.
                if (metadata.target_selector_kind >=
                    EffectRuntime::SELECTOR_NEIGHBORS_R1) {
                    if (target_cell < 0 || target_cell >= _cell_count.get()) continue;
                    target_handle = static_cast<uint64_t>(target_cell);
                    target_generation = 1;
                }
                if (!submit_changes) {
                    if (event_once || instance_alive(instance_id)) {
                        add_family_effect_binding({branch_handle,
                            item.first, item.second, instance_id, branch_generation,
                            metadata.target_domain, target_handle,
                            target_generation, metadata.metric_mask});
                    }
                    continue;
                }
                if (event_once) {
                    add_family_effect_binding({branch_handle, item.first,
                        item.second, instance_id, branch_generation,
                        metadata.target_domain, target_handle, target_generation,
                        metadata.metric_mask});
                    continue;
                }
                std::string error;
                if (!effect_pod_upsert(_effect_runtime, _effect_forwarder,
                        instance_id, item.first, branch_generation, 0x46414d54,
                        static_cast<int64_t>(branch_stable_id), branch_handle,
                        target_handle, target_generation, level, _current_day.get(),
                        -1, true, error) ||
                    !effect_pod_metric(_effect_runtime, _effect_forwarder,
                        instance_id, branch_generation, 0,
                        family_effect_metric_revision(1), item.second, error))
                    continue;
                add_family_effect_binding({branch_handle, item.first,
                    item.second, instance_id, branch_generation,
                    metadata.target_domain, target_handle, target_generation,
                    metadata.metric_mask});
                const auto indexed = _family_effect_binding_by_instance.find(instance_id);
                if (indexed != _family_effect_binding_by_instance.end())
                    publish_family_effect_metrics(
                        _family_effect_bindings[indexed->second],
                        family_effect_metric_revision(1),
                        MetricMask::all_declared(FAMILY_METRIC_COUNT));
            }
        }
        if (!desired_non_trait.empty()) {
            std::sort(desired_non_trait.begin(), desired_non_trait.end());
            desired_non_trait.erase(std::unique(desired_non_trait.begin(),
                desired_non_trait.end()), desired_non_trait.end());
            for (const std::string &key : desired_non_trait) {
                const int32_t effect_id = family_effect_id_for_key(key);
                const int32_t magnitude = family_effect_prestige_magnitude_q16(
                    effect_id, level);
                uint64_t base_target_handle = 0;
                uint32_t base_target_generation = 0;
                EffectRuntime::FamilyEffectMetadataPod metadata;
                if (!resolve_effect_target(key, base_target_handle,
                        base_target_generation, metadata))
                    continue;
                std::vector<int32_t> target_cells;
                collect_family_effect_target_cells(family_influences().cell[branch],
                    metadata.target_selector_kind, target_cells, key, level);
                if (target_cells.empty())
                    target_cells.push_back(family_influences().cell[branch]);
                for (int32_t target_cell : target_cells) {
                    const int64_t instance_id = shaped_effect_instance_id(key, target_cell);
                    if (_family_effect_binding_by_instance.find(instance_id) !=
                        _family_effect_binding_by_instance.end())
                        continue;
                    uint64_t target_handle = base_target_handle;
                    uint32_t target_generation = base_target_generation;
                    if (metadata.target_selector_kind >=
                        EffectRuntime::SELECTOR_NEIGHBORS_R1) {
                        if (target_cell < 0 || target_cell >= _cell_count.get()) continue;
                        target_handle = static_cast<uint64_t>(target_cell);
                        target_generation = 1;
                    }
                    std::string error;
                    if (!effect_pod_upsert(_effect_runtime, _effect_forwarder,
                            instance_id, key, branch_generation, 0x46414d50,
                            static_cast<int64_t>(branch_stable_id), branch_handle,
                            target_handle, target_generation, level,
                            _current_day.get(), -1, true, error) ||
                        !effect_pod_metric(_effect_runtime, _effect_forwarder,
                            instance_id, branch_generation, 0,
                            family_effect_metric_revision(1), magnitude, error))
                        continue;
                    add_family_effect_binding({branch_handle, key, magnitude,
                        instance_id, branch_generation, metadata.target_domain,
                        target_handle, target_generation, metadata.metric_mask});
                    const auto indexed = _family_effect_binding_by_instance.find(instance_id);
                    if (indexed != _family_effect_binding_by_instance.end())
                        publish_family_effect_metrics(
                            _family_effect_bindings[indexed->second],
                            family_effect_metric_revision(1),
                            MetricMask::all_declared(FAMILY_METRIC_COUNT));
                }
            }
        }
        std::vector<std::string> sibling_independent;
        for (const FamilyEffectBinding &binding : _family_effect_bindings) {
            if (binding.branch_handle == branch_handle) continue;
            int32_t other_branch = -1;
            int32_t other_family = -1;
            if (!family_influences().valid_handle(binding.branch_handle,
                    other_branch) ||
                !families_store().valid_handle(
                    family_influences().family_handle[other_branch],
                    other_family) ||
                other_family != family)
                continue;
            EffectRuntime::FamilyEffectMetadataPod metadata;
            if (_effect_runtime == nullptr ||
                !_effect_runtime->family_effect_metadata_pod(
                    binding.definition_key, metadata) ||
                metadata.source_kind == 0)
                continue;
            bool already = false;
            for (const FamilyEffectBinding &mine : _family_effect_bindings) {
                if (mine.branch_handle == branch_handle &&
                    mine.definition_key == binding.definition_key) {
                    already = true;
                    break;
                }
            }
            if (!already)
                sibling_independent.push_back(binding.definition_key);
        }
        std::sort(sibling_independent.begin(), sibling_independent.end());
        sibling_independent.erase(std::unique(sibling_independent.begin(),
            sibling_independent.end()), sibling_independent.end());
        for (const std::string &key : sibling_independent) {
            uint64_t base_target_handle = 0;
            uint32_t base_target_generation = 0;
            EffectRuntime::FamilyEffectMetadataPod metadata;
            if (!resolve_effect_target(key, base_target_handle,
                    base_target_generation, metadata))
                continue;
            const int32_t magnitude = family_effect_prestige_magnitude_q16(
                family_effect_id_for_key(key), level);
            const bool event_once = metadata.lifecycle == 2;
            const int32_t source_cell = family_influences().cell[branch];
            std::vector<int32_t> target_cells;
            collect_family_effect_target_cells(source_cell,
                metadata.target_selector_kind, target_cells, key, level);
            if (target_cells.empty()) target_cells.push_back(source_cell);
            for (int32_t target_cell : target_cells) {
                uint64_t target_handle = base_target_handle;
                uint32_t target_generation = base_target_generation;
                if (metadata.target_selector_kind >=
                    EffectRuntime::SELECTOR_NEIGHBORS_R1) {
                    if (target_cell < 0 || target_cell >= _cell_count.get()) continue;
                    target_handle = static_cast<uint64_t>(target_cell);
                    target_generation = 1;
                }
                const int64_t instance_id =
                    metadata.target_selector_kind >=
                        EffectRuntime::SELECTOR_NEIGHBORS_R1
                    ? shaped_effect_instance_id(key, target_cell)
                    : stable_effect_instance_id(key);
                if (!submit_changes) {
                    // A sibling's instance may have been created by the founding
                    // random-pool grant, which mixes the target cell into the
                    // identity. Probe both shapes and bind the one that is alive.
                    int64_t alive_id = 0;
                    if (instance_alive(instance_id)) {
                        alive_id = instance_id;
                    } else {
                        const int64_t shaped = shaped_effect_instance_id(
                            key, target_cell);
                        if (instance_alive(shaped)) alive_id = shaped;
                    }
                    if (alive_id != 0) {
                        add_family_effect_binding({branch_handle, key, magnitude,
                            alive_id, branch_generation, metadata.target_domain,
                            target_handle, target_generation, metadata.metric_mask});
                    }
                    continue;
                }
                if (event_once) {
                    add_family_effect_binding({branch_handle, key, magnitude,
                        instance_id, branch_generation, metadata.target_domain,
                        target_handle, target_generation, metadata.metric_mask});
                    continue;
                }
                std::string error;
                if (!effect_pod_upsert(_effect_runtime, _effect_forwarder,
                        instance_id, key, branch_generation, 0x46414d54,
                        static_cast<int64_t>(branch_stable_id), branch_handle,
                        target_handle, target_generation, level, _current_day.get(),
                        -1, true, error) ||
                    !effect_pod_metric(_effect_runtime, _effect_forwarder,
                        instance_id, branch_generation, 0,
                        family_effect_metric_revision(1), magnitude, error))
                    continue;
                add_family_effect_binding({branch_handle, key, magnitude, instance_id,
                    branch_generation, metadata.target_domain, target_handle,
                    target_generation, metadata.metric_mask});
                const auto indexed = _family_effect_binding_by_instance.find(instance_id);
                if (indexed != _family_effect_binding_by_instance.end())
                    publish_family_effect_metrics(
                        _family_effect_bindings[indexed->second],
                        family_effect_metric_revision(1),
                        MetricMask::all_declared(FAMILY_METRIC_COUNT));
            }
        }
        grant_random_pool_family_effect(family, submit_changes);
        if (!submit_changes) {
            const int32_t source_cell = family_influences().cell[branch];
            for (const std::string &key : _family_effect_keys) {
                EffectRuntime::FamilyEffectMetadataPod metadata;
                if (!_effect_runtime->family_effect_metadata_pod(key, metadata) ||
                    metadata.source_kind == 0)
                    continue;
                uint64_t base_target_handle = 0;
                uint32_t base_target_generation = 0;
                if (!resolve_effect_target(key, base_target_handle,
                        base_target_generation, metadata))
                    continue;
                const int32_t magnitude = family_effect_prestige_magnitude_q16(
                    family_effect_id_for_key(key), level);
                std::vector<int32_t> target_cells;
                collect_family_effect_target_cells(source_cell,
                    metadata.target_selector_kind, target_cells, key, level);
                if (target_cells.empty()) target_cells.push_back(source_cell);
                for (int32_t target_cell : target_cells) {
                    // The founding random-pool grant owns one instance per target
                    // cell under the shaped identity, so that is the first shape
                    // to probe. The branch-scope shape stays as the fallback for
                    // creators that do not mix the target cell
                    // (grant_ancestral_precept_for_country). Missing both is the
                    // original "the instance is gone" outcome.
                    int64_t instance_id = shaped_effect_instance_id(key, target_cell);
                    if (!instance_alive(instance_id)) {
                        instance_id = stable_effect_instance_id(key);
                        if (!instance_alive(instance_id)) continue;
                    }
                    uint64_t target_handle = base_target_handle;
                    uint32_t target_generation = base_target_generation;
                    // Same rule as the apply path above: a fan-out kind means
                    // one instance per cell, so the handle has to follow the
                    // cell rather than stay on the anchor.
                    if (metadata.target_selector_kind >=
                        EffectRuntime::SELECTOR_NEIGHBORS_R1) {
                        if (target_cell < 0 || target_cell >= _cell_count.get())
                            continue;
                        target_handle = static_cast<uint64_t>(target_cell);
                        target_generation = 1;
                    }
                    add_family_effect_binding({branch_handle, key, magnitude,
                        instance_id, branch_generation, metadata.target_domain,
                        target_handle, target_generation, metadata.metric_mask});
                }
            }
        }
    }
    for (const FamilyEffectBinding &binding : _family_effect_bindings) {
        if (binding.branch_handle != branch_handle) continue;
        add_effect_triggers(binding.definition_key);
    }
    std::vector<size_t> modifier_rows;
    for (size_t i = 0; i < _family_modifier_bindings.size(); ++i)
        if (_family_modifier_bindings[i].branch_handle == branch_handle)
            modifier_rows.push_back(i);
    std::stable_sort(modifier_rows.begin(), modifier_rows.end(), [&](size_t a, size_t b) {
        return _family_modifier_bindings[a].definition_key < _family_modifier_bindings[b].definition_key;
    });
    for (const size_t binding_row : modifier_rows) {
        auto binding_write = _family_modifier_bindings.edit_row(binding_row);
        FamilyModifierBinding &binding = binding_write[0];
        if (binding.branch_handle != branch_handle) continue;
        const auto found = desired.find(binding.definition_key);
        const int32_t magnitude = found == desired.end() ? 0 : found->second;
        if (submit_changes && _effect_runtime != nullptr &&
            magnitude != binding.magnitude_q16) {
            submit_effect_instance(binding.definition_key, magnitude);
        } else if (submit_changes && _modifier_runtime != nullptr &&
            magnitude != binding.magnitude_q16) {
            std::string error;
            modifier_api::queue_family_group_effect(*_modifier_runtime, binding.definition_key,
                family_influences().cell[branch], static_cast<uint64_t>(
                    family_influences().stable_id[branch]), magnitude,
                _current_day.get(), error);
        }
        binding.magnitude_q16 = magnitude;
        if (found != desired.end()) desired.erase(found);
    }
    for (const auto &item : desired) {
        if (item.second == 0) continue;
        int32_t magnitude = item.second;
        if (!submit_changes && _modifier_runtime != nullptr) {
            const int32_t restored = modifier_api::family_group_effect_magnitude(*_modifier_runtime,
                item.first, family_influences().cell[branch], static_cast<uint64_t>(
                    family_influences().stable_id[branch]));
            if (restored >= 0) magnitude = restored;
        } else if (submit_changes && _effect_runtime != nullptr) {
            submit_effect_instance(item.first, magnitude);
        } else if (_modifier_runtime != nullptr) {
            std::string error;
            modifier_api::queue_family_group_effect(*_modifier_runtime, item.first,
                family_influences().cell[branch], static_cast<uint64_t>(
                    family_influences().stable_id[branch]), magnitude,
                _current_day.get(), error);
        }
        _family_modifier_bindings.push_back(
            {branch_handle, item.first, magnitude});
    }
    std::map<std::string, size_t> existing_triggers;
    for (size_t i = 0; i < _family_trigger_bindings.size(); ++i) {
        const auto &binding = _family_trigger_bindings[i];
        if (binding.branch_handle == branch_handle)
            existing_triggers.emplace(binding.definition_key, i);
    }
    std::vector<size_t> expired_triggers;
    for (const auto &[key, row] : existing_triggers) {
        const auto &binding = _family_trigger_bindings[row];
        const auto found = desired_triggers.find(key);
        if (found == desired_triggers.end()) {
            reconcile_trigger_branch_binding(_trigger_runtime, key, branch_handle,
                family_influences().cell[branch], binding.reward_target, false);
            expired_triggers.push_back(row);
            continue;
        }
        if (found->second != binding.reward_target &&
                reconcile_trigger_branch_binding(_trigger_runtime, key, branch_handle,
                    family_influences().cell[branch], found->second, true)) {
            auto binding_write = _family_trigger_bindings.edit_row(row);
            binding_write[0].reward_target = found->second;
        }
        desired_triggers.erase(found);
    }
    std::sort(expired_triggers.rbegin(), expired_triggers.rend());
    for (const size_t row : expired_triggers)
        _family_trigger_bindings.erase(_family_trigger_bindings.begin() + row);
    for (const auto &item : desired_triggers) {
        if (reconcile_trigger_branch_binding(_trigger_runtime, item.first,
                branch_handle, family_influences().cell[branch], item.second,
                true)) {
            _family_trigger_bindings.push_back(
                {branch_handle, item.first, item.second});
        }
    }
}
