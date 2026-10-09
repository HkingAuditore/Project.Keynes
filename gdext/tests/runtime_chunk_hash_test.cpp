#include "runtime_chunk_hash.h"
#include <cassert>
#include <random>

template<class T> void check() {
    std::mt19937_64 random(20261008);
    pk::RuntimeChunkHash hash;
    for (size_t size : {size_t(0),size_t(1),size_t(511),size_t(512),size_t(513),size_t(2049)}) {
        std::vector<T> values(size);
        for (auto &value : values) value = static_cast<T>(random());
        hash.clear();
        assert(hash.update(values, 1, 2) == pk::RuntimeChunkHash::rebuild(values, 1, 2));
        auto retained = hash.pages();
        std::vector<uint8_t> old = retained.empty() ? std::vector<uint8_t>{} : retained[0]->source;
        assert(hash.update(values, 1, 2) == pk::RuntimeChunkHash::rebuild(values, 1, 2));
        assert(hash.metrics().rebuilt_pages == 0);
        assert(hash.cumulative_metrics().compared_bytes == values.size() * sizeof(T) * 2);
        assert(hash.cumulative_metrics().copied_bytes == values.size() * sizeof(T));
        for (int step = 0; step < 40 && !values.empty(); ++step) {
            values[random()%values.size()] = static_cast<T>(random());
            assert(hash.update(values, 1, 2) == pk::RuntimeChunkHash::rebuild(values, 1, 2));
        }
        if (!retained.empty()) assert(retained[0]->source == old);
        std::reverse(values.begin(), values.end());
        assert(hash.update(values, 1, 2) == pk::RuntimeChunkHash::rebuild(values, 1, 2));
        if (!values.empty()) values.pop_back();
        assert(hash.update(values, 1, 2) == pk::RuntimeChunkHash::rebuild(values, 1, 2));
        assert(hash.update(values, 1, 3) == pk::RuntimeChunkHash::rebuild(values, 1, 3));
        hash.clear();
        assert(hash.update(values, 1, 2) == pk::RuntimeChunkHash::rebuild(values, 1, 2));
    }
}
int main() {
    check<int64_t>(); check<int32_t>(); check<uint16_t>(); check<uint8_t>();
    // Layout identity is explicit even for empty columns; a width or domain
    // change cannot reuse an empty root with a different interpretation.
    const std::vector<int64_t> wide;
    const std::vector<int32_t> narrow;
    assert(pk::RuntimeChunkHash::rebuild(wide, 1, 1) != pk::RuntimeChunkHash::rebuild(narrow, 1, 1));
    assert(pk::RuntimeChunkHash::rebuild(wide, 1, 1) != pk::RuntimeChunkHash::rebuild(wide, 2, 1));
    assert(pk::RuntimeChunkHash::rebuild(wide, 1, 1) != pk::RuntimeChunkHash::rebuild(wide, 1, 2));
}
