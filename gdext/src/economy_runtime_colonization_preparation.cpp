#include "economy_runtime_colonization_includes.inc"

namespace pk {
#include "economy_runtime_colonization_internal.h"

uint64_t NativeEconomyRuntime::hash_preparing_missing_stock(
        int32_t source_cell, const int32_t *good_ids, uint32_t count) const {
    if (good_ids == nullptr || count == 0) return 0;
    uint64_t hash = 1469598103934665603ULL;
    hash = trace_hash_mix(hash, COLONIZATION_PREPARING_STOCK_HASH_REVISION);
    for (uint32_t i = 0; i < count; ++i) {
        hash = trace_hash_mix(hash, static_cast<uint32_t>(good_ids[i]));
        hash = trace_hash_mix(hash, static_cast<uint64_t>(
            market_stock(source_cell, good_ids[i])));
    }
    return hash;
}

void NativeEconomyRuntime::store_preparing_missing_goods(
        int32_t expedition, const ColonizationKitPlan &kit) {
    family_expeditions_store().missing_good_begin.write_scalar(expedition, static_cast<uint32_t>(family_expedition_missing_good_ids().size()), market_mutation_sink());
    const int32_t source = family_expeditions_store().source_cell[expedition];
    for (const int32_t good : kit.missing_good_ids) {
        family_expedition_missing_good_ids().push_back(good);
        family_expedition_missing_good_quantities().push_back(
            market_stock(source, good));
    }
    family_expeditions_store().missing_good_count.write_scalar(expedition, static_cast<uint32_t>(kit.missing_good_ids.size()), market_mutation_sink());
    uint64_t identity = hash_preparing_missing_stock(source,
        kit.missing_good_ids.empty() ? nullptr : kit.missing_good_ids.data(),
        static_cast<uint32_t>(kit.missing_good_ids.size()));
    // Stocking progress must move the identity too, otherwise a party whose
    // shortfall list is unchanged looks frozen to the UI while its escrow grows.
    identity = trace_hash_mix(identity,
        static_cast<uint64_t>(std::max<int64_t>(0, kit.bridge_required_units)));
    identity = trace_hash_mix(identity,
        static_cast<uint64_t>(std::max<int64_t>(0, kit.bridge_missing_units)));
    for (const FamilyExpeditionCargoLine &line : kit.cargo) {
        identity = trace_hash_mix(identity,
            static_cast<uint32_t>(line.good_id));
        identity = trace_hash_mix(identity,
            static_cast<uint64_t>(line.quantity));
    }
    family_expeditions_store().kit_missing_stock_identity.write_scalar(expedition, identity == 0 ? 1 : identity, market_mutation_sink());
}

void NativeEconomyRuntime::refresh_preparing_family_expedition_missing(
        int32_t expedition) {
    const uint32_t count = family_expeditions_store().missing_good_count[expedition];
    const uint32_t begin = family_expeditions_store().missing_good_begin[expedition];
    const int32_t source = family_expeditions_store().source_cell[expedition];
    if (count == 0 ||
        begin + count > family_expedition_missing_good_ids().size()) {
        family_expeditions_store().kit_missing_stock_identity.write_scalar(expedition, 0, market_mutation_sink());
        return;
    }
    for (uint32_t i = 0; i < count; ++i) {
        const int32_t good = family_expedition_missing_good_ids()[begin + i];
        if (begin + i < family_expedition_missing_good_quantities().size())
            family_expedition_missing_good_quantities().write_scalar(begin + i, market_stock(source, good), market_mutation_sink());
    }
}

void NativeEconomyRuntime::abort_preparing_family_expedition(
        int32_t expedition, int64_t day, uint8_t kind, const char *code, int64_t sequence) {
    if (_family_expedition_procurement_continuation.active &&
        _family_expedition_procurement_continuation.expedition == expedition) {
        FamilyExpeditionProcurementContinuation &c =
            _family_expedition_procurement_continuation;
        if (c.pending_request_id != 0 && (c.phase == 1 || c.phase == 5)) {
            c.expedition = -1;
            _family_expedition_procurement_orphans.push_back(std::move(c));
        } else if (_simulation_host != nullptr) {
            _simulation_host->release_country_economy_asset_settlement(
                c.pending_request_id);
        }
        _family_expedition_procurement_continuation =
            FamilyExpeditionProcurementContinuation{};
    }
    _family_expedition_procurement_rejections.erase(expedition);
    // Stocked goods were drawn from the source market and must go back there,
    // or cancelling a preparation would destroy them.
    if (family_expeditions_store().cargo_count[expedition] > 0) {
        std::string ignored;
        restore_family_expedition_cargo(expedition,
            family_expeditions_store().source_cell[expedition], false, ignored);
    }
    const uint64_t key = family_expedition_target_key(
        family_expeditions_store().country_handle[expedition],
        family_expeditions_store().target_cell[expedition]);
    append_colonization_receipt(expedition, sequence,
        family_expeditions_store().departure_day[expedition], day, kind, code);
    _family_expedition_target_index.erase(key);
    family_expeditions_store().release(expedition);
    note_family_expedition_audit_invalidation();
}

bool NativeEconomyRuntime::launch_preparing_family_expedition(
        int32_t expedition, int64_t day, const ColonizationKitPlan &kit,
        std::string &error) {
    // The escrow already holds every kit line, so only the people still have
    // to leave. A blocked payload extract keeps the stocked goods and retries
    // tomorrow instead of dumping them back on the market.
    family_expeditions_store().kit_building_begin.write_scalar(expedition, static_cast<uint32_t>(
        family_expedition_kit_buildings().size()), market_mutation_sink());
    if (kit.place_buildings != 0) {
        family_expedition_kit_buildings().insert(
            family_expedition_kit_buildings().end(),
            kit.buildings.begin(), kit.buildings.end());
        family_expeditions_store().kit_building_count.write_scalar(expedition, static_cast<uint32_t>(kit.buildings.size()), market_mutation_sink());
    } else {
        family_expeditions_store().kit_building_count.write_scalar(expedition, 0, market_mutation_sink());
    }
    if (!extract_family_expedition_payload(expedition,
            family_expeditions_store().population[expedition], error)) {
        // These failures cannot be fixed by waiting another day.  Keeping the
        // party in PREPARING while discarding the reason made the UI look like
        // a completed kit was simply waiting forever.
        if (error == "colonization_population_insufficient" ||
            error == "colonization_population_guard_failed" ||
            error == "colonization_payload_empty") {
            const std::string reason = error;
            abort_preparing_family_expedition(expedition, day, 7,
                reason == "colonization_population_insufficient"
                    ? "PREPARING_POPULATION_INSUFFICIENT"
                    : "PREPARING_PAYLOAD_INVALID");
            error.clear();
            return true;
        }
        // Slot allocation and peer synchronization are transient. Keep the
        // escrow and retry, but retain a receipt so the blocked cause is
        // inspectable instead of silently becoming "waiting for departure".
        const std::string retry_reason = error.empty()
            ? "colonization_payload_retry" : error;
        append_colonization_receipt(expedition, 0, day, day, 2,
            retry_reason.c_str());
        error.clear();
        family_expeditions_store().kit_building_count.write_scalar(expedition, 0, market_mutation_sink());
        store_preparing_missing_goods(expedition, kit);
        family_expeditions_store().due_day.write_scalar(expedition, day + 1, market_mutation_sink());
        push_family_expedition_due(expedition);
        return true;
    }
    const int32_t travel = std::max(1,
        (family_expeditions_store().route_cost[expedition] +
         std::max(1, family_expeditions_store().speed[expedition]) - 1) /
        std::max(1, family_expeditions_store().speed[expedition]));
    family_expeditions_store().state.write_scalar(expedition, EXPEDITION_OUTBOUND, market_mutation_sink());
    family_expeditions_store().departure_day.write_scalar(expedition, day, market_mutation_sink());
    family_expeditions_store().due_day.write_scalar(expedition, day + travel, market_mutation_sink());
    family_expeditions_store().missing_good_count.write_scalar(expedition, 0, market_mutation_sink());
    family_expeditions_store().kit_missing_stock_identity.write_scalar(expedition, 0, market_mutation_sink());
    _family_expedition_procurement_rejections.erase(expedition);
    push_family_expedition_due(expedition);
    note_family_expedition_audit_invalidation();
    append_colonization_receipt(expedition, 0, day, day, 1, "STARTED");
    return true;
}

bool NativeEconomyRuntime::preparing_kit_launchable(
        const ColonizationKitPlan &kit, int64_t people) const {
    // Only a party that plants the opening build plan waits for a complete
    // kit; this is the rule apply_start_family_expedition uses. A target that
    // gained buildings while the party stocked up gets no kit, and holding the
    // party for one would leave it "ready" forever.
    const bool needs_complete_kit = kit.place_buildings != 0 &&
        people >= COLONIZATION_KIT_MIN_OWNER_SLOTS;
    return !needs_complete_kit ||
        (kit.kit_partial == 0 && !kit.buildings.empty());
}

bool NativeEconomyRuntime::advance_preparing_family_expedition(
        int32_t expedition, int64_t day, std::string &error) {
    const int32_t source = family_expeditions_store().source_cell[expedition];
    const int32_t target = family_expeditions_store().target_cell[expedition];
    const uint64_t country = family_expeditions_store().country_handle[expedition];
    const uint64_t family = family_expeditions_store().family_handle[expedition];
    const bool caravan = family == 0;
    // 家族队按可派族人缩编；移民队按可派无家族人口缩编。
    const int64_t people = caravan ? 0 : std::min(
        family_expeditions_store().population[expedition],
        family_dispatchable_population_in_cell(family, source));
    const int64_t anonymous_people = caravan ? std::min(
        family_expeditions_store().anonymous[expedition],
        anonymous_dispatchable_in_cell(source)) : 0;
    if (!colonization_target_owner_allowed(country, target)) {
        abort_preparing_family_expedition(expedition, day, 3,
            "TARGET_LOST_RETURNING");
        return true;
    }
    if (people <= 0 && anonymous_people <= 0) {
        abort_preparing_family_expedition(expedition, day, 7, "PREPARING_ABORTED");
        return true;
    }
    FamilyExpeditionProcurementContinuation &continuation =
        _family_expedition_procurement_continuation;
    if (continuation.active) {
        if (continuation.expedition != expedition) {
            error = "colonization_treasury_peer_busy";
            family_expeditions_store().due_day.write_scalar(expedition, day + 1, market_mutation_sink());
            push_family_expedition_due(expedition);
            return true;
        }
        const int32_t good = continuation.good;
        const uint8_t cargo_flags = continuation.cargo_flags;
        const int64_t quantity = continuation.quantity;
        const bool purchased = advance_family_expedition_procurement(
            continuation, error);
        if (!purchased && continuation.active) {
            error.clear();
            family_expeditions_store().due_day.write_scalar(expedition, day + 1, market_mutation_sink());
            push_family_expedition_due(expedition);
            return true;
        }
        if (!purchased)
            note_family_expedition_procurement_rejection(expedition, good,
                cargo_flags, day, error.empty() ? continuation.last_error : error);
        if (purchased && good >= 0 && quantity > 0) {
            const uint32_t begin =
                family_expeditions_store().cargo_begin[expedition];
            const uint32_t count =
                family_expeditions_store().cargo_count[expedition];
            const uint32_t end = begin + count;
            if (end > family_expedition_cargo().size()) {
                error = "colonization_cargo_range_invalid";
                return false;
            }
            std::vector<FamilyExpeditionCargoLine> cargo;
            cargo.reserve(count + 1);
            for (uint32_t i = begin; i < end; ++i)
                cargo.push_back(family_expedition_cargo()[i]);
            auto held = std::find_if(cargo.begin(), cargo.end(),
                [&](const FamilyExpeditionCargoLine &line) {
                    return line.good_id == good && line.flags == cargo_flags;
                });
            if (held == cargo.end()) {
                cargo.push_back({good, quantity, cargo_flags});
            } else {
                held->quantity = saturating_add(held->quantity, quantity,
                    _saturation_count);
            }
            std::sort(cargo.begin(), cargo.end(),
                [](const FamilyExpeditionCargoLine &a,
                   const FamilyExpeditionCargoLine &b) {
                    return std::tie(a.flags, a.good_id) <
                        std::tie(b.flags, b.good_id);
                });
            family_expeditions_store().cargo_begin.write_scalar(expedition, static_cast<uint32_t>(family_expedition_cargo().size()), market_mutation_sink());
            family_expedition_cargo().insert(family_expedition_cargo().end(),
                cargo.begin(), cargo.end());
            family_expeditions_store().cargo_count.write_scalar(expedition, static_cast<uint32_t>(cargo.size()), market_mutation_sink());
            // The line that was rejected earlier finally landed: drop the note so
            // the panel stops reporting a refusal that no longer blocks anything.
            const auto rejection =
                _family_expedition_procurement_rejections.find(expedition);
            if (rejection != _family_expedition_procurement_rejections.end() &&
                rejection->second.good == good &&
                rejection->second.cargo_flags == cargo_flags)
                _family_expedition_procurement_rejections.erase(rejection);
            note_family_expedition_audit_invalidation();
        }
        error.clear();
    }
    const bool family_reduced = people != family_expeditions_store().population[expedition];
    const bool anonymous_changed =
        anonymous_people != family_expeditions_store().anonymous[expedition];
    const bool population_reduced = family_reduced || anonymous_changed;
    if (population_reduced) {
        if (family_reduced)
            family_expeditions_store().population.write_scalar(expedition, people, market_mutation_sink());
        if (anonymous_changed)
            family_expeditions_store().anonymous.write_scalar(expedition, anonymous_people, market_mutation_sink());
        note_family_expedition_audit_invalidation();
    }
    // Stock up day by day. A cell that never holds a whole kit at once can
    // still fund one over time, so the party escrows the spare stock it can
    // afford today and the planner treats that escrow as available tomorrow.
    // Replanning every day is the point: there is no shortcut that skips the
    // top-up, because spare stock can appear in goods that were not short.
    ColonizationReserveContext reserve;
    std::vector<int64_t> reserved_stock;
    collect_family_expedition_reserved_stock(expedition, reserved_stock);
    reserve.reserved = &reserved_stock;
    reserve.prefer_reserved_candidates = true;
    ColonizationKitPlan kit;
    const int32_t travel = std::max(1,
        (family_expeditions_store().route_cost[expedition] +
         std::max(1, family_expeditions_store().speed[expedition]) - 1) /
        std::max(1, family_expeditions_store().speed[expedition]));
    if (!plan_colonization_kit(source, target, people + anonymous_people, travel,
            false, kit, false, &reserve)) {
        abort_preparing_family_expedition(expedition, day, 7, "PREPARING_ABORTED");
        return true;
    }
    // 缩编后按实际人数采购；已成交货物保留，后续只补实际缺口。
    if (population_reduced) {
        family_expeditions_store().kit_bridge_required_units.write_scalar(expedition,
            std::max<int64_t>(0, kit.bridge_required_units), market_mutation_sink());
        family_expeditions_store().kit_material_required_units.write_scalar(expedition,
            std::max<int64_t>(0, kit.material_required_units), market_mutation_sink());
    }
    // Stockpiling only ever clears once the whole opening kit is affordable.
    // When a construction group has no candidate the source market can ever
    // supply, that day never comes, so end the preparation instead of holding
    // the escrow and the target claim forever.
    if (kit.kit_unbuildable != 0) {
        abort_preparing_family_expedition(expedition, day, 7,
            "PREPARING_UNBUILDABLE");
        return true;
    }
    if (!reserve_preparing_family_expedition_cargo(expedition, kit, error, day)) {
        // Escrow accounting must never fatal the economy: keep what is already
        // held, report the shortfall, and try again tomorrow.
        error.clear();
        store_preparing_missing_goods(expedition, kit);
        family_expeditions_store().due_day.write_scalar(expedition, day + 1, market_mutation_sink());
        push_family_expedition_due(expedition);
        return true;
    }
    if (preparing_kit_launchable(kit, people + anonymous_people))
        return launch_preparing_family_expedition(expedition, day, kit, error);
    store_preparing_missing_goods(expedition, kit);
    family_expeditions_store().due_day.write_scalar(expedition, day + 1, market_mutation_sink());
    push_family_expedition_due(expedition);
    return true;
}

bool NativeEconomyRuntime::apply_start_family_expedition(
        const Command &cmd, std::string &error, const uint8_t *visible,
        int32_t visible_count, uint64_t kit_identity) {
    const auto country = static_cast<uint64_t>(cmd.i64_1);
    const uint64_t family = cmd.target_handle;
    const int32_t source = cmd.i32_0, target = cmd.i32_1;
    if (cmd.expedition_route_hash == 0) {
        error = "colonization_requote_required";
        return false;
    }
    if (visible == nullptr && _simulation_host != nullptr) {
        if (const auto *cells = _simulation_host->colonization_visibility()) {
            visible = cells->data();
            visible_count = static_cast<int32_t>(cells->size());
        }
    }
    std::vector<uint8_t> diagnostic_visibility;
    if (visible == nullptr) {
        diagnostic_visibility.assign(static_cast<size_t>(_cell_count.get()), 1);
        visible = diagnostic_visibility.data();
        visible_count = _cell_count.get();
    }
    std::vector<int32_t> route, cumulative;
    int32_t route_cost = 0;
    if (!plan_family_colonization_route(country, source, target, visible, visible_count,
            route, cumulative, route_cost, error)) return false;
    uint64_t route_hash = 1469598103934665603ULL;
    for (size_t i = 0; i < route.size(); ++i) {
        route_hash = trace_hash_mix(route_hash, static_cast<uint32_t>(route[i]));
        route_hash = trace_hash_mix(route_hash, static_cast<uint32_t>(cumulative[i]));
    }
    if (route_hash != cmd.expedition_route_hash) {
        error = "colonization_requote_required";
        return false;
    }
    if (_family_expedition_target_index.count(family_expedition_target_key(country, target))) {
        error = "colonization_duplicate_target";
        return false;
    }
    const bool caravan = family == 0;
    if (!caravan && !colonization_destination_family_allowed(family, target)) {
        error = "colonization_family_cell_capacity";
        return false;
    }
    const int64_t available = caravan ? anonymous_dispatchable_in_cell(source)
        : family_dispatchable_population_in_cell(family, source);
    const int64_t party_people = cmd.i64_0;
    if (party_people < 1 || party_people > available) {
        error = "colonization_population_insufficient";
        return false;
    }
    const int64_t family_people = caravan ? 0 : party_people;
    const int64_t anonymous_people = caravan ? party_people : 0;
    const int32_t travel_days = std::max(1, (route_cost + COLONIZATION_SPEED - 1) / COLONIZATION_SPEED);
    ColonizationKitPlan kit;
    plan_colonization_kit(source, target, party_people,
        travel_days, _epoch_active, kit);
    if (kit_identity != 0 && kit.dest_identity != kit_identity) {
        error = "colonization_kit_requote_required"; return false;
    }
    const int32_t expedition = family_expeditions_store().allocate();
    family_expeditions_store().stable_id.write_scalar(expedition, _next_family_expedition_stable_id++, market_mutation_sink());
    family_expeditions_store().country_handle.write_scalar(expedition, country, market_mutation_sink());
    family_expeditions_store().family_handle.write_scalar(expedition, family, market_mutation_sink());
    family_expeditions_store().source_cell.write_scalar(expedition, source, market_mutation_sink());
    family_expeditions_store().target_cell.write_scalar(expedition, target, market_mutation_sink());
    family_expeditions_store().departure_day.write_scalar(expedition, cmd.effective_day, market_mutation_sink());
    family_expeditions_store().route_cost.write_scalar(expedition, route_cost, market_mutation_sink());
    family_expeditions_store().speed.write_scalar(expedition, COLONIZATION_SPEED, market_mutation_sink());
    family_expeditions_store().due_day.write_scalar(expedition, cmd.effective_day +
        std::max(1, travel_days), market_mutation_sink());
    family_expeditions_store().state.write_scalar(expedition, EXPEDITION_OUTBOUND, market_mutation_sink());
    family_expeditions_store().population.write_scalar(expedition, family_people, market_mutation_sink());
    family_expeditions_store().anonymous.write_scalar(expedition, anonymous_people, market_mutation_sink());
    // Freeze the stocking denominator at expedition creation.  The live
    // market may re-plan substitutes later, but that must never make an
    // already funded party appear to lose progress.
    family_expeditions_store().kit_bridge_required_units.write_scalar(expedition, std::max<int64_t>(0, kit.bridge_required_units), market_mutation_sink());
    family_expeditions_store().kit_material_required_units.write_scalar(expedition, std::max<int64_t>(0, kit.material_required_units), market_mutation_sink());
    family_expeditions_store().route_begin.write_scalar(expedition, static_cast<uint32_t>(
        family_expedition_route_cells().size()), market_mutation_sink());
    family_expeditions_store().route_count.write_scalar(expedition, static_cast<uint32_t>(route.size()), market_mutation_sink());
    for (size_t i = 0; i < route.size(); ++i) {
        family_expedition_route_cells().push_back(route[i]);
        family_expedition_route_costs().push_back(cumulative[i]);
    }
    uint64_t idempotency_key = 1469598103934665603ULL;
    idempotency_key = trace_hash_mix(idempotency_key,
        static_cast<uint64_t>(family_expeditions_store().stable_id[expedition]));
    idempotency_key = trace_hash_mix(idempotency_key,
        static_cast<uint64_t>(cmd.sequence));
    family_expeditions_store().idempotency_key.write_scalar(expedition, idempotency_key == 0 ? 1 : idempotency_key, market_mutation_sink());
    const bool needs_complete_kit = kit.place_buildings != 0 &&
        party_people >= COLONIZATION_KIT_MIN_OWNER_SLOTS;
    const bool kit_incomplete = kit.kit_partial != 0 || kit.buildings.empty();
    // The party exists from this point, so this epoch needs the colonization
    // channel even though its budget freeze already ran. Restoring it here also
    // keeps the fiscal page honest before the first purchase attempt.
    ensure_epoch_colonization_budget(country);
    auto occupy_preparing = [&]() {
        family_expeditions_store().payload_count.write_scalar(expedition, 0, market_mutation_sink());
        family_expeditions_store().kit_building_count.write_scalar(expedition, 0, market_mutation_sink());
        store_preparing_missing_goods(expedition, kit);
        family_expeditions_store().state.write_scalar(expedition, EXPEDITION_PREPARING, market_mutation_sink());
        family_expeditions_store().due_day.write_scalar(expedition, cmd.effective_day, market_mutation_sink());
        _family_expedition_target_index[family_expedition_target_key(
            country, target)] = expedition;
        push_family_expedition_due(expedition);
        note_family_expedition_audit_invalidation();
        append_colonization_receipt(expedition, cmd.sequence, cmd.effective_day,
            cmd.effective_day, 1, "PREPARING");
        return true;
    };
    if (needs_complete_kit && kit_incomplete)
        return occupy_preparing();
    const bool cargo_reserved = reserve_preparing_family_expedition_cargo(
        expedition, kit, error, cmd.effective_day);
    const FamilyExpeditionProcurementContinuation &continuation =
        _family_expedition_procurement_continuation;
    const bool procurement_pending = continuation.active &&
        continuation.expedition == expedition;
    if (!cargo_reserved && (needs_complete_kit || procurement_pending)) {
        error.clear();
        return occupy_preparing();
    }
    if (!cargo_reserved)
        error.clear();
    if (!extract_family_expedition_cargo(expedition, kit, error)) {
        if (needs_complete_kit) {
            error.clear();
            return occupy_preparing();
        }
        family_expeditions_store().release(expedition);
        if (error.empty()) error = "colonization_kit_materials_short";
        return false;
    }
    if (!extract_family_expedition_payload(expedition, family_people, error)) {
        std::string ignored;
        restore_family_expedition_cargo(expedition, source, false,
            ignored);
        if (needs_complete_kit) {
            error.clear();
            return occupy_preparing();
        }
        family_expeditions_store().release(expedition);
        return false;
    }
    _family_expedition_target_index[family_expedition_target_key(
        country, target)] = expedition;
    push_family_expedition_due(expedition);
    note_family_expedition_audit_invalidation();
    append_colonization_receipt(expedition, cmd.sequence, cmd.effective_day,
        cmd.effective_day, 1, "STARTED");
    return true;
}

} // namespace pk
