---
name: perf-forecast
description: 用仓库自带的 perf-forecast 从源码和场景参数预估工作量，判断 Keynes 的一项优化是否值得做，或比较两个版本的计算路径。
---

从仓库根目录运行 `tools/perf/forecast/perf-forecast`。选定实际场景和要数的操作，例如每帧重建几次、每个订单读多少条目录记录。用 `scan 源文件 --function 函数名` 查分支和循环，用 `describe 配置文件` 查看已有配置的输入和假设。

用同一组输入运行 `compare 改前配置 改后配置 场景.json`，核对各项计数和返回值。支持的 Python 函数可加 `--source-only` 直接从源码计数。已有 Lean 模型时，可用 `estimate 配置文件 场景.json` 预测，再按需用 `trace --lean` 核对。执行跟踪前确认配置和源码是受信任的工程代码。

给出是否值得做的判断。工作量有增有减时，指出收益在哪个条件下翻转。没有实测耗时时，报告次数、上限或适用条件。配置示例和可选依赖见[工具说明](../../tools/perf/forecast/README.md)。
