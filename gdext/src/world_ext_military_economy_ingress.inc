// Private D+1 military -> Economy ingress; included once inside namespace pk.
bool NativeMilitaryRuntime::submit_military_economy_commands(
        const std::vector<MilitaryEconomyCommand> &commands,
        std::vector<MilitaryPendingIntent> &pending, std::string &error) {
    if (commands.empty()) return true;
    if (_economy_runtime == nullptr) {
        error = "military_economy_unavailable";
        return false;
    }
    const int64_t count = static_cast<int64_t>(commands.size());
    // Row groups. Army personnel lane rows (opcodes 30/31/32) travel apart from
    // the pre-lane economy rows everywhere: an economy that does not know them
    // rejects a whole batch at the first bad row, so letting them share a batch
    // would take enlistment / casualties down with the lane. Three groups:
    //   * lane_rows      -> army personnel lane rows
    //   * pod_rows       -> the opcodes the POD lane carries (24 cohort convert,
    //                       6 population delta)
    //   * pre_lane_rows  -> every non-lane row, used for the legacy retry
    std::vector<int32_t> lane_rows;
    std::vector<int32_t> pod_rows;
    std::vector<int32_t> pre_lane_rows;
    std::vector<int32_t> all_rows;
    all_rows.reserve(static_cast<size_t>(count));
    for (int64_t i = 0; i < count; ++i) {
        const int32_t opcode = commands[static_cast<size_t>(i)].opcode;
        all_rows.push_back(static_cast<int32_t>(i));
        if (is_army_lane_opcode(opcode)) {
            lane_rows.push_back(static_cast<int32_t>(i));
        } else {
            pre_lane_rows.push_back(static_cast<int32_t>(i));
            if (opcode == MECONOMY_CONVERT_COHORT || opcode == MECONOMY_ADD_POPULATION ||
                opcode == EconomyApi::COMMAND_MILITARY_PROCUREMENT_DEMAND ||
                opcode == EconomyApi::COMMAND_MILITARY_PURCHASE)
                pod_rows.push_back(static_cast<int32_t>(i));
        }
    }
    const auto build_legacy = [&](const std::vector<int32_t> &rows) {
        const int64_t n = static_cast<int64_t>(rows.size());
        PackedInt32Array opcodes, i32_0, i32_1;
        PackedInt64Array days, sequences, targets, i64_0, i64_1;
        opcodes.resize(n);
        i32_0.resize(n);
        i32_1.resize(n);
        days.resize(n);
        sequences.resize(n);
        targets.resize(n);
        i64_0.resize(n);
        i64_1.resize(n);
        for (int64_t k = 0; k < n; ++k) {
            const MilitaryEconomyCommand &c = commands[static_cast<size_t>(rows[static_cast<size_t>(k)])];
            opcodes[k] = c.opcode;
            days[k] = c.effective_day;
            sequences[k] = c.sequence;
            targets[k] = c.target_handle;
            i32_0[k] = c.i32_0;
            i32_1[k] = c.i32_1;
            i64_0[k] = c.i64_0;
            i64_1[k] = c.i64_1;
        }
        Dictionary batch;
        batch["opcodes"] = opcodes;
        batch["effective_days"] = days;
        batch["sequences"] = sequences;
        batch["target_handles"] = targets;
        batch["i32_0"] = i32_0;
        batch["i32_1"] = i32_1;
        batch["i64_0"] = i64_0;
        batch["i64_1"] = i64_1;
        return batch;
    };
    // Marks the pending rows of one row group failed (no receipt will arrive).
    const auto fail_rows = [&](const std::vector<int32_t> &rows) {
        for (MilitaryPendingIntent &row : pending) {
            if (row.authority != 2) continue;
            for (const int32_t i : rows) {
                if (commands[static_cast<size_t>(i)].sequence != row.sequence) continue;
                row.receipt_pending = 0;
                break;
            }
        }
    };
    Dictionary submitted;
    if (_runtime_host && _runtime_host->economy_worker_owns_execution()) {
        submitted["ok"] = false;
        submitted["reason"] = "economy_legacy_ingress_disabled";
    } else {
        submitted = _economy_runtime->submit_commands(build_legacy(all_rows));
    }
    if (!static_cast<bool>(submitted.get("ok", false)) &&
        String(submitted.get("reason", "")) != String("economy_legacy_ingress_disabled") &&
        !lane_rows.empty() && !pre_lane_rows.empty()) {
        // Older economy on the legacy ingress: the lane opcodes are unknown there
        // (`unsupported_command_opcode`), which may fail the whole batch. Retry
        // without them so enlistment still lands, and fail only the lane rows.
        const Dictionary retry = _economy_runtime->submit_commands(build_legacy(pre_lane_rows));
        if (static_cast<bool>(retry.get("ok", false))) {
            fail_rows(lane_rows);
            return true;
        }
    }
    if (!static_cast<bool>(submitted.get("ok", false)) &&
        String(submitted.get("reason", "")) == String("economy_legacy_ingress_disabled") &&
        _runtime_host != nullptr) {
        // B (design 5.4): state-directed cohort conversion, named by signature.
        // Economy resolves both cohorts inside whichever store owns the day, so
        // this works under whole-graph ACTIVE without the legacy ingress. Cash
        // lanes stay out: they would mint inside the POD store.
        const std::vector<int32_t> &cohort_rows = pod_rows;
        const auto build_pod = [&](const std::vector<int32_t> &rows) {
            std::vector<RuntimeEconomyPodCommand> packets;
            packets.reserve(rows.size());
            for (const int32_t i : rows) {
                const MilitaryEconomyCommand &c = commands[static_cast<size_t>(i)];
                // A paid purchase must keep its STABLE request identity as the
                // POD request id: Economy answers the fill under that sequence
                // and the bridge matches the receipt back on `row.sequence`. A
                // fresh counter here would execute the buy and lose the receipt
                // (design D6). Every other row keeps the bridge counter.
                const bool stable_identity =
                    c.opcode == EconomyApi::COMMAND_MILITARY_PURCHASE && c.sequence > 0;
                auto &packet = packets.emplace_back();
                packet.request_id = stable_identity ? static_cast<uint64_t>(c.sequence)
                    : _military_pod_request++;
                packet.opcode = c.opcode;
                packet.target_cohort = c.target_handle;
                switch (c.opcode) {
                case EconomyApi::COMMAND_MILITARY_PURCHASE:
                    // payload0 = qty (GOODS_SCALE), payload1 = cash ceiling
                    // (MONEY_SCALE), target_country = good, target_cell = market
                    // cell, target_cohort = payer country handle.
                    packet.payload0 = c.i64_0;
                    packet.payload1 = c.i64_1;
                    packet.target_country = c.i32_1;
                    packet.target_cell = c.i32_0;
                    break;
                case EconomyApi::COMMAND_MILITARY_PROCUREMENT_DEMAND:
                    packet.payload0 = c.i64_0;
                    packet.payload1 = c.i64_1;
                    packet.target_country = c.i32_1;
                    packet.target_cell = c.i32_0;
                    break;
                case MECONOMY_CONVERT_COHORT:
                    packet.payload0 = c.i64_0;        // heads
                    packet.payload1 = c.i32_1;        // source signature
                    packet.target_country = c.i64_1;        // destination signature
                    packet.target_cell = c.i32_0;     // cell
                    break;
                case MECONOMY_ARMY_EMBARK:
                case MECONOMY_ARMY_DISEMBARK:
                    packet.payload0 = c.i64_0;        // heads
                    packet.payload1 = c.i64_1;        // payload1 (unused for 30/31)
                    packet.target_country = c.i32_1;        // soldier signature for the cell
                    packet.target_cell = c.i32_0;     // source / destination cell
                    break;
                case MECONOMY_ARMY_MERGE_LANES:
                    packet.payload0 = c.i64_0;        // heads folded (informational)
                    packet.payload1 = c.i64_1;        // destination army handle
                    packet.target_country = -1;
                    packet.target_cell = c.i32_0;
                    break;
                case MECONOMY_ARMY_SPLIT_LANES:
                    packet.payload0 = c.i64_0;        // heads actually moved
                    packet.payload1 = c.i64_1;        // destination army handle
                    packet.target_country = -1;
                    packet.target_cell = c.i32_0;
                    break;
                case MECONOMY_ARMY_LANE_PAY:
                    // Army pay (contract §3): payload0 = amount, payload1 =
                    // country handle (the payer), target_cohort = army handle,
                    // target_country unused. Treasury cash only, no cohort.
                    packet.payload0 = c.i64_0;        // MONEY_SCALE amount
                    packet.payload1 = c.i64_1;        // country handle
                    packet.target_country = -1;
                    packet.target_cell = c.i32_0;
                    break;
                default:
                    // ADD_POPULATION: signed population delta.
                    packet.payload0 = c.i64_0;
                    packet.payload1 = -1;
                    packet.target_country = -1;
                    packet.target_cell = c.i32_0;
                    break;
                }
            }
            for (const auto &packet : packets)
                if (packet.request_id == 0) {
                    error = "military_economy_request_identity_exhausted";
                    return false;
                }
            // Admission failure is per request, including capacity rejection.
            // Retain earlier accepted rows when a later row is rejected.
            for (size_t k = 0; k < packets.size(); ++k) {
                const auto &packet = packets[k];
                const auto &command = commands[rows[k]];
                const bool tracked = _runtime_host->submit_economy_pod_command(packet, error);
                const auto *terminal = _runtime_host->economy_pod_terminal(packet.request_id);
                if (tracked && (!terminal || terminal->code == RuntimeEconomyCommandReceiptCode::Committed))
                    continue;
                for (auto &row : pending) {
                    if ((row.authority == 2 || row.authority == 4) && row.sequence == command.sequence) {
                        row.receipt_pending = 3;
                        break;
                    }
                }
            }
            return true;
        };
        if (cohort_rows.empty() && lane_rows.empty()) {
            error = "military_economy_ingress_closed";
            for (MilitaryPendingIntent &row : pending)
                if (row.authority == 2) row.receipt_pending = 0;
            return false;
        }
        if (!cohort_rows.empty()) {
            if (!build_pod(cohort_rows)) {
                for (MilitaryPendingIntent &row : pending)
                    if (row.authority == 2) row.receipt_pending = 0;
                return false;
            }
        }
        if (!lane_rows.empty()) {
            if (!build_pod(lane_rows)) {
                // Degrade, do not poison the day: only the lane rows are lost and
                // they report back as failed receipts, so Military books the army
                // lots without a lane and the pre-lane model still runs.
                for (MilitaryPendingIntent &row : pending) {
                    if (row.authority != 2) continue;
                    for (const int32_t i : lane_rows) {
                        if (commands[static_cast<size_t>(i)].sequence != row.sequence) continue;
                        row.receipt_pending = 0;
                        break;
                    }
                }
            }
        }
        for (MilitaryPendingIntent &row : pending) {
            if (row.authority != 2) continue;
            bool carried = false;
            const std::vector<int32_t> *groups[2] = {&cohort_rows, &lane_rows};
            for (const std::vector<int32_t> *rows : groups) {
                for (const int32_t i : *rows) {
                    if (commands[static_cast<size_t>(i)].sequence == row.sequence) {
                        carried = true;
                        break;
                    }
                }
                if (carried) break;
            }
            if (!carried) row.receipt_pending = 0;
        }
        return true;
    }
    return true;
}
