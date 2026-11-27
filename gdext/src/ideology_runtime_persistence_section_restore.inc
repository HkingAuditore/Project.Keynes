Dictionary NativeIdeologyRuntime::restore(const PackedByteArray &packed) {
    if (!_configured) return fail("ideology_runtime_unconfigured");
    const uint8_t *data = packed.ptr(); const size_t size = packed.size(); size_t cursor = 0;
    uint32_t magic = 0, end = 0; int32_t schema = 0; uint64_t catalog_hash = 0, state_hash = 0;
    uint64_t submit_order = 0, country_count = 0, command_count = 0; int64_t last_day = -1;
    if (!read_le(data, size, cursor, magic) || !read_le(data, size, cursor, schema) ||
            !read_le(data, size, cursor, catalog_hash) || !read_le(data, size, cursor, last_day) ||
            !read_le(data, size, cursor, submit_order) || !read_le(data, size, cursor, state_hash) ||
            magic != SAVE_MAGIC) return fail("ideology_save_header_invalid");
    // PKID v4 (increment-only points, ledger, per-country slot capacity) is
    // fail-closed: earlier schemas are rejected instead of migrated.
    if (schema != SAVE_SCHEMA_VERSION) return fail("ideology_save_schema_unsupported");
    if (catalog_hash != _catalog_hash) return fail("ideology_save_catalog_mismatch");
    std::unordered_map<int32_t, int64_t> producer_high_watermarks;
    if (schema >= 3) {
        uint64_t high_watermark_count = 0;
        if (!read_le(data, size, cursor, high_watermark_count) ||
                high_watermark_count > 65536)
            return fail("ideology_save_producer_count_invalid");
        for (uint64_t i = 0; i < high_watermark_count; ++i) {
            int32_t producer_id = 0;
            int64_t sequence = -1;
            if (!read_le(data, size, cursor, producer_id) ||
                    !read_le(data, size, cursor, sequence) ||
                    producer_id <= 0 || sequence < 0 ||
                    !producer_high_watermarks.emplace(
                        producer_id, sequence).second)
                return fail("ideology_save_producer_invalid");
        }
    }
    uint64_t points_revision_seen = 0;
    uint8_t worker_origin = 0;
    if (!read_le(data, size, cursor, points_revision_seen) ||
            !read_le(data, size, cursor, worker_origin) || worker_origin > 1)
        return fail("ideology_save_points_header_invalid");
    if (!read_le(data, size, cursor, country_count) || country_count > 1000000) return fail("ideology_save_country_count_invalid");
    std::vector<CountryState> countries(static_cast<size_t>(country_count));
    for (CountryState &country : countries) {
        if (!read_le(data, size, cursor, country.handle) || !read_le(data, size, cursor, country.ideology_points_q16) ||
                !read_le(data, size, cursor, country.unlocked_era) ||
                !read_le(data, size, cursor, country.rng_state) || !read_le(data, size, cursor, country.draw_sequence) ||
                !read_le(data, size, cursor, country.free_draws) ||
                !read_le(data, size, cursor, country.points_revision) ||
                !read_le(data, size, cursor, country.baseline_ready) ||
                !read_le(data, size, cursor, country.history_count) ||
                !read_le(data, size, cursor, country.history_head) ||
                !read_le(data, size, cursor, country.baseline_population) ||
                !read_le(data, size, cursor, country.baseline_buildings) ||
                !read_le(data, size, cursor, country.lifetime_points_q16) ||
                !read_le(data, size, cursor, country.trade_paid_day) ||
                !read_le(data, size, cursor, country.ledger.population_q16) ||
                !read_le(data, size, cursor, country.ledger.building_q16) ||
                !read_le(data, size, cursor, country.ledger.trade_q16) ||
                !read_le(data, size, cursor, country.ledger.opinion_factor_q16) ||
                !read_le(data, size, cursor, country.ledger.gain_factor_q16) ||
                !read_le(data, size, cursor, country.ledger.gain_q16) ||
                !read_le(data, size, cursor, country.ledger.day))
            return fail("ideology_save_country_invalid");
        for (int64_t &value : country.history_q16)
            if (!read_le(data, size, cursor, value)) return fail("ideology_save_point_history_invalid");
        if (country.baseline_ready > 1 || country.history_count > POINT_HISTORY ||
                country.history_head >= POINT_HISTORY)
            return fail("ideology_save_point_history_invalid");
        if (!read_vec(data, size, cursor, country.known_bits, _idea_words) ||
                !read_vec(data, size, cursor, country.gate_bits, _gate_words) ||
                !read_le(data, size, cursor, country.offer.generation) || !read_le(data, size, cursor, country.offer.active) ||
                !read_le(data, size, cursor, country.offer.choice_count))
            return fail("ideology_save_country_invalid");
        // read_vec only enforces an upper bound. A short gate_bits vector would
        // make gate() read past the end, so the length has to match exactly.
        // banned_bits is validated where it is read, not here: it appears later
        // in the stream, so a size check at this point would compare against an
        // empty vector and reject every save.
        if (country.known_bits.size() != static_cast<size_t>(_idea_words) ||
                country.gate_bits.size() != static_cast<size_t>(_gate_words) ||
                country.unlocked_era < 0 || country.unlocked_era > MAX_ERA_INDEX ||
                country.offer.active > 1 ||
                country.offer.choice_count > OFFER_CHOICE_CAPACITY)
            return fail("ideology_save_country_invalid");
        for (int32_t &ideology_id : country.offer.ideology_ids)
            if (!read_le(data, size, cursor, ideology_id)) return fail("ideology_save_offer_invalid");
        // banned_bits follows the offer row, matching append order exactly. It is
        // NOT next to known_bits in the stream even though the two are siblings
        // conceptually -- the write site sits inside the offer block, and a
        // reader that assumes otherwise silently shifts every later field.
        if (!read_vec(data, size, cursor, country.banned_bits, _idea_words) ||
                country.banned_bits.size() != static_cast<size_t>(_idea_words))
            return fail("ideology_save_ban_invalid");
        uint64_t idea_count = 0;
        if (!read_le(data, size, cursor, idea_count) || idea_count > _definitions.size()) return fail("ideology_save_idea_count_invalid");
        for (uint64_t n = 0; n < idea_count; ++n) {
            IdeaState state; uint64_t transition_count = 0;
            if (!read_le(data, size, cursor, state.ideology_id) || !read_le(data, size, cursor, state.understanding_q16) ||
                    !read_le(data, size, cursor, state.level) || !read_le(data, size, cursor, state.entered_levels) ||
                    !read_le(data, size, cursor, state.generation) || !read_le(data, size, cursor, state.location) ||
                    (schema >= 9 && !read_le(data, size, cursor, state.slot_index)) ||
                    (schema >= 2 && (!read_le(data, size, cursor, state.binding_id) ||
                        !read_le(data, size, cursor, state.binding_generation) ||
                        !read_le(data, size, cursor, state.binding_signature) ||
                        !read_le(data, size, cursor, state.binding_program_hash))) ||
                    !read_le(data, size, cursor, state.transition.active) ||
                    (schema >= 3 && (!read_le(data, size, cursor,
                        state.transition.producer_id) ||
                        !read_le(data, size, cursor,
                            state.transition.command_sequence) ||
                        !read_le(data, size, cursor,
                            state.transition.command_opcode))) ||
                    !read_le(data, size, cursor, state.transition.previous_level) ||
                    !read_le(data, size, cursor, state.transition.previous_entered_levels) ||
                    !read_le(data, size, cursor, state.transition.previous_generation) ||
                    !read_le(data, size, cursor, state.transition.previous_location) ||
                    (schema >= 9 && !read_le(data, size, cursor,
                        state.transition.previous_slot_index)) ||
                    !read_le(data, size, cursor, state.transition.entered_on_success) ||
                    !read_le(data, size, cursor, transition_count) || transition_count > 4096 ||
                    state.ideology_id < 0 || state.ideology_id >= static_cast<int32_t>(_definitions.size()) ||
                    state.location > NATIONAL_SPIRIT || state.transition.previous_location > NATIONAL_SPIRIT)
                return fail("ideology_save_idea_invalid");
            state.transition.transaction_ids.resize(static_cast<size_t>(transition_count));
            for (int64_t &transaction_id : state.transition.transaction_ids)
                if (!read_le(data, size, cursor, transaction_id) || transaction_id <= 0) return fail("ideology_save_transition_invalid");
            if (schema >= 3) {
                uint64_t changed_synergy_count = 0;
                if (!read_le(data, size, cursor, changed_synergy_count) ||
                        changed_synergy_count > _synergies.size())
                    return fail("ideology_save_synergy_transition_invalid");
                state.transition.changed_synergy_ids.resize(
                    static_cast<size_t>(changed_synergy_count));
                state.transition.previous_synergy_active.resize(
                    static_cast<size_t>(changed_synergy_count));
                for (size_t index = 0;
                        index < static_cast<size_t>(changed_synergy_count);
                        ++index) {
                    if (!read_le(data, size, cursor,
                            state.transition.changed_synergy_ids[index]) ||
                            !read_le(data, size, cursor,
                                state.transition.previous_synergy_active[index]) ||
                            state.transition.changed_synergy_ids[index] < 0 ||
                            state.transition.changed_synergy_ids[index] >=
                                static_cast<int32_t>(_synergies.size()) ||
                            state.transition.previous_synergy_active[index] > 1)
                        return fail(
                            "ideology_save_synergy_transition_invalid");
                }
            }
            if (state.transition.active == 0 && !state.transition.transaction_ids.empty()) return fail("ideology_save_transition_invalid");
            if (schema >= 6) {
                uint64_t effect_instance_count = 0;
                if (!read_le(data, size, cursor, effect_instance_count) ||
                        effect_instance_count > 4096)
                    return fail("ideology_save_effect_instance_count_invalid");
                state.effect_instances.resize(
                    static_cast<size_t>(effect_instance_count));
                for (size_t index = 0;
                        index < static_cast<size_t>(effect_instance_count);
                        ++index) {
                    IdeaState::EffectInstanceRef &ref =
                        state.effect_instances[index];
                    if (!read_le(data, size, cursor, ref.program_hash) ||
                            !read_le(data, size, cursor, ref.target_handle) ||
                            !read_le(data, size, cursor, ref.target_generation) ||
                            !read_le(data, size, cursor, ref.instance_id) ||
                            !read_le(data, size, cursor, ref.generation) ||
                            ref.instance_id <= 0 || ref.generation == 0 ||
                            ref.program_hash == 0)
                        return fail("ideology_save_effect_instance_invalid");
                }
            }
            country.idea_indices[state.ideology_id] = static_cast<int32_t>(country.ideas.size());
            country.ideas.push_back(std::move(state));
        }
        rebuild_country_derived(country);
    }
    if (!read_le(data, size, cursor, command_count) || command_count > 10000000) return fail("ideology_save_command_count_invalid");
    std::vector<Command> commands; commands.reserve(static_cast<size_t>(command_count));
    for (uint64_t n = 0; n < command_count; ++n) {
        Command command;
        if (!read_le(data, size, cursor, command.opcode) || !read_le(data, size, cursor, command.effective_day) ||
                (schema >= 3 && !read_le(data, size, cursor, command.producer_id)) ||
                !read_le(data, size, cursor, command.source_priority) || !read_le(data, size, cursor, command.sequence) ||
                !read_le(data, size, cursor, command.country_handle) || !read_le(data, size, cursor, command.ideology_id) ||
                !read_le(data, size, cursor, command.value_q16) || !read_le(data, size, cursor, command.offer_generation) ||
                !read_le(data, size, cursor, command.choice_index) || !read_le(data, size, cursor, command.gate_id) ||
                !read_le(data, size, cursor, command.submit_order)) return fail("ideology_save_command_invalid");
        std::string error; if (!validate_command_shape(command, error)) return fail(error);
        commands.push_back(command);
    }
    if (!std::is_sorted(commands.begin(), commands.end(), command_less))
        return fail("ideology_save_command_order_invalid");
    DerivedCellFront restored_projection;
    std::vector<DerivedProgramContribution> restored_targets;
    uint32_t projection_marker = 0;
    size_t peek = cursor;
    if (read_le(data, size, peek, projection_marker) &&
        projection_marker == DERIVED_PROJECTION_MARKER &&
        !read_derived_projection(data, size, cursor, restored_projection, restored_targets))
        return fail("ideology_save_truncated");
    // ── plan §18.2: the applied-program basis ─────────────────────────────────
    //
    // Read BEFORE the dates, because that is where it is written: after the command
    // table, self-delimited by its own total byte length.
    std::vector<AppliedProgramBasis> restored_basis;
    {
        const size_t basis_block_begin = cursor;
        uint32_t basis_row_count = 0;
        if (!read_le(data, size, cursor, basis_row_count))
            return fail("ideology_save_truncated");
        // Two bounds: the global cap, and what the remaining bytes could possibly
        // hold (an empty row is 8+4+4+4+4+8 fixed bytes plus two empty strings, so
        // 32 bytes). The second one is what turns a lying count into a SHAPE error
        // instead of a slow truncation deep inside a row read.
        if (basis_row_count > APPLIED_BASIS_ROW_LIMIT ||
                static_cast<uint64_t>(basis_row_count) >
                    (size - cursor) / 32U)
            return fail("ideology_save_applied_basis_invalid");
        restored_basis.reserve(static_cast<size_t>(basis_row_count));
        for (uint32_t index = 0; index < basis_row_count; ++index) {
            AppliedProgramBasis row;
            if (!read_le(data, size, cursor, row.country_handle) ||
                    !read_string(data, size, cursor, row.program_key,
                        APPLIED_BASIS_KEY_LIMIT) ||
                    !read_le(data, size, cursor, row.selector_kind) ||
                    !read_string(data, size, cursor, row.selector_id,
                        APPLIED_BASIS_KEY_LIMIT) ||
                    !read_le(data, size, cursor, row.selector_param[0]) ||
                    !read_le(data, size, cursor, row.selector_param[1]) ||
                    !read_le(data, size, cursor, row.terms_digest))
                return fail("ideology_save_truncated");
            // Shape/pair validation, the same idea as the dates' pair rule above: a
            // row that cannot describe a real program is refused by name instead of
            // being carried into the state hash and a later comparison.
            if (row.country_handle == 0 || row.program_key.empty() ||
                    row.selector_kind < 0 || row.terms_digest == 0)
                return fail("ideology_save_applied_basis_invalid");
            // Strictly ascending (country, program): rejects duplicates and an
            // unsorted block, which is what makes the byte layout a function of the
            // state rather than of iteration order.
            if (!restored_basis.empty()) {
                const AppliedProgramBasis &previous = restored_basis.back();
                const bool ordered = previous.country_handle < row.country_handle ||
                    (previous.country_handle == row.country_handle &&
                     previous.program_key < row.program_key);
                if (!ordered)
                    return fail("ideology_save_applied_basis_invalid");
            }
            restored_basis.push_back(std::move(row));
        }
        // The block's declared length must agree with the bytes actually consumed.
        // Without this a length field could point anywhere and the "addressable from
        // the tail" property would rest on data that is never checked.
        //
        // `basis_rows_end` is taken BEFORE the length field itself is read: the field
        // is not part of the length it declares. Using `cursor` directly after the read
        // counted the field, and the writer/reader disagreed by exactly four bytes --
        // measured: every restore refused a payload this same code had just written.
        const size_t basis_rows_end = cursor;
        uint32_t basis_block_bytes = 0;
        if (!read_le(data, size, cursor, basis_block_bytes))
            return fail("ideology_save_truncated");
        if (basis_block_bytes !=
                static_cast<uint32_t>(basis_rows_end - basis_block_begin))
            return fail("ideology_save_applied_basis_invalid");
    }
    // ── plan §18.2 / §18.5: the LOCAL SCALAR BASIS ────────────────────────────────
    //
    // Read immediately after the applied basis and before the sample day, because
    // that is where it is written: after the command table, self-delimited by its own
    // trailing u32.
    std::vector<LocalScalarValue> restored_scalars;
    {
        const size_t scalar_block_begin = cursor;
        uint32_t scalar_row_count = 0;
        if (!read_le(data, size, cursor, scalar_row_count))
            return fail("ideology_save_truncated");
        // Two bounds again: the global cap, and what the remaining bytes could hold.
        // `LocalScalarValue` is 8 + 4 + 8 = 20 fixed bytes with no variable part, so a
        // count above `(size - cursor) / 20` is a SHAPE error rather than a slow
        // truncation deep inside a row read.
        if (scalar_row_count > LOCAL_SCALAR_ROW_LIMIT ||
                static_cast<uint64_t>(scalar_row_count) >
                    (size - cursor) / 20U)
            return fail("ideology_save_scalar_basis_invalid");
        restored_scalars.reserve(static_cast<size_t>(scalar_row_count));
        for (uint32_t index = 0; index < scalar_row_count; ++index) {
            LocalScalarValue row;
            if (!read_le(data, size, cursor, row.country_handle) ||
                    !read_le(data, size, cursor, row.metric_id) ||
                    !read_le(data, size, cursor, row.value_q16))
                return fail("ideology_save_truncated");
            // Shape: a row must name a country and a real slab slot. `-1` is the
            // builder's own "unresolved key" sentinel, so a payload carrying it cannot
            // have come from a catalog that resolves the scalar keys.
            if (row.country_handle == 0 || row.metric_id < 0)
                return fail("ideology_save_scalar_basis_invalid");
            // Strictly ascending (country, metric): rejects duplicates and an unsorted
            // block, exactly as the applied basis does.
            if (!restored_scalars.empty()) {
                const LocalScalarValue &previous = restored_scalars.back();
                const bool ordered = previous.country_handle < row.country_handle ||
                    (previous.country_handle == row.country_handle &&
                     previous.metric_id < row.metric_id);
                if (!ordered)
                    return fail("ideology_save_scalar_basis_invalid");
            }
            restored_scalars.push_back(row);
        }
        // Same honesty requirement as the block above: the declared length must agree
        // with the bytes actually consumed, and the end is taken BEFORE the length
        // field itself is read (the field is not part of the length it declares).
        const size_t scalar_rows_end = cursor;
        uint32_t scalar_block_bytes = 0;
        if (!read_le(data, size, cursor, scalar_block_bytes))
            return fail("ideology_save_truncated");
        if (scalar_block_bytes !=
                static_cast<uint32_t>(scalar_rows_end - scalar_block_begin))
            return fail("ideology_save_scalar_basis_invalid");
    }
    // §18.5: the sample day the projection was built from. `-1` = nothing projected.
    //
    // The EPOCH ID is deliberately absent from the payload (see the writer's comment):
    // `_derived_epoch_id` is structurally 0, so a field for it would validate nothing.
    // The sample day is the half of the identity that carries information; the
    // execution contract read below pins the rules it was built under.
    int64_t restored_sample_day = -1;
    if (!read_le(data, size, cursor, restored_sample_day))
        return fail("ideology_save_truncated");
    // Shape only. There is deliberately NO pair rule tying the sample day to
    // `_last_day` or to the two §9.3 dates below:
    //   * `drain_derived_cell_layer` drives `step_derived_rebuild(day)` directly, so a
    //     projection can be built for a day the day-completion marker has not reached;
    //   * a transition may CONFIRM on a later day than the build it confirmed, so
    //     `confirmed_day > sample_day` is legal.
    // Both rules would therefore refuse payloads this same code writes, and a check
    // that fires on legal data is worse than none. What is left is the domain: below
    // -1 is neither a real day nor the "no projection" sentinel.
    if (restored_sample_day < -1)
        return fail("ideology_save_scalar_basis_invalid");
    int64_t restored_basis_confirmed_day = -1;
    int64_t restored_basis_eligible_day = -1;
    if (!read_le(data, size, cursor, restored_basis_confirmed_day) ||
        !read_le(data, size, cursor, restored_basis_eligible_day))
        return fail("ideology_save_truncated");
    // Plan §11.5: the execution-contract identity. Explicit refusal, per the plan:
    // "旧档默认明确拒读 cell_program_execution_contract_mismatch, 而不是删掉旧实例继续读."
    uint64_t restored_contract = 0;
    if (!read_le(data, size, cursor, restored_contract))
        return fail("ideology_save_truncated");
    // Compare against THIS runtime's own stamp, not a live recomputation.
    //
    // That asymmetry was a real defect (found while fixing a fixture): `configure`
    // stamps `_execution_contract_hash` on its last line from the catalogs attached AT
    // THAT MOMENT, so a world configured Effect-AFTER-Ideology carries a stamp computed
    // with an effect hash of 0. Comparing the payload against a LIVE recomputation then
    // meant such a world could restore a foreign, correctly-stamped payload yet could
    // never reload its OWN save -- the worst of both directions.
    //
    // Comparing stamp against stamp makes the rule symmetric and states it plainly:
    // a payload is accepted iff the runtime that produced it agreed on the contract. A
    // runtime that reconfigured gets a new stamp, so it refuses payloads from the old
    // one, which is what §11.5 wants ("跨不同覆盖配置加载时必须拒读").
    if (restored_contract != compute_execution_contract_hash())
        return fail("cell_program_execution_contract_mismatch");
    // Reject a nonsensical pair rather than trusting it: the gate treats
    // `eligible < 0` as "no basis yet", so a payload claiming confirmed=9999 /
    // eligible=0 would silently disable it.
    if ((restored_basis_confirmed_day < 0) != (restored_basis_eligible_day < 0) ||
        (restored_basis_eligible_day >= 0 &&
         restored_basis_eligible_day != restored_basis_confirmed_day + 1))
        return fail("ideology_save_basis_dates_invalid");
    if (!read_le(data, size, cursor, end) || end != SAVE_END || cursor != size) return fail("ideology_save_truncated");
    // ── plan §18.2: can the payload's basis be rebuilt from the CURRENT catalogs? ──
    //
    // This is the check the two basis dates cannot make: they say WHEN a projection may
    // be adopted, not WHAT it was built from. The concrete hole it closes -- measured,
    // see `ideology_save_payload_robustness_test` -- is the card-level -> program
    // mapping: `compute_catalog_hash` does not cover `Definition::level_begin`,
    // `Level::persistent_*` or `EffectTemplate::definition_key`, and the execution
    // contract covers only the version vector plus the OTHER two catalogs' hashes. So
    // two builds that disagree about which program a card level carries agree on every
    // other persisted identity, and without this check the reload would silently project
    // a DIFFERENT card from the same rows.
    //
    // Runs against the payload's own country rows, before anything is installed, using
    // the pure rebuild helper: a refusal here leaves the runtime untouched, so it needs
    // no rollback of its own.
    {
        std::vector<AppliedProgramBasis> rebuilt_basis;
        rebuild_applied_program_basis(countries, rebuilt_basis);
        if (rebuilt_basis != restored_basis)
            return fail("ideology_save_applied_basis_mismatch");
    }
    // ── plan §18.5: can the payload's SCALAR values be rebuilt from the CURRENT
    // catalogs and state? ─────────────────────────────────────────────────────────
    //
    // The applied basis above pins which PROGRAMS the projection folds; this pins the
    // NUMBERS their programs read. Two identities that agree on every program can
    // still disagree on `equipped_count` or `unlocked_era`, and a reload that silently
    // re-derives a different value reports "restored" while projecting something else.
    //
    // The comparison is a pure function of (payload country rows, current Effect
    // catalog, this runtime's Country domain), run before anything is installed, so a
    // refusal here needs no rollback: `_local_scalar_basis` still holds the previous
    // record and the country table was never moved.
    //
    // The ONE exception is a row whose input this runtime cannot answer -- the
    // `unlocked_era` term needs the Country domain, which a test or a partially-loaded
    // world may not have ready. Those rows are excluded from the comparison (named, not
    // silently zeroed); every other row is still compared strictly, presence included.
    {
        std::vector<LocalScalarValue> rebuilt_scalars;
        std::vector<LocalScalarValue> cross_domain_rows;
        rebuild_local_scalar_basis(countries, rebuilt_scalars, &cross_domain_rows);
        if (!local_scalar_basis_agrees(restored_scalars, rebuilt_scalars,
                cross_domain_rows)) {
            _last_scalar_basis_mismatch_detail = describe_local_scalar_mismatch(
                restored_scalars, rebuilt_scalars, cross_domain_rows);
            return fail("ideology_save_scalar_basis_mismatch");
        }
        _last_scalar_basis_mismatch_detail.clear();
    }
    auto previous_countries = std::move(_countries);
    auto previous_commands = std::move(_commands);
    auto previous_producer_high_watermarks =
        std::move(_producer_high_watermarks);
    const size_t previous_command_cursor = _command_cursor;
    auto previous_pending_transitions = std::move(_pending_transitions);
    const size_t previous_pending_transition_cursor = _pending_transition_cursor;
    const int64_t previous_active_progress_day = _active_progress_day;
    const int64_t previous_daily_continuation_day = _daily_continuation_day;
    const int32_t previous_active_country_cursor = _active_country_cursor;
    const int32_t previous_active_item_cursor = _active_item_cursor;
    const int64_t previous_last_day = _last_day;
    const uint64_t previous_submit_order = _submit_order;
    const uint64_t previous_points_revision_seen = _points_revision_seen;
    const bool previous_worker_origin = _worker_origin;
    _countries = std::move(countries); _commands = std::move(commands);
    _producer_high_watermarks = std::move(producer_high_watermarks);
    _points_revision_seen = points_revision_seen;
    _worker_origin = worker_origin != 0;
    if (schema < 3) {
        for (const Command &command : _commands) {
            auto &high_watermark =
                _producer_high_watermarks[command.producer_id];
            high_watermark = std::max(high_watermark, command.sequence);
        }
    }
    _command_cursor = 0;
    _daily_continuation_day = -1;
    _active_progress_day = -1;
    _active_country_cursor = 0;
    _active_item_cursor = 0;
    _last_day = last_day;
    _submit_order = submit_order;
    const int64_t previous_basis_confirmed_day = _derived_basis_confirmed_day;
    const int64_t previous_basis_eligible_day = _derived_basis_eligible_day;
    _derived_basis_confirmed_day = restored_basis_confirmed_day;
    _derived_basis_eligible_day = restored_basis_eligible_day;
    // Plan §18.2 commit point: the basis the payload described is now the basis this
    // runtime reports. Same treatment as the two dates above -- assigned at the commit
    // point and put back by `rollback`, so a later failure in this restore cannot leave
    // a basis that describes state which was itself rolled back.
    const std::vector<AppliedProgramBasis> previous_applied_basis =
        _applied_program_basis;
    _applied_program_basis = restored_basis;
    // §18.5 commit point: the scalar record and the projection's sample day. Both are
    // MEMBERS, so a failure AFTER this line (the state hash below, a missing Effect
    // instance, a missing binding) has to put them back; otherwise a refused restore
    // would leave this runtime reporting another world's scalar values -- exactly the
    // class of bug the applied-basis member was introduced to make impossible.
    const std::vector<LocalScalarValue> previous_local_scalar_basis =
        _local_scalar_basis;
    _local_scalar_basis = restored_scalars;
    const int64_t previous_basis_sample_day = _derived_basis_sample_day;
    _derived_basis_sample_day = restored_sample_day;
    rebuild_pending_transition_index();
    auto rollback = [&]() {
        _countries = std::move(previous_countries);
        _commands = std::move(previous_commands);
        _producer_high_watermarks =
            std::move(previous_producer_high_watermarks);
        _command_cursor = previous_command_cursor;
        _pending_transitions = std::move(previous_pending_transitions);
        _pending_transition_cursor = previous_pending_transition_cursor;
        _active_progress_day = previous_active_progress_day;
        _daily_continuation_day = previous_daily_continuation_day;
        _active_country_cursor = previous_active_country_cursor;
        _active_item_cursor = previous_active_item_cursor;
        _last_day = previous_last_day;
        _submit_order = previous_submit_order;
        _points_revision_seen = previous_points_revision_seen;
        _worker_origin = previous_worker_origin;
        _derived_basis_confirmed_day = previous_basis_confirmed_day;
        _derived_basis_eligible_day = previous_basis_eligible_day;
        _applied_program_basis = previous_applied_basis;
        _local_scalar_basis = previous_local_scalar_basis;
        _derived_basis_sample_day = previous_basis_sample_day;
    };
    // The hash is taken over the rows that were just verified, not over a fresh
    // derivation: `rebuilt_basis == restored_basis` was proved above, so this is the same
    // number and it resolves every program only once. Same for the scalar rows, whose
    // equality was proved by the §18.5 check above.
    if (compute_state_hash_with(restored_basis, restored_scalars,
            restored_sample_day) != state_hash) {
        rollback();
        return fail("ideology_save_state_hash_mismatch");
    }
    // A card whose effect lives on a reconciled instance is only half-restored by
    // PKID. If the Effect domain lost that instance the card would silently stop
    // producing anything, so prove ownership here instead. PKEF restores first
    // (game_save_coordinator), which makes this an ordering assertion as well.
    //
    // The check has to ask whichever side owns EFFECT: under worker authority
    // EffectRuntime is writeback-only, so the old unconditional query failed every
    // worker-owned instance and rejected a perfectly good save with
    // ideology_effect_instance_missing. "Cannot answer" is deliberately NOT a
    // failure -- a transport that is not ready yet must not fail a restore.
    if (_effect_runtime != nullptr || _effect_forwarder != nullptr) {
        for (const CountryState &country : _countries) {
            for (const IdeaState &state : country.ideas) {
                for (const IdeaState::EffectInstanceRef &ref :
                        state.effect_instances) {
                    bool ref_exists = false;
                    if (!effect_pod_instance_exists(_effect_runtime,
                            _effect_forwarder, ref.instance_id, ref.generation,
                            ref_exists))
                        continue;
                    if (!ref_exists) {
                        rollback();
                        return fail("ideology_effect_instance_missing");
                    }
                }
            }
        }
    }
    if (_worker_origin) {
        // Worker-authored state binds through Modifier UniqueSource rows that
        // PKCM restores and IDP2 audits; it never owned PKEF bindings.
        if (_modifier_runtime != nullptr) {
            restored_projection.sample_day = restored_sample_day;
            restored_projection.world_identity = _derived_world_identity;
            restored_projection.map_generation = _derived_map_generation;
            restored_projection.epoch_id = _derived_epoch_id;
            restored_projection.execution_contract_hash = restored_contract;
            _derived_installed_generation = restored_projection.generation;
            _derived_installed_contributions = std::move(restored_targets);
            modifier_api::restore_derived_cell_layer(*_modifier_runtime, std::move(restored_projection));
        }
        Dictionary out; out["ok"] = true; out["state_hash"] = static_cast<int64_t>(state_hash);
        out["worker_origin"] = true;
        return out;
    }
    if (_effect_runtime == nullptr) { rollback(); return fail("ideology_effect_runtime_unavailable"); }
    for (const CountryState &country : _countries) {
        std::vector<int64_t> expected_transaction_ids;
        std::vector<uint64_t> expected_source_ids;
        for (const IdeaState &state : country.ideas) {
            if (schema < 2 && (state.location != INACTIVE ||
                    state.transition.active != 0)) {
                rollback();
                return fail("ideology_legacy_active_state_unsupported");
            }
            if (state.location != INACTIVE) {
                const int64_t expected_binding_id = static_cast<int64_t>(
                    binding_id_for(country.handle, state.ideology_id,
                        state.location));
                const uint64_t expected_signature = binding_signature_for(
                    state.ideology_id, state.level);
                const uint64_t expected_program_hash =
                    _effect_runtime->catalog_hash();
                if (state.binding_id != expected_binding_id ||
                    state.binding_generation == 0 ||
                    state.binding_signature != expected_signature ||
                    state.binding_program_hash != expected_program_hash ||
                    !_effect_runtime->has_external_binding_pod(state.binding_id,
                        state.binding_generation, 0x4944454f, state.ideology_id,
                        country.handle, static_cast<uint32_t>(country.handle >> 32U),
                        state.level, state.location, state.binding_signature,
                        state.binding_program_hash)) {
                    rollback();
                    return fail("ideology_effect_binding_missing_or_mismatched");
                }
            }
            if (state.transition.active == 0) continue;
            const uint64_t source_prefix =
                static_cast<uint64_t>(state.ideology_id + 1) << 32U;
            for (const int64_t transaction_id : state.transition.transaction_ids) {
                expected_transaction_ids.push_back(transaction_id);
                expected_source_ids.push_back(source_prefix);
            }
        }
        std::string transaction_error;
        if (!_effect_runtime->verify_external_pending_transactions_pod(
                0x4944454f, country.handle, 0xffffffff00000000ULL,
                expected_transaction_ids, expected_source_ids,
                transaction_error)) {
            rollback();
            return fail(transaction_error.empty()
                ? "ideology_effect_transition_unknown" : transaction_error);
        }
    }
    // Converge the instance set after a load. The verification above proves the
    // saved set still exists; this makes a save that predates a program (or one
    // written by a path that never reconciled) self-heal instead of leaving the
    // card silently inert. Idempotent: a matching set produces no submits.
    for (CountryState &country : _countries)
        reconcile_country_effect_activations(country, std::max<int64_t>(0, _last_day));
    // The restore pass above already revisited every card and stamped its
    // signature, so the first refresh must not repeat it.
    _effect_input_revision_seen = _economy_runtime == nullptr
        ? 0 : economy_api::effect_input_revision(*_economy_runtime);
    _effect_input_revision_target = _effect_input_revision_seen;
    _instance_refresh_pending = false;
    _instance_refresh_dirty = false;
    _instance_refresh_country_cursor = 0;
    recount_managed_active();
    Dictionary out; out["ok"] = true; out["state_hash"] = static_cast<int64_t>(state_hash); return out;
}
