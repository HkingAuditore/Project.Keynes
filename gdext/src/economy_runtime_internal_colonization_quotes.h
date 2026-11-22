// Included inside NativeEconomyRuntime. Family colonization quote queries.
    // Optional native output follows the same order as the returned page.
    godot::Dictionary family_colonization_quotes(
        int64_t country_handle, int32_t target_cell, int64_t family_filter,
        int32_t source_filter, int32_t offset, int32_t limit,
        const uint8_t *visible, int32_t visible_count,
        uint64_t vision_revision, std::vector<uint64_t> *route_hashes = nullptr);
    godot::Dictionary family_colonization_quote_detail(
        int64_t quote_token, int64_t population = -1) const;
