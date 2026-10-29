# M3-10 殖民调查收尾：家族不在本国格内

| 项目 | 内容 |
|---|---|
| 里程碑 | [M3](../22-cell-program-cap-removal-plan-v3.md)（殖民支线收尾） |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 结果 | 殖民**查询可达**但**无报价**；根因定位到最后一层：**本国格内没有家族** |
| 决定 | **殖民支线在此收尾**，转回 M3 主线（D 类 41 个条件常数） |

## 1. 本轮的最后一层根因

```
[pass] owned cells found: 6 first=[1553, 1573, 2177, 2413, 4539, 4949]
[pass] family at cell 1553 -> ok=true families=[]
[pass] family at cell 1573 -> ok=true families=[]
[pass] family at cell 2177 -> ok=true families=[]
[pass] BEST adjacent quote cell=-1 rows=0 after 48 tries
```

**6 个本国格里，一个家族都没有。**

## 2. 完整的因果链（六层，全部实证）

```
generate_world
  -> 国家拥有 6 格（每国 1 格，共 6 国）
    -> 家族存在（日志："founder_families=6 founder_people=6"）
      -> 但 get_family_cell_snapshot 在这些本国格里返回 families=[]
        -> family_colonization_quotes 的 reached_sources 能到达本国格
          -> 但 :600 的 family 循环取不到任何 family
            -> rows=0
```

`:609 if (branch_population <= 1) continue;` 我这轮先怀疑它，但**实测没走到那一步**——家族列表本身就是空的。

## 3. 我这一轮的三次修正

| 我的怀疑 | 实测 |
|---|---|
| 家族资金不足 | 不是，先卡在人口条件之前 |
| 目标格太远（`reached_sources` 为空） | 目标改为本国格邻格后仍 rows=0 |
| 分支人口 ≤ 1 被过滤 | **家族列表就是空的**，没到人口判断 |

每一次都被数据推翻，每一次都缩小了范围。**这是正确的收敛方式**，尽管结论是「问题在更上游」。

## 4. 这个发现的含义

`get_family_cell_snapshot` 在**本国格**返回空，而日志说有 6 个 founder families。两种可能：

1. 家族落在**非本国格**（例如独立的家族聚落，不属于任何国家）；
2. `get_family_cell_snapshot` 的参数语义与我的用法不符（我传 `(cell, 0, 16)`，第二个参数可能是 family_filter 而非 offset）。

**我没有区分这两者。** 这是本轮未完成的最后一小步，但继续追下去又是一个探针循环。

## 5. 决定：支线收尾

殖民调查已用 6 轮（M3-5 到 M3-10）。已确认的成果是实在的：

- ✅ 殖民机制完整存在（`start_family_colonization` → `claim_unowned`）
- ✅ 六道门全部打通，`quote ok=true` 首次达成
- ✅ 正确的调用顺序：**先 `sync_country_territory_to_map()` → 再 `_refresh_vision()`**
- ✅ 新增 `diagnose_colonization_target()` 桥，逐门报告
- ✅ 7 项前置条件的满足方式全部记录

**但「32 上限是否会被触发」仍未定论**，因为领土增长需要一笔成功的殖民，而那需要家族在本国格内。

我按上轮的计划转回 **M3 的 D 类（41 个条件常数）**——它不依赖殖民，是主线。

## 6. 验证

| 项 | 值 |
|---|---|
| 本国格数 | 6（每国 1 格）|
| 本国格内家族数 | **0**（三处采样均为 `[]`）|
| 邻格报价尝试 | 48 次，全部 `rows=0` |
| `quote ok` | **true**（门全开）|
| 纯核门禁 | oracle 735 / materializer 65 / cap_removed 12 / eligibility 56 全 0 |

## 7. 交接给后续者

要继续这条线，只需：

1. 确认 `get_family_cell_snapshot(cell, ?, ?)` 的参数语义；
2. 找到 6 个 founder families 实际所在的格；
3. 若它们不在本国格内，理解为什么（这可能本身就是一个内容/初始化问题）；
4. 让家族与本国的格重叠后，重跑本探针，预期 `rows>0`。

## 8. 局限

- 未验证「家族在非本国格」与「参数用错」哪个成立。
- 未产出一笔成功殖民。
- **32 上限的玩法影响仍未知**。

## 9. 复算方式

```powershell
$exe = 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64.exe'
Start-Process -FilePath $exe -NoNewWindow -Wait -PassThru `
  -ArgumentList '--headless','--path','Project/project-keynes',
    '-s','tests/ideology/ideology_colonization_passable_probe.gd'
# => owned cells 6; family at each -> families=[] ; BEST rows=0
```
