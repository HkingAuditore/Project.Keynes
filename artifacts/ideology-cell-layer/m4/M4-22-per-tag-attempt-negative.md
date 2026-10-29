# M4-22 per-tag changed words：优化尝试无收益，找到真正瓶颈

| 项目 | 内容 |
|---|---|
| 里程碑 | [M4](../22-cell-program-cap-removal-plan-v3.md) §15.6 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 结果 | **active-tag 过滤零收益**（296/296 全有行）；**找到真正瓶颈** |
| 结论 | 负面结果，但诊断有价值 |

## 1. 我做了什么

假设：`TagSnapshot` 重建是 `cells × tags`，而很多 tag 没有行、`matches()` 会立即返回 false（`target_tag.h:203`），所以先过滤掉无行 tag 能省钱。

实现：预计算 `active_tags`，把 `cells × tags` 变成 `cells × active_tags`。

## 2. 实测：零收益

| 规模 | 优化前 | 优化后 |
|---|---:|---:|
| 2400 格 | 12.94 ms | 13.30 ms |
| 6400 格 | 34.92 ms | 35.66 ms |

**在噪声范围内，没有改善。**

原因写在新增的计数器里：

```
tag_declared=296  tag_active=296
```

**296 个 tag 全部有行**，没有可跳过的。我的假设在这个夹具里不成立。

## 3. 真正的瓶颈

```
6400 cells × 296 tags = 1,894,400 matches
35.66 ms / 1.89M = 18.8 ns per match
```

`matches()` 本身已经只扫该 tag 的行，没有明显的常数浪费。**成本就是 `cells × tags` 的正比。**

`tag_declared == tag_active` 说明问题不在「数据里有废 tag」，而在**「这个世界的表声明了 296 个 tag，而每张卡只用 1 个」**。

### 瓶颈在消费者协议，不在重建算法

```cpp
bool tag_bits_needed() const {
    const auto consumers = _effect_input_consumers;
    if (consumers == nullptr) return true;
    return consumers->tags_needed;     // ← 只有布尔
}
```

`EffectInputConsumers` 只有「要不要 tag」这一个布尔，**没有「要哪些 tag」**。

所以只要任何一张卡用 tag，296 个 tag 全都要算。

**要真正降本，需要把消费者协议从 `bool tags_needed` 扩成「tag id 集合」。** 那是协议改动，涉及 effect/ideology 两侧的上报，不是本轮能安全完成的。

## 4. 保留的东西

| 项 | 价值 |
|---|---|
| `active_tags` 预计算 | 正确且无害；对「声明多、使用少」的表会立即生效 |
| `tag_declared_tags` / `tag_active_tags` 计数器 | **让「表里有多少废 tag」一眼可见**，下次不必再猜 |
| 本报告 | 记录了「为什么这条路走不通」与真正方向 |

## 5. 局限

- `per-tag changed words`（增量更新）**未实现**。
- 增量更新同样受消费者协议限制：不知道「谁要哪个 tag」，就无法只更新变化的那一个。
- 峰值内存、B5、release DLL 仍未测。

## 6. 下一步（明确）

1. 把 `EffectInputConsumers::tags_needed` 扩成 `tag_ids` 集合（effect + ideology 两侧上报）；
2. 重建时只算集合内的 tag；
3. 再考虑增量：tag 集合稳定时，只对「来源所属格」重算对应的 tag word。

**第 1 步是前置**：没有它，2 和 3 都无法成立。
