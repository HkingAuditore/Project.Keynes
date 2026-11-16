// Included once by military_core_selftest.cpp.
bool test_performance_flight_sums(std::string &report) {
    using Key = MilitaryFlightSums::Key;
    using Row = MilitaryFlightSums::Row;
    MilitaryFlightSums sums;
    auto original_sum = [](std::vector<Row> rows, const Key &key) {
        std::sort(rows.begin(), rows.end());
        auto at = std::lower_bound(rows.begin(), rows.end(), key,
            [](const auto &row, const auto &value) { return row.first < value; });
        int64_t result = 0;
        while (at != rows.end() && at->first == key) {
            result += at->second;
            ++at;
        }
        return result;
    };
    const Key key{2, MILITARY_LOT_ARMY, 17, 1};
    std::vector<Row> rows{{key, 90}, {{1, MILITARY_LOT_ARMY, 17, 1}, 4}, {key, 5},
                          {{2, MILITARY_LOT_GARRISON, 17, 1}, 6},
                          {{2, MILITARY_LOT_ARMY, 18, 1}, 7},
                          {{2, MILITARY_LOT_ARMY, 17, 2}, 8}, {key, 0}};
    const auto unchanged = rows;
    ST_CHECK(sums.build(rows) && rows == unchanged && sums.size() == 5,
             "inflight index preserves rows and separates every key component");
    for (const Row &row : rows)
        ST_CHECK(sums.get(row.first) == original_sum(rows, row.first),
                 "inflight sums equal original sorted int64 loop");
    ST_CHECK(sums.get(Key{-1, 0, -1, -1}) == 0, "inflight absent key remains zero");
    // These two keys collide in the four-bucket table. Both lookup and an
    // absent key must pass an occupied bucket without reading another total.
    rows = {{{0, 0, 0, 0}, 11}, {{0, 0, 4, 0}, 23}};
    ST_CHECK(sums.build(rows) && sums.get(rows[0].first) == 11 &&
                 sums.get(rows[1].first) == 23 && sums.get(Key{0, 0, 8, 0}) == 0,
             "inflight hash collision preserves both keys and miss termination");
    rows.clear();
    for (int32_t i = 0; i < 512; ++i) {
        rows.push_back({Key{i % 7 - 3, uint8_t(i % 3), i % 23 - 2, i % 5 - 1}, i});
        rows.push_back(rows.back());
    }
    ST_CHECK(sums.build(rows), "inflight dense collision fixture builds");
    bool equal = true;
    for (const Row &row : rows) equal &= sums.get(row.first) == original_sum(rows, row.first);
    ST_CHECK(equal, "inflight repeated mixed signed keys equal original loop");
    const int64_t maximum = std::numeric_limits<int64_t>::max();
    rows = {{key, maximum - 1}, {key, 1}};
    ST_CHECK(sums.build(rows) && sums.get(key) == original_sum(rows, key),
             "inflight largest representable nonnegative sum remains exact");
    rows.push_back({key, 1});
    const auto overflow_rows = rows;
    ST_CHECK(!sums.build(rows) && rows == overflow_rows && sums.size() == 0,
             "overflow risk leaves original rows for existing sorted path");
    // Do not execute signed overflow in a test: it is undefined C++ behavior.
    // A representable negative case does exercise the unchanged old arithmetic.
    rows = {{key, 10}, {key, -4}};
    ST_CHECK(!sums.build(rows) && original_sum(rows, key) == 6 && sums.size() == 0,
             "negative conversion retains original value ordering and addition");
    rows = {{key, 3}};
    ST_CHECK(sums.build(rows) && sums.get(key) == 3,
             "next request cannot reuse prior partial or successful sum");
    rows.clear();
    ST_CHECK(sums.build(rows) && sums.size() == 0 && sums.get(key) == 0,
             "empty request publishes no previous keys");
    sums.clear();
    ST_CHECK(sums.get(key) == 0, "cleared request has no lookup result");
    return true;
}
