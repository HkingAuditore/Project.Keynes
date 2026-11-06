#pragma once

#include "economy_runtime_binary_codec.h"
#include <cstdint>
#include <limits>
#include <vector>

namespace pk::publication_codec {
// ECP2 publication state belongs to Economy. Encode only the committed opinion
// buffer; the other buffer is completely overwritten by the next publication.
struct PublicationWriter {
    std::vector<uint8_t> bytes;
    template<typename T> bool scalar(T &value) {
        binary_codec::append_le<T>(bytes, value);
        return true;
    }
    template<typename T> bool lanes(std::vector<T> &values) {
        uint32_t count = static_cast<uint32_t>(values.size());
        scalar(count);
        for (T &value : values) scalar(value);
        return true;
    }
};
struct PublicationReader {
    const std::vector<uint8_t> &bytes;
    size_t cursor = 0;
    template<typename T> bool scalar(T &value) {
        return binary_codec::read_le(bytes, cursor, value);
    }
    template<typename T> bool lanes(std::vector<T> &values) {
        uint32_t count = 0;
        if (!scalar(count) || count > (bytes.size() - cursor) / sizeof(T)) return false;
        values.resize(count);
        for (T &value : values) if (!scalar(value)) return false;
        return true;
    }
};

template<typename Codec, typename PublishedView>
bool fields(Codec &io, uint64_t &revision, std::vector<uint64_t> &handles,
            std::vector<int64_t> &last_day, std::vector<uint8_t> &qualified,
            PublishedView &view) {
    return io.scalar(revision) && io.lanes(handles) && io.lanes(last_day) &&
        io.lanes(qualified) && io.scalar(view.revision) &&
        io.scalar(view.class_hash) && io.scalar(view.class_metric_content_hash) &&
        io.scalar(view.epoch_day) && io.scalar(view.commit_day) &&
        io.scalar(view.period_index) && io.scalar(view.country_count) &&
        io.scalar(view.class_count) && io.lanes(view.country_handles) &&
        io.lanes(view.country_generations) && io.lanes(view.population) &&
        io.lanes(view.funds) && io.lanes(view.owner_employed) &&
        io.lanes(view.satisfaction_weighted) && io.lanes(view.satisfaction_q16) &&
        io.lanes(view.country_population) && io.lanes(view.country_buildings_installed) &&
        io.lanes(view.country_trade_base_value) && io.scalar(view.period_days);
}

template<typename PublishedView>
bool valid(uint64_t revision, const std::vector<uint64_t> &handles,
           const std::vector<int64_t> &last_day, const std::vector<uint8_t> &qualified,
           const PublishedView &view, size_t metric_count) {
    if (handles.size() > std::numeric_limits<size_t>::max() / (metric_count ? metric_count : 1) ||
        last_day.size() != handles.size() * metric_count || qualified.size() != last_day.size() ||
        view.revision != revision || view.country_count < 0 || view.class_count < 0 ||
        view.period_days <= 0) return false;
    if (revision != 0 && (view.epoch_day < 0 || view.commit_day < view.epoch_day ||
        view.period_index != view.commit_day / view.period_days)) return false;
    for (uint8_t value : qualified) if (value > 1) return false;
    const size_t countries = static_cast<size_t>(view.country_count);
    const size_t classes = static_cast<size_t>(view.class_count);
    if (classes && countries > std::numeric_limits<size_t>::max() / classes) return false;
    const size_t rows = countries * classes;
    if (view.country_handles.size() != countries || view.country_generations.size() != countries ||
        view.population.size() != rows || view.funds.size() != rows ||
        view.owner_employed.size() != rows || view.satisfaction_weighted.size() != rows ||
        view.satisfaction_q16.size() != rows || view.country_population.size() != countries ||
        view.country_buildings_installed.size() != countries || view.country_trade_base_value.size() != countries)
        return false;
    for (size_t i = 0; i < countries; ++i)
        if (view.country_generations[i] != static_cast<uint32_t>(view.country_handles[i] >> 32u)) return false;
    return true;
}

template<typename PublishedView>
std::vector<uint8_t> encode(uint64_t revision, std::vector<uint64_t> handles,
                           std::vector<int64_t> last_day, std::vector<uint8_t> qualified,
                           PublishedView view) {
    PublicationWriter io;
    fields(io, revision, handles, last_day, qualified, view);
    return std::move(io.bytes);
}

template<typename PublishedView>
bool decode(const std::vector<uint8_t> &wire, uint64_t &revision,
            std::vector<uint64_t> &handles, std::vector<int64_t> &last_day,
            std::vector<uint8_t> &qualified, PublishedView &view, size_t metric_count) {
    PublicationReader io{wire};
    return fields(io, revision, handles, last_day, qualified, view) && io.cursor == wire.size() &&
        valid(revision, handles, last_day, qualified, view, metric_count);
}
} // namespace pk::publication_codec
