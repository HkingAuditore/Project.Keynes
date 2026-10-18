#pragma once

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <vector>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>

namespace pk {
class NativeEconomyRuntime;

// Optional observer. Only step/reset touch work state, under the Economy read
// boundary. The render thread exchanges requests and immutable published views.
// Nothing in this class is authoritative, journalled, hashed or persisted.
class TradeVisualCache {
public:
    static constexpr int ROUTE_CAP = 128;
    static constexpr int POINT_CAP = 1024;
    static constexpr int SCAN_CAP = 512;
    static constexpr int EXPANSION_CAP = 256;
    static constexpr int INTEREST_CAP = 4096;
    void request(const godot::PackedInt32Array &cells,
                 const godot::PackedByteArray &visible, int64_t revision,
                 int32_t selected, bool enabled);
    void step(NativeEconomyRuntime &runtime);
    void reset();
    godot::Dictionary snapshot() const;

private:
    struct Request {
        std::vector<int32_t> cells;
        std::vector<uint8_t> visible;
        int64_t revision = 0;
        int32_t selected = -1;
        uint64_t touched_us = 0;
        bool enabled = false;
    };
    struct Route {
        int32_t source = -1, destination = -1, country = -1;
        uint8_t capability = 0, era = 0;
        uint64_t seen_cycle = 0;
        int32_t intensity = 0;
        int64_t representative_order_id = -1;
        bool failed = false;
        std::vector<int32_t> cells;
        // One mode per edge: 0 land, 1 water. Coast edges use the boat.
        std::vector<uint8_t> modes;
    };
    struct View {
        std::vector<Route> routes;
        uint64_t serial = 0, topology = 0, country_topology = 0;
        int64_t day = -1, request_revision = 0;
        uint32_t scanned = 0, expansions = 0, hits = 0, pending = 0;
        uint64_t elapsed_us = 0, bytes = 0;
    };
    struct Search {
        int32_t route = -1;
        uint32_t stamp = 0, pops = 0;
        std::vector<int64_t> distance;
        std::vector<int32_t> parent;
        std::vector<uint32_t> visited;
        std::vector<std::pair<int64_t, int32_t>> heap;
    };
    mutable std::mutex _request_mutex;
    Request _request;
    std::shared_ptr<const View> _view;
    std::vector<Route> _routes;
    Search _search;
    uint64_t _topology = 0, _country_topology = 0;
    uint64_t _serial = 0, _cycle = 1;
    int32_t _scan_cursor = 0;
    int64_t _mask_revision = -1;
};
} // namespace pk
