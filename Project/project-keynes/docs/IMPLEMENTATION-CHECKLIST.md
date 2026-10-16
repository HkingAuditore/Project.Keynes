# ✅ 实施完整清单

## 代码实施（✅ 100% 完成）

### 1. Shader 形状系统
- [x] 创建 `plant_animal_shapes.gdshaderinc`
  - [x] Helper 函数（hash, hash22）
  - [x] 植物形状函数（wheat, corn, rice, leafy）
  - [x] 动物形状函数（horse, cattle, sheep, pig）
  - [x] 贴花系统（roots, soil）
  - [x] 形状分发器（get_plant_animal_shape）

### 2. Shader 集成
- [x] 修改 `resource_impostor.gdshader`
  - [x] 添加 include 指令（第 85 行）
  - [x] 添加 `rs_from_new_shape()` 辅助函数
  - [x] 修改 fragment() 形状生成逻辑（第 279-297 行）
  - [x] 保持回退兼容性

### 3. 参数优化
- [x] 修改 `resource_default.tres`
  - [x] palette_saturation: 0.80 → 0.88
  - [x] luma_compress: 0.75 → 0.60
  - [x] contact_shadow: 0.45 → 0.68
  - [x] outline_strength: 0.0 → 0.15
  - [x] climate_response: 0.7 → 0.85
  - [x] wind_strength: 0.35 → 0.45
  - [x] animal_motion: 0.55 → 0.70

## 测试验证（⏳ 待执行）

### Phase 1: 参数优化验证
```bash
godot --headless -s Project/project-keynes/tests/resource_visual_art_review.gd
```
- [ ] 运行美术审查
- [ ] 检查 tmp/resource_visual_qa/art_review_45.png
- [ ] 验证资源更"跳"出地表
- [ ] 对比：颜色更鲜明？阴影更深？

### Phase 2: 游戏内形状验证
```bash
godot Project/project-keynes/project.godot
```
- [ ] 放大到 3-4 倍 zoom
- [ ] 验证小麦形状
  - [ ] 直立？
  - [ ] 细穗？
  - [ ] 尖头？
- [ ] 验证玉米形状
  - [ ] 粗穗？
  - [ ] 圆头？
  - [ ] 有须根？
- [ ] 验证水稻形状
  - [ ] 下垂？
  - [ ] 细穗？
- [ ] 验证土豆形状
  - [ ] 球形叶？
  - [ ] 矮胖？
- [ ] 验证马形状
  - [ ] 细长？
  - [ ] 长颈？
  - [ ] 竖耳？
- [ ] 验证牛形状
  - [ ] 宽矮？
  - [ ] 有角？
- [ ] 验证羊形状
  - [ ] 球形？
  - [ ] 蓬松？
  - [ ] 冠天毛？
- [ ] 验证猪形状
  - [ ] 矩形？
  - [ ] 鼻子凸？
  - [ ] 卷尾？

### Phase 3: 性能验证
```bash
godot -s Project/project-keynes/tests/resource_visual_perf_test.gd -- --large
```
- [ ] 检查编译是否成功
- [ ] 查看 P95 帧时
- [ ] 验证桌面 < 4.5ms？
- [ ] 验证移动 < 12.1ms？
- [ ] 检查是否有额外纹理采样

### Phase 4: 回归测试
```bash
godot -s Project/project-keynes/tests/resource_visual_render_regression.gd
```
- [ ] 17 项 GPU 测试全部通过？
- [ ] 是否有视觉回归？

## 文档完成

### 交付文档
- [x] 📖 `docs/visual-optimization/00-START-HERE.md` - 5分钟快速入门
- [x] 📖 `docs/visual-optimization/SHAPE-DESIGN-SUMMARY.md` - 15分钟方案总结
- [x] 📖 `docs/visual-optimization/plant-animal-shape-design.md` - 完整设计文档
- [x] 📖 `docs/visual-optimization/shape-implementation-checklist.md` - 实施清单
- [x] 📋 `docs/QUICK-START.md` - 快速启动指南
- [x] 📋 `docs/IMPLEMENTATION-COMPLETE.md` - 实施完整总结
- [x] 📋 `docs/IMPLEMENTATION-PATCH.md` - 代码集成指南

## 代码质量检查

- [ ] Shader 编译无错误？
- [ ] 没有额外的纹理采样？
- [ ] ALU 增长 < 10%？
- [ ] 回退机制正常工作？
- [ ] 其他资源不受影响？

## 提交与发布

- [ ] 所有测试通过？
- [ ] 代码已提交？
- [ ] 提交信息完整？
- [ ] 推送到远程仓库？
- [ ] 创建 PR/MR（如果需要）？

## 最终验收

### 视觉质量
- [ ] 8 种资源视觉辨识度提升 ≥ 80%？
- [ ] 参数优化效果明显？
- [ ] 贴花系统有效？
- [ ] 整体风格一致？

### 性能质量
- [ ] 性能增长在预算内？
- [ ] 零额外纹理采样？
- [ ] GPU 回归测试通过？
- [ ] 移动端性能可接受？

### 代码质量
- [ ] 代码易维护？
- [ ] 参数易调整？
- [ ] 易于扩展其他资源？
- [ ] 文档完整？

## 未来优化方向（可选）

### Phase 3: Shading 增强
- [ ] 实现细节法线
- [ ] 实现各向异性高光
- [ ] 实现自阴影
- [ ] 测试视觉效果

### Phase 4: 动态细节
- [ ] 实现多频风场
- [ ] 实现动物姿态变体
- [ ] 实现天气特效
- [ ] 整合测试

---

## 签名

**实施者**: Claude Opus 5.5
**实施日期**: 2024-12-XX
**状态**: ⏳ 待测试验证

---

## 快速参考

### 关键文件位置
```
新建：Project/project-keynes/shaders/include/plant_animal_shapes.gdshaderinc
修改：Project/project-keynes/shaders/resource_impostor.gdshader
修改：Project/project-keynes/data/visual/resource_default.tres
```

### 关键函数
```glsl
wheat_shape()       - 小麦形状
corn_shape()        - 玉米形状
rice_shape()        - 水稻形状
leafy_shape()       - 土豆形状
horse_shape()       - 马形状
cattle_shape()      - 牛形状
sheep_shape()       - 羊形状
pig_shape()         - 猪形状
compute_decal_shape() - 贴花生成
get_plant_animal_shape() - 形状分发器
```

### 关键参数
```gdscript
palette_saturation      - 颜色饱和度
luma_compress           - 明度压缩
contact_shadow          - 接地阴影
outline_strength        - 描边强度
climate_response        - 气候响应
wind_strength           - 风力强度
animal_motion           - 动物动作
```

---

## 需要帮助？

- 📖 **如何理解设计**：阅读 `docs/visual-optimization/plant-animal-shape-design.md`
- 🚀 **如何快速启动**：按照 `docs/QUICK-START.md` 的 3 个步骤
- 🔧 **如何调整参数**：编辑 `resource_default.tres` 中的参数
- 🐛 **遇到问题**：查看 `docs/QUICK-START.md` 中的常见问题

---

**让我们把这个优化方案推向生产吧！** 🎉
