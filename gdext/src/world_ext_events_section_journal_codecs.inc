namespace {

constexpr int PK_EVENT_VEGETATION_SUCCESSION = 1;
constexpr int PK_EVENT_TERRAIN_FLIP = 2;
constexpr int PK_EVENT_WEATHER_FRONT_CHANGED = 3;
constexpr int PK_EVENT_VISUAL_DIRTY_INTENT = 4;
constexpr int PK_EVENT_ECONOMY_EPOCH_COMMITTED = 5;
constexpr int PK_EVENT_ECONOMY_CONSTRUCTION_COMPLETED = 6;
constexpr int PK_EVENT_ECONOMY_TRADE_ARRIVED = 7;
constexpr int PK_EVENT_ECONOMY_SOCIAL_PRESSURE = 8;
constexpr int PK_EVENT_TARIFF_SUBSIDY_INTENT = 15;
constexpr int PK_EVENT_STRATUM_MOBILIZATION = 18;

constexpr int PK_EVENT_SOURCE_NATIVE = 1;
constexpr int PK_EVENT_SOURCE_GDSCRIPT = 2;
constexpr int PK_EVENT_SOURCE_DEBUG = 3;
constexpr int PK_EVENT_SOURCE_EFFECT = 4;
constexpr int PK_EFFECT_ACTION_GAMEPLAY = 4;
constexpr int PK_EFFECT_ACTION_PUBLISH_EVENT = 5;
constexpr int PK_EFFECT_ACTION_CUSTOM_DOMAIN = 6;
constexpr int PK_EFFECT_GAMEPLAY_DOMAIN = 3;
constexpr int PK_EFFECT_PUBLISH_DOMAIN = 4;
constexpr int PK_EFFECT_CUSTOM_DOMAIN = 6;
constexpr int PK_EFFECT_CUSTOM_AUDIT_OPCODE = 1;
constexpr int PK_EFFECT_CUSTOM_CANAL_COMMIT_OPCODE = 2;
constexpr int PK_EFFECT_CUSTOM_IDEOLOGY_FREE_DRAW_OPCODE = 3;

constexpr int PK_PAYLOAD_NONE = 0;
constexpr int PK_PAYLOAD_SUCCESSION_V1 = 1; // i0=old_veg, i1=new_veg
constexpr int PK_PAYLOAD_ECONOMY_EPOCH_V1 = 2; // i0=epoch, i1=newest id, i2=count
constexpr int PK_PAYLOAD_ECONOMY_CONSTRUCTION_V1 = 3; // i0=type hash, i1=type id, i2=owner signature, i3=sponsor family index
constexpr int PK_PAYLOAD_ECONOMY_TRADE_V1 = 4; // i0=source, i1=destination, i2=good, i3=inter-country
// i0=new level, i1=worst dimension, i2=worst need, i3=previous level;
// value=population-weighted composite Q16, entity_id=population, flags=1 when
// the level fell.
constexpr int PK_PAYLOAD_SOCIAL_PRESSURE_V1 = 5;
// cell, i0=stage, i1=previous_stage, i2=profession, i3=country slot;
// value=mobilization Q16, entity_id=profession population, flags=player|capital.
constexpr int PK_PAYLOAD_STRATUM_MOBILIZATION_V1 = 26;
// cell=destination, entity_id=order, value=quantity; i0=source,
// i1=source country slot, i2=destination country slot, i3=good.
constexpr int PK_PAYLOAD_ECONOMY_TRADE_V2 = 8;

constexpr uint32_t EVENTS_BRIDGE_PRODUCER_ID = 0x45564201u;
constexpr uint64_t EVENTS_BRIDGE_REQUEST_PREFIX = 0x4556420000000000ull;
constexpr uint32_t GAMEPLAY_EFFECT_PRODUCER_ID = 0x45464601u;
constexpr uint64_t FNV_OFFSET = 1469598103934665603ull;
constexpr uint64_t FNV_PRIME = 1099511628211ull;

template <typename T>
static void append_le(std::vector<uint8_t> &out, T value) {
    using U = std::make_unsigned_t<T>;
    const U bits = static_cast<U>(value);
    for (size_t i = 0; i < sizeof(T); ++i)
        out.push_back(static_cast<uint8_t>((bits >> (i * 8u)) & 0xffu));
}

static uint64_t stable_consumer_key(const StringName &consumer_id) {
    const CharString utf8 = String(consumer_id).utf8();
    uint64_t hash = FNV_OFFSET;
    const char *bytes = utf8.get_data();
    for (size_t i = 0; bytes != nullptr && bytes[i] != '\0'; ++i) {
        hash ^= static_cast<uint8_t>(bytes[i]);
        hash *= FNV_PRIME;
    }
    return hash == 0 ? 1 : hash;
}

static int64_t worker_consumer_ack(const RuntimeEventsSnapshot &snapshot,
                                   uint64_t consumer_key) {
    const auto found = std::lower_bound(snapshot.consumer_acks.begin(),
        snapshot.consumer_acks.end(), consumer_key,
        [](const RuntimeEventsConsumerAck &entry, uint64_t key) {
            return entry.consumer_key < key;
        });
    return found != snapshot.consumer_acks.end() &&
        found->consumer_key == consumer_key ? found->event_id : 0;
}

static bool queue_events_bridge_batch(
        NativeSimulationHost *host,
        const std::vector<RuntimeEventsRecord> &records,
        std::string &error) {
    error.clear();
    if (host == nullptr || records.empty() ||
        records.size() > RUNTIME_EVENTS_MAX_BATCH_RECORDS) {
        error = "events_bridge_batch_invalid";
        return false;
    }
    const RuntimeThreadReport report = host->report();
    if (report.state == RuntimeWorkerState::STOPPED ||
        report.state == RuntimeWorkerState::STOPPING ||
        report.state == RuntimeWorkerState::FAULTED ||
        report.mode == RuntimeSimulationMode::OFF) {
        error = "events_bridge_worker_unavailable";
        return false;
    }
    return host->enqueue_legacy_event_batch(records, report.committed_day + 1,
        report.generation, error);
}

static bool queue_events_bridge_ack(NativeSimulationHost *host,
                                    const StringName &consumer_id,
                                    int64_t event_id,
                                    std::string &error) {
    error.clear();
    if (host == nullptr || event_id < 0) {
        error = "events_bridge_ack_invalid";
        return false;
    }
    const RuntimeThreadReport report = host->report();
    if (report.state == RuntimeWorkerState::STOPPED ||
        report.state == RuntimeWorkerState::STOPPING ||
        report.state == RuntimeWorkerState::FAULTED ||
        report.mode == RuntimeSimulationMode::OFF) {
        error = "events_bridge_worker_unavailable";
        return false;
    }
    if (!host->enqueue_event_consumer_ack(stable_consumer_key(consumer_id),
            event_id, report.committed_day + 1, report.generation, true)) {
        error = "events_bridge_queue_full";
        return false;
    }
    return true;
}

static int64_t event_i64_at(const PackedInt64Array &arr, int idx, int64_t fallback) {
    return (idx >= 0 && idx < arr.size()) ? arr[idx] : fallback;
}

static int event_i32_at(const PackedInt32Array &arr, int idx, int fallback) {
    return (idx >= 0 && idx < arr.size()) ? arr[idx] : fallback;
}

static PackedInt32Array dictionary_i32_array(const Dictionary &d, const char *key) {
    if (!d.has(key)) {
        return PackedInt32Array();
    }
    Variant v = d[key];
    if (v.get_type() == Variant::PACKED_INT32_ARRAY) {
        return v;
    }
    return PackedInt32Array();
}

static PackedInt64Array dictionary_i64_array(const Dictionary &d, const char *key) {
    if (!d.has(key)) {
        return PackedInt64Array();
    }
    Variant v = d[key];
    if (v.get_type() == Variant::PACKED_INT64_ARRAY) {
        return v;
    }
    return PackedInt64Array();
}

} // namespace
