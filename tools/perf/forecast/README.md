# Perf Forecast

给 AI 和人使用的本地工作量分析工具。场景通过 JSON 文件或标准输入传入，默认输出 JSON，流程图可输出 Graphviz DOT。从仓库根目录运行 `tools/perf/forecast/perf-forecast`，也可用 `python3 tools/perf/forecast/work.py`。需要 Python 3.11 或更新版本。

## 分析入口

| 命令 | 可回答的问题 | 输入 |
| --- | --- | --- |
| `scan` | 源码里有哪些分支、循环、调用或尚未展开的部分？ | Python、GDScript、C 或 C++ 源文件 |
| `trace` | 给定一串输入，真的经过了哪些观察点，各做几次？ | 配置文件、场景、源码 |
| `compare` | 两个版本在同样场景下，各类工作量怎样变化，返回值是否一致？ | 两份配置、同一场景 |
| `estimate` | 不运行目标程序，这个模型预期每步做几次？ | 带 Lean 模型的配置、场景 |
| `predict` | 条件有多组可能值时，哪一组会改变收益方向？ | 带数值或公式的预测请求 |

### 先跑目录查询示例

```sh
cd tools/perf/forecast
./perf-forecast scan examples/catalog-work/before.py --function quote --dot
./perf-forecast compare examples/catalog-work/before.json examples/catalog-work/after.json examples/catalog-work/input.json
# 安装 Lean 后运行模型
./perf-forecast estimate examples/catalog-work/after.json examples/catalog-work/input.json
```

AI 可先用 `perf-forecast describe 配置文件` 读取工作定义、场景假设和模型所需字段。

对于由普通 Python 函数组成的计算，可以在 `trace` 或 `compare` 后加 `--source-only`。工具读取源码，按场景解释算术、条件、有限的 for 循环、列表推导和本文件的函数调用。它统计命名函数的进入次数，无需导入目标模块、启动游戏或编写 Lean 模型。例如在上面目录对照命令末尾加 `--source-only` 后，计数与执行目标的结果一致。当前支持普通、无默认值/注解的函数；遇到实际路径上的外部调用、不可识别的数据或不支持的语句会报出位置。该步骤本身仍需遍历所选场景；`estimate` 则可使用独立公式直接计算大规模输入。

三步场景的目录读取总数为 14 → 6，订单查询都是 4 次，三次返回值均相同。配置里的 `metrics` 为跨版本共享的工作定义。`delta_after_minus_before` 用原单位逐项比较；耗时不同的操作不相加。`outputs` 单独报告返回值差异或缺少返回值。可观察到的副作用需作为输出或单独指标声明。

### 在 Keynes 中选定情景

```sh
./perf-forecast trace examples/sunlight-profile.json examples/sunlight-steps.json --dot --step 1
./perf-forecast trace examples/keynes-profile.json examples/keynes-steps.json --lean
./perf-forecast estimate examples/keynes-profile.json examples/keynes-steps.json
```

命令在 `tools/perf/forecast` 下运行。示例配置指向同一仓库里的 Keynes 源码。对照旧版时，用 `--source` 指定另一份文件。

`scan --dot` 输出函数可能经过的路径，`trace --dot` 输出本次经过的观察点，边上的数字是经过次数。`--step` 从 0 数起。两种图的节点粒度可能不同。Python 图由当前解释器的指令构建；GDScript 图展开语句级常规分支，`opaque` 表示内部细节未解析。C/C++ 扫描调用 Clang；每条翻译单元可通过重复的 `--clang-arg=-I目录`、`--clang-arg=-D宏` 或 `--clang-arg=-std=c++17` 使用项目的构建条件。扫描结果含块内运算和候选后继，Clang 的这份输出没有逐块源行号。文件间的运行时调用目标、信号和异步调度需另外建模。

## 接入自己的项目

1. **声明输入和观察工作。** 场景格式为 `{"steps":[{...},{...}]}`。各步连续运行；两版分别启动新的运行进程。配置中的源码、证明文件和自定义命令工作目录相对配置文件，命令行的 `--source` 则相对当前目录。核心接收任意 JSON 场景，各适配器可以进一步约束。
2. **选已有的运行方式。** Python 同步函数使用 `adapter: "python"`，填入入口名与要观察的函数或源码语句，可复制目录查询示例。输入对象按关键字传参。行事件表示解释器即将执行该行；函数入口记录包括生成器恢复。只记录当前线程、指定源码文件，导入和子线程工作没有计入。独立同步 GDScript 方法使用 `adapter: "gdscript"`，按日照示例填写有序参数列表和函数内的精确语句，工具自动在临时副本插入观察点。统计粒度为到达该语句，不自动区分同一行内的条件表达式。需要节点树、其他项目资源、C++ 运行时或其他语言的功能可使用下面的命令接口。
3. **需要证明时提供模型。** `proof.files` 依序拼接为 Lean 文件，应定义 `expectedWork : List (List Int) → List (List Nat)`。每个输出向量对应一个输入步骤，列次序由 `proof.metrics` 指定。`proof.inputs` 的 `int` 读取整数，`length` 读取字符串、数组或对象长度，`optional_symbol` 对相等类别编码为同一整数，缺失为零。`estimate` 只执行该模型；`trace --lean` 检查该模型在本次场景的每步工作量是否与独立记录一致。可在同一文件另写对任意输入成立的定理。有限场景的一致性和一般定理分别解读。

### 其他语言或复杂场景

选择 `adapter: "command"`，配置 `command` 参数数组。程序以配置目录为工作目录，`{python}` 表示运行工具的 Python。自定义运行器从标准输入读取 `{"source":"绝对路径","steps":[...],"options":{...}}`，正常退出时仅向标准输出写一份 JSON。下面是单步结果示例。

```json
{"locations":{"lookup":12},"steps":[{"counts":{"lookup":2},"path":[12,12],"output":7}]}
```

`locations` 给出每个工作指标在传入源码里的起始行，`counts` 为每个已声明指标给出非负整数，`path` 保留观察顺序，`output` 可省略。定义缺失、错误步数或非法计数会报错。对于跨文件的运行器，可以在路径事件内包含文件和行号。没有语句或证据时，适配器应报错或调整共同指标定义。配置、外部命令、源码和 Lean 模型均作为本机受信任的工程代码执行。

### 环境与验证

Python 分析使用标准库。GDScript 扫描和通用追踪使用 `gdtoolkit==4.5.0`，追踪还需要命令行可用的 Godot 4。可以在工具目录执行 `uv venv --python 3.11`，然后执行 `uv pip install --python .venv/bin/python gdtoolkit==4.5.0`。启动器会优先使用这里的 `.venv`。Windows 可用 `.venv\Scripts\python.exe` 替换上述 Python 路径，并用 `python perf-forecast` 启动。

C/C++ 扫描需要 Clang。使用 Lean 4 时，`--lean` 会读取 `PERF_FORECAST_LEAN` 或从命令搜索路径读取 `lean`。也可以用 `--lean /path/to/lean` 指定可执行文件。

```sh
python3 -B -m unittest -v
# 已安装可选依赖时，改用 .venv/bin/python 执行同一条命令
```

测试默认读取同一仓库的 Keynes 源码。如需验证另一份检出，可设置 `PERF_FORECAST_KEYNES`。

## 原有公式预测入口

`forecast.py` 保留原 JSON 请求格式。

```sh
python3 forecast.py examples/land.json
python3 forecast.py examples/calendar.json
python3 forecast.py examples/demand-memory.json
python3 forecast.py examples/catalog.json
python3 -m unittest -v
```

AI 可以把同样的 JSON 交给 `python3 forecast.py -` 的标准输入。成功时标准输出是 JSON，输入错误时退出码为 2。

## 写一个预测

从相似示例开始，在 `basis` 写清每个数来自哪行代码、哪次记录或什么假设。一个输入可填单个数或一组候选值。工具逐一组合各组候选值，同一组条件分别用于改前和改后。相互关联的假设请拆成独立请求。改前和改后各自变化的数量请使用不同的输入名。

- `cache` 模拟连续稳定 N 帧的同一幅底图。第一帧直接画，第二帧付一次建图成本并读图，其余帧复用。建图成本填两张图合计的额外时间；每帧共有的成本可以在两种绘制时间里都计入。输出包含开始净赚的最短稳定帧数。现实中稳定时长不同，应逐种时长计算，再按该类实际帧数加权。每次重建的平均间隔不能直接代替稳定时长分布。CPU 和 GPU 重叠时，预测屏幕帧时间需要真正影响显示的耗时。
- `gate` 模拟单个后台顺序结算，且每次绘制最多放行若干天。输出的是速度上限。`target` 超过上限时返回 `ruled_out`，未超过时返回 `not_ruled_out`。窗口帧率若也随改动而变化，需换相应条件或自定义模型。
- `repeat` 比较逐次准备数据与每批只准备一次。适用于同一批次中数据可以共享的情形。

## 加入新模型

`examples/demand-memory.json` 展示如何直接在请求里定义模型。填写指标和单位、数值变大还是变小更好、输入的取值要求，以及改前和改后公式。公式支持变量、常数、括号、四则运算和 min/max。定义新模型无需改 Python。公式两侧的单位和输入依据由建模者核对。

`improvement` 为按所选方向计算的绝对收益，正数代表改善。上限模型中的改善仅指上限的变化。`improvement_range` 只覆盖枚举的条件。`decision_sensitive_inputs` 列出在其他输入固定时，能改变快慢结论或目标判断的参数。`unsourced_inputs` 列出未填写依据的输入；标为示例假设的数值仍然是假设。工具不为假设分配概率。

地表示例中的毫秒数是演示用假设。日历示例使用 Keynes 旧窗口的约 24 帧/秒及每帧最多结算一天，后台耗时是假设值。内存示例基于该项目 100×64 四国地图的行数与行宽。历史数据见[功能状态](../../../docs/architecture/feature-status.md)中“96×64 四国开局的后台天气准备”和“稀疏经济需求缓存”。

## 按场景追踪源码与 Lean 检查

`scenario_trace.py` 是针对 Keynes 陆地缓存的实验入口。需要 Godot 4，数学检查可选。AI 可从标准输入传 JSON，用 `revision` 设定每帧的地图版本，用可选的 `tint` 改变地貌配色。省略配色时沿用上一帧。程序返回逐帧走到的观察点、源码行号、重建数与底图更新请求数。

```sh
python3 scenario_trace.py examples/cache-path.json \
  --source ../../../Project/project-keynes/scripts/rendering/land_base_cache.gd \
  --lean lean
```

可将 `lean` 替换为可执行文件的绝对路径，或省略整个 `--lean lean`。同一请求分别传入两个版本的源码，即可比较输出。工具在临时目录为提供的脚本副本加入观察点，通过无画面 Godot 执行实际的参数更新和绘制准备函数。驱动固定原生材质已配置、地图和视口可用、镜头及网格不变。输出只覆盖标记的动作；纹理更新表示提交请求。这里没有测量 GPU 绘制、材质编译或真实帧时间。

传入 Lean 时，工具用场景输入推导模型事件，并检查模型与独立从 Godot 记录的每帧重建次数、更新请求数一致。模型另有适用于任意长度稳定区间的证明。数学检查使用 Lean 4 核心库，已在 4.8.0 验证。GDScript 到模型的普遍等价性仍需单独证明。
