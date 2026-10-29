# M5-81 【决策 2 完成】协同撤销泄漏已修复 —— 按您选的「稳的方法」

| 项目 | 内容 |
|---|---|
| 决策 | 您选「**稳的方法**」：给协同另开一条不经过 Effect 实例的路径，不碰卡片与一次性语义 |
| 结果 | ✅ **修好了**。`drought/plain` 从 `0.95/1.03` 变回 **`1.00/1.00`**，`removes` 的 country delta 从 **1 变 2**，`[FINDING]` **消失** |
| 夹具 | `ideology_mechanism_synergy_spirit_test`：**144 → 147** 检查（FINDING 分支翻成真断言）|
| 日期 | 2026-10-28，Asia/Hong_Kong |

## 1. 修复前后

| | 修前 | 修后 |
|---|---|---|
| `drought` / `plain`（协同效果）| `0.95000` / `1.03000` ← **行泄漏** | **`1.00000` / `1.00000`** ← 行已删 |
| `removes` 的 country delta | **1** | **2** |
| `[FINDING] synergy release…` | 有 | **消失** |
| 检查数 | 144 | **147** |

**`country delta` 从 1 变 2 是关键**：多出来的那一次就是**协同行自己**终于被删掉了。
`agriculture=1.03000` 仍是 `1.03`，因为那是 `resonance.agrarian.2` 的 count-rule 效果，**该留着**。

## 2. 修法：一个**opt-in 的稳定身份**

```cpp
// ExternalEffectCommandPod（新增，默认 false）
bool stable_source_identity = false;

// EffectRuntime::Command（新增，镜像上面的）
bool external_source_is_stable = false;

// 转换时携带
:3541  command.external_source_is_stable = source.stable_source_identity;

// collect_affected_synergies 置位（:1463-1466 的稳定 id 本来就算好了，只是没人读）
command.stable_source_identity = true;

// 消费侧（generic MODIFIER_COMMAND 分支）
native.source_id =
    command->external_source_is_stable && command->external_source_id != 0
        ? static_cast<uint64_t>(command->external_source_id)
        : static_cast<uint64_t>(source_instance->source_id);
```

**为什么这是「稳」的**：**只有 `collect_affected_synergies` 置位**。
卡片层级行与 on-enter 一次性行**完全不设这个标记**，身份仍然是 per-fire——

**这一点必须保住**，因为如果一次性行的身份变稳定，第二次入场会被当成「行已存在」而被吞掉，
而那正是 §18.1「一次性效果不重放」要验证的语义。

## 3. 我走错了两步（记下来省别人时间）

### 错步 1：以为是 `NATIVE_MODIFIER_IDEOLOGY` 分支

我先改了 `:5663`（IDEO 分支的 `native.source_id`）。**编译过、测试仍泄漏。**

**为什么**：`:1124-1132` 决定 `native_modifier_adapter`——

```cpp
else if (command.owner_program_id >= 0) {
    if (owner.managed_declared)
        command.native_modifier_adapter = NATIVE_MODIFIER_IDEOLOGY;
}
```

**协同行的 `owner_program_id` 是 -1**，所以 adapter 停在默认的 `NATIVE_MODIFIER_GENERIC`，
**IDEO 分支对它根本不执行**。

### 错步 2：把两个同名结构体搞混

`ExternalEffectCommandPod` 与 `EffectRuntime::Command` **都有** `source_id` 字段，
我第一版在 `:5663` 写了 `command->source_id`，编译报
`error C2039: "source_id": 不是 "pk::EffectRuntime::Command" 的成员`。

`EffectRuntime::Command` 里对应的是 **`external_source_id`**（`:985`），
由 `:3540` 从 pod 的 `source_id` 拷过来。

### 真正的落点

`:5705` 的 **generic `MODIFIER_COMMAND` 分支**：

```cpp
:5713  native.source_id = static_cast<uint64_t>(source_instance->source_id);   // ← 批次身份
```

**这才是协同行的实际路径**，而 `source_instance->source_id` 是**批次的 `transition_source_id`**，
APPLY 与 REMOVE 被**按世代拆成两个批次**（`:3629-3636`），**两者必然不同**。

我把 `:5663` 的改动**撤掉了**（协同走不到那里，留着就是死代码），只改 `:5713`。

## 4. 顺带确认的一件事

`:1463-1466` 本来就算好了稳定 id：

```cpp
command.source_id = (0x7fffULL << 48U) | ((synergy_id + 1) << 16U) | (effect + 1);
```

**这个字段写了却从没被读**（M5-64 把它记为第四个死字段）。**这才是本会话第一个「死字段直接导致功能缺陷」的例子**——现在它被读上了。

## 5. 交付物

| 文件 | 改动 |
|---|---|
| `gdext/src/effect_runtime.h` | `Command::external_source_is_stable` |
| `gdext/src/effect_runtime.h` | `ExternalEffectCommandPod::stable_source_identity` |
| `gdext/src/effect_runtime.cpp` | `:3541` 携带标记；`:5713` 消费 |
| `gdext/src/ideology_runtime.cpp` | 协同发射器置位 |
| `tools/ideology/verify_delivery.py` | 协同夹具 144 → 147 |
