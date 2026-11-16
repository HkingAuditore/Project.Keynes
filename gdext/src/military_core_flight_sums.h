#pragma once

#include <cstddef>
#include <cstdint>
#include <limits>
#include <tuple>
#include <utility>
#include <vector>

namespace pk {

// Request-local lookup for the existing procurement in-flight sums. It never
// changes the source rows or supplies an iteration order to a gameplay loop.
class MilitaryFlightSums {
public:
    using Key = std::tuple<int32_t, uint8_t, int32_t, int32_t>;
    using Row = std::pair<Key, int64_t>;

    void clear() {
        _buckets.clear();
        _rows.clear();
    }

    bool build(const std::vector<Row> &source) {
        clear();
        // Optimization eligibility, not input rejection: the caller retains
        // the original sort and int64_t additions if this returns false.
        if (source.size() > std::numeric_limits<size_t>::max() / 2) return false;
        size_t capacity = 1;
        const size_t needed = source.size() * 2;
        while (capacity < needed) {
            if (capacity > std::numeric_limits<size_t>::max() / 2) return false;
            capacity *= 2;
        }
        _buckets.assign(capacity, -1);
        _rows.reserve(source.size());
        for (const Row &row : source) {
            // The old vector sort orders same-key values before int64_t sum.
            // Reordering nonnegative representable sums is exact. For negative
            // converted values or overflowing totals, execute that old path.
            if (row.second < 0) { clear(); return false; }
            const size_t bucket = find_bucket(row.first);
            const int32_t index = _buckets[bucket];
            if (index < 0) {
                if (_rows.size() > size_t(std::numeric_limits<int32_t>::max())) {
                    clear();
                    return false;
                }
                _buckets[bucket] = int32_t(_rows.size());
                _rows.push_back(row);
                continue;
            }
            int64_t &sum = _rows[size_t(index)].second;
            if (row.second > std::numeric_limits<int64_t>::max() - sum) {
                clear();
                return false;
            }
            sum += row.second;
        }
        return true;
    }

    int64_t get(const Key &key) const {
        if (_buckets.empty()) return 0;
        const int32_t index = _buckets[find_bucket(key)];
        return index < 0 ? 0 : _rows[size_t(index)].second;
    }

    size_t size() const { return _rows.size(); }

private:
    std::vector<int32_t> _buckets;
    std::vector<Row> _rows;

    static uint64_t hash(const Key &key) {
        uint64_t value = 1469598103934665603ull;
        for (uint32_t part : {uint32_t(std::get<0>(key)), uint32_t(std::get<1>(key)),
                              uint32_t(std::get<2>(key)), uint32_t(std::get<3>(key))}) {
            value = (value ^ part) * 1099511628211ull;
        }
        value ^= value >> 32;
        return value;
    }

    size_t find_bucket(const Key &key) const {
        const size_t mask = _buckets.size() - 1;
        size_t bucket = size_t(hash(key)) & mask;
        while (_buckets[bucket] >= 0 && _rows[size_t(_buckets[bucket])].first != key)
            bucket = (bucket + 1) & mask;
        return bucket;
    }
};

} // namespace pk
