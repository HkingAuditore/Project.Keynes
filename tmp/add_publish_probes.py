exec(open('tmp/edit_publish_optimization.py',encoding='utf-8').read().split('for domain,cls')[0])
p,s=read('gdext/src/economy_graph_stage_dispatch.cpp')
s=s.replace('#include <cstdio>','#include <cstdio>\n#include <chrono>')
s=s.replace('''    case RuntimeEconomyGraphStage::AGGREGATE_PUBLISH: {
        int64_t work''','''    case RuntimeEconomyGraphStage::AGGREGATE_PUBLISH: {
        const auto probe_begin = std::chrono::steady_clock::now();
        int64_t work''')
s=s.replace('''        // ACTIVE 投影在真正执行 POD 命令前或 Host 最终发布时刷新。
        finish_ok(result, input, runtime, stage);''','''        // ACTIVE 投影在真正执行 POD 命令前或 Host 最终发布时刷新。
        const auto probe_publish = std::chrono::steady_clock::now();
        finish_ok(result, input, runtime, stage);
        if (input.sample_day % 100 == 0 && !input.stage_hashes_enabled) {
            std::fprintf(stderr, "[economy-aggregate-cost] day=%lld publish_ms=%.3f native_hash_ms=%.3f\\n",
                static_cast<long long>(input.sample_day),
                std::chrono::duration<double, std::milli>(probe_publish - probe_begin).count(),
                std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - probe_publish).count());
        }''')
p.write_text(s,encoding='utf-8')
p,s=read('gdext/src/runtime_economy_pod.cpp')
s=s.replace('#include <cstring>','#include <cstring>\n#include <cstdio>')
s=s.replace('''    ledger.clear();
    ledger.generation = _state.state_generation;''','''    ledger.clear();
    const auto copy_started = std::chrono::steady_clock::now();
    ledger.generation = _state.state_generation;''')
s=s.replace('''    const char *validation_reason = nullptr;
    if (!ledger.valid(&validation_reason))''','''    const auto validation_started = std::chrono::steady_clock::now();
    const char *validation_reason = nullptr;
    if (!ledger.valid(&validation_reason))''')
s=s.replace('''    ledger.recompute_hash();
    return true;
}

void RuntimeEconomyPodAuthority::reset''','''    const auto hash_started = std::chrono::steady_clock::now();
    ledger.recompute_hash();
    if (ledger.committed_day > 0 && ledger.committed_day % 100 == 0) {
        std::fprintf(stderr, "[economy-ledger-cost] day=%lld copy_ms=%.3f validate_ms=%.3f hash_ms=%.3f cohorts=%zu markets=%zu\\n",
            static_cast<long long>(ledger.committed_day),
            std::chrono::duration<double, std::milli>(validation_started - copy_started).count(),
            std::chrono::duration<double, std::milli>(hash_started - validation_started).count(),
            elapsed_ms(hash_started), ledger.cohort_active.size(), ledger.market_stock.size());
    }
    return true;
}

void RuntimeEconomyPodAuthority::reset''')
# Compare optimized hash to the actual serialized wire, including empty and populated fixtures.
needle='''    if (!authority.capture_committed_ledger_state('''
pos=s.index(needle,s.index('bool RuntimeEconomyPodAuthority::self_test'))
test='''    auto wire_hash_matches = [](const auto &store) {
        std::vector<uint8_t> wire;
        store.append_wire(wire);
        uint64_t expected = FNV_OFFSET;
        uint64_t mixed = (uint64_t{0x123456789abcdef0} ^ wire.size()) * FNV_PRIME;
        for (uint8_t byte : wire) {
            expected = (expected ^ byte) * FNV_PRIME;
            mixed = (mixed ^ byte) * FNV_PRIME;
        }
        return expected == store.wire_content_hash() &&
            mixed == store.mix_wire_hash(0x123456789abcdef0);
    };
    if (!wire_hash_matches(authority.state().building.store) ||
        !wire_hash_matches(authority.state().family.store) ||
        !wire_hash_matches(authority.state().trade_escrow.store) ||
        !wire_hash_matches(RuntimeEconomyBuildingStore{}) ||
        !wire_hash_matches(RuntimeEconomyFamilyStore{}) ||
        !wire_hash_matches(RuntimeEconomyTradeEscrowStore{})) {
        error = "economy_streaming_wire_hash_mismatch";
        return false;
    }
'''
s=s[:pos]+test+s[pos:]
p.write_text(s,encoding='utf-8')
