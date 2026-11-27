Dictionary DCWorldExt::get_ideology_snapshot(int64_t country_handle) const {
    if (const auto view = published_ideology(_runtime_host.get()))
        return read_ideology_country(*view, static_cast<uint64_t>(country_handle),
            &RuntimeIdeologyReadView::CardView::state);
    return _ideology_runtime == nullptr ? unavailable()
        : ideology_runtime_from(_ideology_runtime)->snapshot(country_handle);
}

Dictionary DCWorldExt::get_ideology_effect_instance_report(int64_t country_handle) const {
    if (const auto view = published_ideology(_runtime_host.get()))
        return read_ideology_country(*view, static_cast<uint64_t>(country_handle),
            &RuntimeIdeologyReadView::CardView::instances);
    return _ideology_runtime == nullptr ? unavailable()
        : ideology_runtime_from(_ideology_runtime)->effect_instance_report(country_handle);
}

Dictionary DCWorldExt::get_ideology_effect_target_report(int64_t country_handle) const {
    if (const auto view = published_ideology(_runtime_host.get()))
        return read_ideology_country(*view, static_cast<uint64_t>(country_handle),
            &RuntimeIdeologyReadView::CardView::targets);
    return _ideology_runtime == nullptr ? unavailable()
        : ideology_runtime_from(_ideology_runtime)->effect_target_report(country_handle);
}
