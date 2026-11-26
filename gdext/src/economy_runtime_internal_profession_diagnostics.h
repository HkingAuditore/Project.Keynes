// Read-only profession, tax tolerance, and satisfaction probes.

    // ── R-4 X16 diagnostics ─────────────────────────────────────────────────
    // The profession id table, in `profession_id` order, so a probe can index the
    // frozen per-profession arrays by name.
    const std::vector<std::string> &profession_ids() const noexcept {
        return _profession_ids;
    }
    // The value `update_cohort_satisfaction` will use for (country_slot, profession).
    // Returns the DESIGN DEFAULTS (1.0 / 0) when the index is out of range, matching
    // what the reader does -- a probe that reported -1 instead would be measuring the
    // probe, not the runtime.
    //
    // Takes a COUNTRY SLOT, not a handle: the epoch arrays are slot-indexed, and
    // converting a handle here would need a lookup that does not exist on this class.
    // Callers get the slot from `get_country_cell_summary(...).country_slot`.
    void epoch_profession_values(int32_t country_slot, int32_t profession_id,
                                 int32_t &tax_tolerance_q16,
                                 int32_t &satisfaction_bp) const noexcept {
        tax_tolerance_q16 = Q16_ONE;
        satisfaction_bp = 0;
        if (country_slot < 0 || profession_id < 0) return;
        const size_t professions = std::max<size_t>(1, _profession_ids.size());
        const size_t index = static_cast<size_t>(country_slot) * professions +
            static_cast<size_t>(profession_id);
        if (index < _epoch_country_profession_tax_tolerance_q16.size())
            tax_tolerance_q16 = _epoch_country_profession_tax_tolerance_q16[index];
        if (index < _epoch_country_profession_satisfaction_bp.size())
            satisfaction_bp = _epoch_country_profession_satisfaction_bp[index];
    }
