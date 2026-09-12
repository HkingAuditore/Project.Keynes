# -*- coding: utf-8 -*-
"""E8 remaining patches: commands, writeback, suppress, gates, report."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def patch_modifier_runtime_h():
    path = ROOT / "gdext/src/modifier_runtime.h"
    text = path.read_text(encoding="utf-8")
    if "apply_pod_snapshot" in text:
        print("modifier_runtime.h already has apply_pod_snapshot")
        return
    needle = (
        "    bool export_pod_catalog(RuntimeModifierPodCatalog &out,\n"
        "                            std::string &error) const;"
    )
    insert = needle + (
        "\n"
        "    // E8 ACTIVE write-back: replace stores from a worker-committed POD\n"
        "    // snapshot so evaluate_modifier_stat / hot-path consumers observe\n"
        "    // the submitted state. Generation must be monotonic; failures leave\n"
        "    // the previous stores untouched.\n"
        "    bool apply_pod_snapshot(const RuntimeModifierPodSnapshot &snapshot,\n"
        "                            std::string &error);\n"
        "    uint64_t pod_snapshot_generation() const {\n"
        "        return _pod_snapshot_generation;\n"
        "    }"
    )
    if needle not in text:
        raise SystemExit("export_pod_catalog needle missing")
    text = text.replace(needle, insert, 1)
    # private members
    if "_pod_snapshot_generation" not in text:
        # find a private field to insert near
        marker = "    std::array<Store, DOMAIN_COUNT> _stores;"
        if marker not in text:
            raise SystemExit("stores marker missing")
        text = text.replace(
            marker,
            "    uint64_t _pod_snapshot_generation = 0;\n" + marker,
            1,
        )
    path.write_text(text, encoding="utf-8")
    print("modifier_runtime.h ok")


def patch_modifier_runtime_cpp():
    path = ROOT / "gdext/src/modifier_runtime.cpp"
    text = path.read_text(encoding="utf-8")
    if "ModifierRuntime::apply_pod_snapshot" in text:
        print("apply_pod_snapshot already present")
        return
    # Insert after export_pod_catalog function
    anchor = "bool ModifierRuntime::export_pod_catalog(RuntimeModifierPodCatalog &out,\n"
    idx = text.find(anchor)
    if idx < 0:
        raise SystemExit("export_pod_catalog missing")
    # find end of function: next "Dictionary ModifierRuntime::submit_commands"
    end = text.find("Dictionary ModifierRuntime::submit_commands", idx)
    if end < 0:
        raise SystemExit("submit_commands after export missing")
    fn = r'''
bool ModifierRuntime::apply_pod_snapshot(const RuntimeModifierPodSnapshot &snapshot,
                                         std::string &error) {
    error.clear();
    if (!_configured) {
        error = "modifier_runtime_not_configured";
        return false;
    }
    if (snapshot.abi_version != RUNTIME_MODIFIER_POD_ABI_VERSION) {
        error = "modifier_pod_snapshot_abi_mismatch";
        return false;
    }
    if (snapshot.generation != 0 &&
        snapshot.generation <= _pod_snapshot_generation) {
        error = "modifier_pod_snapshot_generation_regression";
        return false;
    }
    for (const RuntimeModifierPodEntry &entry : snapshot.entries) {
        if (entry.domain >= DOMAIN_COUNT) {
            error = "modifier_pod_snapshot_domain_invalid";
            return false;
        }
        if (entry.scope < GLOBAL || entry.scope > ENTITY) {
            error = "modifier_pod_snapshot_scope_invalid";
            return false;
        }
        if (entry.definition_id < 0 ||
            entry.definition_id >= static_cast<int32_t>(_definitions.size())) {
            error = "modifier_pod_snapshot_definition_invalid";
            return false;
        }
    }
    for (const RuntimeModifierPodBucket &bucket : snapshot.buckets) {
        if (bucket.domain >= DOMAIN_COUNT || bucket.scope > ENTITY) {
            error = "modifier_pod_snapshot_bucket_shape_invalid";
            return false;
        }
    }

    // Build into temporaries so a mid-apply failure cannot leave a half state.
    std::array<Store, DOMAIN_COUNT> next_stores{};
    for (int32_t domain = 0; domain < DOMAIN_COUNT; ++domain) {
        next_stores[domain].snapshot_version =
            _stores[domain].snapshot_version + 1;
        next_stores[domain].structure_epoch =
            _stores[domain].structure_epoch + 1;
        if (domain < static_cast<int32_t>(snapshot.domain_versions.size()) &&
            snapshot.domain_versions[domain] != 0) {
            next_stores[domain].snapshot_version = std::max(
                next_stores[domain].snapshot_version,
                snapshot.domain_versions[domain]);
        }
    }

    for (const RuntimeModifierPodEntry &entry : snapshot.entries) {
        if (entry.modifier_handle == 0) continue;
        Store &store = next_stores[entry.domain];
        const uint32_t index =
            static_cast<uint32_t>(entry.modifier_handle & 0xffffffffULL);
        const uint32_t generation =
            static_cast<uint32_t>(entry.modifier_handle >> 32U);
        if (generation == 0) {
            error = "modifier_pod_snapshot_handle_invalid";
            return false;
        }
        if (index >= store.active.size()) {
            const size_t grow = static_cast<size_t>(index) + 1u;
            store.active.resize(grow, 0);
            store.generation.resize(grow, 0);
            store.definition_id.resize(grow, -1);
            store.entity_handle.resize(grow, 0);
            store.group_handle.resize(grow, 0);
            store.source_type.resize(grow, 0);
            store.source_id.resize(grow, 0);
            store.scope.resize(grow, GLOBAL);
            store.stacks.resize(grow, 1);
            store.magnitude_q16.resize(grow, Q16_ONE);
            store.applied_day.resize(grow, -1);
            store.expiry_day.resize(grow, PERMANENT_EXPIRY);
            store.expiry_revision.resize(grow, 0);
        }
        if (store.active[index] != 0) {
            error = "modifier_pod_snapshot_duplicate_slot";
            return false;
        }
        store.active[index] = 1;
        store.generation[index] = generation;
        store.definition_id[index] = entry.definition_id;
        store.entity_handle[index] = entry.entity_handle;
        store.group_handle[index] = entry.group_handle;
        store.source_type[index] = entry.source_type;
        store.source_id[index] = entry.source_id;
        store.scope[index] = entry.scope;
        store.stacks[index] = entry.stacks;
        store.magnitude_q16[index] = entry.magnitude_q16;
        store.applied_day[index] = entry.applied_day;
        store.expiry_day[index] = entry.expires_day;
        store.expiry_revision[index] = 1;
        if (store.expiry_day[index] >= 0) {
            store.expiry_heap.push({store.expiry_day[index], index,
                                   store.generation[index],
                                   store.expiry_revision[index]});
        }
        const Definition &definition = _definitions[entry.definition_id];
        if (definition.policy != INDEPENDENT) {
            UniqueKey unique{entry.definition_id, entry.scope,
                             entry.scope == GROUP ? entry.group_handle
                                 : (entry.scope == ENTITY ? entry.entity_handle
                                                         : 0),
                             entry.source_type, entry.source_id};
            store.unique_instances[unique] = index;
        }
        ++store.active_instances;
        store.peak_instances =
            std::max(store.peak_instances, store.active_instances);
    }

    // Install aggregated buckets from the snapshot so evaluate_* matches the
    // worker commit even when contribution rebuild would diverge on ordering.
    for (const RuntimeModifierPodBucket &pod_bucket : snapshot.buckets) {
        Store &store = next_stores[pod_bucket.domain];
        BucketKey key{static_cast<int32_t>(pod_bucket.stat_id),
                      static_cast<int32_t>(pod_bucket.scope),
                      pod_bucket.scope_id};
        Bucket bucket;
        bucket.sum_add = pod_bucket.sum_add;
        if (pod_bucket.product_factor == 0.0) {
            bucket.zero_factor_count = 1;
            bucket.product_nonzero = 1.0;
        } else {
            bucket.zero_factor_count = 0;
            bucket.product_nonzero = pod_bucket.product_factor;
        }
        store.buckets[key] = bucket;
        bump_stat_version(store, key.stat_id);
    }

    // Swap in only after the full rebuild succeeded.
    _stores = std::move(next_stores);
    _pending_commands.clear();
    if (snapshot.committed_day >= 0)
        _current_day = snapshot.committed_day;
    _pod_snapshot_generation = snapshot.generation;
    return true;
}

'''
    text = text[:end] + fn + text[end:]
    path.write_text(text, encoding="utf-8")
    print("modifier_runtime.cpp ok")


def patch_world_ext_modifier():
    path = ROOT / "gdext/src/world_ext_modifier.cpp"
    text = path.read_text(encoding="utf-8")

    # Rewrite submit_modifier_commands for unique writer
    old_submit_start = "Dictionary DCWorldExt::submit_modifier_commands(const Dictionary &packed_batch) {\n"
    if "domain_is_worker_authoritative(\n            RuntimeDomainId::MODIFIER)" in text:
        print("submit already authoritative-aware")
    else:
        # Replace the whole function through run_modifier_daily
        start = text.find(old_submit_start)
        end = text.find("Dictionary DCWorldExt::run_modifier_daily(", start)
        if start < 0 or end < 0:
            raise SystemExit("submit_modifier_commands bounds missing")
        new_fn = r'''Dictionary DCWorldExt::submit_modifier_commands(const Dictionary &packed_batch) {
    if (_modifier_runtime == nullptr) return unavailable();
    ModifierRuntime *runtime = runtime_from(_modifier_runtime);
    const bool worker_authoritative = _runtime_host != nullptr &&
        _runtime_host->domain_is_worker_authoritative(
            RuntimeDomainId::MODIFIER);

    auto encode_and_enqueue = [&](const Dictionary &batch,
                                  const PackedInt64Array &request_ids,
                                  bool require_enqueue) -> Dictionary {
        Dictionary result;
        result["ok"] = true;
        const PackedInt32Array opcodes = batch.get("opcodes", PackedInt32Array());
        const PackedInt32Array producers = batch.get("producer_ids", PackedInt32Array());
        const PackedInt64Array sequences = batch.get("sequences", PackedInt64Array());
        const PackedInt64Array days = batch.get("effective_days", PackedInt64Array());
        const PackedStringArray definitions = batch.get("definition_keys", PackedStringArray());
        const PackedInt32Array domains = batch.get("domains", PackedInt32Array());
        const PackedInt32Array scopes = batch.get("scopes", PackedInt32Array());
        const PackedInt64Array entities = batch.get("entity_handles", PackedInt64Array());
        const PackedInt64Array groups = batch.get("group_handles", PackedInt64Array());
        const PackedInt64Array source_types = batch.get("source_types", PackedInt64Array());
        const PackedInt64Array source_ids = batch.get("source_ids", PackedInt64Array());
        const PackedInt32Array durations = batch.get("duration_days", PackedInt32Array());
        const PackedInt32Array stacks = batch.get("stacks", PackedInt32Array());
        const PackedInt32Array magnitudes = batch.get("magnitude_q16", PackedInt32Array());
        const PackedInt64Array handles = batch.get("modifier_handles", PackedInt64Array());
        const int32_t count = request_ids.size();
        int32_t enqueued = 0;
        std::string enqueue_error;
        const RuntimeThreadReport host_report = _runtime_host->report();
        for (int32_t i = 0; i < count; ++i) {
            RuntimeCommandPacket packet;
            packet.envelope.request_id = static_cast<uint64_t>(request_ids[i]);
            packet.envelope.producer_id = static_cast<uint32_t>(producers[i]);
            packet.envelope.sequence = static_cast<uint64_t>(sequences[i]);
            packet.envelope.observed_generation = host_report.generation;
            packet.envelope.requested_day = days[i];
            packet.envelope.effective_day = days[i];
            packet.envelope.domain = static_cast<uint16_t>(RuntimeDomainId::MODIFIER);
            packet.envelope.opcode = static_cast<uint16_t>(opcodes[i]);
            packet.envelope.payload_size = RUNTIME_MODIFIER_POD_WIRE_SIZE;
            size_t cursor = 0;
            const auto append = [&packet, &cursor](auto value) {
                using T = decltype(value);
                using U = std::make_unsigned_t<T>;
                U bits = static_cast<U>(value);
                for (size_t byte = 0; byte < sizeof(T); ++byte) {
                    packet.payload[cursor++] = static_cast<uint8_t>(
                        bits & static_cast<U>(0xffu));
                    bits >>= 8u;
                }
            };
            const int32_t definition_id = runtime->definition_id_for_key(
                definitions[i].utf8().get_data());
            const uint64_t entity_handle = static_cast<uint64_t>(entities[i]);
            const uint32_t target_generation = scopes[i] == ModifierRuntime::ENTITY
                ? static_cast<uint32_t>(entity_handle >> 32u) : 0u;
            append(static_cast<uint32_t>(RUNTIME_MODIFIER_POD_WIRE_ABI_VERSION));
            append(static_cast<uint16_t>(domains[i]));
            append(static_cast<uint16_t>(scopes[i]));
            append(definition_id);
            append(entity_handle);
            append(static_cast<uint64_t>(groups[i]));
            append(static_cast<uint64_t>(source_types[i]));
            append(static_cast<uint64_t>(source_ids[i]));
            append(static_cast<int32_t>(durations[i]));
            append(static_cast<int32_t>(stacks[i]));
            append(static_cast<int32_t>(magnitudes[i]));
            append(static_cast<uint64_t>(handles[i]));
            append(target_generation);
            append(host_report.environment_generation);
            if (cursor != RUNTIME_MODIFIER_POD_WIRE_SIZE ||
                !_runtime_host->enqueue_modifier_shadow(std::move(packet))) {
                enqueue_error = "modifier_host_enqueue_failed";
                if (require_enqueue) {
                    result["ok"] = false;
                    result["reason"] = String(enqueue_error.c_str());
                    result["modifier_host_enqueued"] = enqueued;
                    return result;
                }
                continue;
            }
            ++enqueued;
        }
        result["request_ids"] = request_ids;
        result["modifier_host_enqueued"] = enqueued;
        result["modifier_shadow_enqueued"] = enqueued;
        result["modifier_shadow_fallback_reason"] = String(enqueue_error.c_str());
        return result;
    };

    if (worker_authoritative) {
        // E8: Host is the sole writer. Never apply to legacy first.
        if (!_runtime_host) {
            Dictionary out;
            out["ok"] = false;
            out["reason"] = "modifier_host_unavailable";
            return out;
        }
        const PackedInt32Array opcodes = packed_batch.get("opcodes", PackedInt32Array());
        const int32_t count = opcodes.size();
        PackedInt64Array request_ids;
        request_ids.resize(count);
        for (int32_t i = 0; i < count; ++i) {
            request_ids.set(i, static_cast<int64_t>(
                _runtime_host->allocate_command_request_id()));
        }
        return encode_and_enqueue(packed_batch, request_ids, true);
    }

    Dictionary result = runtime->submit_commands(packed_batch);
    if (!static_cast<bool>(result.get("ok", false)) || !_runtime_host) return result;
    const PackedInt64Array request_ids = result.get("request_ids", PackedInt64Array());
    Dictionary mirrored = encode_and_enqueue(packed_batch, request_ids, false);
    result["modifier_shadow_enqueued"] = mirrored.get("modifier_host_enqueued", 0);
    result["modifier_shadow_fallback_reason"] =
        mirrored.get("modifier_shadow_fallback_reason", "");
    return result;
}

'''
        text = text[:start] + new_fn + text[end:]

    # should_run + run_modifier_daily suppress
    old_run = (
        "Dictionary DCWorldExt::run_modifier_daily(int64_t day_index) {\n"
        "    return _modifier_runtime == nullptr ? unavailable()\n"
        "        : runtime_from(_modifier_runtime)->run_daily(day_index);\n"
        "}\n"
        "\n"
        "bool DCWorldExt::modifier_should_run(int64_t day_index) const {\n"
        "    return _modifier_runtime != nullptr &&\n"
        "        runtime_from(_modifier_runtime)->should_run(day_index);\n"
        "}\n"
    )
    new_run = (
        "Dictionary DCWorldExt::run_modifier_daily(int64_t day_index) {\n"
        "    if (_modifier_runtime == nullptr) return unavailable();\n"
        "    if (_runtime_host != nullptr &&\n"
        "        _runtime_host->domain_is_worker_authoritative(\n"
        "            RuntimeDomainId::MODIFIER)) {\n"
        "        Dictionary out;\n"
        "        out[\"ok\"] = true;\n"
        "        out[\"done\"] = true;\n"
        "        out[\"work_done\"] = 0;\n"
        "        out[\"commands_applied\"] = 0;\n"
        "        out[\"expired\"] = 0;\n"
        "        out[\"stage\"] = \"modifier_worker_authoritative\";\n"
        "        out[\"path\"] = \"MODIFIER_WORKER\";\n"
        "        out[\"suppressed\"] = true;\n"
        "        return out;\n"
        "    }\n"
        "    return runtime_from(_modifier_runtime)->run_daily(day_index);\n"
        "}\n"
        "\n"
        "bool DCWorldExt::modifier_should_run(int64_t day_index) const {\n"
        "    if (_runtime_host != nullptr &&\n"
        "        _runtime_host->domain_is_worker_authoritative(\n"
        "            RuntimeDomainId::MODIFIER)) {\n"
        "        return false;\n"
        "    }\n"
        "    return _modifier_runtime != nullptr &&\n"
        "        runtime_from(_modifier_runtime)->should_run(day_index);\n"
        "}\n"
    )
    if "modifier_worker_authoritative" in text and "suppressed" in text:
        print("run_modifier_daily already suppressed")
    else:
        if old_run not in text:
            raise SystemExit("run_modifier_daily block missing")
        text = text.replace(old_run, new_run, 1)
        print("run/should_run suppressed")

    # apply facade after get_runtime_modifier_snapshot
    if "apply_runtime_modifier_snapshot" not in text:
        apply_fn = r'''
Dictionary DCWorldExt::apply_runtime_modifier_snapshot(int64_t after_generation) {
    Dictionary out;
    out["ok"] = false;
    out["available"] = false;
    out["applied"] = false;
    if (_modifier_runtime == nullptr) {
        out["reason"] = "modifier_runtime_unavailable";
        return out;
    }
    if (!_runtime_host) {
        out["reason"] = "runtime_host_unavailable";
        return out;
    }
    if (!_runtime_host->domain_is_worker_authoritative(RuntimeDomainId::MODIFIER)) {
        out["ok"] = true;
        out["reason"] = "modifier_not_worker_authoritative";
        return out;
    }
    const uint64_t cursor = after_generation < 0
        ? std::numeric_limits<uint64_t>::max()
        : static_cast<uint64_t>(after_generation);
    uint32_t slot = 0;
    if (!_runtime_host->try_acquire_modifier_snapshot(cursor, slot)) {
        out["ok"] = true;
        out["reason"] = "";
        return out;
    }
    const RuntimeModifierPodSnapshot &snapshot =
        _runtime_host->modifier_snapshot_buffer(slot);
    bool shape_ok = snapshot.abi_version == RUNTIME_MODIFIER_POD_ABI_VERSION &&
        snapshot.catalog_hash == _runtime_host->modifier_pod_catalog_hash();
    for (const RuntimeModifierPodEntry &entry : snapshot.entries)
        shape_ok = shape_ok && entry.domain < 4;
    for (const RuntimeModifierPodBucket &bucket : snapshot.buckets)
        shape_ok = shape_ok && bucket.domain < 4 && bucket.scope < 3;
    if (!shape_ok) {
        _runtime_host->release_modifier_snapshot(slot);
        out["reason"] = "modifier_snapshot_shape_or_catalog_invalid";
        return out;
    }
    std::string apply_error;
    const bool applied =
        runtime_from(_modifier_runtime)->apply_pod_snapshot(snapshot, apply_error);
    out["ok"] = applied;
    out["available"] = true;
    out["applied"] = applied;
    out["generation"] = static_cast<int64_t>(snapshot.generation);
    out["committed_day"] = snapshot.committed_day;
    out["state_hash"] = static_cast<int64_t>(snapshot.state_hash);
    out["reason"] = applied ? "" : String(apply_error.c_str());
    _runtime_host->release_modifier_snapshot(slot);
    return out;
}

'''
        insert_at = text.find("Dictionary DCWorldExt::runtime_modifier_pod_self_test")
        if insert_at < 0:
            raise SystemExit("self_test insert point missing")
        text = text[:insert_at] + apply_fn + text[insert_at:]
        print("apply_runtime_modifier_snapshot added")

    path.write_text(text, encoding="utf-8")
    print("world_ext_modifier.cpp ok")


def patch_world_ext_h_and_binds():
    h = ROOT / "gdext/src/world_ext.h"
    text = h.read_text(encoding="utf-8")
    if "apply_runtime_modifier_snapshot" not in text:
        needle = "    godot::Dictionary get_runtime_modifier_snapshot(int64_t after_generation);"
        if needle not in text:
            raise SystemExit("get_runtime_modifier_snapshot decl missing")
        text = text.replace(
            needle,
            needle
            + "\n"
            + "    godot::Dictionary apply_runtime_modifier_snapshot(int64_t after_generation);",
            1,
        )
        h.write_text(text, encoding="utf-8")
        print("world_ext.h ok")
    else:
        print("world_ext.h already has apply")

    b = ROOT / "gdext/src/world_ext_bind_methods.cpp"
    bt = b.read_text(encoding="utf-8")
    if "apply_runtime_modifier_snapshot" not in bt:
        needle = (
            '    ClassDB::bind_method(D_METHOD("get_runtime_modifier_snapshot", "after_generation"),\n'
            "                         &DCWorldExt::get_runtime_modifier_snapshot,"
        )
        # find a simpler bind nearby
        simple = 'ClassDB::bind_method(D_METHOD("get_runtime_modifier_snapshot"'
        idx = bt.find(simple)
        if idx < 0:
            raise SystemExit("bind get_runtime_modifier_snapshot missing")
        # find end of this bind_method call
        semi = bt.find(";", idx)
        insert = (
            '\n    ClassDB::bind_method(D_METHOD("apply_runtime_modifier_snapshot", "after_generation"),\n'
            "                         &DCWorldExt::apply_runtime_modifier_snapshot,\n"
            "                         DEFVAL(-1));"
        )
        bt = bt[: semi + 1] + insert + bt[semi + 1 :]
        b.write_text(bt, encoding="utf-8")
        print("binds ok")
    else:
        print("binds already present")

    # allocate_command_request_id must be public on host
    nh = ROOT / "gdext/src/native_simulation_host.h"
    nt = nh.read_text(encoding="utf-8")
    if "allocate_command_request_id()" not in nt.split("public:")[1].split("private:")[0]:
        # currently may be private — expose near enqueue_modifier_shadow
        if "uint64_t allocate_command_request_id();" in nt:
            # move or duplicate in public if needed
            pub_marker = "    bool enqueue_modifier_shadow(RuntimeCommandPacket packet);"
            if pub_marker in nt and "allocate_command_request_id" not in nt[nt.find("public:") : nt.find(pub_marker) + 200]:
                nt = nt.replace(
                    pub_marker,
                    "    uint64_t allocate_command_request_id();\n" + pub_marker,
                    1,
                )
                # remove private duplicate if present to avoid redefinition
                # keep one declaration only in public — remove from private
                parts = nt.split("private:")
                if len(parts) >= 2:
                    priv = parts[1]
                    priv2 = priv.replace(
                        "    uint64_t allocate_command_request_id();\n", "", 1
                    )
                    nt = parts[0] + "private:" + priv2
                nh.write_text(nt, encoding="utf-8")
                print("allocate_command_request_id made public")
            else:
                print("allocate_command_request_id already public-ish")
        else:
            print("WARNING: allocate_command_request_id declaration missing")
    else:
        print("allocate_command_request_id already public")


def patch_runtime_graph():
    path = ROOT / "gdext/src/world_ext_runtime_graph.cpp"
    text = path.read_text(encoding="utf-8")
    # suppress block around modifier daily
    old = (
        "        if (_modifier_runtime != nullptr &&\n"
        "            static_cast<ModifierRuntime *>(_modifier_runtime)->should_run(day)) {\n"
        "            if (_effect_runtime != nullptr) dispatch_effect_native_modifier();\n"
        "            ran(run_modifier_daily(day), DIRTY_COUNTRY_STATE);\n"
        "            if (_effect_runtime != nullptr) ack_effect_native_modifier();\n"
        "            progressed = true;\n"
        "        }\n"
    )
    new = (
        "        const bool modifier_worker_authoritative = _runtime_host != nullptr &&\n"
        "            _runtime_host->domain_is_worker_authoritative(\n"
        "                RuntimeDomainId::MODIFIER);\n"
        "        if (!modifier_worker_authoritative && _modifier_runtime != nullptr &&\n"
        "            static_cast<ModifierRuntime *>(_modifier_runtime)->should_run(day)) {\n"
        "            if (_effect_runtime != nullptr) dispatch_effect_native_modifier();\n"
        "            ran(run_modifier_daily(day), DIRTY_COUNTRY_STATE);\n"
        "            if (_effect_runtime != nullptr) ack_effect_native_modifier();\n"
        "            progressed = true;\n"
        "        }\n"
    )
    if "modifier_worker_authoritative = _runtime_host" not in text:
        if old not in text:
            raise SystemExit("modifier daily graph block missing")
        text = text.replace(old, new, 1)
        print("graph suppress ok")
    else:
        print("graph suppress already present")

    # Also suppress Effect->Modifier dispatch/ack when worker authoritative
    # in the effect daily block above
    old_eff = (
        "                dispatch_effect_native_modifier();\n"
        "                dispatch_effect_native_gameplay();\n"
        "                ack_effect_native_country();\n"
        "                ack_effect_native_economy();\n"
        "                ack_effect_native_modifier();\n"
        "                ack_effect_native_gameplay();\n"
    )
    new_eff = (
        "                if (!(_runtime_host != nullptr &&\n"
        "                      _runtime_host->domain_is_worker_authoritative(\n"
        "                          RuntimeDomainId::MODIFIER))) {\n"
        "                    dispatch_effect_native_modifier();\n"
        "                }\n"
        "                dispatch_effect_native_gameplay();\n"
        "                ack_effect_native_country();\n"
        "                ack_effect_native_economy();\n"
        "                if (!(_runtime_host != nullptr &&\n"
        "                      _runtime_host->domain_is_worker_authoritative(\n"
        "                          RuntimeDomainId::MODIFIER))) {\n"
        "                    ack_effect_native_modifier();\n"
        "                }\n"
        "                ack_effect_native_gameplay();\n"
    )
    if "domain_is_worker_authoritative(\n                          RuntimeDomainId::MODIFIER))) {\n                    dispatch_effect_native_modifier" not in text:
        if old_eff not in text:
            print("WARN: effect ack block shape drifted; skipping dual-ack guard")
        else:
            text = text.replace(old_eff, new_eff, 1)
            print("effect modifier dual-ack guard ok")
    else:
        print("effect dual-ack guard already present")

    # report field
    if '"modifier_worker_authoritative"' not in text:
        # insert near country_worker_authoritative assignments — both report paths
        needle = 'out["country_worker_authoritative"] = host.country_worker_authoritative;'
        count = text.count(needle)
        if count == 0:
            raise SystemExit("country_worker_authoritative report missing")
        replacement = (
            needle
            + "\n"
            + '        out["modifier_worker_authoritative"] =\n'
            + "            (host.authoritative_domain_mask &\n"
            + "             runtime_domain_mask(RuntimeDomainId::MODIFIER)) != 0u;"
        )
        text = text.replace(needle, replacement)
        print(f"report field added x{count}")
    else:
        print("report field already present")

    path.write_text(text, encoding="utf-8")
    print("world_ext_runtime_graph.cpp ok")


def patch_world_runtime_host():
    path = ROOT / "Project/project-keynes/scripts/game/world_runtime_host.gd"
    text = path.read_text(encoding="utf-8")
    text2 = text.replace(
        'config["authoritative_domain_mask"] = 0x806',
        'config["authoritative_domain_mask"] = 0x846',
    )
    text2 = text2.replace(
        "# 线程安全\"，不是整图。CLIMATE(0x2)|COUNTRY(0x4)|COMMIT(0x800)=0x806：",
        "# 线程安全\"，不是整图。CLIMATE(0x2)|COUNTRY(0x4)|MODIFIER(0x40)|COMMIT(0x800)=0x846：",
    )
    text2 = text2.replace(
        "# D12：Country 与 Climate 同开关进入生产 ACTIVE；不得用 handoff /",
        "# E8：Climate|Country|Modifier 同开关进入生产 ACTIVE；不得用 handoff /",
    )
    text2 = text2.replace(
        "[runtime-worker] Climate|Country ACTIVE refused:",
        "[runtime-worker] Climate|Country|Modifier ACTIVE refused:",
    )
    text2 = text2.replace(
        "[runtime-worker] Climate|Country authority start refused:",
        "[runtime-worker] Climate|Country|Modifier authority start refused:",
    )
    if "_consume_modifier_worker_snapshot_if_authoritative" not in text2:
        # add state var near country read generation
        if "var _country_worker_read_generation" in text2:
            text2 = text2.replace(
                "var _country_worker_read_generation",
                "var _modifier_worker_snapshot_generation: int = 0\n"
                "var _country_worker_read_generation",
                1,
            )
        consume_fn = '''
## E8 ACTIVE Modifier write-back. Non-blocking: drops intermediate generations.
## Targets legacy ModifierRuntime (not MapData arrays). main_wait_on_sim_us stays 0.
func _consume_modifier_worker_snapshot_if_authoritative() -> void:
	if not _runtime_ready_for_ticks or _generator == null:
		return
	if not _generator.has_method("apply_runtime_modifier_snapshot"):
		return
	var report: Dictionary = _generator.get_runtime_thread_report() \\
		if _generator.has_method("get_runtime_thread_report") else {}
	var granted_mask := int(report.get("authoritative_domain_mask", 0))
	if (granted_mask & 0x040) == 0:
		return
	var applied: Dictionary = _generator.apply_runtime_modifier_snapshot(
		_modifier_worker_snapshot_generation)
	if not bool(applied.get("ok", false)) or not bool(applied.get("applied", false)):
		return
	var generation := int(applied.get("generation", 0))
	if generation <= _modifier_worker_snapshot_generation:
		return
	_modifier_worker_snapshot_generation = generation


'''
        # insert before country consume
        marker = "func _consume_country_worker_read_view_if_authoritative() -> void:"
        if marker not in text2:
            raise SystemExit("country consume marker missing")
        text2 = text2.replace(marker, consume_fn + marker, 1)
        # call sites near climate/country consume
        for call_marker in [
            "\t_consume_country_worker_read_view_if_authoritative()\n",
            "\t_apply_climate_writeback_if_authoritative(report)\n",
        ]:
            if call_marker in text2 and "_consume_modifier_worker_snapshot_if_authoritative()" not in text2.split(call_marker)[0][-200:]:
                text2 = text2.replace(
                    call_marker,
                    "\t_consume_modifier_worker_snapshot_if_authoritative()\n" + call_marker,
                    1,
                )
        # ensure both tick paths call it — add next to every country consume
        text2 = text2.replace(
            "\t_consume_country_worker_read_view_if_authoritative()\n",
            "\t_consume_modifier_worker_snapshot_if_authoritative()\n"
            "\t_consume_country_worker_read_view_if_authoritative()\n",
        )
        # de-dupe accidental double inserts
        while (
            "\t_consume_modifier_worker_snapshot_if_authoritative()\n"
            "\t_consume_modifier_worker_snapshot_if_authoritative()\n"
        ) in text2:
            text2 = text2.replace(
                "\t_consume_modifier_worker_snapshot_if_authoritative()\n"
                "\t_consume_modifier_worker_snapshot_if_authoritative()\n",
                "\t_consume_modifier_worker_snapshot_if_authoritative()\n",
            )
        print("world_runtime_host consume added")
    if text2 != text:
        path.write_text(text2, encoding="utf-8")
        print("world_runtime_host.gd ok")
    else:
        print("world_runtime_host.gd unchanged?")


def patch_modifier_daily_system():
    path = ROOT / "Project/project-keynes/scripts/simulation/systems/modifier_daily_system.gd"
    text = path.read_text(encoding="utf-8")
    if "modifier_worker_authoritative" in text:
        print("modifier_daily_system already guarded")
        return
    old = '''func should_run(ctx: SusTickContext) -> bool:
	return facade != null and facade.is_configured() and ctx != null \\
		and bool(facade.world_ext().modifier_should_run(ctx.day_index))
'''
    # file may not have escaped backslash
    old2 = """func should_run(ctx: SusTickContext) -> bool:
	return facade != null and facade.is_configured() and ctx != null \\
		and bool(facade.world_ext().modifier_should_run(ctx.day_index))
"""
    # read exact
    if "func should_run" not in text:
        raise SystemExit("should_run missing")
    new_should = '''func should_run(ctx: SusTickContext) -> bool:
	# E8: when Modifier is Host ACTIVE, native graph + C++ should_run already
	# suppress production writes; keep the SUS shell idle as well.
	if facade != null and facade.is_configured() and facade.world_ext() != null:
		var report: Dictionary = facade.world_ext().get_runtime_thread_report() \\
			if facade.world_ext().has_method("get_runtime_thread_report") else {}
		if bool(report.get("modifier_worker_authoritative", false)):
			return false
	return facade != null and facade.is_configured() and ctx != null \\
		and bool(facade.world_ext().modifier_should_run(ctx.day_index))
'''
    import re
    text2, n = re.subn(
        r"func should_run\(ctx: SusTickContext\) -> bool:\n(?:\t.*\n)+?(?=\nfunc |\Z)",
        new_should + "\n",
        text,
        count=1,
    )
    if n != 1:
        raise SystemExit(f"should_run replace failed n={n}")
    path.write_text(text2, encoding="utf-8")
    print("modifier_daily_system.gd ok")


if __name__ == "__main__":
    patch_modifier_runtime_h()
    patch_modifier_runtime_cpp()
    patch_world_ext_h_and_binds()
    patch_world_ext_modifier()
    patch_runtime_graph()
    patch_world_runtime_host()
    patch_modifier_daily_system()
