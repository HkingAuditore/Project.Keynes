Dictionary DCWorldExt::refresh_effect_input_digest_for_test() {
    Dictionary out;
    if (_economy_runtime == nullptr) {
        out["ok"] = false;
        out["code"] = "economy_runtime_unavailable";
        return out;
    }
    static_cast<NativeEconomyRuntime *>(_economy_runtime)
        ->refresh_effect_input_digest();
    out["ok"] = true;
    return out;
}

Dictionary DCWorldExt::set_effect_metric_override_for_test(int32_t metric,
        int64_t value, bool has_value) {
    Dictionary out;
    if (_economy_runtime == nullptr) {
        out["ok"] = false;
        out["code"] = "economy_runtime_unavailable";
        return out;
    }
    static_cast<NativeEconomyRuntime *>(_economy_runtime)
        ->set_effect_metric_override(metric, value, has_value);
    out["ok"] = true;
    return out;
}

Dictionary DCWorldExt::set_family_target_min_branches_override_for_test(
        int32_t min_branches) {
    Dictionary out;
    if (_economy_runtime == nullptr) {
        out["ok"] = false;
        out["code"] = "economy_runtime_unavailable";
        return out;
    }
    static_cast<NativeEconomyRuntime *>(_economy_runtime)
        ->set_family_target_min_branches_override_for_test(
            std::max(0, min_branches));
    out["ok"] = true;
    return out;
}

void DCWorldExt::set_tag_force_all_for_test(bool force) {
    if (_economy_runtime == nullptr) return;
    static_cast<NativeEconomyRuntime *>(_economy_runtime)
        ->set_tag_force_all_for_test(force);
}


Dictionary DCWorldExt::set_cell_tag_override_for_test(
        const String &tag_key, int32_t cell, bool on) {
    Dictionary out;
    if (_economy_runtime == nullptr) {
        out["ok"] = false;
        out["code"] = "economy_runtime_unavailable";
        return out;
    }
    const std::string key = tag_key.utf8().get_data();
    if (!static_cast<NativeEconomyRuntime *>(_economy_runtime)
            ->set_cell_tag_override_for_test(key, cell, on)) {
        out["ok"] = false;
        out["code"] = "cell_tag_override_rejected";
        return out;
    }
    out["ok"] = true;
    return out;
}

Dictionary DCWorldExt::clear_cell_tag_overrides_for_test() {
    Dictionary out;
    if (_economy_runtime == nullptr) {
        out["ok"] = false;
        out["code"] = "economy_runtime_unavailable";
        return out;
    }
    static_cast<NativeEconomyRuntime *>(_economy_runtime)
        ->clear_cell_tag_overrides_for_test();
    out["ok"] = true;
    return out;
}

Dictionary DCWorldExt::get_class_metric_source_for_test() const {
    Dictionary out;
    if (_economy_runtime == nullptr) {
        out["ok"] = false;
        out["code"] = "economy_runtime_unavailable";
        return out;
    }
    const NativeEconomyRuntime *runtime =
        static_cast<const NativeEconomyRuntime *>(_economy_runtime);
    const NativeEconomyRuntime::CountryClassOpinionSnapshot &source =
        runtime->country_class_opinion_snapshot();
    const Dictionary debug = runtime->country_class_opinion_snapshot_debug();
    out["ok"] = true;
    out["source_revision"] = runtime->class_metric_source_revision();
    out["source_epoch_day"] = runtime->class_metric_source_epoch_day();
    out["source_content_hash"] = static_cast<int64_t>(
        runtime->class_metric_source_content_hash());
    out["snapshot_revision"] = static_cast<int64_t>(source.revision);
    out["snapshot_content_hash"] = static_cast<int64_t>(
        source.class_metric_content_hash);
    out["snapshot_epoch_day"] = source.epoch_day;
    out["snapshot_country_count"] = source.country_count;
    out["snapshot_class_count"] = source.class_count;
    out["snapshot_class_ids"] = debug.get("class_ids", PackedStringArray());
    out["snapshot_population"] = debug.get("population", PackedInt64Array());
    out["snapshot_satisfaction_weighted"] =
        debug.get("satisfaction_weighted", PackedInt64Array());
    out["snapshot_satisfaction_q16"] =
        debug.get("satisfaction_q16", PackedInt32Array());
    PackedInt64Array copied_satisfaction;
    PackedInt64Array copied_weighted;
    for (const int64_t value : runtime->class_metric_satisfaction_q16())
        copied_satisfaction.append(value);
    for (const int64_t value :
         runtime->class_metric_weighted_satisfaction_q16())
        copied_weighted.append(value);
    PackedInt64Array copied_farmer;
    for (const int64_t value :
         runtime->class_metric_farmer_satisfaction_q16())
        copied_farmer.append(value);
    PackedInt64Array copied_worker;
    for (const int64_t value :
         runtime->class_metric_worker_satisfaction_q16())
        copied_worker.append(value);
    out["copied_satisfaction_q16"] = copied_satisfaction;
    out["copied_weighted_satisfaction_q16"] = copied_weighted;
    out["copied_farmer_satisfaction_q16"] = copied_farmer;
    out["copied_worker_class_satisfaction_q16"] = copied_worker;
    return out;
}

Dictionary DCWorldExt::capture_class_metric_source_for_test() {
    if (_economy_runtime == nullptr) {
        Dictionary out;
        out["ok"] = false;
        out["code"] = "economy_runtime_unavailable";
        return out;
    }
    static_cast<NativeEconomyRuntime *>(_economy_runtime)
        ->refresh_class_opinion_metrics_for_test();
    return get_class_metric_source_for_test();
}

Dictionary DCWorldExt::set_class_opinion_source_override_for_test(
        PackedInt64Array population, PackedInt32Array satisfaction_q16,
        PackedInt64Array satisfaction_weighted) {
    Dictionary out;
    if (_economy_runtime == nullptr) {
        out["ok"] = false;
        out["code"] = "economy_runtime_unavailable";
        return out;
    }
    std::vector<int64_t> population_rows;
    std::vector<int32_t> satisfaction_rows;
    std::vector<int64_t> weighted_rows;
    population_rows.reserve(static_cast<size_t>(population.size()));
    satisfaction_rows.reserve(static_cast<size_t>(satisfaction_q16.size()));
    weighted_rows.reserve(static_cast<size_t>(satisfaction_weighted.size()));
    for (const int64_t value : population) population_rows.push_back(value);
    for (const int32_t value : satisfaction_q16)
        satisfaction_rows.push_back(value);
    for (const int64_t value : satisfaction_weighted)
        weighted_rows.push_back(value);
    static_cast<NativeEconomyRuntime *>(_economy_runtime)
        ->set_class_opinion_source_override_for_test(
            population_rows, satisfaction_rows, weighted_rows);
    out["ok"] = true;
    return out;
}

Dictionary DCWorldExt::clear_class_opinion_source_override_for_test() {
    Dictionary out;
    if (_economy_runtime == nullptr) {
        out["ok"] = false;
        out["code"] = "economy_runtime_unavailable";
        return out;
    }
    static_cast<NativeEconomyRuntime *>(_economy_runtime)
        ->clear_class_opinion_source_override_for_test();
    out["ok"] = true;
    return out;
}

Dictionary DCWorldExt::set_country_technology_metric_input_for_test(
        int32_t country_slot, PackedInt64Array words) {
    Dictionary out;
    if (_economy_runtime == nullptr) {
        out["ok"] = false;
        out["code"] = "economy_runtime_unavailable";
        return out;
    }
    NativeEconomyRuntime *runtime =
        static_cast<NativeEconomyRuntime *>(_economy_runtime);
    const int32_t country_count = runtime->epoch_country_count_for_test();
    const int32_t word_count = runtime->epoch_country_technology_words_for_test();
    if (country_slot < 0 || country_slot >= country_count ||
        word_count <= 0 || words.size() != word_count) {
        out["ok"] = false;
        out["code"] = "technology_metric_input_shape_invalid";
        out["country_slot"] = country_slot;
        out["country_count"] = country_count;
        out["expected_words"] = word_count;
        out["actual_words"] = words.size();
        return out;
    }
    std::vector<uint64_t> bits(
        static_cast<size_t>(country_count) * static_cast<size_t>(word_count),
        0);
    for (int32_t country = 0; country < country_count; ++country) {
        for (int32_t word = 0; word < word_count; ++word) {
            const int64_t current =
                runtime->epoch_country_technology_word_for_test(country, word);
            bits[static_cast<size_t>(country) * word_count + word] =
                static_cast<uint64_t>(current);
        }
    }
    for (int32_t word = 0; word < word_count; ++word) {
        bits[static_cast<size_t>(country_slot) * word_count + word] =
            static_cast<uint64_t>(words[word]);
    }
    runtime->set_epoch_country_technologies_for_test(bits);
    out["ok"] = true;
    out["technology_metric_rebuilds"] =
        static_cast<int64_t>(runtime->technology_metric_rebuilds());
    out["technology_metric_source_hash"] =
        static_cast<int64_t>(runtime->technology_metric_source_hash());
    return out;
}

Dictionary DCWorldExt::clear_country_technology_metric_input_for_test() {
    Dictionary out;
    if (_economy_runtime == nullptr) {
        out["ok"] = false;
        out["code"] = "economy_runtime_unavailable";
        return out;
    }
    NativeEconomyRuntime *runtime =
        static_cast<NativeEconomyRuntime *>(_economy_runtime);
    runtime->clear_epoch_country_technologies_for_test();
    out["ok"] = true;
    return out;
}

Dictionary DCWorldExt::get_effect_input_revisions() const {
    Dictionary out;
    if (_economy_runtime == nullptr) {
        out["ok"] = false;
        out["code"] = "economy_runtime_unavailable";
        return out;
    }
    const NativeEconomyRuntime *runtime =
        static_cast<const NativeEconomyRuntime *>(_economy_runtime);
    out["ok"] = true;
    out["global"] = static_cast<int64_t>(runtime->effect_input_revision());
    out["territory"] = static_cast<int64_t>(runtime->effect_territory_revision());
    out["tag"] = static_cast<int64_t>(runtime->effect_tag_revision());
    out["family"] = static_cast<int64_t>(runtime->effect_family_revision());
    const auto snapshot = runtime->effect_input_snapshot();
    out["generation"] = snapshot == nullptr
        ? static_cast<int64_t>(0)
        : static_cast<int64_t>(snapshot->generation);
    PackedInt64Array metrics;
    metrics.resize(static_cast<int64_t>(NativeEconomyRuntime::FAMILY_METRIC_COUNT));
    for (int32_t metric = 0;
            metric < static_cast<int32_t>(NativeEconomyRuntime::FAMILY_METRIC_COUNT);
            ++metric)
        metrics.set(metric,
            static_cast<int64_t>(runtime->effect_metric_revision(metric)));
    out["metrics"] = metrics;
    return out;
}

// R-4 X16 observability: the frozen per-profession values the satisfaction loop reads.
//
// A card's `tax_tolerance_factor` / `satisfaction_bp` row lands in the Modifier
// runtime, but what actually moves a cohort is the value frozen into the epoch. Asking
// for the Modifier read instead would pass even when the freeze never picked the stat
// up, which is the exact failure this reports.
Dictionary DCWorldExt::get_epoch_profession_report(int64_t country_slot) const {
    Dictionary out;
    if (_economy_runtime == nullptr) {
        out["ok"] = false;
        out["reason"] = "economy_runtime_unavailable";
        return out;
    }
    const NativeEconomyRuntime *runtime =
        static_cast<const NativeEconomyRuntime *>(_economy_runtime);
    PackedStringArray profession_ids;
    PackedInt64Array tolerance_q16;
    PackedInt64Array satisfaction_bp;
    const auto &ids = runtime->profession_ids();
    for (size_t index = 0; index < ids.size(); ++index) {
        profession_ids.push_back(String(ids[index].c_str()));
        int32_t frozen_tolerance = 0;
        int32_t frozen_bias = 0;
        runtime->epoch_profession_values(static_cast<int32_t>(country_slot),
                                        static_cast<int32_t>(index),
                                        frozen_tolerance, frozen_bias);
        tolerance_q16.push_back(static_cast<int64_t>(frozen_tolerance));
        satisfaction_bp.push_back(static_cast<int64_t>(frozen_bias));
    }
    out["ok"] = true;
    out["profession_ids"] = profession_ids;
    out["tax_tolerance_q16"] = tolerance_q16;
    out["satisfaction_bp"] = satisfaction_bp;
    return out;
}

// R-4: sample one effect metric for one cell through the real sampling path.
//
// Exists so the metric tests can assert on what a card would actually read, without
// `set_effect_metric_override_for_test` (which would bypass the epoch accounting this
// round is about).
Dictionary DCWorldExt::sample_effect_metric_probe(int64_t metric, int64_t cell,
                                                  int64_t country_handle) const {
    Dictionary out;
    if (_economy_runtime == nullptr) {
        out["ok"] = false;
        out["reason"] = "economy_runtime_unavailable";
        return out;
    }
    const int32_t metric_index = static_cast<int32_t>(metric);
    if (metric_index < 0 ||
        metric_index >= static_cast<int32_t>(NativeEconomyRuntime::FAMILY_METRIC_COUNT)) {
        out["ok"] = false;
        out["reason"] = "effect_metric_out_of_range";
        return out;
    }
    const NativeEconomyRuntime *runtime =
        static_cast<const NativeEconomyRuntime *>(_economy_runtime);
    std::array<int64_t, NativeEconomyRuntime::FAMILY_METRIC_COUNT> values{};
    MetricMask mask;
    mask.set(metric_index);
    runtime->sample_effect_metrics(static_cast<int32_t>(cell),
        static_cast<int32_t>(NativeEconomyRuntime::FAMILY_METRIC_COUNT), values.data(),
        mask);
    (void)country_handle;
    out["ok"] = true;
    out["value"] = values[static_cast<size_t>(metric_index)];
    return out;
}
