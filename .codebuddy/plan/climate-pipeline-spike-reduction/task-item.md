# 实施计划

- [ ] 1. 建立统一 pass 生命周期、预算与诊断基础结构
   - 编写通用 pass 状态、阶段、游标、预算结果和取消原因的数据结构。
   - 接入每 tick 预算推进、完成/未完成/失败返回值和诊断采样开关。
   - 为 pass generation/token 增加旧任务防覆盖保护。
   - _需求：3.1、3.2、3.3、6.1、6.2、6.3、6.4_

- [ ] 2. 实现 Generic climate chunk API 骨架
   - 编写 `begin_climate_pass`、`run_climate_pass_slice`、`abort_climate_pass` 或等价接口。
   - 将 pass 类型、range/chunk 游标、临时缓冲和 native/script 清理逻辑纳入统一生命周期。
   - 为完成、继续、失败、abort 等路径编写基础测试或调试断言。
   - _需求：3.1、3.2、3.3、3.4、3.6_

- [ ] 3. 将 ocean water 与 land 的 range cursor 接入通用 climate chunk API
   - 替换现有分散的 range cursor 编排代码，保持现有输出语义不变。
   - 验证 chunk 边界、full sweep、取消重启和完成提交路径。
   - 补充对旧 pass 不发布过期结果的测试或运行时校验。
   - _需求：3.4、3.5、3.6、6.4、7.1、7.3_

- [ ] 4. 将 sea ice 改造成多 tick 状态机
   - 实现 `native_compute`、`dense_sync_chunk`、`terrain_flip_chunk`、`commit` 等阶段状态与阶段游标。
   - 将 dense 同步和 terrain flip 拆成受预算控制的 chunk 推进。
   - 保证未进入 `commit` 前不暴露半成品地形状态，完成后一次性发布最终结果。
   - _需求：1.1、1.2、1.3、1.4、3.1、3.3_

- [ ] 5. 完善 sea ice abort、重启与诊断路径
   - 为新地图生成、气候重算或取消请求接入 sea ice abort 清理。
   - 增加阶段耗时、处理数量、剩余游标和预算中断指标。
   - 编写中途取消、重启、full sweep 和不同切片预算下确定性的验证代码。
   - _需求：1.5、1.6、6.2、6.3、6.4、7.2、7.3_

- [ ] 6. 将 Atlas smooth dirty 膨胀和 prep 纳入分片执行
   - 为 dirty 膨胀、去重排序、prep 和 smooth step 建立统一阶段游标。
   - 对极端 dirty/full sweep 场景启用分片处理，避免单 tick 完成全部预处理。
   - 保证重复或重叠 dirty 的去重结果顺序确定。
   - _需求：2.1、2.2、2.3、2.5、6.1_

- [ ] 7. 完善 Atlas smooth 取消、替换与结果等价验证
   - 实现 Atlas smooth pass 被取消或被新 dirty 请求替代时的缓冲释放和过期结果拦截。
   - 编写一次性执行与多 tick 分片执行结果等价的验证逻辑。
   - 覆盖 full sweep、大 dirty 集合和小 dirty 增量场景。
   - _需求：2.4、2.6、6.4、7.1、7.2、7.3、7.4_

- [ ] 8. 实现 weather fronts diff/signature 增量发布链路
   - 编写 fronts/cells/渲染片段级 signature 与 diff 计算代码。
   - 在 signature 未变化时跳过 renderer/fronts 发布与刷新。
   - 在局部变化时仅发布受影响的增量范围。
   - _需求：4.1、4.2、4.3、6.1_

- [ ] 9. 增加 weather fronts renderer fallback 与诊断指标
   - 实现增量 diff 与 renderer 状态不一致时的安全全量同步 fallback。
   - 记录 diff 命中率、signature 跳过次数、增量发布数量和 fallback 次数。
   - 验证增量发布完成后渲染可见状态与气候数据源一致。
   - _需求：4.4、4.5、4.6、7.1、7.4_

- [ ] 10. 收敛 DOTS/native 批量迁移边界
   - 将 `Project/project-keynes/scripts/geography/map_generator.gd` 中 ocean begin 可迁移的打包、初始化和大循环下沉到 DOTS/native 路径。
   - 将 sea ice 提交编排中的批量数据准备和可批处理提交迁移到 DOTS/native 或通用 chunk API。
   - 对必须保留在 GDScript 的 Godot API 边界进行最小化封装，并使用批量结构减少逐 cell 交互。
   - _需求：5.1、5.2、5.3、5.4_

- [ ] 11. 编写端到端性能与正确性回归验证
   - 覆盖相同 seed、典型地图、极端 dirty、full sweep、大地图、密集 weather fronts 和中途 abort 场景。
   - 对比改造前后主线程耗时、分配量、主要尖峰阶段耗时和总耗时。
   - 为 DOTS/native 异常或性能目标未达成场景输出 fallback 或瓶颈诊断。
   - _需求：5.5、5.6、6.5、6.6、7.1、7.4、7.5、7.6_
