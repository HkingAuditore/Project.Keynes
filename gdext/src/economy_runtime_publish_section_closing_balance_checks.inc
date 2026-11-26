        if (_publish_cursor >= _structural_touched_cells.size()) {
            _incremental_closing_totals =
                _closing_audit_mode != 0 &&
                        !_closing_audit_runtime_disabled
                    ? incremental_audit_totals()
                    : AuditTotals{};
            const bool periodic_full =
                _full_audit_verify_interval_days > 0 &&
                _current_day.get() % _full_audit_verify_interval_days == 0;
            const char *verify_every_day = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_AUDIT_VERIFY_EVERY_DAY);
            const bool diagnostic_full = verify_every_day &&
                std::strcmp(verify_every_day, "1") == 0;
            // Army personnel lanes (contract §1.2) move people and cash out of
            // the cohort table inside the epoch. The incremental shadow re-reads
            // lane holdings live, so only an epoch that actually changed them
            // needs the full verification.
            const bool army_lane_drift =
                _army_personnel.total_population() !=
                    _opening_totals.army_lane_population ||
                _army_personnel.total_funds() != _opening_totals.army_lane_funds;
            const bool full_required = _closing_audit_mode != 2 ||
                _closing_audit_runtime_disabled ||
                _closing_audit_force_full || periodic_full || diagnostic_full ||
                army_lane_drift;
            _closing_audit_incremental_this_epoch = !full_required;
            _closing_audit_lane_full = army_lane_drift;
            _closing_totals_valid = false;
            if (full_required) {
                ++_closing_audit_full_verifications;
                _closing_totals = {};
            } else {
                ++_closing_audit_fast_paths;
                _closing_totals = _incremental_closing_totals;
            }
            _publish_valuation_sat = 0;
            _publish_cursor = 0;
            _publish_phase = full_required
                ? PublishPhase::AUDIT_POPULATION : PublishPhase::VERIFY;
        }
