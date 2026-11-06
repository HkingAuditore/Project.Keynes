#pragma once
#include <cstdint>
#include <cstddef>
#include <tuple>

namespace pk {
// A view over existing owner queues. No second queue, counter or save format.
enum class ResolveFlow { CountryCommand, EconomyCommand, TriggerCommand };
enum class ResolveResult { Accepted, Replay, Capacity, InvalidIdentity };
struct ResolveOrder {
    int64_t day;
    uint64_t first, second, request;
    bool operator<(const ResolveOrder &b) const noexcept {
        return std::tie(day, first, second, request) < std::tie(b.day, b.first, b.second, b.request);
    }
};
// Owners choose the existing policy: Country and Trigger preserve all admitted
// records (their semantic consumer owns dedup); Economy replays stored receipts.
template<class Rows> const typename Rows::value_type *resolve_find_receipt(
        const Rows &rows, uint64_t request) {
    for (const auto &row : rows) if (row.request_id == request) return &row;
    return nullptr;
}
template<ResolveFlow Flow, class Rows, class Command>
ResolveResult resolve_enqueue(Rows &rows, const Command &command, size_t capacity) {
    if (command.request_id == 0) return ResolveResult::InvalidIdentity;
    if (rows.size() >= capacity) return ResolveResult::Capacity;
    rows.push_back(command);
    return ResolveResult::Accepted;
}
inline const char *resolve_reason(ResolveResult result) {
    switch (result) {
        case ResolveResult::Accepted: return "accepted";
        case ResolveResult::Replay: return "replay";
        case ResolveResult::Capacity: return "queue_capacity";
        case ResolveResult::InvalidIdentity: return "invalid_identity";
    }
    return "invalid_result";
}
} // namespace pk
