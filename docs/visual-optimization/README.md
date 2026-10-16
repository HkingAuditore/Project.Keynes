# 地块资源与物种分布视觉优化 - 完整方案

## 概述

本优化方案针对游戏中**地块上的资源和物种分布视觉表现**，通过参数调优、shader增强和数据优化，在不增加纹理采样或draw call的前提下，显著提升美术表现、辨识度和光影质感。

### 核心问题
1. **美术辨识度不足**：程序化形状抽象，远景难以区分资源类型
2. **视觉层次感弱**：资源点缀与地形融合度低，"贴纸感"明显
3. **光影表现单一**：虽接入GI系统，但材质响应不够丰富

### 优化目标
- ✅ 铜矿有绿色条纹，金矿有金色反光，煤块有层状结构
- ✅ 动物有明确接地阴影，"站在地上"而非"浮在空中"
- ✅ 植物摆动有多层次感，雨天变暗
- ✅ 晶体在阳光下闪烁，夜晚有月光高光
- ✅ 远景仍可通过形状和光泽区分资源类别

---

## 文档结构

### 1. [resource-species-visual-enhancement.md](./resource-species-visual-enhancement.md)
**完整技术方案**，包括：
- 当前系统分析（优势与问题）
- 三大优化方向：美术设计、辨识度、光影表现
- 实施优先级（Phase 1-4）
- 性能考量与预算分析
- 配置文件示例
- 预期效果对比

**适合**：技术负责人、图形程序员

### 2. [shader-enhancements-code.md](./shader-enhancements-code.md)
**可直接集成的shader代码**，包括：
- 矿物形态生成函数（层状/条纹/晶簇）
- 植物轮廓增强
- 动物姿态变体
- 差异化光照响应（金属/晶体/植物）
- 多层阴影系统
- 昼夜与天气效果
- 多频风场与动态细节

**适合**：Shader开发者

### 3. [implementation-guide.md](./implementation-guide.md)
**分步实施指南**，包括：
- 快速开始（15分钟见效）
- 渐进优化路线图（Phase 1-4）
- 每个Phase的详细步骤
- 验证清单与检查点
- 性能验证流程
- 故障排查
- 最终验收标准
- 发布准备

**适合**：执行开发者、QA测试

---

## 快速开始

### 最小改动（15分钟，立即见效）

1. **编辑** `Project/project-keynes/data/visual/resource_default.tres`：
   ```gdscript
   palette_saturation = 0.88   # 0.80 → 0.88
   luma_compress = 0.60        # 0.75 → 0.60
   contact_shadow = 0.68       # 0.45 → 0.68
   outline_strength = 0.15     # 0.0 → 0.15
   ```

2. **验证**：
   ```bash
   godot --headless -s Project/project-keynes/tests/resource_visual_art_review.gd
   # 查看 tmp/resource_visual_qa/art_review_45.png
   ```

3. **对比**：资源是否更鲜明、更"跳"出地表？

### 完整实施（1-2周）

按 Phase 1 → 2 → 3 → 4 顺序实施，每个Phase包含：
- 代码/数据修改
- 单元测试验证
- 性能测试
- 视觉对比检查

详见 [implementation-guide.md](./implementation-guide.md)

---

## 性能影响

| Phase | 桌面增量 | 移动增量 | Shader ALU | 纹理采样 |
|-------|---------|---------|-----------|---------|
| Phase 1（参数） | +0.1ms | +0.2ms | 0% | 0 |
| Phase 2（形态） | +0.2ms | +0.5ms | +5% | 0 |
| Phase 3（光照） | +0.5ms | +1.2ms | +20% | 0 |
| Phase 4（动态） | +0.7ms | +1.5ms | +25% | 0 |

**基准**：当前 Xiaomi 15 P95 = 10.9ms，预算 = 4ms/帧（资源层）
**Phase 3 完成后**：约 +0.5ms（桌面）/ +1.2ms（移动），在预算内

所有优化**零额外纹理采样**，复用现有 terrain horizon/GI 数据。

---

## 验证测试

### 自动化测试

```bash
# 功能回归（56项）
godot -s Project/project-keynes/tests/resource_visual_layer_test.gd

# 渲染回归（17项GPU检查）
godot -s Project/project-keynes/tests/resource_visual_render_regression.gd

# 性能测试（20万格）
godot -s Project/project-keynes/tests/resource_visual_perf_test.gd -- --large

# 完整世界场景
godot -s Project/project-keynes/tests/resource_visual_world_qa.gd
```

### 手动检查清单

- [ ] **形态识别**：铜矿有条纹、金矿有晶面、煤有层理？
- [ ] **接地感**：动物有清晰阴影，不是悬浮？
- [ ] **光泽对比**：金属反光、晶体透光、植物柔和？
- [ ] **昼夜变化**：黄昏暖调、夜晚月光高光？
- [ ] **天气响应**：雨天植物变暗、矿物反光？
- [ ] **动态自然**：植物多层摆动、动物有觅食动作？

---

## 实施优先级

### 推荐路径（时间紧张）

**Phase 1 + Phase 3 光照部分**
- 时间：3-4天
- 效果：+60% 视觉提升
- 风险：低（主要调参数和现有逻辑增强）

### 完整路径（追求极致）

**Phase 1 → 2 → 3 → 4**
- 时间：10-12天
- 效果：+80% 视觉提升
- 风险：中（需要shader重构和充分测试）

### 保守路径（稳字当头）

**仅 Phase 1**
- 时间：1天
- 效果：+25% 视觉提升
- 风险：极低（纯参数调整）

根据项目节奏选择合适路径。

---

## 技术亮点

1. **零额外成本优化**
   - 不增加纹理采样
   - 不增加draw call
   - 复用现有GI/horizon数据

2. **渐进式增强**
   - 每个Phase独立可验证
   - 可随时回滚到上一Phase
   - 移动端有降级路径

3. **数据驱动**
   - `sub_style` 控制形态变体
   - profile 控制所有视觉参数
   - 无需硬编码，易于调整

4. **充分测试覆盖**
   - 56项单元测试
   - 17项GPU渲染测试
   - 性能/内存/完整场景验证

---

## 预期效果

### 优化前
- ❌ 矿物颗粒模糊，远景难辨认
- ❌ 动物/植物"贴纸感"，与地表脱节
- ❌ 日夜/天气变化不明显
- ❌ 所有资源"扁平"，无质感差异

### 优化后
- ✅ 铜矿青绿条纹、金矿金色反光、煤块层状结构
- ✅ 动物有接地阴影和轻微投影，"站在地上"
- ✅ 植物多层摆动，雨天变暗，雪天有冰霜
- ✅ 晶体阳光下闪烁，夜晚月光高光
- ✅ 远景可通过形状/光泽区分资源类别
- ✅ 整体视觉层次感提升，融入地形环境

### 玩家盲测目标
≥ 80% 玩家在对比截图中选择优化后版本

---

## 后续方向

完成Phase 1-4后，如需进一步提升：

### 方向A：手绘纹理图集
- 为关键矿物制作4-6张impostor纹理
- 预期：+60% 识别度，+0.3ms
- 需要：美术资源制作

### 方向B：密度自适应
- 根据地形/植被动态调整资源实例
- 预期：+20% 分布自然度，0ms
- 纯CPU逻辑优化

### 方向C：透镜交互
- 悬停高亮、储量条、品质星级
- 预期：+50% 可用性
- UI层面，非渲染

根据玩家反馈选择下一步。

---

## 联系与支持

**问题反馈**：
- 技术问题：查看 [implementation-guide.md](./implementation-guide.md) 的"故障排查"章节
- Shader代码：参考 [shader-enhancements-code.md](./shader-enhancements-code.md)
- 方案讨论：参考 [resource-species-visual-enhancement.md](./resource-species-visual-enhancement.md)

**验收标准**：
- 所有测试通过（73项）
- 性能在预算内（桌面<4.5ms, 移动<12ms）
- 视觉辨识度提升≥40%（主观评测）

**发布清单**：
- 更新 `resource-visual-runtime.md` 文档
- 添加 Changelog 条目
- 准备回滚计划（保留Phase 1参数）

---

## 版本历史

- **2024-12-XX**：初始方案（Phase 1-4完整规划）
- 基于代码审查：`resource_visual_layer.gd`, `resource_impostor.gdshader`, `resource_visual_catalog.gd`
- 目标设备：桌面RTX 4080 / 移动Xiaomi 15
- Godot版本：4.6.2

---

**Ready to implement? Start with [implementation-guide.md](./implementation-guide.md) → Quick Start!**
