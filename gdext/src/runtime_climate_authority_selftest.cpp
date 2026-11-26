#include "runtime_climate_authority.h"
#include "runtime_switch_registry.h"
#include "runtime_climate_parity.h"
#include "runtime_climate_physics.h"

#include <chrono>
#include <cmath>
#include <cstring>
#include <cstdlib>
#include <limits>

namespace pk {

namespace {
#include "runtime_climate_authority_checksum.inc"
} // namespace

bool RuntimeClimateAuthority::self_test(std::string &error) {
    if (!RuntimeClimateKernel::self_test(error)) return false;
    // B8 P2：物理环流共享纯内核自检（SLP Pass A 有限性/水陆差异、Pass B Jacobi
    // 平均、recenter 零均值、response_rate=0 保持 prev）。生产路径已经切到同一份
    // 内核，所以这里的失败等价于 MapBaker 每日 SLP 求解失败。
    if (!pk_async_physics::self_test(error)) {
        error = "climate_physics_self_test_failed:" + error;
        return false;
    }
    // 开发期不兼容旧档：合成历史 payload，经正式 restore 验证版本错误。
    // 不把缺失继续态的旧档作为中性初始化世界加载。
    {
        const auto migration_fail = [&](const std::string &reason) {
            error = reason;
            std::fprintf(stderr, "[climate][abi-migration] %s\n", reason.c_str());
            std::fflush(stderr);
            return false;
        };
        RuntimeClimateAuthority authority;
        authority.reset(2);
        RuntimeEnvironmentSnapshot env;
        env.generation = 1;
        env.day = 0;
        env.cell_count = 2;
        env.climate_map_width = 2;
        env.climate_map_height = 1;
        env.climate_catalog_hash = 7;
        env.cell_temp = {15.0f, -8.0f};
        env.cell_temp_30d = env.cell_temp;
        env.cell_moisture = {0.5f, 0.25f};
        env.cell_plant_available_water = {0.7f, 0.2f};
        env.terrain = {1, 0};
        env.is_water = {0, 1};
        env.neighbor_offsets = {0, 1, 2};
        env.neighbor_indices = {1, 0};
        RuntimeClimateVerticalReport report;
        if (!authority.plan_day(0, env, report) ||
            !authority.commit_day(0, report)) {
            return migration_fail("climate_abi_migration_seed_failed");
        }
        std::vector<uint8_t> v4;
        if (!authority.serialize(v4, error) || v4.size() <= 88u) {
            return migration_fail(error.empty()
                ? "climate_abi_migration_serialize_failed" : error);
        }
        // 下面的布局常量描述 ABI 9（含历史 lane）：本函数会先把当前 ABI 10 的
        // payload 还原成 ABI 9 再逐级裁剪。
        // ABI 9 payload：header 80B + 前缀 56B +
        //   31 条 float lane（每条 u32 长度 + cells*f32）+
        //   temperature_history（u32 长度 + 365*cells*f32）+
        //   8 条 u8 lane（每条 u32 长度 + cells 字节）+
        //   2 条 i32 lane（每条 u32 长度 + cells*i32）+
        //   cyclone blob + physics blob。
        // 旧档 = 从这份 payload 里剪掉对应版本没有的 lane，改写 header 三处字段。
        constexpr size_t PAYLOAD_PREFIX = 56u;
        constexpr size_t FLOAT_LANES = 31u;
        constexpr size_t U8_LANES = 8u;
        constexpr size_t I32_LANES = 2u;
        const uint32_t cells = 2u;
        const size_t float_lane = sizeof(uint32_t) + cells * sizeof(float);
        const size_t u8_lane = sizeof(uint32_t) + cells;
        const size_t i32_lane = sizeof(uint32_t) + cells * sizeof(uint32_t);
        const size_t history_block =
            sizeof(uint32_t) + static_cast<size_t>(cells) * 365u * sizeof(float);
        const size_t floats_start = 80u + PAYLOAD_PREFIX;
        const size_t history_start = floats_start + FLOAT_LANES * float_lane;
        const size_t u8_start = history_start + history_block;
        const size_t i32_start = u8_start + U8_LANES * u8_lane;
        const size_t blob_start = i32_start + I32_LANES * i32_lane;
        // 当前序列化已是 ABI 10，不带历史 lane。把它还原成 ABI 9 的布局（在
        // history_start 插回 365*cells 的 f32 lane 并改写 header 的 abi/hash/
        // payload_size/checksum），再用这份 payload 按旧布局逐级裁剪：ABI 9 必须
        // 仍能恢复，ABI 8 及更旧必须被明确拒绝。
        {
            const auto &history = authority.store().temperature_history;
            if (history.size() != static_cast<size_t>(cells) * 365u) {
                return migration_fail("climate_abi_migration_history_shape_unexpected");
            }
            const uint32_t history_count = static_cast<uint32_t>(history.size());
            std::vector<uint8_t> values(sizeof(uint32_t) +
                                        history.size() * sizeof(float));
            std::memcpy(values.data(), &history_count, sizeof(history_count));
            std::memcpy(values.data() + sizeof(history_count), history.data(),
                        history.size() * sizeof(float));
            v4.insert(v4.begin() + static_cast<ptrdiff_t>(history_start),
                      values.begin(), values.end());
            const uint32_t abi9 = 9u;
            std::memcpy(v4.data() + 4, &abi9, sizeof(abi9));
            const uint64_t legacy_hash = authority.store().state_hash_abi8();
            std::memcpy(v4.data() + 56, &legacy_hash, sizeof(legacy_hash));
            const uint64_t payload_size = static_cast<uint64_t>(v4.size() - 80u);
            std::memcpy(v4.data() + 64, &payload_size, sizeof(payload_size));
            const uint64_t payload_checksum =
                checksum(v4.data() + 80, v4.size() - 80u);
            std::memcpy(v4.data() + 72, &payload_checksum,
                        sizeof(payload_checksum));
        }
        // blob 区 = u32 长度前缀 + bytes；长度必须与实际长度一致，否则形状异常。
        if (v4.size() < blob_start + sizeof(uint32_t)) {
            return migration_fail("climate_abi_migration_shape_unexpected");
        }
        uint32_t blob_len = 0;
        std::memcpy(&blob_len, v4.data() + blob_start, sizeof(blob_len));
        const size_t physics_start = blob_start + sizeof(uint32_t) + blob_len;
        if (v4.size() < physics_start + sizeof(uint32_t) +
                         authority.store().physics_state.size()) {
            return migration_fail("climate_abi_migration_blob_shape_unexpected");
        }
        const auto build_legacy = [&](uint32_t abi, size_t drop_float_lanes,
                                      size_t drop_u8_lanes,
                                      std::vector<uint8_t> &out,
                                      std::string &why) {
            out.assign(v4.begin(), v4.begin() + 80);
            out.insert(out.end(), v4.begin() + 80,
                       v4.begin() + static_cast<ptrdiff_t>(
                           floats_start + (FLOAT_LANES - drop_float_lanes) *
                               float_lane));
            out.insert(out.end(),
                       v4.begin() + static_cast<ptrdiff_t>(
                           history_start),
                       v4.begin() + static_cast<ptrdiff_t>(
                           u8_start + (U8_LANES - drop_u8_lanes) * u8_lane));
            // ABI >= 7 保留 physics；ABI 6 保留 cyclone、剪掉 physics；更旧剪掉 blob。
            const size_t payload_end = abi >= 7u ? physics_start + sizeof(uint32_t) + authority.store().physics_state.size()
                : (abi >= 6u ? physics_start : blob_start);
            out.insert(out.end(),
                       v4.begin() + static_cast<ptrdiff_t>(i32_start),
                       v4.begin() + static_cast<ptrdiff_t>(payload_end));
            std::memcpy(out.data() + 4, &abi, sizeof(abi));
            const uint64_t legacy_hash = abi >= 8u ? authority.store().state_hash_abi8() : abi >= 7u
                ? authority.store().state_hash_abi7()
                : authority.store().state_hash_abi6();
            std::memcpy(out.data() + 56, &legacy_hash, sizeof(legacy_hash));
            const uint64_t payload_size =
                static_cast<uint64_t>(out.size() - 80u);
            std::memcpy(out.data() + 64, &payload_size, sizeof(payload_size));
            const uint64_t payload_checksum =
                checksum(out.data() + 80, out.size() - 80u);
            std::memcpy(out.data() + 72, &payload_checksum,
                        sizeof(payload_checksum));
            why.clear();
            return true;
        };
        const auto check_legacy = [&](uint32_t abi, size_t drop_float_lanes,
                                      size_t drop_u8_lanes,
                                      const char *label) -> bool {
            std::vector<uint8_t> legacy;
            std::string why;
            if (!build_legacy(abi, drop_float_lanes, drop_u8_lanes, legacy, why)) {
                return migration_fail(std::string(label) + "_build_failed");
            }
            RuntimeClimateAuthority restored;
            restored.reset(2);
            std::string restore_error;
            if (restored.restore(legacy.data(), legacy.size(), restore_error) ||
                restore_error != "climate_section_version_mismatch_expected_10_got_" + std::to_string(abi)) {
                return migration_fail(std::string(label) + "_not_explicitly_rejected:" + restore_error);
            }
            return true;
        };
        // ABI 9 必须仍然可读：旧档带着历史 lane，恢复后 state_hash_abi8 复核要过，
        // 而 ABI 10 的当前哈希必须与它不同（历史不再参与）。
        {
            RuntimeClimateAuthority legacy_reader;
            legacy_reader.reset(2);
            std::string restore_error;
            if (!legacy_reader.restore(v4.data(), v4.size(), restore_error)) {
                return migration_fail("climate_abi9_read_failed:" + restore_error);
            }
            if (legacy_reader.store().temperature_history !=
                authority.store().temperature_history) {
                return migration_fail("climate_abi9_history_lost");
            }
            if (legacy_reader.store().state_hash() != authority.store().state_hash()) {
                return migration_fail("climate_abi9_current_hash_drift");
            }
            if (legacy_reader.snapshot().state_hash != legacy_reader.store().state_hash()) {
                return migration_fail("climate_abi9_published_hash_mismatch");
            }
        }
        if (!check_legacy(8u, 0u, 0u, "climate_abi8")) return false;
        // ABI 7 = 只缺 terrain / cover（2 条 u8 lane），保留 physics。
        if (!check_legacy(7u, 0u, 2u, "climate_abi7")) return false;
        // ABI 6 = 缺 terrain/cover + physics blob；现在明确拒绝。
        if (!check_legacy(6u, 0u, 2u, "climate_abi6")) return false;
        // ABI 5 = 缺 terrain/cover + cyclone / physics blob。
        if (!check_legacy(5u, 0u, 2u, "climate_abi5")) return false;
        // ABI 4 = 缺 vegetation / base_vegetation / terrain / cover（4 条 u8）。
        if (!check_legacy(4u, 0u, 4u, "climate_abi4")) return false;
        // ABI 3 = 同时缺 ψ 两条 float lane 与上述 4 条 u8 lane。
        if (!check_legacy(3u, 2u, 4u, "climate_abi3")) return false;
    }
    RuntimeEnvironmentSnapshot environment;
    environment.generation = 1;
    environment.day = 0;
    environment.cell_count = 2;
    environment.climate_map_width = 2;
    environment.climate_map_height = 1;
    environment.climate_catalog_hash = 7;
    environment.cell_temp = {15.0f, -8.0f};
    environment.cell_temp_30d = environment.cell_temp;
    environment.cell_moisture = {0.5f, 0.25f};
    environment.cell_plant_available_water = {0.7f, 0.2f};
    environment.terrain = {1, 0};
    environment.is_water = {0, 1};
    environment.neighbor_offsets = {0, 1, 2};
    environment.neighbor_indices = {1, 0};
    std::string validation_error;
    RuntimeEnvironmentSnapshot bad_nan = environment;
    bad_nan.cell_temp[0] = std::numeric_limits<float>::quiet_NaN();
    if (validate_runtime_environment_snapshot(bad_nan, validation_error) ||
        validation_error != "runtime_input_non_finite") {
        error = "climate_input_nan_not_rejected";
        return false;
    }
    RuntimeEnvironmentSnapshot bad_csr = environment;
    bad_csr.neighbor_offsets = {0, 2, 1};
    validation_error.clear();
    if (validate_runtime_environment_snapshot(bad_csr, validation_error) ||
        validation_error != "runtime_input_csr_invalid") {
        error = "climate_input_csr_not_rejected";
        return false;
    }
    RuntimeEnvironmentSnapshot bad_hydro = environment;
    bad_hydro.hydro_parent = {-1, 2};
    validation_error.clear();
    if (validate_runtime_environment_snapshot(bad_hydro, validation_error) ||
        validation_error != "runtime_input_hydro_parent_invalid") {
        error = "climate_input_hydro_parent_not_rejected";
        return false;
    }
    RuntimeEnvironmentSnapshot bad_hydro_cycle = environment;
    bad_hydro_cycle.hydro_parent = {1, 0};
    validation_error.clear();
    if (validate_runtime_environment_snapshot(bad_hydro_cycle, validation_error) ||
        validation_error != "runtime_input_hydro_cycle") {
        error = "climate_input_hydro_cycle_not_rejected";
        return false;
    }
    RuntimeEnvironmentSnapshot bad_lut = environment;
    bad_lut.trade_passable_lut = {1};
    bad_lut.trade_move_cost_lut = {1};
    validation_error.clear();
    if (validate_runtime_environment_snapshot(bad_lut, validation_error) ||
        validation_error != "runtime_input_lut_shape_mismatch") {
        error = "climate_input_lut_not_rejected";
        return false;
    }
    RuntimeEnvironmentSnapshot incomplete = environment;
    incomplete.climate_input_complete = true;
    incomplete.climate_catalog_hash = 7;
    incomplete.climate_map_width = 2;
    incomplete.climate_map_height = 1;
    incomplete.topology_validated = true;
    validation_error.clear();
    if (validate_runtime_environment_snapshot(incomplete, validation_error) ||
        validation_error != "runtime_input_complete_shape_missing") {
        error = "climate_complete_input_missing_lane_not_rejected";
        return false;
    }
    RuntimeEnvironmentSnapshot bad_dt = environment;
    bad_dt.dt_days = 0.0f;
    validation_error.clear();
    if (validate_runtime_environment_snapshot(bad_dt, validation_error) ||
        validation_error != "runtime_input_value_invalid") {
        error = "climate_invalid_dt_not_rejected";
        return false;
    }
    RuntimeClimateAuthority authority;
    RuntimeClimateVerticalReport report;
    if (!authority.plan_day(0, environment, report)) {
        error = report.error;
        return false;
    }
    // The host compares parity at plan time but only the committed state
    // becomes authoritative. If commit could change the parity reduction, a
    // day could be admitted on the strength of a hash that no longer describes
    // what was committed.
    const uint64_t planned_parity = report.parity_hash;
    if (planned_parity == 0) {
        error = "climate_plan_parity_hash_zero";
        return false;
    }
    if (!authority.commit_day(0, report)) {
        error = report.error;
        return false;
    }
    if (report.parity_hash != planned_parity) {
        error = "climate_commit_changed_parity_hash";
        return false;
    }
    if (authority.store().parity_hash() != planned_parity) {
        error = "climate_committed_store_parity_hash_mismatch";
        return false;
    }
    // commit 复用 plan 缓存的 state_hash；必须与提交后 store 重算一致。
    if (report.state_hash == 0 ||
        report.state_hash != authority.store().state_hash()) {
        error = "climate_commit_state_hash_reuse_mismatch";
        return false;
    }
    // parity_hash and state_hash must stay distinct concerns: the former is
    // comparable across the boundary, the latter guards save integrity.
    if (authority.store().parity_hash() == authority.store().state_hash()) {
        error = "climate_parity_and_state_hash_conflated";
        return false;
    }
    // A parity barrier may reject the planned next state before commit. The
    // abort must leave the last committed day/hash untouched and allow the
    // same input frame to be planned again deterministically.
    RuntimeClimateAuthority transaction;
    RuntimeClimateVerticalReport transaction_report;
    if (!transaction.plan_day(0, environment, transaction_report)) {
        error = "climate_discard_plan_fixture_failed";
        return false;
    }
    const uint64_t transaction_initial_hash = transaction.store().state_hash();
    transaction.discard_plan();
    if (transaction.store().committed_day != -1 ||
        transaction.store().generation != 0 ||
        transaction.store().state_hash() != transaction_initial_hash ||
        !transaction.plan_day(0, environment, transaction_report) ||
        !transaction.commit_day(0, transaction_report)) {
        error = "climate_discard_plan_not_transactional";
        return false;
    }
    std::vector<uint8_t> bytes;
    if (!authority.serialize(bytes, error)) return false;
    RuntimeClimateAuthority restored;
    if (!restored.restore(bytes.data(), bytes.size(), error) ||
        restored.store().state_hash() != authority.store().state_hash()) {
        if (error.empty()) error = "climate_section_roundtrip_failed";
        return false;
    }
    if (restored.snapshot().state_hash != restored.store().state_hash()) {
        error = "climate_section_published_hash_mismatch";
        return false;
    }

    std::vector<uint8_t> reencoded;
    if (!restored.serialize(reencoded, error) || reencoded != bytes) {
        error = "climate_continuation_roundtrip_bytes_changed";
        return false;
    }

    // Committed-view contract across worker-style plan/discard/retry and restore.
    RuntimeClimateCommittedView view;
    RuntimeClimateViewCursor cursor;
    const uint32_t cells = authority.store().cell_count;
    if (!authority.copy_committed_view(0, cells, cells, view) ||
        !cursor.observe(view) || !cursor.observe(view) ||
        view.fields[0] != authority.store().temperature) {
        error = "climate_committed_view_initial_failed";
        return false;
    }
    auto invalid_view = view;
    invalid_view.committed = false;
    if (cursor.accepts(invalid_view)) {
        error = "climate_view_inflight_accepted";
        return false;
    }
    invalid_view = view;
    --invalid_view.generation;
    if (cursor.accepts(invalid_view)) {
        error = "climate_view_generation_regression_accepted";
        return false;
    }
    invalid_view = view;
    --invalid_view.day;
    if (cursor.accepts(invalid_view)) {
        error = "climate_view_day_regression_accepted";
        return false;
    }
    RuntimeEnvironmentSnapshot next = environment;
    next.day = 1;
    next.generation = 2;
    RuntimeClimateVerticalReport next_report;
    if (!transaction.plan_day(1, next, next_report)) return false;
    transaction.discard_plan();
    RuntimeClimateCommittedView retry_view;
    if (!transaction.copy_committed_view(0, cells, cells, retry_view) ||
        !cursor.observe(retry_view) || retry_view.fields != view.fields ||
        !transaction.plan_day(1, next, next_report) ||
        !transaction.commit_day(1, next_report) ||
        !transaction.copy_committed_view(1, cells, cells, retry_view) ||
        !cursor.observe(retry_view) || cursor.accepts(view) ||
        view.day != 0 || view.fields[0] != authority.store().temperature) {
        error = "climate_committed_view_retry_failed";
        return false;
    }
    if (!restored.plan_day(1, next, next_report) ||
        !restored.commit_day(1, next_report) ||
        restored.store().state_hash() != transaction.store().state_hash()) {
        error = "climate_committed_view_restore_continuation_failed";
        return false;
    }

    // The worker must reject a second plan that reuses an input generation,
    // and must expose catalog drift as a preflight error instead of silently
    // reseeding the POD store.
    RuntimeClimateVerticalReport rejected;
    RuntimeEnvironmentSnapshot repeated = environment;
    repeated.generation = 2;
    repeated.day = 1;
    repeated.climate_catalog_hash = 8;
    if (authority.plan_day(1, repeated, rejected) ||
        std::string(rejected.error) != "climate_catalog_hash_mismatch") {
        error = "climate_catalog_mismatch_not_rejected";
        return false;
    }
    repeated.climate_catalog_hash = environment.climate_catalog_hash;
    repeated.generation = 1;
    if (authority.plan_day(1, repeated, rejected) ||
        std::string(rejected.error) != "climate_input_generation_not_monotonic") {
        error = "climate_generation_reuse_not_rejected";
        return false;
    }

    RuntimeEnvironmentSnapshot bad_abi = environment;
    bad_abi.generation = 2;
    bad_abi.day = 1;
    bad_abi.climate_catalog_abi_version = RUNTIME_DOMAIN_POD_ABI_VERSION + 1u;
    if (authority.plan_day(1, bad_abi, rejected) ||
        std::string(rejected.error) != "climate_catalog_abi_mismatch") {
        error = "climate_catalog_abi_mismatch_not_rejected";
        return false;
    }

    // A restore is decoded into a temporary store, then checked against the
    // already bootstrapped catalog and map shape before any member is changed.
    RuntimeClimateAuthority shape_mismatch;
    if (!shape_mismatch.plan_day(0, environment, rejected) ||
        !shape_mismatch.commit_day(0, rejected)) {
        error = "climate_restore_shape_fixture_failed";
        return false;
    }
    RuntimeEnvironmentSnapshot different_shape = environment;
    different_shape.climate_map_width = 1;
    different_shape.climate_map_height = 2;
    RuntimeClimateAuthority shape_reference;
    if (!shape_reference.plan_day(0, different_shape, rejected) ||
        !shape_reference.commit_day(0, rejected)) {
        error = "climate_restore_shape_reference_failed";
        return false;
    }
    if (shape_reference.restore(bytes.data(), bytes.size(), error) ||
        error != "climate_restore_catalog_mismatch") {
        error = "climate_restore_shape_mismatch_not_rejected";
        return false;
    }

    std::vector<uint8_t> bad_section_abi = bytes;
    bad_section_abi[4] = 1u;
    RuntimeClimateAuthority incompatible;
    if (incompatible.restore(bad_section_abi.data(), bad_section_abi.size(), error) ||
        error != "climate_section_version_mismatch_expected_10_got_1") {
        error = "climate_section_abi_mismatch_not_rejected";
        return false;
    }
    return true;
}

} // namespace pk
