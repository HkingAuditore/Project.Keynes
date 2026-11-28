#pragma once

#include "runtime_events_authority.h"

namespace pk {

RuntimeCommandPacket make_event_append_packet(
    uint64_t request, uint32_t producer, uint64_t sequence, int64_t day,
    const RuntimeEventsRecord &record, uint64_t idempotency = 0);

} // namespace pk
