# M3-7 殖民被拒的完整根因链（已定位到末端）

| 项目 | 内容 |
|---|---|
| 里程碑 | [M3](../22-cell-program-cap-removal-plan-v3.md) |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 交付 | `diagnose_colonization_target()` 桥、`ideology_colonization_gate_probe.gd` |
| 结果 | **根因链完整打通，末端是 `country_slot_arr` 为空** |
| 结论 | M3-6 的「疑似可见性门」已证实；但可见性为空**不是缺陷**，是「没有玩家」的合理结果 |

## 1. 完整根因链（每一环都有实测数据）

```
gameplay_start_report  ok=true  cell=4539        ← 起点格存在
country_slot_arr       size=0                    ← 但槽位数组为空
  -> _resolve_player_country_slot() = -1
    -> VisionSolver.solve() 返回全零视野
      -> visible_arr 6144 格全为 0
        -> family_colonization_quotes 判 target_visible=false
          -> 167/167 采样格全部 colonization_target_invalid
```

| 环节 | 数据 |
|---|---|
| `visible_is_byte_array` | `true` |
| `visible_size` | **6144**（尺寸正确）|
| `visible_nonzero` | **0**（全零）|
| `target_visible` | `false` |
| `owner_handle` | `0`（无主）|
| `owner_allows` | **`true`**（主权门是开着的）|
| `player_country_slot` | **`-1`** |
| `gameplay_start_report` | `ok=true, cell=4539` |
| `country_slot_arr` | **`size=0, assigned=0`** |

**关键判读：主权门（`owner_allows=true`）是开的，唯一关闭的是可见性门。** 这排除了一整类猜测。

## 2. 这不是缺陷

`player_country_slot == -1` 在无头夹具里是**正确**的：没有人玩，就没有视野。`VisionSolver` 返回全零平面是合理行为。

所以 M3-6 的「疑似可见性门」得到证实，但**性质**与我当时的措辞不同：这不是系统坏了，而是**我的夹具没有建立玩家身份**。

`country_slot_arr` 为空才是需要理解的那一环——它是 `_resolve_player_country_slot` 的数据源（`world_runtime_host.gd:4806`）。

## 3. 本轮新增的诊断能力

`diagnose_colonization_target(country_handle, target_cell)` 把六道门拆开报告：

```json
{ "visible_is_byte_array": true, "visible_size": 6144, "visible_nonzero": 0,
  "target_visible": false, "owner_handle": 0, "owner_allows": true }
```

**这个桥的价值在于消除了一整类误判。** 公共接口把六道门压成一个 `colonization_target_invalid`，导致我在 M3-6 里只能猜。

## 4. 我这一轮做对的一件事

M3-6 我写下「疑似可见性门」并明确标注未验证。这轮**先加观测再加结论**，所以：

- 一次就拿到了 `visible_nonzero=0`；
- 附带发现 `owner_allows=true`，**排除**了我原本怀疑的另一半原因；
- `player_country_slot=-1` 直接指出是身份问题而非数据问题。

**对比 M3-5/M3-6 三次把「探测失败」读成「功能缺失」，本轮方法是对的。**

## 5. 下一步（明确可执行）

要完成殖民验证，需要在夹具里建立玩家身份：

1. 查 `country_slot_arr` 由谁写入（大概率在 `generate_world` 的国家提交阶段）；
2. 若该阶段在无头下被跳过，需要让夹具走完 `configure_session` 的完整提交；
3. 或者在夹具里显式设定 `player_country_slot` 并重算视野。

**这条路比继续猜要短得多**，因为现在知道唯一缺的是"身份"。

## 6. 局限

- 未查清 `country_slot_arr` 为空的原因（本轮时间用尽）。
- 未验证建立玩家身份后殖民是否真的成功。
- **32 上限的真实玩法影响仍然未知**——这一结论自 M3-5 以来没有推进，只是从"机制不存在"修正为"机制存在但夹具未走通"。
- `diagnose_colonization_target` 未覆盖 trade topology 门（无公开访问器）。

## 7. 复算方式

```powershell
$exe = 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64.exe'
Start-Process -FilePath $exe -NoNewWindow -Wait -PassThru `
  -ArgumentList '--headless','--path','Project/project-keynes',
    '-s','tests/ideology/ideology_colonization_gate_probe.gd'
# => visible_size=6144 visible_nonzero=0 player_country_slot=-1
#    country_slot_arr size=0 assigned=0
```
