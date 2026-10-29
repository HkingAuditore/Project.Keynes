# M3-15 环境槽注册是最后一块拼图（未完成）

| 项目 | 内容 |
|---|---|
| 里程碑 | [M3](../22-cell-program-cap-removal-plan-v3.md) |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 结果 | 秒级探针已能跑到 economy epoch，但**环境槽注册缺失**导致 epoch 打不开 |
| 结论 | 理念激活的最后阻塞是 DataCore 环境槽；与 M1-8 是同一道门 |

## 1. 本轮确认的完整阻塞链

```
configure_economy / effects / modifiers / ideologies   全部 ok=true
  -> begin_or_reuse_economy_input_epoch
       -> required_environment_slot_missing   (fatal_reason)
          -> 没有 economy opinion
             -> ideology 点数不累积
                -> discover 永远 pending
                   -> ideas=0
                      -> seen=0 / taken=0
                         -> 取不到 ramp 真实值
```

**这解释了自 M3-12 以来所有的 `seen=0`。**

## 2. 环境槽的具体要求（已查明）

`world_ext_economy.cpp:802-828` 要求 10 个槽，每个长度 `cell_count`：

| dtype | 槽名 |
|---|---|
| F32 × 8 | `cell_temp`, `cell_temp_30d`, `cell_moisture`, `cell_plant_available_water`, `cell_weather_precip`, `cell_snow_cover`, `cell_weather_intensity`, `cell_temp_365d` |
| U8 × 2 | `cell_weather_type`, `cell_cover` |

失败信息在 **`fatal_reason`** 而非 `reason`——我第一版读 `reason`，打印为空，白等了一轮。

## 3. 我尝试了但失败的部分

```gdscript
ext.component_id("cell_temp")   -> 负数
ext.write_f32_range(sid, 0, zeros_f32)   -> 未执行
[q] environment slots filled=0 of 10
```

**槽位没有注册，`component_id` 就返回 -1。**

槽定义在 `scripts/data_core/component_schema.gd:56+`（`name = &"cell.temp", cpp_name = "cell_temp"`），由 `bind_map_data` 注册——也就是说**需要真实 MapData**，这正是 M1-8 记录的那道门。

## 4. 这轮的实际价值

| 产出 | 价值 |
|---|---|
| **完整阻塞链** | 从 `seen=0` 一路追到 `required_environment_slot_missing`，每一环有实测 |
| 环境槽清单 | 10 个槽名与 dtype，可直接用于补注册 |
| 秒级探针 | 约 10 秒/次，替代 10 分钟 |
| 明确下一步 | 只差「注册这 10 个槽」 |

**从「不知道为什么 seen=0」到「只差注册 10 个槽」，这是实质进展。**

## 5. 局限（必须说清）

- **仍未取得 ramp 真实数值。**
- `component_id` 返回 -1 后我没有再找「不依赖 MapData 的槽注册路径」。
- 未尝试 `bind_map_data` 传一个最小 stub（M1-8 记录它会在 `world_ext_economy.cpp:929-930` 段错误）。
- 探针里 `run_economy_slice({"budget_ms": 64})` 返回 `ok=false done=true`，说明 slice API 的参数格式可能也不对，未深入。

## 6. 下一步（具体）

两条路，成本相近：

1. **补槽注册**：找 `component_schema.gd` 的注册入口，把 10 个槽在 `configure_economy` 之前注册进 DataCore；
2. **绕过 economy**：直接在探针里调用 `IdeologyRuntime::grant_*` 一类接口把理念塞进 `Active`，跳过点数累积——但需要先确认这类接口存在。

第 2 条更快，前提是接口存在。

## 7. 验证

| 项 | 值 |
|---|---|
| 探针耗时 | 约 10 秒 |
| `configure_*` | 4/4 `ok=true` |
| 环境槽填充 | **0 / 10**（未注册）|
| economy epoch | `ok=false required_environment_slot_missing` |
| discover | `accepted=1 pending=1` |
| 纯核门禁 | oracle 735 / materializer 65 / cap_removed 12 全 0 |

## 8. 复算方式

```powershell
$exe = 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64.exe'
Start-Process -FilePath $exe -NoNewWindow -Wait -PassThru `
  -ArgumentList '--headless','--path','Project/project-keynes',
    '-s','tests/ideology/ideology_ideology_queue_probe.gd'
# => environment slots filled=0 of 10
#    economy epoch ok=false reason=required_environment_slot_missing
```
