// ─── Canonical Climate stage order（B8 P0）───────────────────────────────────
//
// 表必须与 runtime_climate_kernel.cpp 里 plan_day 的实际调用序一致。任何一侧
// 改动都会让 runtime_climate_stage_order_self_test() 或运行期 sequence 校验失败，
// 而不是等到数值对拍里出现"某个字段不同"。
const RuntimeClimateStageOrderEntry RUNTIME_CLIMATE_CANONICAL_ORDER[] = {
    {RuntimeClimateStage::PASS_A, RuntimeClimateStageOrderKind::CORE},
    {RuntimeClimateStage::PASS_B, RuntimeClimateStageOrderKind::CORE},
    {RuntimeClimateStage::OCEAN_WATER, RuntimeClimateStageOrderKind::CORE},
    {RuntimeClimateStage::OCEAN_LAND, RuntimeClimateStageOrderKind::CORE},
    {RuntimeClimateStage::WIND_AIR, RuntimeClimateStageOrderKind::CORE},
    {RuntimeClimateStage::WIND_SURFACE, RuntimeClimateStageOrderKind::CORE},
    {RuntimeClimateStage::SEA_ICE, RuntimeClimateStageOrderKind::CORE},
    {RuntimeClimateStage::TRANSPIRATION, RuntimeClimateStageOrderKind::CORE},
    {RuntimeClimateStage::WEATHER, RuntimeClimateStageOrderKind::CONDITIONAL},
    {RuntimeClimateStage::RUNTIME_HYDROLOGY, RuntimeClimateStageOrderKind::CONDITIONAL},
    {RuntimeClimateStage::ALBEDO, RuntimeClimateStageOrderKind::CONDITIONAL},
    {RuntimeClimateStage::VEGETATION_DYNAMICS, RuntimeClimateStageOrderKind::CONDITIONAL},
    {RuntimeClimateStage::CLIMATE_FEEDBACK, RuntimeClimateStageOrderKind::CONDITIONAL},
    {RuntimeClimateStage::STAGE_B_AFTER_HYDROLOGY,
     RuntimeClimateStageOrderKind::FALLBACK_TAIL},
};

static_assert(sizeof(RUNTIME_CLIMATE_CANONICAL_ORDER) /
                      sizeof(RUNTIME_CLIMATE_CANONICAL_ORDER[0]) ==
                  RUNTIME_CLIMATE_CANONICAL_ORDER_COUNT,
              "canonical climate order table is out of sync with its count");

size_t runtime_climate_canonical_order_index(RuntimeClimateStage stage) {
    for (size_t i = 0; i < RUNTIME_CLIMATE_CANONICAL_ORDER_COUNT; ++i) {
        if (RUNTIME_CLIMATE_CANONICAL_ORDER[i].stage == stage) return i;
    }
    return RUNTIME_CLIMATE_STAGE_COUNT;
}

const char *runtime_climate_canonical_order_names() {
    // 静态拼接：调用方（契约测试、soak dump）把它当只读字符串。
    static const std::string joined = [] {
        std::string out;
        for (size_t i = 0; i < RUNTIME_CLIMATE_CANONICAL_ORDER_COUNT; ++i) {
            if (i != 0) out += '>';
            out += runtime_climate_stage_name(
                RUNTIME_CLIMATE_CANONICAL_ORDER[i].stage);
        }
        return out;
    }();
    return joined.c_str();
}

bool runtime_climate_stage_order_self_test(std::string &error) {
    error.clear();
    // 1. 每个真实 stage 恰好出现一次，COUNT 不出现。
    std::array<int, RUNTIME_CLIMATE_STAGE_COUNT> seen{};
    bool saw_fallback_tail = false;
    bool saw_weather = false;
    for (size_t i = 0; i < RUNTIME_CLIMATE_CANONICAL_ORDER_COUNT; ++i) {
        const RuntimeClimateStageOrderEntry &entry =
            RUNTIME_CLIMATE_CANONICAL_ORDER[i];
        const size_t index = static_cast<size_t>(entry.stage);
        if (index >= RUNTIME_CLIMATE_STAGE_COUNT) {
            error = "climate_stage_order_contains_count";
            return false;
        }
        if (++seen[index] != 1) {
            error = std::string("climate_stage_order_duplicate_") +
                runtime_climate_stage_name(entry.stage);
            return false;
        }
        // 2. FALLBACK_TAIL 只能在表尾，且不能再出现 CORE/CONDITIONAL。
        if (entry.kind == RuntimeClimateStageOrderKind::FALLBACK_TAIL) {
            saw_fallback_tail = true;
            if (i + 1u != RUNTIME_CLIMATE_CANONICAL_ORDER_COUNT) {
                error = "climate_stage_order_fallback_tail_not_last";
                return false;
            }
        } else if (saw_fallback_tail) {
            error = "climate_stage_order_core_after_fallback_tail";
            return false;
        }
        // 3. weather 段必须在 round 之后。round 的最后一个 stage 是 TRANSPIRATION；
        //    这条断言就是 B8-1 的机器可读形式。
        if (entry.stage == RuntimeClimateStage::WEATHER) saw_weather = true;
        if (entry.stage == RuntimeClimateStage::TRANSPIRATION && saw_weather) {
            error = "climate_stage_order_weather_before_round";
            return false;
        }
    }
    for (size_t i = 0; i < RUNTIME_CLIMATE_STAGE_COUNT; ++i) {
        if (seen[i] != 1) {
            error = std::string("climate_stage_order_missing_") +
                runtime_climate_stage_name(
                    static_cast<RuntimeClimateStage>(i));
            return false;
        }
    }
    // 4. stage_b 三段必须严格在 weather 之后，且内部顺序是 albedo → veg → feedback。
    const size_t weather = runtime_climate_canonical_order_index(
        RuntimeClimateStage::WEATHER);
    const size_t albedo = runtime_climate_canonical_order_index(
        RuntimeClimateStage::ALBEDO);
    const size_t vegetation = runtime_climate_canonical_order_index(
        RuntimeClimateStage::VEGETATION_DYNAMICS);
    const size_t feedback = runtime_climate_canonical_order_index(
        RuntimeClimateStage::CLIMATE_FEEDBACK);
    const size_t hydrology = runtime_climate_canonical_order_index(
        RuntimeClimateStage::RUNTIME_HYDROLOGY);
    if (!(weather < hydrology && hydrology < albedo && albedo < vegetation &&
          vegetation < feedback)) {
        error = "climate_stage_order_stage_b_not_after_weather";
        return false;
    }
    return true;
}

bool runtime_climate_stage_sequence_is_canonical(
        const uint8_t *sequence, size_t count, std::string &error) {
    error.clear();
    if (sequence == nullptr && count != 0) {
        error = "climate_stage_sequence_null";
        return false;
    }
    size_t previous = 0;
    bool have_previous = false;
    for (size_t i = 0; i < count; ++i) {
        const size_t raw = static_cast<size_t>(sequence[i]);
        if (raw >= RUNTIME_CLIMATE_STAGE_COUNT) {
            error = "climate_stage_sequence_out_of_range";
            return false;
        }
        const auto stage = static_cast<RuntimeClimateStage>(raw);
        const size_t index = runtime_climate_canonical_order_index(stage);
        if (index == RUNTIME_CLIMATE_STAGE_COUNT) {
            error = std::string("climate_stage_sequence_unknown_") +
                runtime_climate_stage_name(stage);
            return false;
        }
        if (have_previous && index < previous) {
            error = std::string("climate_stage_sequence_out_of_order_") +
                runtime_climate_stage_name(
                    static_cast<RuntimeClimateStage>(
                        sequence[i - 1u])) +
                "_then_" +
                runtime_climate_stage_name(stage);
            return false;
        }
        previous = index;
        have_previous = true;
    }
    return true;
}
