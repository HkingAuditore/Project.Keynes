#pragma once

#include "runtime_climate_passes.h"

#include <memory>

namespace pk::pk_async_climate {

// The sampling state of the script weather path, with its original precision.
// The worker uses it only when it cannot sample from its own weather inputs.
struct WeatherThermalEquatorInput {
    double bounds_y = 0.0;
    double bounds_height = 0.0;
    std::vector<float> temperature;
    std::vector<double> pos_y;
};

// 生产 stage 11 当天真正读到的输入。
//
// 与 ClimateFeedbackInput / VegetationDynamicsInput 同一理由：weather 跑在 round
// 末尾，environment 快照那份温度/风/湿度是 tick 起始拍的，用它等于拿昨天的场算
// 今天的天气。另外这里还要记那些跨 tick 状态的初值：worker 第一次跑 weather 时
// 若从零起步，ψ 与对流抑制都会与生产错开若干天才收敛，那会被记成算法分叉。
struct WeatherFieldInput {
    WeatherFieldKnobs knobs;
    SynopticAdvanceKnobs synoptic;
    int  n_cells = 0;
    bool ran = false;
    // ψ 是否参与：生产 weather_synoptic_enabled 为假时 PSI 是 nullptr。
    bool synoptic_enabled = false;
    std::shared_ptr<const WeatherThermalEquatorInput> captured_thermal_equator;

    // 读 lane。空 vector = 生产当天那条 lane 是 nullptr（component 没绑）。
    std::vector<float>   temp_read;
    std::vector<float>   moisture_read;
    std::vector<float>   air_anomaly;
    std::vector<float>   wind_x;
    std::vector<float>   wind_y;
    std::vector<float>   wind_speed;
    std::vector<uint8_t> terrain;
    std::vector<uint8_t> has_river;
    std::vector<float>   river_q30;
    std::vector<float>   elevation;
    std::vector<uint8_t> vegetation;
    std::vector<float>   soil_moisture;
    std::vector<float>   vitality;
    std::vector<float>   sea_ice;
    std::vector<float>   pos_x;
    std::vector<float>   pos_y;
    std::vector<float>   temp_anomaly;
    std::vector<float>   snow_cover;
    std::vector<float>   temp_transport_anomaly;

    // 跨 tick 状态的初值（生产读到的那一份）。worker 只在自己那份还没建立时用它
    // 播种，之后走自己的演化 —— 否则 parity 就退化成"把生产的状态抄一遍"。
    std::vector<float>    conv_inhib;
    // ψ 记的是生产在 solve 前刚推进完的那一帧（也就是 solve 实际读到的）。
    // B8-2 起 worker 自持 ψ：这一对 lane 只作为**冷启动/恢复后的播种值**，worker
    // 第一次见到齐长 lane 时把它拷进自己的 scratch，之后每个 weather 日用自己的
    // 风场与归一化温度推进（见 RuntimeClimateKernel::_synoptic_psi）。psi_prev
    // 只在播种时需要，用来给第一次推进一个正确的平流历史。
    std::vector<float>    psi;
    std::vector<float>    psi_prev;
    std::vector<uint32_t> cyclone_tag;
    uint32_t              cyclone_generation = 0;
    std::vector<float>    cyclone_lift;
    std::vector<float>    cyclone_x;
    std::vector<float>    cyclone_y;
    std::vector<float>    monsoon_thermal;
    // 轨迹表是风场的派生量且带指纹校验，worker 侧无法重建同一份，所以照抄生产当
    // 天用过的那张。生产没命中时为空，worker 也走逐次重算的分支。
    std::vector<int32_t>  traj_idx;
    std::vector<float>    traj_w;
    // 生产 cell_weather_field_init。worker 若从全零起步会按 moisture*0.15
    // 重做 spinup，而生产生成阶段通常已经把这张图标成已初始化 —— 那就是
    // vapor 全图偏 0.15 的来源。
    std::vector<uint8_t>  field_init;
    // conv_inhib 跨天由谁持有，与 WeatherDistributeInput::own_snow_state 同理。
    // SHADOW 留 false：生产是权威写者，worker 每天跟着它播种才是在对拍同一条
    // 状态链。ACTIVE 置 true：生产的对流抑制不再推进，每天拿它重置等于把这条
    // 记忆抹平，对流会一直从"无抑制"起步。
    bool own_field_state = false;
};

} // namespace pk::pk_async_climate
