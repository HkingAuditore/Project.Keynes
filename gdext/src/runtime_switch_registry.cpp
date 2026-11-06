#include "runtime_switch_registry.h"
#include <cassert>
#include <cstdlib>
#include <filesystem>
#include <cstdio>

namespace pk {
namespace {
constexpr RuntimeSwitchDescriptor switches[] = {
    {"PK_CLIMATE_CYCLONE_FORCE", "关闭覆盖；原调用点解析", "强制开启气旋", false},
    {"PK_CLIMATE_CYCLONE_GENESIS_GATE", "0（不覆盖原阈值）", "覆盖气旋生成强度阈值", false},
    {"PK_CLIMATE_FIELD_DIAG", "关闭覆盖；原调用点解析", "气候对拍逐字段差异", true},
    {"PK_CLIMATE_HISTORY_COPY_FULL", "关闭覆盖；原调用点解析", "完整复制气候历史", true},
    {"PK_CLIMATE_HISTORY_COPY_VERIFY", "关闭覆盖；原调用点解析", "核对气候历史增量复制", true},
    {"PK_CLIMATE_INPUT_HASH_FULL", "关闭覆盖；原调用点解析", "完整计算气候输入哈希", true},
    {"PK_CLIMATE_LANE_DIAG", "关闭覆盖；原调用点解析", "气候列覆盖诊断", true},
    {"PK_CLIMATE_PHYSICS_RESIDENT_VERIFY", "关闭覆盖；原调用点解析", "核对气候驻留状态复用", true},
    {"PK_CLIMATE_PHYSICS_RESTORE_FULL", "关闭覆盖；原调用点解析", "完整恢复气候物理状态", true},
    {"PK_CLIMATE_SCALAR_DIAG", "关闭覆盖；原调用点解析", "气候标量覆盖诊断", true},
    {"PK_CLIMATE_STAGE_ORDER_LEGACY", "关闭覆盖；原调用点解析", "采用旧气候阶段顺序", false},
    {"PK_CLIMATE_STAGE_TRACE", "关闭覆盖；原调用点解析", "气候阶段执行追踪", true},
    {"PK_CLIMATE_SYNOPTIC_OFF", "关闭覆盖；原调用点解析", "关闭大尺度天气推进", false},
    {"PK_CLIMATE_TRACE_CELL", "-1（不追踪）", "指定地块气候追踪", true},
    {"PK_COUNTRY_HASH_PROBE", "关闭；任意已设置值（含空串）开启", "国家恢复哈希错误诊断", true},
    {"PK_DIAG_NO_FOOD_SUBSTITUTE", "关闭；任意已设置值（含空串）开启", "禁止食品替代价格上限（改变模拟）", false},
    {"PK_DIAG_NO_STARVING_RELEASE", "关闭；任意已设置值（含空串）开启", "禁止饥饿所有者释放岗位（改变模拟）", false},
    {"PK_DIAG_STAGE_MONEY", "-1（不追踪）", "从指定日开始逐阶段资金诊断", true},
    {"PK_DISABLE_SUPPORT_GATE", "关闭；任意已设置值（含空串）开启", "清空意识形态支持门槛（改变模拟）", false},
    {"PK_ECONOMY_ACTIVE_WORKSET_DISABLE", "关闭覆盖；原调用点解析", "关闭经济活动集合优化", true},
    {"PK_ECONOMY_ATTRIBUTION_MEMO_DISABLE", "关闭覆盖；原调用点解析", "关闭冻结价归属缓存", true},
    {"PK_ECONOMY_AUDIT_SHADOW_REUSE", "开启；仅精确字符串 0 关闭", "复用守恒审计前像", true},
    {"PK_ECONOMY_AUDIT_VERIFY_EVERY_DAY", "关闭覆盖；原调用点解析", "每天核对全量守恒审计", true},
    {"PK_ECONOMY_COST_CSV", "不输出文件；空串也不打开", "经济阶段耗时 CSV 文件", true},
    {"PK_ECONOMY_COST_CSV_FULL", "关闭覆盖；原调用点解析", "逐条输出经济耗时", true},
    {"PK_ECONOMY_DERIVED_PARALLEL", "开启；仅精确字符串 0 关闭", "派生数据并行计算", true},
    {"PK_ECONOMY_DERIVED_PRICE_CONDUCTION", "开启；仅精确字符串 0 关闭", "派生需求价格传导", false},
    {"PK_ECONOMY_DERIVED_STARTUP", "开启；仅精确字符串 0 关闭", "派生需求价格传导", false},
    {"PK_ECONOMY_DERIVED_TASKS", "0（使用原自动任务数）", "覆盖派生数据任务数", true},
    {"PK_ECONOMY_DERIVED_TRACE", "关闭覆盖；原调用点解析", "派生任务耗时诊断", true},
    {"PK_ECONOMY_FAMILY_GOOD_CACHE_DISABLE", "关闭覆盖；原调用点解析", "关闭家庭物资折扣缓存", true},
    {"PK_ECONOMY_FAMILY_LOOKUP_LINEAR", "关闭覆盖；原调用点解析", "家庭行为查询改走线性参考", true},
    {"PK_ECONOMY_FAMILY_LOOKUP_VERIFY", "关闭覆盖；原调用点解析", "核对家庭查询索引", true},
    {"PK_ECONOMY_FAMILY_METRIC_MASK_DISABLE", "关闭覆盖；原调用点解析", "计算完整家庭指标", true},
    {"PK_ECONOMY_FOOD_CAPACITY_SERIAL", "关闭覆盖；原调用点解析", "食物承载计算串行", true},
    {"PK_ECONOMY_FOOD_STOCK_SCAN_SCALAR", "关闭覆盖；原调用点解析", "食物库存改走完整扫描", true},
    {"PK_ECONOMY_HASH_V2", "开启；仅精确字符串 0 关闭", "启用分块哈希", false},
    {"PK_ECONOMY_HASH_VERIFY", "关闭覆盖；原调用点解析", "核对经济增量哈希", true},
    {"PK_ECONOMY_MARKET_PUBLISH_FULL", "关闭覆盖；原调用点解析", "市场发布完整复制", true},
    {"PK_ECONOMY_MEMO_DISABLE", "关闭覆盖；原调用点解析", "关闭生活成本缓存", true},
    {"PK_ECONOMY_MEMO_VERIFY", "关闭覆盖；原调用点解析", "核对经济缓存命中结果", true},
    {"PK_ECONOMY_MIRROR_VERIFY", "关闭覆盖；原调用点解析", "核对经济镜像导入与发布", true},
    {"PK_ECONOMY_MUL_DIV_SCALAR", "关闭覆盖；原调用点解析", "乘除改走宽整数参考", true},
    {"PK_ECONOMY_OWNER_QUOTE_TRACE", "关闭覆盖；原调用点解析", "建筑所有者报价耗时诊断", true},
    {"PK_ECONOMY_POW_CACHE_DISABLE", "关闭覆盖；原调用点解析", "关闭定点幂缓存", true},
    {"PK_ECONOMY_PREVIEW_BASIS_DISABLE", "关闭覆盖；原调用点解析", "关闭需求预估基底复用", true},
    {"PK_ECONOMY_PRODUCTION_TASKS", "0（使用原自动任务数）", "覆盖生产任务数量", true},
    {"PK_ECONOMY_RESOURCE_PROJECTION_SCALAR", "关闭覆盖；原调用点解析", "资源投影改走标量复制", true},
    {"PK_ECONOMY_RESOURCE_WIRE_CACHE_DISABLE", "关闭覆盖；原调用点解析", "关闭资源保存哈希缓存", true},
    {"PK_ECONOMY_RESOURCE_WIRE_HASH_SCALAR", "关闭覆盖；原调用点解析", "资源保存哈希标量参考", true},
    {"PK_ECONOMY_RETENTION_MEMO_DISABLE", "关闭覆盖；原调用点解析", "关闭留存估值缓存", true},
    {"PK_ECONOMY_STAGE_PLAN_SERIAL", "关闭覆盖；原调用点解析", "经济计划任务串行", true},
    {"PK_ECONOMY_STARTUP_TRACE", "关闭覆盖；原调用点解析", "启动生产者选择耗时", true},
    {"PK_ECONOMY_TRACK_B", "开启；仅精确字符串 0 关闭", "开启分日刷新和缓存节拍", false},
    {"PK_ECONOMY_TRACK_B_COMMIT_CADENCE", "4；正数上限 30", "建筑提交刷新周期", false},
    {"PK_ECONOMY_TRACK_B_COMMIT_SPREAD", "4；正数上限 32", "建筑投资分日分桶数", false},
    {"PK_ECONOMY_TRACK_B_DERIVED_CADENCE", "5；正数上限 30", "派生数据刷新周期", false},
    {"PK_ECONOMY_TRACK_B_DERIVED_SPREAD", "4；正数上限 32", "派生数据分日分桶数", false},
    {"PK_ECONOMY_TRACK_B_FAMILY_ATTRIBUTION_CADENCE", "5；正数上限 30", "家庭归属刷新周期", false},
    {"PK_ECONOMY_TRACK_B_FAMILY_ATTRIBUTION_SPREAD", "1；正数上限 32", "家庭归属分日分桶数", false},
    {"PK_ECONOMY_TRACK_B_FAMILY_CACHE_CADENCE", "5；正数上限 30", "家庭缓存刷新周期", false},
    {"PK_ECONOMY_TRACK_B_FAMILY_CACHE_OFFSET", "1；非零取绝对值", "家庭缓存刷新相位", false},
    {"PK_ECONOMY_TRACK_B_HASH_CADENCE", "8；正数上限 30", "哈希全量刷新周期", false},
    {"PK_ECONOMY_TRACK_B_HASH_OFFSET", "2；非零取绝对值", "哈希刷新相位", false},
    {"PK_ECONOMY_TRACK_B_MOBILITY_CADENCE", "5；正数上限 30", "就业流动刷新周期", false},
    {"PK_ECONOMY_TRACK_B_MOBILITY_SPREAD", "1；正数上限 32", "就业流动分日分桶数", false},
    {"PK_ECONOMY_TRACK_B_RECOVERY_OFFSET", "1；非零取绝对值", "恢复提交刷新相位", false},
    {"PK_ECONOMY_TRACK_B_INVESTMENT_OFFSET", "3；非零取绝对值", "建筑投资刷新相位", false},
    {"PK_ECONOMY_VARIANT_PRICE_BASIS_DISABLE", "关闭覆盖；原调用点解析", "关闭变体价格基底复用", true},
    {"PK_ECONOMY_VARIANT_WEIGHT_SCALAR", "关闭覆盖；原调用点解析", "变体权重改走标量参考", true},
    {"PK_ECONOMY_WORKER_TASK_CAP", "0（使用原自动任务数）", "覆盖经济工作任务上限", true},
    {"PK_EVENTS_APPEND_SCALAR", "关闭覆盖；原调用点解析", "事件追加采用标量压缩", true},
    {"PK_GOLDEN_COUNTRY_TRACE", "不输出文件；空串也不打开", "国家逐列黄金诊断文件", true},
    {"PK_GOLDEN_DOMAINS", "关闭覆盖；原调用点解析", "只读逐域黄金摘要", true},
    {"PK_INLINE_DAY_BUDGET_MS", "30000 ms；空串同；非正数为 0", "内联日执行预算", false},
    {"PK_INLINE_PARALLEL", "关闭覆盖；原调用点解析", "允许内联日线程池", false},
    {"PK_PEER_STALL_TIMEOUT_MS", "RUNTIME_DAY_STALL_PEER_FAULT_TIMEOUT_MS；空串同；仅允许增大", "国家经济互等故障超时", false},
    {"PK_RUNTIME_INPUT_HASH_FULL", "关闭覆盖；原调用点解析", "完整重算冻结输入哈希", true},
    {"PK_RUNTIME_INPUT_HASH_VERIFY", "关闭覆盖；原调用点解析", "核对冻结输入哈希复用", true},
    {"PK_RUNTIME_WATERFALL_CSV", "不输出文件；空串也不打开", "运行时阶段耗时 CSV 文件", true},
    {"PK_SAVE_BYTE_HASH_SCALAR", "关闭覆盖；原调用点解析", "保存字节哈希改走标量参考实现", true},
    {"PK_SAVE_BYTE_HASH_VERIFY", "关闭覆盖；原调用点解析", "核对保存字节哈希", true},
    {"PK_SAVE_CODEC_SCALAR", "关闭覆盖；原调用点解析", "保存编码改走标量参考", true},
    {"PK_SAVE_CODEC_VERIFY", "关闭覆盖；原调用点解析", "核对保存编码字节", true},
    {"PK_SAVE_MIGRATE", "关闭覆盖；原调用点解析", "允许旧哈希保存迁移", false},
    {"PK_SAVE_SHAPE_PROBE", "关闭；任意已设置值（含空串）开启", "保存形状错误诊断", true},
    {"PK_SIM_DAY_TRACE", "不输出文件；空串也不打开", "逐日环境和阶段追踪文件", true},
    {"PK_TAG_FORCE_ALL", "关闭覆盖；原调用点解析", "家庭效果计算全部标签", true},
    {"PK_TRIGGER_BINDING_SCAN_SCALAR", "关闭覆盖；原调用点解析", "触发绑定完整扫描", true},
    {"PK_TRIGGER_COMMAND_COPY_SCALAR", "关闭覆盖；原调用点解析", "触发命令复制并排序参考", true},
    {"PK_TRIGGER_HASH_SCALAR", "关闭覆盖；原调用点解析", "触发状态哈希标量参考", true},
    {"PK_TRIGGER_MEMO_VERIFY", "关闭覆盖；原调用点解析", "核对触发缓存结果", true},
    {"PK_TTA_CARRY_OFF", "继承开启；任意已设置值（含空串）关闭", "关闭温度输送异常跨日继承", false},
    {"PK_TTA_DIAG", "关闭；任意已设置值（含空串）开启", "打印温度输送异常统计", true},
    {"PK_WEB_PARALLEL", "关闭覆盖；原调用点解析", "允许 Web 线程池", false},
    {"PK_WS_PROBE_CELL", "-1（不追踪）", "指定地块地表风探针", true},
    {"PK_X16_PROBE", "关闭；任意已设置值（含空串）开启", "冻结 Modifier 职业容忍参数诊断", true},
    {"PK_EXPERIMENT_EXTERNAL_DAY_ALIGNMENT", "关闭；仅精确字符串 1 开启", "仅测试宿主：同日空闲边界执行军事与资源；正式宿主无入口", true},
    {"PK_WEB_ALLOW_GDSCRIPT_DAILY_FALLBACK", "关闭；脚本导出属性或精确字符串 1 开启", "Web 原生执行器不可用时允许旧脚本日推进；桌面不读取", false},
};
static_assert(sizeof(switches) / sizeof(switches[0]) == static_cast<std::size_t>(RuntimeSwitch::COUNT));
constexpr RuntimeFaultDescriptor faults[] = {
    {"authority.switch.after", "disabled until armed", "explicit host boundary", true},
    {"authority.switch.before", "disabled until armed", "explicit host boundary", true},
    {"climate.plan.after", "disabled until armed", "domain plan boundary", true},
    {"climate.plan.before", "disabled until armed", "domain plan boundary", true},
    {"commit.plan.after", "disabled until armed", "domain plan boundary", true},
    {"commit.plan.before", "disabled until armed", "domain plan boundary", true},
    {"country.plan.after", "disabled until armed", "domain plan boundary", true},
    {"country.plan.before", "disabled until armed", "domain plan boundary", true},
    {"day.commit.after", "disabled until armed", "explicit host boundary", true},
    {"day.commit.before", "disabled until armed", "explicit host boundary", true},
    {"day.plan.after", "disabled until armed", "domain plan boundary", true},
    {"day.plan.before", "disabled until armed", "domain plan boundary", true},
    {"economy.commit.after", "disabled until armed", "explicit host boundary", true},
    {"economy.commit.before", "disabled until armed", "explicit host boundary", true},
    {"economy.plan.after", "disabled until armed", "domain plan boundary", true},
    {"economy.plan.before", "disabled until armed", "domain plan boundary", true},
    {"economy.reservation.after", "disabled until armed", "explicit host boundary", true},
    {"economy.reservation.before", "disabled until armed", "explicit host boundary", true},
    {"effect.plan.after", "disabled until armed", "domain plan boundary", true},
    {"effect.plan.before", "disabled until armed", "domain plan boundary", true},
    {"events.append.after", "disabled until armed", "explicit host boundary", true},
    {"events.append.before", "disabled until armed", "explicit host boundary", true},
    {"events.commit.after", "disabled until armed", "explicit host boundary", true},
    {"events.commit.before", "disabled until armed", "explicit host boundary", true},
    {"events.plan.after", "disabled until armed", "domain plan boundary", true},
    {"events.plan.before", "disabled until armed", "domain plan boundary", true},
    {"gameplay_effect.plan.after", "disabled until armed", "domain plan boundary", true},
    {"gameplay_effect.plan.before", "disabled until armed", "domain plan boundary", true},
    {"ideology.plan.after", "disabled until armed", "domain plan boundary", true},
    {"ideology.plan.before", "disabled until armed", "domain plan boundary", true},
    {"input_capture.plan.after", "disabled until armed", "domain plan boundary", true},
    {"input_capture.plan.before", "disabled until armed", "domain plan boundary", true},
    {"modifier.plan.after", "disabled until armed", "domain plan boundary", true},
    {"modifier.plan.before", "disabled until armed", "domain plan boundary", true},
    {"restore.decode.before", "disabled until armed", "explicit host boundary", true},
    {"restore.swap.before", "disabled until armed", "explicit host boundary", true},
    {"restore.validate.before", "disabled until armed", "explicit host boundary", true},
    {"save.barrier.after", "disabled until armed", "explicit host boundary", true},
    {"save.barrier.before", "disabled until armed", "explicit host boundary", true},
    {"trigger_input.plan.after", "disabled until armed", "domain plan boundary", true},
    {"trigger_input.plan.before", "disabled until armed", "domain plan boundary", true},
    {"unknown.plan.after", "disabled until armed", "domain plan boundary", true},
    {"unknown.plan.before", "disabled until armed", "domain plan boundary", true},
    {"visual.plan.after", "disabled until armed", "domain plan boundary", true},
    {"visual.plan.before", "disabled until armed", "domain plan boundary", true},
    {"worker.inflight.before", "disabled until armed", "explicit host boundary", true},
};
}

const char *runtime_switch_value(RuntimeSwitch id) noexcept {
    const auto index = static_cast<std::size_t>(id);
    assert(index < static_cast<std::size_t>(RuntimeSwitch::COUNT));
    // Do not normalize unset/empty values or cache here. The existing reader
    // owns both decisions and receives the same environment-owned pointer.
    const char *value = std::getenv(switches[index].name);
    const bool file_path = id == RuntimeSwitch::PK_SIM_DAY_TRACE ||
        id == RuntimeSwitch::PK_GOLDEN_COUNTRY_TRACE ||
        id == RuntimeSwitch::PK_ECONOMY_COST_CSV ||
        id == RuntimeSwitch::PK_RUNTIME_WATERFALL_CSV;
    if (file_path && value && *value && !std::filesystem::path(value).is_absolute()) {
        // A boolean such as "1" is not a filename. Reject before any writer opens it.
        return nullptr;
    }
    return value;
}
const RuntimeSwitchDescriptor *runtime_switch_registry(std::size_t &count) noexcept {
    count = sizeof(switches) / sizeof(switches[0]);
    return switches;
}
const RuntimeFaultDescriptor *runtime_fault_registry(std::size_t &count) noexcept {
    count = sizeof(faults) / sizeof(faults[0]);
    return faults;
}
} // namespace pk
