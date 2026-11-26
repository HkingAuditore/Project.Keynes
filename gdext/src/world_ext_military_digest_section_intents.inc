void NativeMilitaryRuntime::translate_military_intent(const MilitaryIntent &intent,
                                           int64_t effective_day,
                                           const MilitaryWorldDigest &digest,
                                           std::vector<MilitaryCountryCommand> &country,
                                           std::vector<MilitaryEconomyCommand> &economy,
                                           std::vector<MilitaryPendingIntent> &pending,
                                           int32_t &unsequenced) {
    (void)digest;
    (void)unsequenced;
    MilitaryPendingIntent row;
    row.kind = intent.kind;
    row.cell = intent.cell;
    row.good = intent.good;
    row.source_id = intent.source_id;
    row.country_handle = intent.country_a;
    row.count = intent.count;
    row.amount = intent.amount;
    row.effective_day = effective_day;
    const auto next_sequence = [this]() { return ++_military_sequence; };
    NativeEconomyRuntime *economy_runtime = _economy_runtime == nullptr ? nullptr
        : static_cast<NativeEconomyRuntime *>(_economy_runtime);
    const int32_t soldier_profession = economy_runtime == nullptr ? -1
        : economy_api::military_soldier_profession(*economy_runtime);
    const int32_t unemployed_profession = economy_runtime == nullptr ? -1
        : economy_api::military_unemployed_profession(*economy_runtime);
    // LEVY draws from the cell's non-merchant employee cohorts once the
    // unemployed pool is exhausted (design 5.4), so it must not reuse the
    // ENLIST source. The candidate list is built from the province catalog
    // (dense profession ids), never from a cohort scan.
    std::vector<int32_t> levy_professions;
    if (intent.kind == MILITARY_INTENT_LEVY && economy_runtime != nullptr) {
        const int32_t count = economy_api::profession_count(*economy_runtime);
        levy_professions.reserve(static_cast<size_t>(std::max(0, count)));
        for (int32_t profession = 0; profession < count; ++profession) {
            if (profession == soldier_profession || profession == unemployed_profession ||
                profession == economy_api::military_merchant_profession(*economy_runtime))
                continue;
            levy_professions.push_back(profession);
        }
    }

    switch (intent.kind) {
    case MILITARY_INTENT_ENLIST:
    case MILITARY_INTENT_LEVY:
    case MILITARY_INTENT_DISCHARGE:
    case MILITARY_INTENT_CASUALTY: {
        // All four are cohort transitions on the cell's soldier cohort
        // (contract §0.5).
        if (economy_runtime == nullptr || intent.cell < 0) return;
        const int64_t heads = std::max<int64_t>(0, intent.count);
        if (heads == 0) return;
        uint64_t handle = 0;
        int32_t target_signature = -1;
        switch (intent.kind) {
        case MILITARY_INTENT_ENLIST: {
            // unemployed -> soldier: the source is the cell's unemployed cohort
            // (lowest ethnicity that still has people).
            handle = economy_api::military_cohort_handle_any_ethnicity(*economy_runtime,
                intent.cell, unemployed_profession);
            target_signature = soldier_profession;
            if (handle == 0) {
                // No unemployed pool in the cell: the enlist cannot be
                // conserved, so it is reported back as a failed receipt instead
                // of being silently dropped.
                row.receipt_pending = 0;
                pending.push_back(row);
                return;
            }
            break;
        }
        case MILITARY_INTENT_LEVY: {
            // Forced service: unemployed first, then any other cohort the
            // state may draft (employee lanes of the same cell).
            handle = economy_api::military_cohort_handle_any_ethnicity(*economy_runtime,
                intent.cell, unemployed_profession);
            if (handle == 0) {
                handle = economy_api::military_cohort_handle_from_professions(*economy_runtime,
                    intent.cell, levy_professions.data(),
                    static_cast<int32_t>(levy_professions.size()));
            }
            target_signature = soldier_profession;
            if (handle == 0) {
                // Nothing left that may be drafted.
                row.receipt_pending = 0;
                pending.push_back(row);
                return;
            }
            break;
        }
        case MILITARY_INTENT_DISCHARGE:
            handle = economy_api::military_cohort_handle_any_ethnicity(*economy_runtime,
                intent.cell, soldier_profession);
            target_signature = unemployed_profession;
            break;
        default:
            // CASUALTY: negative population on the soldier cohort.
            handle = economy_api::military_cohort_handle_any_ethnicity(*economy_runtime,
                intent.cell, soldier_profession);
            target_signature = -1;
            break;
        }
        if (handle == 0) return;
        // CHANGE_SIGNATURE names a SIGNATURE id, not a profession id, and the
        // cohort keeps its ethnicity through the transition: resolve
        // (target_profession, source ethnicity) explicitly instead of relying on
        // the dense profession row and the signature row sharing an index.
        if (target_signature >= 0 && intent.kind != MILITARY_INTENT_CASUALTY) {
            const int32_t ethnicity = economy_api::military_cohort_ethnicity(*economy_runtime,
                static_cast<uint64_t>(handle));
            // Resolve with the ECONOMY runtime's own table for this cell: the
            // bridge's profession id and the executor's signature id are not
            // guaranteed to line up, and a mismatch silently moves people into
            // another profession (unemployed drains, soldier cohort stays 0).
            int32_t resolved = economy_api::military_signature_for_cell_ethnicity(*economy_runtime,
                intent.cell, target_signature);
            if (resolved < 0 && ethnicity >= 0)
                resolved = economy_api::military_signature_for(*economy_runtime, target_signature, ethnicity);
            if (resolved < 0) {
                row.receipt_pending = 0;
                pending.push_back(row);
                return;
            }
            target_signature = resolved;
        }
        MilitaryEconomyCommand command;
        command.effective_day = effective_day;
        command.sequence = next_sequence();
        command.target_handle = static_cast<int64_t>(handle);
        if (intent.kind == MILITARY_INTENT_CASUALTY) {
            // The dead cannot be more than the cell's live soldier cohort.
            const int64_t alive = economy_api::military_soldier_heads(*economy_runtime, intent.cell);
            const int64_t dead = std::min(heads, alive);
            if (dead <= 0) {
                row.receipt_pending = 0;
                pending.push_back(row);
                return;
            }
            command.opcode = MECONOMY_ADD_POPULATION;
            command.i64_0 = -dead;
            command.i32_0 = intent.cell;
            row.count = dead;
        } else {
            if (target_signature < 0) return;
            // B: name the cohorts by signature, never by slot id. Economy
            // resolves both inside whichever store owns the day and moves the
            // people there, so this works under whole-graph ACTIVE without
            // reopening the legacy ingress.
            const int32_t source_signature =
                economy_api::military_cohort_signature(*economy_runtime, static_cast<uint64_t>(handle));
            command.opcode = MECONOMY_CONVERT_COHORT;
            row.count = heads;
            command.i32_0 = intent.cell;
            command.i32_1 = source_signature;
            command.i64_0 = heads;
            command.i64_1 = target_signature;
        }
        row.authority = 2;
        row.sequence = command.sequence;
        row.receipt_pending = 1;
        row.opcode = command.opcode;
        row.target_handle = command.target_handle;
        row.target_signature = command.opcode == MECONOMY_CHANGE_SIGNATURE ? command.i32_0 : -1;
        pending.push_back(row);
        economy.push_back(command);
        return;
    }
    case MILITARY_INTENT_PAY_WAGES: {
        if (economy_runtime == nullptr || intent.cell < 0 || intent.amount <= 0) return;
        const uint64_t handle = economy_api::military_cohort_handle_any_ethnicity(*economy_runtime,
            intent.cell, soldier_profession);
        if (handle == 0) return;
        MilitaryEconomyCommand command;
        command.opcode = MECONOMY_TRANSFER_TO_COHORT;
        command.effective_day = effective_day;
        command.sequence = next_sequence();
        command.target_handle = static_cast<int64_t>(handle);
        command.i64_0 = intent.amount;
        command.i64_1 = static_cast<int64_t>(intent.country_a);
        command.i32_0 = intent.cell;
        row.authority = 2;
        row.sequence = command.sequence;
        row.receipt_pending = 1;
        row.opcode = command.opcode;
        row.target_handle = command.target_handle;
        pending.push_back(row);
        economy.push_back(command);
        return;
    }
    case MILITARY_INTENT_PROCUREMENT_DEMAND:
    case MILITARY_INTENT_PROCURE_GOOD: {
        const bool forecast = intent.kind == MILITARY_INTENT_PROCUREMENT_DEMAND;
        if (economy_runtime == nullptr || (!forecast && (intent.cell < 0 ||
            intent.good < 0 || intent.count <= 0 || intent.country_a == 0))) return;
        MilitaryEconomyCommand command;
        command.opcode = forecast ? EconomyApi::COMMAND_MILITARY_PROCUREMENT_DEMAND : EconomyApi::COMMAND_MILITARY_PURCHASE;
        command.effective_day = effective_day;
        // A paid purchase carries the core's STABLE request id in `source_id`
        // (physical-maintenance design D6). Reusing it as the economy sequence
        // makes the identity survive a save/restore and lets Economy answer a
        // repeated submission with the same receipt instead of buying twice;
        // the forecast row has no such identity and keeps the bridge counter.
        // The offset keeps purchase identities in their own numeric range: the
        // bridge counter also starts at 1 and Economy keys POD admission and
        // receipt rows on `sequence` alone, so the two must never collide.
        command.sequence = (!forecast && intent.source_id > 0)
                               ? (kMilitaryPurchaseSequenceBase + static_cast<int64_t>(intent.source_id))
                               : next_sequence();
        command.target_handle = static_cast<int64_t>(intent.country_a);
        command.i32_0 = intent.cell;
        command.i32_1 = intent.good;
        command.i64_0 = intent.count;
        command.i64_1 = intent.amount;
        if (!forecast) { // Paid purchases require a real terminal; never optimistic.
            row.authority = 4;
            row.sequence = command.sequence;
            row.receipt_pending = 1;
            row.opcode = command.opcode;
            row.target_handle = command.target_handle;
            pending.push_back(row);
        }
        economy.push_back(command);
        return;
    }
    case MILITARY_INTENT_CONSUME_TREASURY_GOOD: {
        if (intent.country_a == 0 || intent.good < 0 || intent.count <= 0) return;
        MilitaryCountryCommand command;
        command.opcode = MCOUNTRY_CONSUME_TREASURY_GOODS;
        command.effective_day = effective_day;
        command.sequence = next_sequence();
        command.target_handle = static_cast<int64_t>(intent.country_a);
        command.aux = intent.good;
        command.value = intent.count;
        row.authority = 1;
        row.sequence = command.sequence;
        row.receipt_pending = 1;
        pending.push_back(row);
        country.push_back(command);
        return;
    }
    case MILITARY_INTENT_REQUISITION: {
        // Explicit market stock delta, no payment (COMMAND_REMOVE_STOCK).
        if (economy_runtime == nullptr || intent.cell < 0 || intent.good < 0 ||
            intent.count <= 0)
            return;
        MilitaryEconomyCommand command;
        command.opcode = MECONOMY_REMOVE_STOCK;
        command.effective_day = effective_day;
        command.sequence = next_sequence();
        command.target_handle = 0;
        command.i32_0 = intent.cell;
        command.i32_1 = intent.good;
        command.i64_0 = std::max<int64_t>(0, intent.count);
        row.authority = 2;
        row.sequence = command.sequence;
        row.receipt_pending = 1;
        row.opcode = command.opcode;
        row.target_handle = 0;
        pending.push_back(row);
        economy.push_back(command);
        return;
    }
    case MILITARY_INTENT_SPEND_CASH: {
        // Military upkeep / building cash. Country has no "debit cash" opcode,
        // so this retains the cash-neutral fiscal reserve/collect adapter. It is
        // deferred to D+1 (apply_military_deferred_cash at the start of the
        // next military day) so it reads the same committed treasury the rest
        // of the D+1 batch does; the receipt carries the collected amount, and
        // a shortfall reports the smaller committed_amount.
        if (economy_runtime == nullptr || intent.country_a == 0 || intent.amount <= 0) return;
        row.authority = 3;
        row.receipt_pending = 1;
        row.sequence = next_sequence();
        pending.push_back(row);
        return;
    }
    case MILITARY_INTENT_STATE_BUILD: {
        // A state building request (see MILITARY_INTENT_STATE_BUILD in
        // military_bridge.h). This is the only settlement path for a state lot:
        // the economy charges the treasury for the real materials and, only
        // when it accepted the order, the core gets the bookkeeping command
        // that schedules the completion day.
        if (economy_runtime == nullptr || intent.country_a == 0 ||
            intent.cell < 0 || intent.count <= 0)
            return;
        MilitaryCore *core = &this->core();
        const int32_t building = static_cast<int32_t>(intent.count);
        if (building >= static_cast<int32_t>(core->_catalog.state_buildings.size()))
            return;
        const int32_t economy_type = core->_catalog.state_buildings[
            static_cast<size_t>(building)].economy_building_id;
        // A catalog compiled before this bridge leaves the column at -1: those
        // lots have no economy profile, therefore no bill, therefore they are
        // not built at all instead of being built for free.
        if (economy_type < 0) return;
        const Dictionary queued = economy_api::queue_treasury_sponsored_build(*economy_runtime,
            static_cast<int64_t>(intent.country_a), intent.cell, economy_type,
            effective_day, next_sequence(), false);
        if (!bool(queued.get("ok", false))) return;
        // The economy owns the schedule; the core only mirrors it. Feeding the
        // accepted lot back through the ordinary command queue keeps the
        // pending construction slots and the completion day on one code path.
        MilitaryCommand command;
        command.op = MCMD_STATE_BUILD;
        command.country = intent.country_a;
        command.cell = intent.cell;
        command.unit_to = building;
        command.effective_day = effective_day;
        command.sequence = static_cast<uint64_t>(next_sequence());
        std::string command_error;
        core->submit(std::move(command), command_error);
        // Deliberately no `pending` row: this branch already holds the economy's
        // synchronous accept/reject, so there is nothing left to await, and the
        // core's receipt fold has no case for this kind. Pushing an authority=2
        // row here would sit unresolved until the receipt timeout and then emit
        // a failure the core ignores anyway.
        return;
    }
    case MILITARY_INTENT_STATE_DEMOLISH: {
        // The mirror of STATE_BUILD on the removal side. The economy drops the
        // unit from the ledger row first and only an accepted removal is echoed
        // back as MCMD_STATE_DEMOLISH, so the ledger is always the first to
        // change and the core can never report a demolition the ledger did not
        // record (requirement 6.5). `count` carries the state building index,
        // exactly like STATE_BUILD; one unit per request.
        if (economy_runtime == nullptr || intent.country_a == 0 ||
            intent.cell < 0 || intent.count <= 0)
            return;
        MilitaryCore *core = &this->core();
        const int32_t building = static_cast<int32_t>(intent.count);
        if (building >= static_cast<int32_t>(core->_catalog.state_buildings.size()))
            return;
        const int32_t economy_type = core->_catalog.state_buildings[
            static_cast<size_t>(building)].economy_building_id;
        // A catalog compiled before this bridge leaves the column at -1: the lot
        // has no economy profile, so it is not in the ledger and there is
        // nothing that could remove it.
        if (economy_type < 0) return;
        const Dictionary queued = economy_api::queue_treasury_sponsored_demolish(*economy_runtime,
            static_cast<int64_t>(intent.country_a), intent.cell, economy_type, 1,
            effective_day, next_sequence(), false);
        if (!bool(queued.get("ok", false))) return;
        MilitaryCommand command;
        command.op = MCMD_STATE_DEMOLISH;
        command.country = intent.country_a;
        command.cell = intent.cell;
        command.unit_to = building;
        command.effective_day = effective_day;
        command.sequence = static_cast<uint64_t>(next_sequence());
        std::string command_error;
        core->submit(std::move(command), command_error);
        // No `pending` row: the economy's accept/reject above is synchronous.
        return;
    }
    case MILITARY_INTENT_ARMY_EMBARK:
    case MILITARY_INTENT_ARMY_DISEMBARK: {
        // Army personnel lane (army-personnel contract §1.2, opcode 30/31).
        // The lane row is named by ARMY HANDLE (target_cohort) and the cohort by
        // (cell, signature) — never by slot id, same rule as opcode 24. Economy
        // resolves the soldier|ethnicity signature itself; the bridge only offers
        // the signature it can see for the cell, and -1 means "you decide".
        if (economy_runtime == nullptr || intent.cell < 0 || intent.source_id == 0) return;
        const int64_t heads = std::max<int64_t>(0, intent.count);
        if (heads == 0) return;
        int32_t signature = -1;
        if (soldier_profession >= 0) {
            signature = economy_api::military_signature_for_cell_ethnicity(*economy_runtime,
                intent.cell, soldier_profession);
        }
        MilitaryEconomyCommand command;
        command.opcode = intent.kind == MILITARY_INTENT_ARMY_EMBARK
            ? MECONOMY_ARMY_EMBARK : MECONOMY_ARMY_DISEMBARK;
        command.effective_day = effective_day;
        command.sequence = next_sequence();
        command.target_handle = static_cast<int64_t>(intent.source_id);  // army handle
        command.i32_0 = intent.cell;
        command.i32_1 = signature;
        command.i64_0 = heads;
        command.i64_1 = 0;
        row.authority = 2;
        row.sequence = command.sequence;
        row.receipt_pending = 1;
        row.opcode = command.opcode;
        row.target_handle = command.target_handle;
        pending.push_back(row);
        economy.push_back(command);
        return;
    }
    case MILITARY_INTENT_ARMY_MERGE_LANES: {
        // Opcode 32: fold the source lane into the destination lane. payload1
        // carries the destination army handle; the source is target_cohort.
        if (economy_runtime == nullptr || intent.country_a == 0 || intent.country_b == 0) return;
        MilitaryEconomyCommand command;
        command.opcode = MECONOMY_ARMY_MERGE_LANES;
        command.effective_day = effective_day;
        command.sequence = next_sequence();
        command.target_handle = static_cast<int64_t>(intent.country_a);   // source lane
        command.i64_0 = std::max<int64_t>(0, intent.count);
        command.i64_1 = static_cast<int64_t>(intent.country_b);           // destination
        command.i32_0 = intent.cell;
        command.i32_1 = -1;
        row.authority = 2;
        row.sequence = command.sequence;
        row.receipt_pending = 1;
        row.opcode = command.opcode;
        row.target_handle = command.target_handle;
        pending.push_back(row);
        economy.push_back(command);
        return;
    }
    case MILITARY_INTENT_ARMY_SPLIT_LANES: {
        // Opcode 33 (contract-2 §1.1/§1.2): move the heads a split / partial
        // transfer actually moved from the source formation's lane into the
        // destination formation's lane. payload0 = heads, payload1 = destination
        // army handle, target_cohort = source army handle — the same key layout
        // as 32, and lane -> lane names no cohort, so no signature is needed.
        if (intent.country_a == 0 || intent.country_b == 0 ||
            intent.country_a == intent.country_b)
            return;
        const int64_t heads = std::max<int64_t>(0, intent.count);
        if (heads == 0) return;
        if (economy_runtime == nullptr) return;
        if (!army_lane_split_supported(economy_runtime)) {
            // Feature detection (contract-2 §1.1): this Economy build does not
            // implement opcode 33. Emitting the row anyway would be rejected as an
            // unknown opcode and could take the whole batch down. Report it as a
            // failed receipt instead — a no-op command plus one pending row
            // failure, never a crash — and Military stays on the pre-split-lane
            // model (the lots have already moved, so only the lane bookkeeping is
            // skipped).
            row.authority = 2;
            row.receipt_pending = 0;
            row.opcode = MECONOMY_ARMY_SPLIT_LANES;
            row.target_handle = static_cast<int64_t>(intent.country_a);
            pending.push_back(row);
            return;
        }
        MilitaryEconomyCommand command;
        command.opcode = MECONOMY_ARMY_SPLIT_LANES;
        command.effective_day = effective_day;
        command.sequence = next_sequence();
        command.target_handle = static_cast<int64_t>(intent.country_a);   // source lane
        command.i64_0 = heads;                                            // heads moved
        command.i64_1 = static_cast<int64_t>(intent.country_b);           // destination
        command.i32_0 = intent.cell;
        // Unused by opcode 33 (lane -> lane), but 0 rather than -1 so the legacy
        // settlement fold (`expected_i1 == 0` for this opcode) can match the row
        // and settle it instead of letting it time out.
        command.i32_1 = 0;
        row.authority = 2;
        row.sequence = command.sequence;
        row.receipt_pending = 1;
        row.opcode = command.opcode;
        row.target_handle = command.target_handle;
        pending.push_back(row);
        economy.push_back(command);
        return;
    }
    case MILITARY_INTENT_ARMY_PAY: {
        // Opcode 34 (army-pay contract §3): the wages of the heads that march
        // with the formation, paid into its lane from the treasury.
        //   payload0 = amount (MONEY_SCALE), payload1 = country handle,
        //   target_cohort = army handle (the lane key 30-33 already use).
        // No cohort is named and no structural command is involved, so the row
        // rides the same POD lane as 24/30-33 and is deduplicated there by
        // `sequence`.
        //
        // The receipt needs the PRE-PAYMENT lane balance, because the only
        // truth Economy can report afterwards is the new balance and a lane also
        // spends cash on guest consumption the same day. `row.count` carries
        // that base value: the fold reads military_army_funds(handle) and books
        // max(0, now - prev) clamped to the amount requested.
        if (intent.source_id == 0 || intent.country_a == 0 || intent.amount <= 0)
            return;
        if (economy_runtime == nullptr) return;
        if (!army_lane_pay_supported(economy_runtime)) {
            // Feature detection (contract §3.3): this Economy build has no
            // opcode 34. Emitting the row anyway would be an unknown opcode at
            // admission; report a failed receipt instead — a no-op command plus
            // one failed pending row, never a crash — and Military keeps the
            // pre-army-pay model (the formation's people are simply not paid
            // through the lane this day).
            row.authority = 2;
            row.receipt_pending = 0;
            row.opcode = MECONOMY_ARMY_LANE_PAY;
            row.target_handle = static_cast<int64_t>(intent.source_id);
            pending.push_back(row);
            return;
        }
        MilitaryEconomyCommand command;
        command.opcode = MECONOMY_ARMY_LANE_PAY;
        command.effective_day = effective_day;
        command.sequence = next_sequence();
        command.target_handle = static_cast<int64_t>(intent.source_id);  // army handle
        command.i64_0 = intent.amount;                                   // MONEY_SCALE
        command.i64_1 = static_cast<int64_t>(intent.country_a);           // payer
        // Unused by opcode 34 (the lane knows its own cell), but 0 rather than
        // -1 so the settlement fold can match the row and settle it.
        command.i32_0 = intent.cell;
        command.i32_1 = 0;
        row.authority = 2;
        row.sequence = command.sequence;
        row.receipt_pending = 1;
        row.opcode = command.opcode;
        row.target_handle = command.target_handle;
        // Base value for the receipt: the lane's cash before this payment.
        // Economy answers 0 for a lane that does not exist yet, which is also
        // the correct base (a new lane starts empty), so the read is unconditional.
        row.count = economy_api::military_army_funds(*economy_runtime,
            static_cast<uint64_t>(intent.source_id));
        row.amount = intent.amount;
        pending.push_back(row);
        economy.push_back(command);
        return;
    }
    case MILITARY_INTENT_TRANSFER_TERRITORY: {
        if (intent.cell < 0 || intent.country_b == 0) return;
        MilitaryCountryCommand command;
        command.opcode = MCOUNTRY_TRANSFER_TERRITORY;
        command.effective_day = effective_day;
        command.sequence = next_sequence();
        command.target_handle = static_cast<int64_t>(intent.country_b);
        command.cell = intent.cell;
        row.authority = 1;
        row.sequence = command.sequence;
        row.receipt_pending = 1;
        pending.push_back(row);
        country.push_back(command);
        return;
    }
    case MILITARY_INTENT_TRANSFER_CASH: {
        // Opcode 23: target_handle = payer, cell/aux = receiver slot/generation
        // (contract §0.4), value = MONEY_SCALE.
        if (intent.country_a == 0 || intent.country_b == 0 || intent.amount <= 0) return;
        MilitaryCountryCommand command;
        command.opcode = MCOUNTRY_TRANSFER_CASH;
        command.effective_day = effective_day;
        command.sequence = next_sequence();
        command.target_handle = static_cast<int64_t>(intent.country_a);
        command.cell = static_cast<int32_t>(intent.country_b & 0xFFFFFFFFull);
        command.aux = static_cast<int32_t>(intent.country_b >> 32u);
        command.value = intent.amount;
        row.authority = 1;
        row.sequence = command.sequence;
        row.receipt_pending = 1;
        pending.push_back(row);
        country.push_back(command);
        return;
    }
    case MILITARY_INTENT_TRANSFER_GOODS: {
        // Opcode 24: same receiver encoding, domain = dense good.
        if (intent.country_a == 0 || intent.country_b == 0 || intent.good < 0 ||
            intent.count <= 0)
            return;
        MilitaryCountryCommand command;
        command.opcode = MCOUNTRY_TRANSFER_GOODS;
        command.effective_day = effective_day;
        command.sequence = next_sequence();
        command.target_handle = static_cast<int64_t>(intent.country_a);
        command.cell = static_cast<int32_t>(intent.country_b & 0xFFFFFFFFull);
        command.aux = static_cast<int32_t>(intent.country_b >> 32u);
        command.domain = intent.good;
        command.value = intent.count;
        row.authority = 1;
        row.sequence = command.sequence;
        row.receipt_pending = 1;
        pending.push_back(row);
        country.push_back(command);
        return;
    }
    case MILITARY_INTENT_ANNEX_COUNTRY: {
        // Opcode 27: target_handle = victim, cell/aux = annexer slot/generation.
        if (intent.country_a == 0 || intent.country_b == 0) return;
        MilitaryCountryCommand command;
        command.opcode = MCOUNTRY_ANNEX;
        command.effective_day = effective_day;
        command.sequence = next_sequence();
        command.target_handle = static_cast<int64_t>(intent.country_a);
        command.cell = static_cast<int32_t>(intent.country_b & 0xFFFFFFFFull);
        command.aux = static_cast<int32_t>(intent.country_b >> 32u);
        row.authority = 1;
        row.sequence = command.sequence;
        row.receipt_pending = 1;
        pending.push_back(row);
        country.push_back(command);
        return;
    }
    default:
        return;
    }
}
