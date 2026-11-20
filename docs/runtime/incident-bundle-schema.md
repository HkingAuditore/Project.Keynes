# `.pkinc` 事故包契约（schema v1）

> 日期：2026-11-19
> 状态：**契约已定，实现并行进行**
> 上游计划：`docs/plans/runtime-fault-infrastructure-plan.md` §5、§6
> 本文件是唯一真相。生产者（`incident_bundle.gd`）与消费者（`inspect_incident.py`、
> `incident_replay.gd`、`EconomyInvariantProbe::replay_incident`）都必须按本文件实现。

## 1. 容器

一个 **zip**（deflate），扩展名 `.pkinc`。schema 版本在 `MANIFEST.json` 里，不在文件名里。

| 约束 | 值 |
|---|---|
| 单包目标体积 | < 200 KB（day 2506 量级现场） |
| 硬上限 | 2 MB；超限时按 `cell.json` → `commands.json` 的顺序裁剪并在 `MANIFEST.truncated` 记账 |
| 编码 | 全部 UTF-8 无 BOM 的 JSON；数字一律十进制；不使用 `NaN`/`Infinity` |
| 版本字段 | `MANIFEST.schema = "pkinc/1"` |

## 2. 成员文件

顺序即写入顺序，便于流式读取。

### 2.1 `MANIFEST.json`（必需，第一个写入）

```json
{
  "schema": "pkinc/1",
  "created_at": "2026-11-19T16:18:49",
  "producer": "runtime_forensics.gd",
  "build_id": "<git sha>+<utc>",
  "files": [
    {"name": "incident.json", "bytes": 812, "sha256": "..."},
    {"name": "witness.json",  "bytes": 640, "sha256": "..."}
  ],
  "truncated": [],
  "notes": []
}
```

- `files` **必须**覆盖包里除自身以外的每个成员；`sha256` 是小写十六进制（64 字符）。
- `truncated` 列出因体积被裁剪/跳过的成员名（例如 `"cell.json:market_lanes"`）。
- 缺文件时**消费者必须报出缺的具体成员名**，不允许只说「包损坏」。

### 2.2 `incident.json`（必需）

```json
{
  "assert_id": "INV-ECON-0042",
  "reason": "building_construction_preflight_funds_drift",
  "kind": "fatal",
  "stage": "building_commit",
  "day": 2506,
  "epoch_id": 2506,
  "build_id": "<git sha>+<utc>",
  "world_id": "<seed>|<width>x<height>",
  "captured_at": "2026-11-19T16:18:49",
  "cell": 4123,
  "type_id": 17,
  "force_injected": false
}
```

`assert_id` 允许为空字符串（台账未登记时），但 `reason` 必须非空。

### 2.3 `witness.json`（必需，可为 `{}`）

该断言在台账 `witness` 里声明的字段集合，字段名与 C++ struct 一一对应。
类型按台账：`i32`/`i64` → JSON 整数；`f64` → JSON 浮点；`bool` → JSON 布尔；`str` → 字符串。

未登记 `witness` schema 的 reason，写 C++ `fatal_context_report()` 里能拿到的扁平键子集。

### 2.4 `cell.json`（必需）

失败格切片。单格 ≤ 64 KB。

```json
{
  "cell": 4123,
  "cohorts": [{"signature": 4294967296, "population": 120, "funds": 900, "employed": 88,
               "satisfaction": 61, "profession": 3}],
  "merchants": [{"slot": 7, "cash": 4200}],
  "buildings": [{"type_id": 17, "units": 3, "filled_owner": 2, "debt_principal": 0}],
  "pending_construction": [{"type_id": 21, "units": 1, "required_good": 4,
                            "required_qty": 12, "stock": 0}],
  "market_lanes": [{"good_id": 4, "price": 131, "stock": 55}]
}
```

**不含**：玩家姓名、家族全表、全图 cohort、完整 PKEC、原始 `.pksv`。

### 2.5 `commands.json`（可选）

```json
{"epoch": 2506, "structural": [...], "ledger": [...]}
```

按 `cell` 过滤的相关子集，≤ 128 条。裁剪时在 `MANIFEST.truncated` 记 `"commands.json"`。

### 2.6 `world.json`（必需）

```json
{"seed": 20260101, "width": 60, "height": 40, "formal_start": true,
 "catalog_hashes": {"economy": 123, "country": 456}, "country_count": 9}
```

### 2.7 `hashes.txt`（必需）

纯文本 `key=value` 每行一个：

```
state_hash=-6056925157648909117
economy_state_hash=0
ledger_hash=0
catalog_hash=123
```

## 3. 不变量

1. `.pkinc` 是**诊断产物**：不进 PKEC/PKSV、不参与状态哈希、不可作为存档加载。
2. 包里只有标量、哈希与该失败格的切片；任何全图/全人口明细都算违约。
3. `MANIFEST.schema` 升级到 `pkinc/2` 时，消费者必须仍能读 `pkinc/1`（n-1 兼容）。

## 4. 消费者契约

`tools/ci/inspect_incident.py <path>` 输出：

- 包级：schema / build_id / 成员数 / 总体积 / sha256 校验结果
- 事件级：assert_id / reason / kind / stage / day / epoch / cell
- witness 表：字段 / 值 / 台账声明类型 / 类型是否匹配
- 判定：`verdict=consistent`（witness 与不变量自洽）/ `verdict=violated` / `verdict=unknown`

退出码：`0` consistent、`1` violated、`2` 包本身损坏或缺失成员。
